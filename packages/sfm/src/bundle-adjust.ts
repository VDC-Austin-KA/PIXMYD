/**
 * Bundle adjustment: refine every camera and every point together.
 *
 * Incremental reconstruction accumulates error — each new camera is placed
 * against points triangulated from earlier cameras, and small biases compound
 * along the trajectory until the two ends of a loop no longer meet. Bundle
 * adjustment is the correction: minimise total reprojection error over all
 * parameters at once, so no camera is privileged and the error distributes.
 *
 * The implementation is Levenberg-Marquardt with the **Schur complement**,
 * which is the one structural choice that matters. The normal equations for a
 * 200-camera, 50,000-point problem are a 151,200 x 151,200 matrix — hopeless
 * dense. But points do not see each other, so the point block is
 * block-diagonal with 3x3 blocks, and eliminating it leaves a system the size
 * of the cameras alone. That is the difference between seconds and never.
 */

import { quat, v3, type Quat, type Vec3 } from '@pixmyd/core/math';
import { quatToRowMajor } from './geometry.ts';
import { solveLinearSystem } from './pnp.ts';

export interface BaCamera {
  rotation: Quat;
  position: Vec3;
  /** Held at its initial value when true — control, or a fixed gauge. */
  fixed?: boolean;
}

export interface BaObservation {
  camera: number;
  point: number;
  /** Normalized image coordinates. */
  x: number;
  y: number;
  /** Down-weights an uncertain observation. Defaults to 1. */
  weight?: number;
}

export interface BaProblem {
  cameras: BaCamera[];
  points: Vec3[];
  observations: BaObservation[];
}

export interface BaOptions {
  iterations?: number;
  /** Initial LM damping. */
  lambda?: number;
  /**
   * Huber threshold in normalized units. Residuals beyond it are down-weighted
   * rather than dropped, so a surviving outlier bends the solution a little
   * instead of dominating it.
   */
  huber?: number;
  onProgress?: (iteration: number, rms: number) => void;
}

export interface BaResult {
  cameras: BaCamera[];
  points: Vec3[];
  /** RMS reprojection error before and after, in normalized units. */
  initialRms: number;
  finalRms: number;
  iterations: number;
}

/** Robust weight: unity inside the Huber band, falling off outside it. */
function huberWeight(residual: number, threshold: number): number {
  const magnitude = Math.abs(residual);
  return magnitude <= threshold ? 1 : Math.sqrt(threshold / magnitude);
}

/**
 * Squared-residual charged to an observation that has fallen behind its camera.
 *
 * Enormous in normalized units — a residual of 10 is roughly ten image widths —
 * so any configuration that puts a point behind a camera scores far worse than
 * any legitimate fit.
 */
const BEHIND_CAMERA_PENALTY = 100;

/**
 * Total reprojection error, over a **fixed** observation set.
 *
 * The fixed part is load-bearing. An earlier version skipped observations whose
 * point had fallen behind the camera, which made the objective depend on the
 * current parameters: a step that pushed points behind cameras removed their
 * residuals from the sum entirely and looked like a dramatic improvement. The
 * line search then accepted it, and the solve converged to a reported RMS of
 * 1e-16 while having flung a point sixteen metres.
 *
 * Charging a large penalty instead keeps the denominator constant, so two RMS
 * values are always comparable.
 */
function computeRms(problem: BaProblem, observations = problem.observations): number {
  if (observations.length === 0) return Infinity;
  let sum = 0;
  for (const observation of observations) {
    const camera = problem.cameras[observation.camera];
    const point = problem.points[observation.point];
    const local = quat.rotate(quat.conjugate(camera.rotation), v3.sub(point, camera.position));
    if (local[2] <= 1e-9) {
      sum += BEHIND_CAMERA_PENALTY;
      continue;
    }
    const dx = local[0] / local[2] - observation.x;
    const dy = local[1] / local[2] - observation.y;
    sum += dx * dx + dy * dy;
  }
  return Math.sqrt(sum / observations.length);
}

