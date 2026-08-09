/**
 * FAST corner detection, Harris scoring, and intensity-centroid orientation.
 *
 * This is the ORB front end (Rublee et al., 2011), chosen over SIFT for a
 * reason that is about the field rather than about accuracy: it is roughly two
 * orders of magnitude faster, and everything here has to run in a browser tab on
 * a laptop in a site trailer, on hundreds of images, with no server. SIFT's
 * patent expired in 2020 so it is legally usable now, but its cost is real and
 * PIXMYD has pose priors from IMU and GNSS that a general-purpose matcher does
 * not get to assume.
 */

import { sampleGray, type GrayImage, type PyramidLevel } from './image.ts';

export interface Keypoint {
  /** Position in level-0 pixels, subpixel where refinement succeeded. */
  x: number;
  y: number;
  /** Harris corner response. Higher is a stronger, better-localised corner. */
  score: number;
  /** Orientation in radians, from the intensity centroid. */
  angle: number;
  /** Pyramid level the keypoint was found at. */
  level: number;
  /** Level-0 scale of that level, so a descriptor can size its patch. */
  scale: number;
}

/**
 * The Bresenham circle of radius 3 that FAST tests, 16 pixels, in order.
 * The order matters — the contiguity test below walks it.
 */
const CIRCLE: ReadonlyArray<readonly [number, number]> = [
  [0, -3], [1, -3], [2, -2], [3, -1],
  [3, 0], [3, 1], [2, 2], [1, 3],
  [0, 3], [-1, 3], [-2, 2], [-3, 1],
  [-3, 0], [-3, -1], [-2, -2], [-1, -3],
];

/** Contiguous arc length FAST requires. 9 of 16 is the standard choice. */
const ARC = 9;

/**
 * How many of the four compass points (circle indices 0, 4, 8, 12) an arc of
 * `ARC` contiguous pixels must contain.
 *
 * The compass points are spaced four apart, so a window of `ARC` consecutive
 * indices contains at least `floor(ARC / 4)` of them. For FAST-9 that is **2**.
 * The widely quoted "at least 3 of 4" shortcut is the FAST-**12** bound, and
 * using it for a 9-arc makes the early rejection unsound: it throws away real
 * corners before the full test ever runs. A right-angled corner presents 11
 * dark circle pixels and exactly two dark compass points, so requiring three
 * rejects the most common corner in architecture outright.
 */
const MIN_COMPASS = Math.floor(ARC / 4);

export interface DetectOptions {
  /** Intensity difference from the centre that counts as brighter or darker. */
  threshold?: number;
  /** Keep at most this many keypoints, strongest first. */
  maxKeypoints?: number;
  /** Suppress keypoints within this radius of a stronger one, in level pixels. */
  suppressionRadius?: number;
  /** Harris k. 0.04 is the value from the original paper. */
  harrisK?: number;
}

/**
 * Is there an arc of `ARC` contiguous circle pixels all brighter than
 * `centre + threshold`, or all darker than `centre - threshold`?
 *
 * The early rejection on pixels 0, 4, 8 and 12 is not an optimisation detail —
 * it is what makes FAST fast. An arc of 9 must contain at least `MIN_COMPASS`
 * of those four, so if fewer agree in sign the full test cannot possibly pass,
 * and the overwhelming majority of pixels in any image fail here.
 */
function isCorner(image: GrayImage, x: number, y: number, threshold: number): boolean {
  const centre = image.data[y * image.width + x];
  const high = centre + threshold;
  const low = centre - threshold;

  let brighter = 0;
  let darker = 0;
  for (const index of [0, 4, 8, 12]) {
    const value = sampleGray(image, x + CIRCLE[index][0], y + CIRCLE[index][1]);
    if (value > high) brighter += 1;
    else if (value < low) darker += 1;
  }
  if (brighter < MIN_COMPASS && darker < MIN_COMPASS) return false;

  // Walk the circle twice so an arc that wraps past index 15 is still seen as
  // contiguous. Stopping at 16 would miss every corner whose arc straddles the
  // start of the array, which is one in sixteen of them.
  let runBrighter = 0;
  let runDarker = 0;
  for (let i = 0; i < 16 + ARC; i += 1) {
    const [dx, dy] = CIRCLE[i % 16];
    const value = sampleGray(image, x + dx, y + dy);

    if (value > high) {
      runBrighter += 1;
      runDarker = 0;
    } else if (value < low) {
      runDarker += 1;
      runBrighter = 0;
    } else {
      runBrighter = 0;
      runDarker = 0;
    }

    if (runBrighter >= ARC || runDarker >= ARC) return true;
  }
  return false;
}

/**
 * Harris response over a 7x7 window.
 *
 * FAST answers "is this a corner" with a yes or no, which gives no way to rank
 * one corner against another, and ranking is the whole game once there are
 * thousands of them and a budget of hundreds. Harris also demotes points along
 * an edge that squeaked past the arc test — those have a well-defined position
 * in one direction only, and matching them produces correspondences that slide.
 */
export function harrisResponse(image: GrayImage, x: number, y: number, k = 0.04): number {
  let ixx = 0;
  let iyy = 0;
  let ixy = 0;

  for (let dy = -3; dy <= 3; dy += 1) {
    for (let dx = -3; dx <= 3; dx += 1) {
      const px = x + dx;
      const py = y + dy;
      // Central differences; the /2 is folded into the products as /4.
      const gx = sampleGray(image, px + 1, py) - sampleGray(image, px - 1, py);
      const gy = sampleGray(image, px, py + 1) - sampleGray(image, px, py - 1);
      ixx += gx * gx;
      iyy += gy * gy;
      ixy += gx * gy;
    }
  }

  ixx /= 4;
  iyy /= 4;
  ixy /= 4;

  const determinant = ixx * iyy - ixy * ixy;
  const trace = ixx + iyy;
  return determinant - k * trace * trace;
}

