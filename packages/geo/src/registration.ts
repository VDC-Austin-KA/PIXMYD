/**
 * Rigid registration: putting a capture in the right place, and stating how
 * wrong it is.
 *
 * Producing a transform is the easy half. The half that matters is the error
 * figure that goes on screen next to it. A capture registered to survey control
 * is unusually persuasive — it *looks* authoritative because it lines up with
 * the world — and the failure mode is a fitter trusting a 200 mm error because
 * the graphics were crisp.
 *
 * The method is Horn's closed-form absolute orientation via unit quaternions
 * (Horn, JOSA A 4(4), 1987). Given N >= 3 non-collinear correspondences it
 * returns the rotation and translation minimising squared residual, with no
 * iteration and no local minima.
 *
 * Scale is estimated but **off by default**, deliberately. A survey control
 * network and a LiDAR capture are both metric and true; if solving for scale
 * improves the fit, the improvement is almost certainly absorbing tracking
 * drift rather than correcting a real unit error — which hides the very error
 * the user needs to see. Turn it on to diagnose a unit mismatch at ingest, and
 * turn it back off.
 */

import { mat4, quat, v3, type Mat4, type Quat, type Vec3 } from '@pixmyd/core/math';

export interface ControlPair {
  /** Surveyed position in project coordinates, metres. */
  project: Vec3;
  /** The same point as measured in the capture's own frame, metres. */
  observed: Vec3;
  id?: string;
  /** 1-sigma survey accuracy, metres. Weights the solve when present. */
  sigma?: number;
}

export interface Residual {
  id?: string;
  error: number;
  /** Component residuals, useful for spotting a systematic axis problem. */
  delta: Vec3;
}

export interface RigidSolution {
  rotation: Quat;
  translation: Vec3;
  scale: number;
  /** Column-major 4x4 taking observed coordinates to project coordinates. */
  matrix: Mat4;
  rmsError: number;
  maxError: number;
  residuals: Residual[];
  pairCount: number;
  /** The input pairs, so leave-one-out diagnostics can refit without them. */
  pairs: ControlPair[];
}

export interface SolveOptions {
  /** Default false. See the module note. */
  estimateScale?: boolean;
  /** Weight each pair by 1/sigma^2 when sigma is present. Default true. */
  useWeights?: boolean;
}

function weightedCentroid(points: Vec3[], weights: number[]): Vec3 {
  let total = 0;
  const c: Vec3 = [0, 0, 0];
  for (let i = 0; i < points.length; i++) {
    const w = weights[i];
    c[0] += points[i][0] * w;
    c[1] += points[i][1] * w;
    c[2] += points[i][2] * w;
    total += w;
  }
  return [c[0] / total, c[1] / total, c[2] / total];
}

/**
 * Are these points collinear or coincident? A rigid transform is not determined
 * by such a set, and the solve would return an arbitrary rotation about the line.
 */
function isDegenerate(centred: Vec3[]): boolean {
  // Build the scatter matrix and check its smallest dimension via the spread
  // perpendicular to the dominant direction.
  let maxLen = 0;
  let axis: Vec3 = [0, 0, 0];
  for (const p of centred) {
    const l = v3.length(p);
    if (l > maxLen) {
      maxLen = l;
      axis = p;
    }
  }
  if (maxLen < 1e-9) return true; // all coincident

  const unit = v3.normalize(axis);
  let maxPerp = 0;
  for (const p of centred) {
    const along = v3.dot(p, unit);
    const perp = v3.length(v3.sub(p, v3.scale(unit, along)));
    if (perp > maxPerp) maxPerp = perp;
  }
  // Perpendicular spread under 0.1% of the longest baseline is collinear
  // for any practical purpose.
  return maxPerp < maxLen * 1e-3;
}

/**
 * Largest eigenvector of a symmetric 4x4, by power iteration with a shift.
 *
 * Horn's N matrix has its largest eigenvalue corresponding to the optimal
 * rotation quaternion. Shifting by the trace guarantees the dominant eigenvalue
 * is the one power iteration finds, even when the true largest is negative.
 */
