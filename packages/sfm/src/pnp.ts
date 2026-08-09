/**
 * Perspective-n-Point: recover a camera pose from known 3D points and their
 * image observations.
 *
 * This is the workhorse of incremental reconstruction. Once a few points are
 * triangulated, every subsequent camera is placed by PnP against them rather
 * than by another two-view solve, which is what keeps error from compounding
 * pairwise along a trajectory.
 *
 * Three layers, each of which exists because the one below is not enough:
 *
 *   `solvePnpDlt`       linear, closed form, needs 6 points, tolerates no noise
 *   `refinePnp`         Gauss-Newton on reprojection error, needs a starting guess
 *   `solvePnpRansac`    robust to outliers, which real matches always contain
 */

import { quat, v3, type Quat, type Vec3 } from '@pixmyd/core/math';
import {
  applyRowMajor,
  determinant3,
  nullSpaceVector,
  quatToRowMajor,
  symmetricEigen,
  type Vec2,
} from './geometry.ts';

export interface PnpObservation {
  /** Point in world coordinates. */
  world: Vec3;
  /** Its observation in normalized image coordinates. */
  image: Vec2;
}

export interface PnpSolution {
  /** Camera-to-world rotation. */
  rotation: Quat;
  /** Camera centre in world coordinates. */
  position: Vec3;
  /** RMS reprojection error in normalized units. */
  rms: number;
  /** Indices of the observations treated as inliers. */
  inliers: number[];
}

// ---------------------------------------------------------------------------
// Linear DLT
// ---------------------------------------------------------------------------

/**
 * Direct linear transform PnP.
 *
 * Solves for the 3x4 projection matrix directly, then extracts a rotation from
 * its left 3x3 block. That block is only approximately a rotation once there is
 * any noise, so it is orthogonalised — skipping that produces a "rotation" with
 * a scale baked in, which shifts every subsequent triangulation.
 *
 * Needs at least six points, and they must not be coplanar: a planar
 * configuration leaves the system rank deficient and the solution arbitrary.
 */
export function solvePnpDlt(observations: PnpObservation[]): PnpSolution | null {
  if (observations.length < 6) return null;

  // Normalize the world points to zero mean and unit average distance. Without
  // this the system is badly conditioned whenever the scene is far from the
  // origin — which, after a georeference, it always is.
  const centroid = observations
    .reduce<Vec3>((sum, o) => v3.add(sum, o.world), [0, 0, 0])
    .map((c) => c / observations.length) as Vec3;

  let scale = 0;
  for (const o of observations) scale += v3.distance(o.world, centroid);
  scale = scale > 0 ? observations.length / scale : 1;

  const rows: number[][] = [];
  for (const { world, image } of observations) {
    const p = v3.scale(v3.sub(world, centroid), scale);
    rows.push([
      p[0], p[1], p[2], 1, 0, 0, 0, 0,
      -image.x * p[0], -image.x * p[1], -image.x * p[2], -image.x,
    ]);
    rows.push([
      0, 0, 0, 0, p[0], p[1], p[2], 1,
      -image.y * p[0], -image.y * p[1], -image.y * p[2], -image.y,
    ]);
  }

  const solution = nullSpaceVector(rows, 12);

  // Left 3x3 block, row-major.
  let m = [
    solution[0], solution[1], solution[2],
    solution[4], solution[5], solution[6],
    solution[8], solution[9], solution[10],
  ];
  let t: Vec3 = [solution[3], solution[7], solution[11]];

  const det = determinant3(m);
  if (Math.abs(det) < 1e-12) return null;
  // The DLT solution is defined up to sign; a negative determinant means the
  // whole thing is flipped, which would put the scene behind the camera.
  if (det < 0) {
    m = m.map((value) => -value);
    t = [-t[0], -t[1], -t[2]];
  }

  // Recover the scale the DLT left in, then orthogonalise.
  const rowNorm = Math.cbrt(Math.abs(determinant3(m)));
  if (!(rowNorm > 1e-12)) return null;
  const rotationMatrix = orthogonalise(m.map((value) => value / rowNorm));
  if (!rotationMatrix) return null;
  const translation: Vec3 = [t[0] / rowNorm, t[1] / rowNorm, t[2] / rowNorm];

  // Undo the normalization: the solve was in a shifted, scaled frame.
  const worldToCamera = rotationMatrix;
  const scaledTranslation = v3.scale(translation, 1 / scale);
  const position = v3.sub(
    centroid,
    applyRowMajor(transposeRowMajor(worldToCamera), scaledTranslation),
  );

  const rotation = quat.fromMat3(
    new Float64Array([
      worldToCamera[0], worldToCamera[3], worldToCamera[6],
      worldToCamera[1], worldToCamera[4], worldToCamera[7],
      worldToCamera[2], worldToCamera[5], worldToCamera[8],
    ]),
  );
  // worldToCamera is the inverse of the camera-to-world rotation we report.
  const cameraToWorld = quat.conjugate(rotation);

  const rms = reprojectionRms(observations, cameraToWorld, position);
  if (!Number.isFinite(rms)) return null;

  return {
    rotation: cameraToWorld,
    position,
    rms,
    inliers: observations.map((_, i) => i),
  };
}

