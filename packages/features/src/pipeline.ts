/**
 * The bridge from images to the correspondences `@pixmyd/sfm` consumes.
 *
 * Everything above this file works in pixels; everything below it works in
 * normalized camera coordinates. This is where the intrinsics are divided out
 * and where a match set stops being "descriptors that looked similar" and
 * becomes "observations consistent with a single rigid motion".
 */

import {
  estimateEssential,
  sampsonDistance,
  type Correspondence,
  type Vec2,
} from '@pixmyd/sfm/geometry';
import type { CameraModel } from '@pixmyd/core/bundle';

import { buildPyramid, type GrayImage, type PyramidOptions } from './image.ts';
import { detectKeypoints, type DetectOptions, type Keypoint } from './detect.ts';
import { describeKeypoints, type DescriptorSet } from './descriptor.ts';
import { filterByMotionConsistency, matchDescriptors, type Match, type MatchOptions } from './match.ts';

/** Everything found in one image, ready to be matched against another. */
export interface ImageFeatures {
  keypoints: Keypoint[];
  descriptors: DescriptorSet;
  width: number;
  height: number;
}

export interface ExtractOptions extends DetectOptions, PyramidOptions {}

export function extractFeatures(image: GrayImage, options: ExtractOptions = {}): ImageFeatures {
  const pyramid = buildPyramid(image, options);
  const keypoints = detectKeypoints(pyramid, options);
  return {
    keypoints,
    descriptors: describeKeypoints(pyramid, keypoints),
    width: image.width,
    height: image.height,
  };
}

/**
 * Undo the intrinsics: pixels to normalized camera coordinates.
 *
 * Distortion is inverted iteratively because the Brown-Conrady model is defined
 * forwards — undistorted to distorted — and has no closed-form inverse. The
 * fixed-point iteration below runs to convergence rather than a fixed small
 * count; a fisheye takes the equidistant branch instead, by Newton on theta.
 */
export function normalizePixel(camera: CameraModel, pixel: Vec2): Vec2 | null {
  if (camera.model === 'pinhole') {
    const x = (pixel.x - camera.cx) / camera.fx;
    const y = (pixel.y - camera.cy) / camera.fy;

    const k1 = camera.k1 ?? 0;
    const k2 = camera.k2 ?? 0;
    const k3 = camera.k3 ?? 0;
    const p1 = camera.p1 ?? 0;
    const p2 = camera.p2 ?? 0;
    if (k1 === 0 && k2 === 0 && k3 === 0 && p1 === 0 && p2 === 0) return { x, y };

    let ux = x;
    let uy = y;
    for (let i = 0; i < 20; i += 1) {
      const r2 = ux * ux + uy * uy;
      const radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3));
      const tangentialX = 2 * p1 * ux * uy + p2 * (r2 + 2 * ux * ux);
      const tangentialY = p1 * (r2 + 2 * uy * uy) + 2 * p2 * ux * uy;
      const nx = (x - tangentialX) / radial;
      const ny = (y - tangentialY) / radial;
      const step = Math.abs(nx - ux) + Math.abs(ny - uy);
      ux = nx;
      uy = ny;
      // A hundredth of a pixel on a 1450 px focal length. The iteration count
      // is 20 rather than the 5 that is often quoted because 5 is only enough
      // for mild distortion: measured against the forward model, a k1 of -0.28
      // at the corner of a 1920x1440 frame is still 0.13 px out after five
      // passes and reaches machine precision at about ten.
      if (step < 1e-5 / 1450) break;
    }
    return { x: ux, y: uy };
  }

  if (camera.model === 'fisheye') {
    // Equidistant: r_distorted = theta * (1 + k1 th^2 + k2 th^4 + ...).
    const mx = (pixel.x - camera.cx) / camera.fx;
    const my = (pixel.y - camera.cy) / camera.fy;
    const rd = Math.hypot(mx, my);
    if (rd < 1e-12) return { x: 0, y: 0 };

    const k1 = camera.k1 ?? 0;
    const k2 = camera.k2 ?? 0;
    const k3 = camera.k3 ?? 0;
    const k4 = camera.k4 ?? 0;

    let theta = rd;
    for (let i = 0; i < 10; i += 1) {
      const t2 = theta * theta;
      const t4 = t2 * t2;
      const t6 = t4 * t2;
      const t8 = t4 * t4;
      const f = theta * (1 + k1 * t2 + k2 * t4 + k3 * t6 + k4 * t8) - rd;
      const df = 1 + 3 * k1 * t2 + 5 * k2 * t4 + 7 * k3 * t6 + 9 * k4 * t8;
      if (Math.abs(df) < 1e-12) break;
      theta -= f / df;
    }

    // Past 90 degrees the ray points behind the camera, and a normalized
    // coordinate — which is x/z — is meaningless there. The pinhole-based
    // geometry downstream cannot represent it, so the point is dropped rather
    // than folded to the front of the camera as a plausible wrong answer.
    if (theta >= Math.PI / 2 - 1e-6) return null;

    const scale = Math.tan(theta) / rd;
    return { x: mx * scale, y: my * scale };
  }

  // Equirectangular. Same caveat: only the forward hemisphere is representable.
  const longitude = ((pixel.x + 0.5) / camera.width - 0.5) * 2 * Math.PI;
  const latitude = (0.5 - (pixel.y + 0.5) / camera.height) * Math.PI;
  const z = Math.cos(latitude) * Math.cos(longitude);
  if (z <= 1e-6) return null;
  return {
    x: (Math.cos(latitude) * Math.sin(longitude)) / z,
    y: -Math.sin(latitude) / z,
  };
}