function largestEigenvector4(N: number[]): Quat {
  let trace = 0;
  for (let i = 0; i < 4; i++) trace += Math.abs(N[i * 5]);
  const shift = trace + 1;
  const M = N.slice();
  for (let i = 0; i < 4; i++) M[i * 5] += shift;

  // Start away from any axis so a symmetric matrix cannot leave us on an
  // eigenvector of the wrong eigenvalue.
  let v = [0.5, 0.5, 0.5, 0.5];
  for (let iter = 0; iter < 200; iter++) {
    const next = [0, 0, 0, 0];
    for (let r = 0; r < 4; r++) {
      let sum = 0;
      for (let c = 0; c < 4; c++) sum += M[r * 4 + c] * v[c];
      next[r] = sum;
    }
    const norm = Math.hypot(next[0], next[1], next[2], next[3]);
    if (norm < 1e-300) break;
    for (let i = 0; i < 4; i++) next[i] /= norm;
    let delta = 0;
    for (let i = 0; i < 4; i++) delta += Math.abs(next[i] - v[i]);
    v = next;
    if (delta < 1e-15) break;
  }
  // Horn's quaternion is (w, x, y, z); this codebase stores (x, y, z, w).
  return quat.normalize([v[1], v[2], v[3], v[0]]);
}

export function solveRigidTransform(
  pairs: ControlPair[],
  options: SolveOptions = {},
): RigidSolution {
  const estimateScale = options.estimateScale ?? false;
  const useWeights = options.useWeights ?? true;

  if (pairs.length < 3) {
    throw new Error(
      `need at least 3 control pairs, got ${pairs.length}. ` +
      'Three determines the transform; six is the practical minimum for ' +
      'detecting a bad point.',
    );
  }

  const src = pairs.map((p) => p.observed);
  const dst = pairs.map((p) => p.project);
  const weights = pairs.map((p) =>
    useWeights && p.sigma && p.sigma > 0 ? 1 / (p.sigma * p.sigma) : 1,
  );

  const cSrc = weightedCentroid(src, weights);
  const cDst = weightedCentroid(dst, weights);
  const pSrc = src.map((p) => v3.sub(p, cSrc));
  const pDst = dst.map((p) => v3.sub(p, cDst));

  if (isDegenerate(pSrc) || isDegenerate(pDst)) {
    throw new Error(
      'control points are collinear or coincident — a rigid transform is not ' +
      'determined. Spread control across at least three non-collinear positions, ' +
      'and prefer points that differ in height.',
    );
  }

  // Weighted 3x3 cross-covariance, row-major.
  const M = new Array(9).fill(0);
  for (let i = 0; i < pSrc.length; i++) {
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        M[r * 3 + c] += weights[i] * pSrc[i][r] * pDst[i][c];
      }
    }
  }
  const [Sxx, Sxy, Sxz, Syx, Syy, Syz, Szx, Szy, Szz] = M;

  // Horn's symmetric 4x4, in (w, x, y, z) ordering.
  const N = [
    Sxx + Syy + Szz, Syz - Szy, Szx - Sxz, Sxy - Syx,
    Syz - Szy, Sxx - Syy - Szz, Sxy + Syx, Szx + Sxz,
    Szx - Sxz, Sxy + Syx, -Sxx + Syy - Szz, Syz + Szy,
    Sxy - Syx, Szx + Sxz, Syz + Szy, -Sxx - Syy + Szz,
  ];

  const rotation = largestEigenvector4(N);

  let scale = 1;
  if (estimateScale) {
    let num = 0;
    let den = 0;
    for (let i = 0; i < pSrc.length; i++) {
      num += weights[i] * v3.dot(pDst[i], quat.rotate(rotation, pSrc[i]));
      den += weights[i] * v3.lengthSq(pSrc[i]);
    }
    if (den > 0) scale = num / den;
  }

  const translation = v3.sub(cDst, v3.scale(quat.rotate(rotation, cSrc), scale));

  const residuals: Residual[] = pairs.map((pair, i) => {
    const mapped = applyTransform(rotation, translation, scale, src[i]);
    const delta = v3.sub(mapped, dst[i]);
    return { id: pair.id, error: v3.length(delta), delta };
  });

  let sumSq = 0;
  let maxError = 0;
  for (const r of residuals) {
    sumSq += r.error * r.error;
    if (r.error > maxError) maxError = r.error;
  }

  return {
    rotation,
    translation,
    scale,
    matrix: mat4.compose(translation, rotation, [scale, scale, scale]),
    rmsError: Math.sqrt(sumSq / residuals.length),
    maxError,
    residuals,
    pairCount: pairs.length,
    pairs,
  };
}