/**
 * Nearest rotation matrix, by polar decomposition via the eigendecomposition of
 * `MᵀM`. Returns null if the input is singular.
 */
function orthogonalise(m: number[]): number[] | null {
  const mtm = new Array(9).fill(0);
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += m[k * 3 + i] * m[k * 3 + j];
      mtm[i * 3 + j] = sum;
    }
  }

  const { values, vectors } = symmetricEigen(mtm, 3);
  if (values[0] < 1e-18) return null;

  // (MᵀM)^(-1/2), assembled from the eigenbasis.
  const inverseSqrt = new Array(9).fill(0);
  for (let index = 0; index < 3; index++) {
    const factor = 1 / Math.sqrt(values[index]);
    const vec = vectors[index];
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) inverseSqrt[r * 3 + c] += factor * vec[r] * vec[c];
    }
  }

  const out = new Array(9).fill(0);
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += m[r * 3 + k] * inverseSqrt[k * 3 + c];
      out[r * 3 + c] = sum;
    }
  }
  return Math.abs(determinant3(out) - 1) < 1e-3 ? out : null;
}

function transposeRowMajor(m: number[]): number[] {
  return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
}

// ---------------------------------------------------------------------------
// Reprojection
// ---------------------------------------------------------------------------

/** Project a world point into normalized image coordinates. Null if behind. */
export function reproject(world: Vec3, rotation: Quat, position: Vec3): Vec2 | null {
  const local = quat.rotate(quat.conjugate(rotation), v3.sub(world, position));
  if (local[2] <= 1e-9) return null;
  return { x: local[0] / local[2], y: local[1] / local[2] };
}

export function reprojectionRms(
  observations: PnpObservation[],
  rotation: Quat,
  position: Vec3,
): number {
  let sum = 0;
  let count = 0;
  for (const { world, image } of observations) {
    const projected = reproject(world, rotation, position);
    if (!projected) return Infinity;
    const dx = projected.x - image.x;
    const dy = projected.y - image.y;
    sum += dx * dx + dy * dy;
    count++;
  }
  return count === 0 ? Infinity : Math.sqrt(sum / count);
}

// ---------------------------------------------------------------------------
// Nonlinear refinement
// ---------------------------------------------------------------------------

/**
 * Refine a pose by Gauss-Newton on reprojection error.
 *
 * The state is six parameters: a three-vector rotation increment applied on the
 * *right* of the current rotation, and a three-vector translation increment.
 * Parameterising the increment rather than the rotation itself avoids
 * gimbal lock and keeps the quaternion on its manifold — the increment is
 * small, so a first-order axis-angle map is exact enough and singularity-free.
 */
