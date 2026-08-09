/**
 * Steered BRIEF descriptors: 256 bits per keypoint.
 *
 * A binary descriptor rather than a gradient histogram because the distance
 * between two of them is a XOR and a popcount. Matching is the quadratic step
 * in the whole pipeline — 2,000 features against 2,000 features is four million
 * comparisons per image pair — and the difference between 32 bytes of XOR and
 * 128 floats of Euclidean distance decides whether a hundred-image set matches
 * in seconds or in minutes.
 */

import { sampleGrayBilinear, type PyramidLevel } from './image.ts';
import type { Keypoint } from './detect.ts';

/** Bits per descriptor. 256 is BRIEF-256 / ORB's size. */
export const DESCRIPTOR_BITS = 256;
export const DESCRIPTOR_BYTES = DESCRIPTOR_BITS / 8;

/** Side of the square patch the sampling pairs live in. */
const PATCH_SIZE = 31;

/**
 * Deterministic sampling pairs, drawn once from an isotropic Gaussian.
 *
 * BRIEF's paper found this distribution — sigma = S^2/25 over an SxS patch —
 * to be the best of the five it tried. ORB improves on it with a *learned* set
 * of 256 pairs, greedily selected for high variance and low mutual correlation
 * over a training corpus. That table is a specific list of 512 integers, and
 * reproducing it from memory is exactly the kind of thing that would silently
 * be a slightly different table that still almost works, so this uses BRIEF's
 * distribution honestly rather than claiming ORB's.
 *
 * The practical cost is some correlation between bits, which makes the
 * effective descriptor length shorter than 256 and pushes the ratio test a
 * little. The geometric verification downstream absorbs it.
 */
function buildSamplingPairs(): Int8Array {
  const pairs = new Int8Array(DESCRIPTOR_BITS * 4);
  // Fixed seed: the same image must always produce the same descriptor, or a
  // capture re-processed tomorrow would not match one processed today.
  let state = 0x2545f491;
  const nextUniform = (): number => {
    // xorshift32. Small, deterministic, and the statistical quality needed here
    // is "not visibly patterned", which it comfortably clears.
    state ^= state << 13;
    state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    return state / 0x100000000;
  };

  const sigma = (PATCH_SIZE * PATCH_SIZE) / 25;
  const limit = (PATCH_SIZE - 1) / 2;

  const nextGaussian = (): number => {
    // Box-Muller. Only the first of the two outputs is used; the second is
    // discarded rather than cached, because caching it would couple successive
    // coordinates in a way that shows up as diagonal structure in the pairs.
    const u = Math.max(nextUniform(), Number.MIN_VALUE);
    const v = nextUniform();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  };

  const nextOffset = (): number => {
    for (;;) {
      const value = Math.round(nextGaussian() * Math.sqrt(sigma) * 0.35);
      if (value >= -limit && value <= limit) return value;
    }
  };

  for (let i = 0; i < DESCRIPTOR_BITS; i += 1) {
    let ax = 0;
    let ay = 0;
    let bx = 0;
    let by = 0;
    // Reject degenerate pairs: a pair that samples the same pixel twice always
    // yields the same bit and carries no information at all.
    do {
      ax = nextOffset();
      ay = nextOffset();
      bx = nextOffset();
      by = nextOffset();
    } while (ax === bx && ay === by);

    pairs[i * 4] = ax;
    pairs[i * 4 + 1] = ay;
    pairs[i * 4 + 2] = bx;
    pairs[i * 4 + 3] = by;
  }

  return pairs;
}

const SAMPLING_PAIRS = buildSamplingPairs();

/** The sampling pairs, for tests and for anyone wanting to inspect them. */
export function samplingPairs(): Int8Array {
  return SAMPLING_PAIRS;
}

/**
 * Describe one keypoint. Returns 32 bytes.
 *
 * The pairs are rotated by the keypoint's orientation before sampling — this is
 * the "steered" part, and it is the only thing making the descriptor invariant
 * to camera roll. Without it, two photos of the same wall taken with the phone
 * held at different angles share almost no matches, which on a site is the
 * normal case rather than an edge case.
 */
export function describeKeypoint(
  level: PyramidLevel,
  keypoint: Keypoint,
  out = new Uint8Array(DESCRIPTOR_BYTES),
): Uint8Array {
  const cos = Math.cos(keypoint.angle);
  const sin = Math.sin(keypoint.angle);

  // Keypoint coordinates are stored at level 0; sampling happens at its level.
  const cx = keypoint.x / keypoint.scale;
  const cy = keypoint.y / keypoint.scale;

  out.fill(0);

  for (let i = 0; i < DESCRIPTOR_BITS; i += 1) {
    const ax = SAMPLING_PAIRS[i * 4];
    const ay = SAMPLING_PAIRS[i * 4 + 1];
    const bx = SAMPLING_PAIRS[i * 4 + 2];
    const by = SAMPLING_PAIRS[i * 4 + 3];

    const rax = ax * cos - ay * sin;
    const ray = ax * sin + ay * cos;
    const rbx = bx * cos - by * sin;
    const rby = bx * sin + by * cos;

    // Bilinear, not nearest: rotated offsets land between pixels, and rounding
    // them makes the descriptor change in steps as the patch rotates, which is
    // precisely the invariance the steering is there to provide.
    const a = sampleGrayBilinear(level.image, cx + rax, cy + ray);
    const b = sampleGrayBilinear(level.image, cx + rbx, cy + rby);

    if (a < b) out[i >> 3] |= 1 << (i & 7);
  }

  return out;
}

/** A packed set of descriptors: `count` rows of `DESCRIPTOR_BYTES`. */
export interface DescriptorSet {
  count: number;
  data: Uint8Array;
}

export function describeKeypoints(
  pyramid: PyramidLevel[],
  keypoints: Keypoint[],
): DescriptorSet {
  const data = new Uint8Array(keypoints.length * DESCRIPTOR_BYTES);
  const scratch = new Uint8Array(DESCRIPTOR_BYTES);

  for (let i = 0; i < keypoints.length; i += 1) {
    describeKeypoint(pyramid[keypoints[i].level], keypoints[i], scratch);
    data.set(scratch, i * DESCRIPTOR_BYTES);
  }

  return { count: keypoints.length, data };
}

/** Popcount of each byte value, so Hamming distance is 32 table lookups. */
const POPCOUNT = (() => {
  const table = new Uint8Array(256);
  for (let i = 0; i < 256; i += 1) {
    table[i] = (i & 1) + table[i >> 1];
  }
  return table;
})();

/** Hamming distance between descriptor `i` of `a` and descriptor `j` of `b`. */
export function hammingDistance(
  a: Uint8Array,
  aIndex: number,
  b: Uint8Array,
  bIndex: number,
): number {
  const pa = aIndex * DESCRIPTOR_BYTES;
  const pb = bIndex * DESCRIPTOR_BYTES;
  let distance = 0;
  for (let byte = 0; byte < DESCRIPTOR_BYTES; byte += 1) {
    distance += POPCOUNT[a[pa + byte] ^ b[pb + byte]];
  }
  return distance;
}