export function applyTransform(
  rotation: Quat,
  translation: Vec3,
  scale: number,
  p: Vec3,
): Vec3 {
  return v3.add(v3.scale(quat.rotate(rotation, p), scale), translation);
}

// ---------------------------------------------------------------------------
// Outliers
// ---------------------------------------------------------------------------

export interface Outlier {
  id?: string;
  index: number;
  /** This point's residual in the full solution, metres. */
  error: number;
  /** Robust z-score: how many MADs from the median residual. */
  score: number;
  /**
   * RMS of the solution refitted without this point. A value far below the
   * full-fit RMS is the strongest evidence available that this point is bad.
   */
  rmsWithout: number;
  /** fullRms / rmsWithout. Above ~3 means this one point dominates the fit. */
  influence: number;
  reason: string;
}

export interface OutlierOptions {
  /** MAD z-score above which a residual is out of family. */
  madThreshold?: number;
  /** Influence ratio above which a point is judged to dominate the fit. */
  influenceThreshold?: number;
  estimateScale?: boolean;
}

/**
 * Flag control points that do not belong.
 *
 * Two tests, because neither is sufficient alone:
 *
 * **Median/MAD z-score.** Robust to a single gross error in a way that
 * mean/stddev is not — one bad point inflates the standard deviation enough to
 * hide itself. The 1.4826 factor makes MAD a consistent estimator of sigma for
 * normal data, so the threshold reads as a z-score.
 *
 * **Leave-one-out influence.** The MAD test still suffers *masking* on small
 * networks: a least-squares fit distributes one gross error across every
 * residual, so with six points a 300 mm blunder can leave the culprit at a
 * z-score of 2.9 while dragging its neighbours up with it. Refitting without
 * each point in turn measures its influence directly, and a bad point announces
 * itself unmistakably — the RMS collapses when it is removed.
 *
 * Leave-one-out is O(n) closed-form solves, which is nothing for a control
 * network of a few dozen points, and it needs at least four points so that
 * three remain.
 */