export function refinePnp(
  observations: PnpObservation[],
  initial: { rotation: Quat; position: Vec3 },
  iterations = 20,
): { rotation: Quat; position: Vec3; rms: number } {
  let rotation = quat.normalize(initial.rotation);
  let position = initial.position;
  let rms = reprojectionRms(observations, rotation, position);

  for (let iteration = 0; iteration < iterations; iteration++) {
    // Normal equations for the 6-parameter update.
    const H = new Array(36).fill(0);
    const g = new Array(6).fill(0);
    const inverseRotation = quat.conjugate(rotation);
    let used = 0;

    for (const { world, image } of observations) {
      const local = quat.rotate(inverseRotation, v3.sub(world, position));
      const z = local[2];
      if (z <= 1e-9) continue;
      used++;

      const invZ = 1 / z;
      const x = local[0] * invZ;
      const y = local[1] * invZ;
      const residual = [x - image.x, y - image.y];

      // d(projection)/d(camera-space point)
      const dpdc = [
        invZ, 0, -x * invZ,
        0, invZ, -y * invZ,
      ];

      // Camera-space point derivative with respect to the increments.
      // For a right-multiplied rotation increment, d(local)/d(omega) = -[local]x
      // For translation in world, d(local)/d(dt) = -Rᵀ
      const R = quatToRowMajor(inverseRotation);
      const jacobian: number[] = new Array(12).fill(0);
      for (let axis = 0; axis < 3; axis++) {
        // Rotation columns: -[local]x e_axis
        // d(local)/d(omega) = local x e. A rotation increment applied on the
        // right of the camera-to-world rotation acts as exp(-omega) on the
        // world-to-camera side, so local' = local + local x omega. The opposite
        // sign makes every Gauss-Newton step point uphill, and the line search
        // then rejects all of them — the solve silently does nothing.
        const e: Vec3 = [0, 0, 0];
        e[axis] = 1;
        const cross: Vec3 = [
          local[1] * e[2] - local[2] * e[1],
          local[2] * e[0] - local[0] * e[2],
          local[0] * e[1] - local[1] * e[0],
        ];

        for (let row = 0; row < 2; row++) {
          jacobian[row * 6 + axis] =
            dpdc[row * 3] * cross[0] + dpdc[row * 3 + 1] * cross[1] + dpdc[row * 3 + 2] * cross[2];
        }
        // Translation columns: -Rᵀ e_axis, i.e. minus the axis-th column of Rᵀ.
        const dt: Vec3 = [-R[axis], -R[3 + axis], -R[6 + axis]];
        for (let row = 0; row < 2; row++) {
          jacobian[row * 6 + 3 + axis] =
            dpdc[row * 3] * dt[0] + dpdc[row * 3 + 1] * dt[1] + dpdc[row * 3 + 2] * dt[2];
        }
      }

      for (let row = 0; row < 2; row++) {
        for (let i = 0; i < 6; i++) {
          g[i] += jacobian[row * 6 + i] * residual[row];
          for (let j = 0; j < 6; j++) {
            H[i * 6 + j] += jacobian[row * 6 + i] * jacobian[row * 6 + j];
          }
        }
      }
    }

    if (used < 3) break;

    // Levenberg damping keeps the step sane when H is near singular, which
    // happens whenever the points are nearly coplanar or nearly collinear.
    for (let i = 0; i < 6; i++) H[i * 6 + i] *= 1 + 1e-6;
    const delta = solveLinearSystem(H, g.map((value) => -value), 6);
    if (!delta) break;

    const omega: Vec3 = [delta[0], delta[1], delta[2]];
    const magnitude = v3.length(omega);
    const increment = magnitude < 1e-12
      ? quat.identity()
      : quat.fromAxisAngle(v3.scale(omega, 1 / magnitude), magnitude);

    const candidateRotation = quat.normalize(quat.multiply(rotation, increment));
    const candidatePosition = v3.add(position, [delta[3], delta[4], delta[5]]);
    const candidateRms = reprojectionRms(observations, candidateRotation, candidatePosition);

    // Only accept a step that actually improves the fit. Gauss-Newton can
    // overshoot badly on a poor initial guess, and an unconditional update
    // turns a mediocre pose into a nonsensical one.
    if (!(candidateRms < rms)) break;
    rotation = candidateRotation;
    position = candidatePosition;
    const improvement = rms - candidateRms;
    rms = candidateRms;
    if (improvement < 1e-12) break;
  }

  return { rotation, position, rms };
}