export function bundleAdjust(problem: BaProblem, options: BaOptions = {}): BaResult {
  const maxIterations = options.iterations ?? 25;
  const huber = options.huber ?? 0.01;
  let lambda = options.lambda ?? 1e-4;

  // Work on copies so a failed solve leaves the caller's data intact.
  let cameras = problem.cameras.map((c) => ({ ...c }));
  let points = problem.points.map((p) => [...p] as Vec3);

  let currentRms = 0; // set once the usable observation set is known

  // Only free cameras get columns in the reduced system.
  const cameraIndex: number[] = [];
  let freeCameras = 0;
  for (let i = 0; i < cameras.length; i++) {
    cameraIndex[i] = cameras[i].fixed ? -1 : freeCameras++;
  }

  if (freeCameras === 0 || problem.observations.length === 0) {
    const rms = computeRms({ ...problem, cameras, points });
    return { cameras, points, initialRms: rms, finalRms: rms, iterations: 0 };
  }

  // Drop observations of points seen by fewer than two cameras.
  //
  // A point with a single observation is unconstrained along that camera's
  // viewing ray: it can slide anywhere on the ray with no change in
  // reprojection error, so its 3x3 block in the normal equations is singular.
  // Inverting it — even with damping — turns a tiny gradient into an enormous
  // point update, and the Schur complement propagates that straight into the
  // cameras. The symptom is a solve that reports a *lower* residual while
  // having moved the cameras metres, which is exactly the failure this guard
  // was written for.
  //
  // Such a point also contributes nothing to camera estimation: any camera
  // motion can be absorbed by moving the point along its ray. Excluding it
  // loses no information.
  const observationCount = new Int32Array(points.length);
  for (const observation of problem.observations) observationCount[observation.point]++;
  const usableObservations = problem.observations.filter(
    (observation) => observationCount[observation.point] >= 2,
  );

  const initialRms = computeRms({ ...problem, cameras, points }, usableObservations);
  currentRms = initialRms;

  if (usableObservations.length === 0) {
    return { cameras, points, initialRms, finalRms: initialRms, iterations: 0 };
  }

  const cameraDim = freeCameras * 6;
  let completed = 0;

  for (let iteration = 0; iteration < maxIterations; iteration++) {
    // U: camera blocks. V: point blocks (3x3, one per point). W: coupling.
    const U = new Float64Array(cameraDim * cameraDim);
    const bCamera = new Float64Array(cameraDim);
    const V = new Float64Array(points.length * 9);
    const bPoint = new Float64Array(points.length * 3);
    // W is stored per observation-group, since each entry couples one camera
    // with one point and the matrix is otherwise almost entirely zero.
    const W = new Map<string, Float64Array>();

    for (const observation of usableObservations) {
      const camera = cameras[observation.camera];
      const point = points[observation.point];
      const inverseRotation = quat.conjugate(camera.rotation);
      const local = quat.rotate(inverseRotation, v3.sub(point, camera.position));
      const z = local[2];
      if (z <= 1e-9) continue;

      const invZ = 1 / z;
      const px = local[0] * invZ;
      const py = local[1] * invZ;
      const residual = [px - observation.x, py - observation.y];

      const weight =
        (observation.weight ?? 1) *
        huberWeight(Math.hypot(residual[0], residual[1]), huber);

      // d(projection)/d(camera-space point), 2x3
      const dpdc = [invZ, 0, -px * invZ, 0, invZ, -py * invZ];
      const R = quatToRowMajor(inverseRotation);

      // Camera Jacobian, 2x6: three rotation, three translation.
      const jc = new Float64Array(12);
      const c = cameraIndex[observation.camera];
      if (c >= 0) {
        for (let axis = 0; axis < 3; axis++) {
          // Rotation increment on the right: d(local)/d(omega) = -[local]x e
          // d(local)/d(omega) = local x e — see the note in pnp.ts.
          const e: Vec3 = [0, 0, 0];
          e[axis] = 1;
          const cross: Vec3 = [
            local[1] * e[2] - local[2] * e[1],
            local[2] * e[0] - local[0] * e[2],
            local[0] * e[1] - local[1] * e[0],
          ];
          for (let row = 0; row < 2; row++) {
            jc[row * 6 + axis] =
              dpdc[row * 3] * cross[0] + dpdc[row * 3 + 1] * cross[1] + dpdc[row * 3 + 2] * cross[2];
          }
          // Translation: d(local)/d(position) = -Rᵀ
          const dt: Vec3 = [-R[axis], -R[3 + axis], -R[6 + axis]];
          for (let row = 0; row < 2; row++) {
            jc[row * 6 + 3 + axis] =
              dpdc[row * 3] * dt[0] + dpdc[row * 3 + 1] * dt[1] + dpdc[row * 3 + 2] * dt[2];
          }
        }
      }

      // Point Jacobian, 2x3: d(local)/d(point) = Rᵀ (world to camera rotation).
      const jp = new Float64Array(6);
      for (let axis = 0; axis < 3; axis++) {
        const dp: Vec3 = [R[axis], R[3 + axis], R[6 + axis]];
        for (let row = 0; row < 2; row++) {
          jp[row * 3 + axis] =
            dpdc[row * 3] * dp[0] + dpdc[row * 3 + 1] * dp[1] + dpdc[row * 3 + 2] * dp[2];
        }
      }

      // Accumulate the normal equations.
      const p = observation.point;
      for (let row = 0; row < 2; row++) {
        const r = residual[row] * weight;
        if (c >= 0) {
          for (let i = 0; i < 6; i++) {
            const jci = jc[row * 6 + i] * weight;
            bCamera[c * 6 + i] -= jci * r;
            for (let j = 0; j < 6; j++) {
              U[(c * 6 + i) * cameraDim + (c * 6 + j)] += jci * jc[row * 6 + j] * weight;
            }
          }
        }
        for (let i = 0; i < 3; i++) {
          const jpi = jp[row * 3 + i] * weight;
          bPoint[p * 3 + i] -= jpi * r;
          for (let j = 0; j < 3; j++) {
            V[p * 9 + i * 3 + j] += jpi * jp[row * 3 + j] * weight;
          }
        }
        if (c >= 0) {
          const key = `${c}:${p}`;
          let block = W.get(key);
          if (!block) {
            block = new Float64Array(18);
            W.set(key, block);
          }
          for (let i = 0; i < 6; i++) {
            for (let j = 0; j < 3; j++) {
              block[i * 3 + j] += jc[row * 6 + i] * weight * jp[row * 3 + j] * weight;
            }
          }
        }
      }
    }

    // --- Schur complement ---
    //
    // S = U - W V^-1 Wᵀ,  and  b_S = b_c - W V^-1 b_p
    //
    // This is the whole reason bundle adjustment is tractable. V is
    // block-diagonal because no two points constrain each other, so its inverse
    // is 3x3 inversions rather than a factorisation of the full matrix.
    const S = Float64Array.from(U);
    const bS = Float64Array.from(bCamera);

    const vInverse = new Float64Array(points.length * 9);
    for (let p = 0; p < points.length; p++) {
      const block = [
        V[p * 9 + 0] * (1 + lambda), V[p * 9 + 1], V[p * 9 + 2],
        V[p * 9 + 3], V[p * 9 + 4] * (1 + lambda), V[p * 9 + 5],
        V[p * 9 + 6], V[p * 9 + 7], V[p * 9 + 8] * (1 + lambda),
      ];
      const inverse = invert3(block);
      if (inverse) vInverse.set(inverse, p * 9);
      // A point with no observations leaves a zero block, which correctly
      // contributes nothing to the Schur complement.
    }

    // Group the W blocks by point so the outer products can be formed.
    const byPoint = new Map<number, { camera: number; block: Float64Array }[]>();
    for (const [key, block] of W) {
      const [cameraText, pointText] = key.split(':');
      const p = Number(pointText);
      const list = byPoint.get(p) ?? [];
      list.push({ camera: Number(cameraText), block });
      byPoint.set(p, list);
    }

    for (const [p, entries] of byPoint) {
      const vi = vInverse.subarray(p * 9, p * 9 + 9);
      // W V^-1 b_p contribution
      for (const { camera: c, block } of entries) {
        for (let i = 0; i < 6; i++) {
          let sum = 0;
          for (let k = 0; k < 3; k++) {
            let inner = 0;
            for (let m = 0; m < 3; m++) inner += vi[k * 3 + m] * bPoint[p * 3 + m];
            sum += block[i * 3 + k] * inner;
          }
          bS[c * 6 + i] -= sum;
        }
      }
      // W V^-1 Wᵀ contribution, over every camera pair sharing this point.
      for (const { camera: ci, block: bi } of entries) {
        for (const { camera: cj, block: bj } of entries) {
          for (let i = 0; i < 6; i++) {
            for (let j = 0; j < 6; j++) {
              let sum = 0;
              for (let k = 0; k < 3; k++) {
                for (let m = 0; m < 3; m++) {
                  sum += bi[i * 3 + k] * vi[k * 3 + m] * bj[j * 3 + m];
                }
              }
              S[(ci * 6 + i) * cameraDim + (cj * 6 + j)] -= sum;
            }
          }
        }
      }
    }

    for (let i = 0; i < cameraDim; i++) S[i * cameraDim + i] *= 1 + lambda;

    const cameraDelta = solveLinearSystem([...S], [...bS], cameraDim);
    if (!cameraDelta) {
      lambda *= 10;
      if (lambda > 1e12) break;
      continue;
    }

    // Back-substitute for the points: dp = V^-1 (b_p - Wᵀ dc)
    const pointDelta = new Float64Array(points.length * 3);
    for (let p = 0; p < points.length; p++) {
      const rhs = [bPoint[p * 3], bPoint[p * 3 + 1], bPoint[p * 3 + 2]];
      for (const { camera: c, block } of byPoint.get(p) ?? []) {
        for (let j = 0; j < 3; j++) {
          let sum = 0;
          for (let i = 0; i < 6; i++) sum += block[i * 3 + j] * cameraDelta[c * 6 + i];
          rhs[j] -= sum;
        }
      }
      const vi = vInverse.subarray(p * 9, p * 9 + 9);
      for (let i = 0; i < 3; i++) {
        pointDelta[p * 3 + i] =
          vi[i * 3] * rhs[0] + vi[i * 3 + 1] * rhs[1] + vi[i * 3 + 2] * rhs[2];
      }
    }

    // --- trial step ---
    const trialCameras = cameras.map((camera, i) => {
      const c = cameraIndex[i];
      if (c < 0) return { ...camera };
      const omega: Vec3 = [
        cameraDelta[c * 6], cameraDelta[c * 6 + 1], cameraDelta[c * 6 + 2],
      ];
      const magnitude = v3.length(omega);
      const increment = magnitude < 1e-14
        ? quat.identity()
        : quat.fromAxisAngle(v3.scale(omega, 1 / magnitude), magnitude);
      return {
        ...camera,
        rotation: quat.normalize(quat.multiply(camera.rotation, increment)),
        position: v3.add(camera.position, [
          cameraDelta[c * 6 + 3], cameraDelta[c * 6 + 4], cameraDelta[c * 6 + 5],
        ]),
      };
    });

    const trialPoints = points.map((point, p): Vec3 => [
      point[0] + pointDelta[p * 3],
      point[1] + pointDelta[p * 3 + 1],
      point[2] + pointDelta[p * 3 + 2],
    ]);

    const trialRms = computeRms(
      { ...problem, cameras: trialCameras, points: trialPoints },
      usableObservations,
    );

    if (trialRms < currentRms) {
      // Accept, and trust the linearisation a little more next time.
      cameras = trialCameras;
      points = trialPoints;
      const improvement = currentRms - trialRms;
      currentRms = trialRms;
      lambda = Math.max(lambda * 0.3, 1e-12);
      completed = iteration + 1;
      options.onProgress?.(iteration, currentRms);
      if (improvement < 1e-12) break;
    } else {
      // Reject, and take a smaller, more gradient-like step.
      lambda *= 10;
      if (lambda > 1e12) break;
    }
  }

  return { cameras, points, initialRms, finalRms: currentRms, iterations: completed };
}

/** Invert a 3x3, row-major. Null when singular. */
function invert3(m: number[]): number[] | null {
  const a = m[4] * m[8] - m[5] * m[7];
  const b = m[5] * m[6] - m[3] * m[8];
  const c = m[3] * m[7] - m[4] * m[6];
  const det = m[0] * a + m[1] * b + m[2] * c;
  if (Math.abs(det) < 1e-18) return null;
  const inverseDet = 1 / det;
  return [
    a * inverseDet,
    (m[2] * m[7] - m[1] * m[8]) * inverseDet,
    (m[1] * m[5] - m[2] * m[4]) * inverseDet,
    b * inverseDet,
    (m[0] * m[8] - m[2] * m[6]) * inverseDet,
    (m[2] * m[3] - m[0] * m[5]) * inverseDet,
    c * inverseDet,
    (m[1] * m[6] - m[0] * m[7]) * inverseDet,
    (m[0] * m[4] - m[1] * m[3]) * inverseDet,
  ];
}