export interface VerifiedMatches {
  /** Matches that survived geometric verification. */
  matches: Match[];
  /** The same matches as normalized correspondences, in the same order. */
  correspondences: Correspondence[];
  /** The essential matrix the inliers agree on, row-major. */
  essential: number[];
  /** Fraction of the input matches that survived. */
  inlierRatio: number;
  /** Conditioning of the final solve; low means the motion is degenerate. */
  conditioning: number;
}

export interface VerifyOptions {
  /**
   * Inlier threshold in **pixels** of Sampson error. Converted per camera using
   * its focal length, so the same number means the same thing on a wide lens
   * and a long one.
   */
  thresholdPx?: number;
  iterations?: number;
  /** Seed, so a rerun of the same capture produces the same reconstruction. */
  seed?: number;
}

/**
 * Pixels per normalized unit for a camera — its focal length, generalised.
 *
 * A normalized coordinate is x/z, so near the optical axis one unit is one
 * radian, and this is the factor converting an angular error into a pixel one.
 * For an equirectangular image there is no focal length: the whole 2*pi of
 * longitude maps across the width, so the same factor is width / (2*pi).
 */
function focalScale(camera: CameraModel): number {
  if (camera.model === 'equirect') return camera.width / (2 * Math.PI);
  return (camera.fx + camera.fy) / 2;
}

/**
 * RANSAC on the essential matrix.
 *
 * The threshold is given in pixels and converted to normalized units per
 * camera, which is the only form that behaves the same on a 24 mm lens, a
 * 77 mm lens and a panorama.
 *
 * Note the squaring. `sampsonDistance` returns the **squared** distance, so a
 * threshold used against it directly is the square of what it appears to be —
 * a "0.001" that looks tight is 0.032 normalized, which on a 300 px focal
 * length is nine pixels of slack and leaves RANSAC with nothing to discriminate
 * on. It quietly returns a pose built from whatever it sampled.
 *
 * Deterministic by construction: the sampler is seeded. Reprocessing the same
 * capture and getting a different answer would make it impossible to tell a
 * genuine improvement from RANSAC's luck.
 */