/** Gaussian elimination with partial pivoting. Returns null if singular. */
export function solveLinearSystem(a: number[], b: number[], n: number): number[] | null {
  const m = a.slice();
  const x = b.slice();

  for (let column = 0; column < n; column++) {
    let pivot = column;
    for (let row = column + 1; row < n; row++) {
      if (Math.abs(m[row * n + column]) > Math.abs(m[pivot * n + column])) pivot = row;
    }
    if (Math.abs(m[pivot * n + column]) < 1e-14) return null;

    if (pivot !== column) {
      for (let k = 0; k < n; k++) {
        const temp = m[column * n + k];
        m[column * n + k] = m[pivot * n + k];
        m[pivot * n + k] = temp;
      }
      const temp = x[column];
      x[column] = x[pivot];
      x[pivot] = temp;
    }

    for (let row = column + 1; row < n; row++) {
      const factor = m[row * n + column] / m[column * n + column];
      if (factor === 0) continue;
      for (let k = column; k < n; k++) m[row * n + k] -= factor * m[column * n + k];
      x[row] -= factor * x[column];
    }
  }

  const out = new Array(n).fill(0);
  for (let row = n - 1; row >= 0; row--) {
    let sum = x[row];
    for (let k = row + 1; k < n; k++) sum -= m[row * n + k] * out[k];
    out[row] = sum / m[row * n + row];
  }
  return out;
}

// ---------------------------------------------------------------------------
// RANSAC
// ---------------------------------------------------------------------------

export interface RansacOptions {
  /** Inlier threshold on reprojection error, in normalized units. */
  threshold?: number;
  iterations?: number;
  /** Deterministic seed. Reproducible solves matter for a survey deliverable. */
  seed?: number;
  /** Stop early once this fraction of observations are inliers. */
  confidence?: number;
}

/**
 * Robust PnP.
 *
 * Real feature matches contain outliers — repeated structure, moving objects,
 * plain mismatches — and least squares has a breakdown point of zero: a single
 * gross outlier drags the solution arbitrarily far. RANSAC finds the consensus
 * set first and fits only to that.
 *
 * The random sampling is seeded and deterministic. A reconstruction that gives
 * a different answer each run cannot be checked against a control network.
 */
export function solvePnpRansac(
  observations: PnpObservation[],
  options: RansacOptions = {},
): PnpSolution | null {
  const threshold = options.threshold ?? 0.004; // ~4 px at f=1000
  const maxIterations = options.iterations ?? 500;
  const confidence = options.confidence ?? 0.99;
  if (observations.length < 6) return null;

  let seed = options.seed ?? 0x9e3779b9;
  const random = (): number => {
    // xorshift32 — deterministic, and adequate for sample selection.
    seed ^= seed << 13; seed >>>= 0;
    seed ^= seed >>> 17;
    seed ^= seed << 5; seed >>>= 0;
    return seed / 0x100000000;
  };

  let bestInliers: number[] = [];
  let best: { rotation: Quat; position: Vec3 } | null = null;

  for (let iteration = 0; iteration < maxIterations; iteration++) {
    // Draw six distinct observations.
    const sample = new Set<number>();
    let guard = 0;
    while (sample.size < 6 && guard++ < 200) {
      sample.add(Math.floor(random() * observations.length));
    }
    if (sample.size < 6) continue;

    const candidate = solvePnpDlt([...sample].map((i) => observations[i]));
    if (!candidate) continue;

    const inliers: number[] = [];
    for (let i = 0; i < observations.length; i++) {
      const projected = reproject(observations[i].world, candidate.rotation, candidate.position);
      if (!projected) continue;
      const dx = projected.x - observations[i].image.x;
      const dy = projected.y - observations[i].image.y;
      if (Math.hypot(dx, dy) < threshold) inliers.push(i);
    }

    if (inliers.length > bestInliers.length) {
      bestInliers = inliers;
      best = { rotation: candidate.rotation, position: candidate.position };
      if (inliers.length >= observations.length * confidence) break;
    }
  }

  if (!best || bestInliers.length < 6) return null;

  // Refit to the consensus set, then refine. Fitting to the inliers rather than
  // keeping the minimal-sample estimate is what makes the result accurate
  // rather than merely correct.
  const inlierObservations = bestInliers.map((i) => observations[i]);
  const refined = refinePnp(inlierObservations, best);

  // Re-classify with the refined pose: a better pose usually admits more inliers.
  const finalInliers: number[] = [];
  for (let i = 0; i < observations.length; i++) {
    const projected = reproject(observations[i].world, refined.rotation, refined.position);
    if (!projected) continue;
    const dx = projected.x - observations[i].image.x;
    const dy = projected.y - observations[i].image.y;
    if (Math.hypot(dx, dy) < threshold) finalInliers.push(i);
  }

  return {
    rotation: refined.rotation,
    position: refined.position,
    rms: refined.rms,
    inliers: finalInliers.length >= bestInliers.length ? finalInliers : bestInliers,
  };
}