/**
 * Orientation from the intensity centroid over a radius-15 disc.
 *
 * The vector from the patch centre to its intensity centroid gives an angle
 * that rotates with the patch, which is what makes the binary descriptor below
 * rotation-invariant. A disc rather than a square: a square window's corners
 * enter and leave as the patch rotates, so the "same" patch at 45 degrees would
 * be measured over different pixels and report a different angle.
 */
export function intensityCentroidAngle(image: GrayImage, x: number, y: number, radius = 15): number {
  let m01 = 0;
  let m10 = 0;
  const r2 = radius * radius;

  for (let dy = -radius; dy <= radius; dy += 1) {
    const span = Math.floor(Math.sqrt(r2 - dy * dy));
    for (let dx = -span; dx <= span; dx += 1) {
      const value = sampleGray(image, x + dx, y + dy);
      m10 += dx * value;
      m01 += dy * value;
    }
  }

  return Math.atan2(m01, m10);
}

/** FAST + Harris on one image, with non-maximum suppression. */
export function detectCorners(
  image: GrayImage,
  options: DetectOptions = {},
): Array<{ x: number; y: number; score: number }> {
  const threshold = options.threshold ?? 20;
  const harrisK = options.harrisK ?? 0.04;
  const radius = options.suppressionRadius ?? 3;

  // The border is what the radius-3 circle and the 7x7 Harris window need. A
  // detector that runs to the edge and clamps its reads reports corners on the
  // image border itself, where the clamped rows form a perfect step edge.
  const border = 4;
  const found: Array<{ x: number; y: number; score: number }> = [];

  for (let y = border; y < image.height - border; y += 1) {
    for (let x = border; x < image.width - border; x += 1) {
      if (!isCorner(image, x, y, threshold)) continue;
      const score = harrisResponse(image, x, y, harrisK);
      if (score <= 0) continue;
      found.push({ x, y, score });
    }
  }

  return suppressNonMaxima(found, radius, image.width);
}

/**
 * Keep the strongest corner in each neighbourhood.
 *
 * FAST fires on every pixel of a corner's neighbourhood, so a single physical
 * corner arrives as a blob of twenty detections. Left in, they waste the
 * keypoint budget and — worse — produce twenty near-identical descriptors that
 * make every ratio test around that corner fail, deleting a good feature.
 *
 * Bucketed by a grid of the suppression radius so this is linear in the number
 * of detections rather than quadratic; at 40,000 raw corners the difference is
 * seconds per image.
 */
function suppressNonMaxima(
  points: Array<{ x: number; y: number; score: number }>,
  radius: number,
  width: number,
): Array<{ x: number; y: number; score: number }> {
  if (radius <= 0) return points;

  const cell = radius;
  const columns = Math.ceil(width / cell) + 1;
  const buckets = new Map<number, Array<{ x: number; y: number; score: number }>>();

  const sorted = [...points].sort((a, b) => b.score - a.score);
  const kept: Array<{ x: number; y: number; score: number }> = [];
  const r2 = radius * radius;

  for (const point of sorted) {
    const cx = Math.floor(point.x / cell);
    const cy = Math.floor(point.y / cell);

    let blocked = false;
    for (let gy = cy - 1; gy <= cy + 1 && !blocked; gy += 1) {
      for (let gx = cx - 1; gx <= cx + 1 && !blocked; gx += 1) {
        const bucket = buckets.get(gy * columns + gx);
        if (!bucket) continue;
        for (const other of bucket) {
          const dx = other.x - point.x;
          const dy = other.y - point.y;
          if (dx * dx + dy * dy < r2) {
            blocked = true;
            break;
          }
        }
      }
    }
    if (blocked) continue;

    kept.push(point);
    const key = cy * columns + cx;
    const bucket = buckets.get(key);
    if (bucket) bucket.push(point);
    else buckets.set(key, [point]);
  }

  return kept;
}

/**
 * Detect across a pyramid, returning keypoints in level-0 coordinates.
 *
 * The budget is spread across levels in proportion to each level's area, which
 * is how ORB allocates it. Taking the globally strongest N instead would fill
 * the entire budget from level 0, because Harris response falls with blur, and
 * a feature set with no coarse levels cannot match across a scale change.
 */
export function detectKeypoints(pyramid: PyramidLevel[], options: DetectOptions = {}): Keypoint[] {
  const maxKeypoints = options.maxKeypoints ?? 2000;
  const areas = pyramid.map((level) => level.image.width * level.image.height);
  const totalArea = areas.reduce((sum, area) => sum + area, 0);

  const keypoints: Keypoint[] = [];

  for (let level = 0; level < pyramid.length; level += 1) {
    const { image, scale } = pyramid[level];
    const budget = Math.max(1, Math.round((maxKeypoints * areas[level]) / totalArea));

    const corners = detectCorners(image, options);
    corners.sort((a, b) => b.score - a.score);

    for (const corner of corners.slice(0, budget)) {
      keypoints.push({
        x: corner.x * scale,
        y: corner.y * scale,
        score: corner.score,
        angle: intensityCentroidAngle(image, corner.x, corner.y),
        level,
        scale,
      });
    }
  }

  keypoints.sort((a, b) => b.score - a.score);
  return keypoints.slice(0, maxKeypoints);
}