export function verifyMatches(
  matches: Match[],
  keypointsA: Keypoint[],
  keypointsB: Keypoint[],
  cameraA: CameraModel,
  cameraB: CameraModel,
  options: VerifyOptions = {},
): VerifiedMatches | null {
  // Two pixels: enough for a corner's localisation error and for the couple of
  // tenths a coarse pyramid level adds, tight enough that a mismatch fails.
  const thresholdPx = options.thresholdPx ?? 2;
  const iterations = options.iterations ?? 512;

  // Sampson is symmetric across the pair, so the error budget is shared; using
  // the mean of the two cameras' scales rather than either one keeps the
  // threshold meaningful when a phone frame is matched against a drone frame.
  const scale = (focalScale(cameraA) + focalScale(cameraB)) / 2;
  const thresholdSquared = (thresholdPx / scale) ** 2;

  // Normalize once. Matches whose pixel cannot be normalized — behind a fisheye
  // or over the horizon of a panorama — drop out here rather than becoming
  // silent garbage in the solve.
  const usable: Match[] = [];
  const points: Correspondence[] = [];
  for (const match of matches) {
    const a = normalizePixel(cameraA, keypointsA[match.a]);
    const b = normalizePixel(cameraB, keypointsB[match.b]);
    if (!a || !b) continue;
    usable.push(match);
    points.push({ a, b });
  }

  if (points.length < 8) return null;

  let state = (options.seed ?? 0x9e3779b9) >>> 0;
  const nextIndex = (limit: number): number => {
    state ^= state << 13;
    state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    return state % limit;
  };

  let bestInliers: number[] = [];

  for (let iteration = 0; iteration < iterations; iteration += 1) {
    const sampleIndices = new Set<number>();
    let guard = 0;
    while (sampleIndices.size < 8 && guard < 100) {
      sampleIndices.add(nextIndex(points.length));
      guard += 1;
    }
    if (sampleIndices.size < 8) continue;

    const sample = [...sampleIndices].map((index) => points[index]);
    let candidate: ReturnType<typeof estimateEssential>;
    try {
      candidate = estimateEssential(sample);
    } catch {
      continue;
    }
    if (candidate.degenerate) continue;

    const inliers: number[] = [];
    for (let i = 0; i < points.length; i += 1) {
      if (sampsonDistance(candidate.matrix, points[i].a, points[i].b) < thresholdSquared) {
        inliers.push(i);
      }
    }

    if (inliers.length > bestInliers.length) bestInliers = inliers;
  }

  if (bestInliers.length < 8) return null;

  // Refit on all inliers. The eight-point sample that won is the one that got
  // lucky on eight points, not the best fit to the hundreds it agrees with.
  const inlierPoints = bestInliers.map((index) => points[index]);
  const refit = estimateEssential(inlierPoints);

  // Re-score against the refit model: a few points that were outliers to the
  // sample are inliers to the better estimate, and dropping them loses real
  // observations.
  const finalIndices: number[] = [];
  for (let i = 0; i < points.length; i += 1) {
    if (sampsonDistance(refit.matrix, points[i].a, points[i].b) < thresholdSquared) {
      finalIndices.push(i);
    }
  }

  const indices = finalIndices.length >= bestInliers.length ? finalIndices : bestInliers;

  return {
    matches: indices.map((index) => usable[index]),
    correspondences: indices.map((index) => points[index]),
    essential: refit.matrix,
    inlierRatio: matches.length > 0 ? indices.length / matches.length : 0,
    conditioning: refit.conditioning,
  };
}

export interface PairOptions extends MatchOptions, VerifyOptions {
  /** Skip the cheap motion-consistency pre-filter. */
  skipMotionFilter?: boolean;
}

/**
 * Match two already-extracted feature sets and verify the result geometrically.
 *
 * Returns null when the pair does not share a view — which is the common case
 * in a capture of a hundred images, where most pairs genuinely have nothing in
 * common and the honest answer is "no overlap" rather than a pose.
 */
export function matchImagePair(
  a: ImageFeatures,
  b: ImageFeatures,
  cameraA: CameraModel,
  cameraB: CameraModel,
  options: PairOptions = {},
): VerifiedMatches | null {
  let matches = matchDescriptors(a.descriptors, b.descriptors, options);
  if (!options.skipMotionFilter) {
    matches = filterByMotionConsistency(matches, a.keypoints, b.keypoints);
  }
  if (matches.length < 8) return null;
  return verifyMatches(matches, a.keypoints, b.keypoints, cameraA, cameraB, options);
}
