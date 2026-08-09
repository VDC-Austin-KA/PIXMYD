/**
 * Descriptor matching, and the filters that make the result usable.
 *
 * Raw nearest-neighbour matching between two images always returns a match for
 * every feature, including features that appear in only one of them. The
 * filters below exist because structure-from-motion is not robust to a
 * correspondence set that is mostly wrong: a handful of consistent outliers will
 * drag an essential matrix to a plausible, entirely fictional relative pose.
 */

import { DESCRIPTOR_BITS, hammingDistance, type DescriptorSet } from './descriptor.ts';
import type { Keypoint } from './detect.ts';

export interface Match {
  /** Index into the first image's keypoints. */
  a: number;
  /** Index into the second image's keypoints. */
  b: number;
  /** Hamming distance, 0 to 256. */
  distance: number;
}

export interface MatchOptions {
  /**
   * Lowe's ratio. A match is kept only if the best distance is less than this
   * fraction of the second-best.
   */
  ratio?: number;
  /** Reject anything above this Hamming distance outright. */
  maxDistance?: number;
  /** Require the match to be mutual. */
  crossCheck?: boolean;
}

/**
 * Brute-force match with the ratio test.
 *
 * Lowe's ratio test is the single most valuable filter here, and the reasoning
 * is worth stating: a correct match is usually *distinctly* better than every
 * alternative, whereas a feature with no true correspondence — a window mullion
 * on a facade of identical windows — has many near-equal candidates. Comparing
 * the best against the second best asks "is this unambiguous", which is a much
 * better question than "is this close", because absolute descriptor distance
 * varies with texture and exposure.
 *
 * 0.8 is Lowe's figure for SIFT. Binary descriptors are noisier, so the default
 * here is 0.75 — tighter, keeping fewer and better matches, on the reasoning
 * that a construction scene is full of repeated geometry that the ratio test is
 * the only thing standing against.
 */
export function matchDescriptors(
  a: DescriptorSet,
  b: DescriptorSet,
  options: MatchOptions = {},
): Match[] {
  const ratio = options.ratio ?? 0.75;
  const maxDistance = options.maxDistance ?? DESCRIPTOR_BITS;
  const crossCheck = options.crossCheck ?? true;

  const forward = nearestNeighbours(a, b, ratio, maxDistance);
  if (!crossCheck) return forward;

  // Cross-check: b's best match for the candidate must be a. This removes the
  // asymmetry in nearest-neighbour matching, where several features in one
  // image can all claim the same feature in the other — at most one of them can
  // be right, and without this all of them survive.
  const reverse = new Int32Array(b.count).fill(-1);
  for (let j = 0; j < b.count; j += 1) {
    let best = Number.POSITIVE_INFINITY;
    let bestIndex = -1;
    for (let i = 0; i < a.count; i += 1) {
      const distance = hammingDistance(b.data, j, a.data, i);
      if (distance < best) {
        best = distance;
        bestIndex = i;
      }
    }
    reverse[j] = bestIndex;
  }

  return forward.filter((match) => reverse[match.b] === match.a);
}

function nearestNeighbours(
  a: DescriptorSet,
  b: DescriptorSet,
  ratio: number,
  maxDistance: number,
): Match[] {
  const matches: Match[] = [];

  for (let i = 0; i < a.count; i += 1) {
    let best = Number.POSITIVE_INFINITY;
    let second = Number.POSITIVE_INFINITY;
    let bestIndex = -1;

    for (let j = 0; j < b.count; j += 1) {
      const distance = hammingDistance(a.data, i, b.data, j);
      if (distance < best) {
        second = best;
        best = distance;
        bestIndex = j;
      } else if (distance < second) {
        second = distance;
      }
    }

    if (bestIndex < 0 || best > maxDistance) continue;
    // With fewer than two candidates there is no ratio to test, and letting the
    // match through unchecked would mean a two-feature image matches perfectly.
    if (!Number.isFinite(second)) continue;
    if (best >= ratio * second) continue;

    matches.push({ a: i, b: bestIndex, distance: best });
  }

  return matches;
}

/**
 * Match, then filter the survivors by whether their motion agrees with their
 * neighbours'.
 *
 * This is a cheap stand-in for full geometric verification and runs before it.
 * True correspondences between two views of a rigid scene move coherently:
 * nearby features shift by similar amounts. A mismatch usually does not. Taking
 * the median shift and discarding anything far from it removes gross outliers
 * for a fraction of a RANSAC's cost, which matters when the caller is about to
 * run one on every pair in a hundred-image set.
 *
 * It is deliberately loose. Parallax on a deep scene is real motion that
 * disagrees with the median, and throwing that away would remove exactly the
 * observations that make the reconstruction well conditioned.
 */
/**
 * Absolute allowance on top of the robust spread, in level-0 pixels. A corner's
 * position is only ever localised to a pixel or two, and a pyramid keypoint at
 * a coarse level rather less than that.
 */
const LOCALISATION_NOISE_PX = 2;

export function filterByMotionConsistency(
  matches: Match[],
  keypointsA: Keypoint[],
  keypointsB: Keypoint[],
  tolerance = 3,
): Match[] {
  if (matches.length < 8) return matches;

  const dx = matches.map((m) => keypointsB[m.b].x - keypointsA[m.a].x);
  const dy = matches.map((m) => keypointsB[m.b].y - keypointsA[m.a].y);

  const medianX = median(dx);
  const medianY = median(dy);

  // Median absolute deviation, scaled to be a standard-deviation equivalent for
  // a normal distribution. Robust: the mean and standard deviation of a set
  // containing outliers are themselves dragged by those outliers, which is how
  // an outlier filter ends up keeping the outliers and cutting the good data.
  const deviations = matches.map((_, i) =>
    Math.hypot(dx[i] - medianX, dy[i] - medianY),
  );
  const mad = median(deviations) * 1.4826;

  // The floor is added, not maxed, and it is not cosmetic. A set can have a MAD
  // of exactly zero — a planar scene under pure translation, where every true
  // match shifts by the identical amount — and returning early on that case
  // means a match that moved 60 px against a perfectly uniform crowd is kept,
  // which is the most obvious outlier there is. Adding a small absolute
  // allowance instead keeps the filter meaningful at zero spread while still
  // tolerating the couple of pixels of localisation noise a detector has.
  const limit = tolerance * mad + LOCALISATION_NOISE_PX;
  return matches.filter((_, i) => deviations[i] <= limit);
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}