export function findOutliers(
  solution: RigidSolution,
  options: OutlierOptions | number = {},
): Outlier[] {
  // A bare number keeps the older call shape working as the MAD threshold.
  const opts: OutlierOptions =
    typeof options === 'number' ? { madThreshold: options } : options;
  const madThreshold = opts.madThreshold ?? 3.5;
  const influenceThreshold = opts.influenceThreshold ?? 3;

  const errors = solution.residuals.map((r) => r.error);
  const sorted = [...errors].sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];
  const deviations = errors.map((e) => Math.abs(e - median)).sort((a, b) => a - b);
  const mad = deviations[Math.floor(deviations.length / 2)];

  const pairs = solution.pairs;
  const canRefit = pairs.length >= 4;

  const out: Outlier[] = [];
  for (let i = 0; i < errors.length; i++) {
    // All residuals identical means nothing stands out; dividing by a zero MAD
    // would instead make every point an outlier.
    const score = mad < 1e-12 ? 0 : Math.abs(errors[i] - median) / (mad * 1.4826);

    let rmsWithout = solution.rmsError;
    if (canRefit) {
      try {
        rmsWithout = solveRigidTransform(
          pairs.filter((_, k) => k !== i),
          { estimateScale: opts.estimateScale ?? false },
        ).rmsError;
      } catch {
        // Removing this point makes the remainder degenerate, which means it is
        // load-bearing geometry rather than a blunder. Leave the RMS unchanged.
        rmsWithout = solution.rmsError;
      }
    }
    const influence = rmsWithout > 1e-12 ? solution.rmsError / rmsWithout : 1;

    const byMad = score > madThreshold;
    const byInfluence = influence > influenceThreshold;
    if (!byMad && !byInfluence) continue;

    const reasons: string[] = [];
    if (byInfluence) {
      reasons.push(
        `removing it drops RMS from ${(solution.rmsError * 1000).toFixed(0)} mm ` +
        `to ${(rmsWithout * 1000).toFixed(0)} mm`,
      );
    }
    if (byMad) reasons.push(`residual is ${score.toFixed(1)} MADs from the median`);

    out.push({
      id: solution.residuals[i].id,
      index: i,
      error: errors[i],
      score,
      rmsWithout,
      influence,
      reason: `Re-shoot or exclude: ${reasons.join('; ')}.`,
    });
  }

  // Most influential first — that is the one to check on the ground.
  return out.sort((a, b) => b.influence - a.influence || b.score - a.score);
}

// ---------------------------------------------------------------------------
// Accuracy grading
// ---------------------------------------------------------------------------

export type AccuracyBand =
  | 'layout'
  | 'penetrations'
  | 'dimensional-control'
  | 'coordination'
  | 'context'
  | 'unusable';

export interface AccuracyGrade {
  band: AccuracyBand;
  rmsError: number;
  label: string;
  guidance: string;
}

/**
 * Map an RMS residual onto the construction tolerance bands, with guidance in
 * the terms a crew uses.
 *
 * These bands are the working tolerances from the field, not a statistical
 * convention: a number displayed without one is an unfinished measurement,
 * because a crew will build to whatever is on the screen.
 */
export function classifyAccuracy(rmsError: number): AccuracyGrade {
  if (!Number.isFinite(rmsError) || rmsError < 0) {
    return {
      band: 'unusable',
      rmsError,
      label: 'No solution',
      guidance: 'The registration did not solve. Do not use this positioning for anything.',
    };
  }
  if (rmsError <= 0.003) {
    return {
      band: 'layout',
      rmsError,
      label: 'Layout',
      guidance:
        'Within structural and MEP point layout tolerance (~3 mm). Verify against ' +
        'an instrument before laying out from it — this is a fit statistic, not ' +
        'an independent check.',
    };
  }
  if (rmsError <= 0.006) {
    return {
      band: 'penetrations',
      rmsError,
      label: 'Sleeves and penetrations',
      guidance: 'Good enough to place sleeves and penetrations (~6 mm). Not for point layout.',
    };
  }
  if (rmsError <= 0.010) {
    return {
      band: 'dimensional-control',
      rmsError,
      label: 'Dimensional control',
      guidance:
        'Good enough to confirm installed work against the model (~10 mm). ' +
        'Not a substitute for layout instruments.',
    };
  }
  if (rmsError <= 0.050) {
    return {
      band: 'coordination',
      rmsError,
      label: 'Coordination',
      guidance:
        'Usable for clash checking and coordination (~25-50 mm). Do not measure ' +
        'installed positions from it.',
    };
  }
  if (rmsError <= 0.250) {
    return {
      band: 'context',
      rmsError,
      label: 'Context only',
      guidance:
        'Shows roughly what is where (~250 mm). Wayfinding and zone identification only.',
    };
  }
  return {
    band: 'unusable',
    rmsError,
    label: 'Unusable',
    guidance:
      `RMS of ${(rmsError * 1000).toFixed(0)} mm is past any construction use. ` +
      'Check for a wrong zone, a wrong unit, or a mis-keyed control point.',
  };
}
