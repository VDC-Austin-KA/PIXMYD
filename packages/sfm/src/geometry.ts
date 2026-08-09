/**
 * Multi-view geometry: the algebra structure-from-motion is built on.
 *
 * Everything here operates on **normalized** image coordinates — pixel
 * coordinates with the intrinsics divided out, so a point is `(x/z, y/z)` in
 * camera space. Working in normalized coordinates rather than pixels means the
 * same code serves a phone, a drone and a cube face cut from a panorama, and it
 * keeps the numerics well conditioned: pixel coordinates run to thousands and
 * their squares to millions, which wrecks the conditioning of every linear
 * system below.
 */

import { mat4, quat, v3, type Quat, type Vec3 } from '@pixmyd/core/math';

export interface Vec2 {
  x: number;
  y: number;
}

/** A correspondence between two views, in normalized coordinates. */
export interface Correspondence {
  a: Vec2;
  b: Vec2;
}

/** A rigid transform: rotation and translation. */
export interface RelativePose {
  rotation: Quat;
  /** Unit-length for a two-view solve — the baseline scale is unobservable. */
  translation: Vec3;
}

// ---------------------------------------------------------------------------
// Small dense linear algebra
// ---------------------------------------------------------------------------

/**
 * Jacobi eigenvalue iteration for a symmetric matrix.
 *
 * Used to get the null space of `AᵀA`, which is how every "solve Ax = 0 subject
 * to |x| = 1" problem below is answered. Jacobi rather than a full SVD because
 * the matrices here are 9x9 at most, it is unconditionally stable for symmetric
 * input, and it is about forty lines instead of four hundred.
 *
 * Returns eigenvalues ascending, with `vectors[i]` the column for `values[i]`.
 */
export function symmetricEigen(
  matrix: number[],
  n: number,
  sweeps = 60,
): { values: number[]; vectors: number[][] } {
  const a = matrix.slice();
  // Eigenvector accumulator, identity to start.
  const v: number[] = new Array(n * n).fill(0);
  for (let i = 0; i < n; i++) v[i * n + i] = 1;

  for (let sweep = 0; sweep < sweeps; sweep++) {
    // Off-diagonal magnitude; stop once it is negligible.
    let off = 0;
    for (let p = 0; p < n; p++) {
      for (let q = p + 1; q < n; q++) off += a[p * n + q] * a[p * n + q];
    }
    if (off < 1e-30) break;

    for (let p = 0; p < n; p++) {
      for (let q = p + 1; q < n; q++) {
        const apq = a[p * n + q];
        if (Math.abs(apq) < 1e-300) continue;

        const app = a[p * n + p];
        const aqq = a[q * n + q];
        // Rotation angle that zeroes a[p][q].
        const theta = (aqq - app) / (2 * apq);
        const t =
          Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
        const c = 1 / Math.sqrt(t * t + 1);
        const s = t * c;

        for (let k = 0; k < n; k++) {
          const akp = a[k * n + p];
          const akq = a[k * n + q];
          a[k * n + p] = c * akp - s * akq;
          a[k * n + q] = s * akp + c * akq;
        }
        for (let k = 0; k < n; k++) {
          const apk = a[p * n + k];
          const aqk = a[q * n + k];
          a[p * n + k] = c * apk - s * aqk;
          a[q * n + k] = s * apk + c * aqk;
        }
        for (let k = 0; k < n; k++) {
          const vkp = v[k * n + p];
          const vkq = v[k * n + q];
          v[k * n + p] = c * vkp - s * vkq;
          v[k * n + q] = s * vkp + c * vkq;
        }
      }
    }
  }

  const values = new Array(n);
  for (let i = 0; i < n; i++) values[i] = a[i * n + i];

  const order = values.map((_, i) => i).sort((i, j) => values[i] - values[j]);
  return {
    values: order.map((i) => values[i]),
    vectors: order.map((i) => {
      const column = new Array(n);
      for (let k = 0; k < n; k++) column[k] = v[k * n + i];
      return column;
    }),
  };
}

/** Solve `Ax = 0` for unit `x`: the eigenvector of `AᵀA` with least eigenvalue. */
export function nullSpaceVector(rows: number[][], n: number): number[] {
  const ata = new Array(n * n).fill(0);
  for (const row of rows) {
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) ata[i * n + j] += row[i] * row[j];
    }
  }
  return symmetricEigen(ata, n).vectors[0];
}

// ---------------------------------------------------------------------------
// Essential matrix
// ---------------------------------------------------------------------------

/**
 * Essential matrix from eight or more correspondences.
 *
 * The epipolar constraint is `b' E a = 0`, linear in E's nine entries, so eight
 * points determine it up to scale. The result is then projected onto the
 * essential manifold: a true essential matrix has two equal non-zero singular
 * values and one zero, and the linear solution generally has none of that.
 * Skipping the projection gives a matrix that decomposes into a rotation which
 * is not a rotation.
 *
 * Returns row-major 3x3.
 */
export function essentialFromCorrespondences(points: Correspondence[]): number[] {
  return estimateEssential(points).matrix;
}

function projectToEssential(e: number[]): number[] {
  // EᵀE is symmetric positive semi-definite; its eigenvectors are E's right
  // singular vectors.
  const ete = new Array(9).fill(0);
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += e[k * 3 + i] * e[k * 3 + j];
      ete[i * 3 + j] = sum;
    }
  }

  const { values, vectors } = symmetricEigen(ete, 3);
  // Ascending, so the two largest are indices 2 and 1.
  const sigma = values.map((value) => Math.sqrt(Math.max(0, value)));
  const target = (sigma[2] + sigma[1]) / 2;

  // Rebuild E with singular values (target, target, 0):
  //   E' = sum over the two largest of  target * u_i v_iᵀ
  // where u_i = E v_i / sigma_i.
  const out = new Array(9).fill(0);
  for (const index of [2, 1]) {
    if (sigma[index] < 1e-12) continue;
    const vColumn = vectors[index];
    const u = [0, 0, 0];
    for (let r = 0; r < 3; r++) {
      let sum = 0;
      for (let c = 0; c < 3; c++) sum += e[r * 3 + c] * vColumn[c];
      u[r] = sum / sigma[index];
    }
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) out[r * 3 + c] += target * u[r] * vColumn[c];
    }
  }
  return out;
}

/** Sampson distance: the first-order approximation to geometric epipolar error. */
export function sampsonDistance(e: number[], a: Vec2, b: Vec2): number {
  const ax = a.x, ay = a.y;
  const bx = b.x, by = b.y;

  // Ea and Eᵀb
  const ea0 = e[0] * ax + e[1] * ay + e[2];
  const ea1 = e[3] * ax + e[4] * ay + e[5];
  const ea2 = e[6] * ax + e[7] * ay + e[8];

  const etb0 = e[0] * bx + e[3] * by + e[6];
  const etb1 = e[1] * bx + e[4] * by + e[7];

  const numerator = bx * ea0 + by * ea1 + ea2;
  const denominator = ea0 * ea0 + ea1 * ea1 + etb0 * etb0 + etb1 * etb1;
  // Algebraic error alone is scale-dependent and useless as a threshold;
  // dividing by the gradient norm makes it a distance in normalized units.
  return denominator < 1e-30 ? Infinity : (numerator * numerator) / denominator;
}

/**
 * Recover the relative pose from an essential matrix.
 *
 * E decomposes into four candidate (R, t) pairs — two rotations times two
 * translation signs. Only one puts the triangulated points in front of both
 * cameras, so the correspondences are used to choose. This "cheirality" test is
 * not optional: three of the four candidates reconstruct the scene behind a
 * camera and look perfectly self-consistent otherwise.
 */
export function decomposeEssential(
  e: number[],
  points: Correspondence[],
): RelativePose | null {
  // E = U diag(s, s, 0) Vt.
  //
  // V comes from the eigenvectors of EtE. U must then be *derived* from E and V
  // as u_i = E v_i / s_i, not from a separate eigendecomposition of EEt: an
  // eigenvector's sign is arbitrary, so two independent decompositions produce
  // U and V whose column signs do not correspond, and U W Vt is then not the
  // rotation but some reflection of it. That failure is quiet — the matrix still
  // has determinant +1 half the time.
  const ete = new Array(9).fill(0);
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += e[k * 3 + i] * e[k * 3 + j];
      ete[i * 3 + j] = sum;
    }
  }

  const eigen = symmetricEigen(ete, 3);
  // Descending: the two large singular directions first, the null one last.
  const v1 = eigen.vectors[2];
  const v2 = eigen.vectors[1];
  const sigma1 = Math.sqrt(Math.max(0, eigen.values[2]));
  const sigma2 = Math.sqrt(Math.max(0, eigen.values[1]));
  if (sigma1 < 1e-12 || sigma2 < 1e-12) return null;

  const applyE = (v: number[]): number[] => [
    e[0] * v[0] + e[1] * v[1] + e[2] * v[2],
    e[3] * v[0] + e[4] * v[1] + e[5] * v[2],
    e[6] * v[0] + e[7] * v[1] + e[8] * v[2],
  ];
  const normalize = (v: number[]): number[] => {
    const length = Math.hypot(v[0], v[1], v[2]);
    return length < 1e-15 ? [0, 0, 0] : [v[0] / length, v[1] / length, v[2] / length];
  };
  const cross = (a: number[], b: number[]): number[] => [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];

  const u1 = normalize(applyE(v1));
  const u2 = normalize(applyE(v2));
  // Complete both bases right-handed, so U and V are rotations by construction
  // and no handedness fix is needed afterwards.
  const u3 = cross(u1, u2);
  const vNull = cross(v1, v2);

  // Column-major bases as row-major matrices.
  const uMatrix = columnsToRowMajor([u1, u2, u3]);
  const vMatrix = columnsToRowMajor([v1, v2, vNull]);

  const W = [0, -1, 0, 1, 0, 0, 0, 0, 1]; // row-major

  const R1 = multiply3(multiply3(uMatrix, W), transpose3(vMatrix));
  const R2 = multiply3(multiply3(uMatrix, transpose3(W)), transpose3(vMatrix));
  const t1: Vec3 = [u3[0], u3[1], u3[2]];
  const t2: Vec3 = [-u3[0], -u3[1], -u3[2]];

  const candidates: { rotation: number[]; translation: Vec3 }[] = [
    { rotation: R1, translation: t1 },
    { rotation: R1, translation: t2 },
    { rotation: R2, translation: t1 },
    { rotation: R2, translation: t2 },
  ];

  let best: RelativePose | null = null;
  let bestInFront = 0;

  for (const candidate of candidates) {
    // A negative determinant is a reflection, not a rotation. It arises when the
    // recovered bases came out left-handed, and using it would mirror the scene.
    if (determinant3(candidate.rotation) < 0) continue;

    let inFront = 0;
    for (const point of points) {
      const world = triangulateNormalized(
        point.a, point.b, candidate.rotation, candidate.translation,
      );
      if (!world) continue;
      // In front of camera one, whose frame is the world frame here.
      if (world[2] <= 0) continue;
      // And in front of camera two.
      const inSecond = applyRowMajor(candidate.rotation, world);
      if (inSecond[2] + candidate.translation[2] > 0) inFront++;
    }

    if (inFront > bestInFront) {
      bestInFront = inFront;
      best = {
        rotation: quat.fromMat3(rowMajorToColumnMajorFloat(candidate.rotation)),
        translation: v3.normalize(candidate.translation),
      };
    }
  }

  // Cheirality is not a tie-break, it is the whole selection. Three of the four
  // candidates reconstruct the scene behind a camera and are otherwise perfectly
  // self-consistent. If none puts a clear majority in front of both, the pair is
  // degenerate — almost always a near-zero baseline, where the essential matrix
  // carries no translation information at all.
  if (!best || bestInFront < points.length * 0.6) return null;
  return best;
}

/**
 * Estimate an essential matrix and report whether the correspondences actually
 * determine one.
 *
 * A pure rotation is the case that matters. With no baseline every
 * correspondence satisfies the epipolar constraint for *any* translation, so the
 * linear system has a multi-dimensional null space and the "solution" is an
 * arbitrary member of it. The eight-point algorithm returns something confident
 * and meaningless, and downstream that becomes a fabricated camera translation.
 *
 * The null space dimension is visible in the eigenvalues of AtA: a
 * well-conditioned pair has one tiny eigenvalue and eight large ones, while a
 * degenerate pair has several tiny ones.
 */
export function estimateEssential(points: Correspondence[]): {
  matrix: number[];
  /** Ratio of the second-smallest to the largest eigenvalue of AtA. */
  conditioning: number;
  degenerate: boolean;
} {
  if (points.length < 8) {
    throw new Error(`the eight-point algorithm needs 8 correspondences, got ${points.length}`);
  }

  const rows = points.map(({ a, b }) => [
    b.x * a.x, b.x * a.y, b.x,
    b.y * a.x, b.y * a.y, b.y,
    a.x, a.y, 1,
  ]);

  const ata = new Array(81).fill(0);
  for (const row of rows) {
    for (let i = 0; i < 9; i++) {
      for (let j = 0; j < 9; j++) ata[i * 9 + j] += row[i] * row[j];
    }
  }

  const { values, vectors } = symmetricEigen(ata, 9);
  const largest = values[8];
  // values[0] is the null direction; values[1] should be well clear of it.
  const conditioning = largest > 0 ? values[1] / largest : 0;

  return {
    matrix: projectToEssential(vectors[0]),
    conditioning,
    // Below roughly 1e-9 the second direction is also a null direction, which
    // means the translation is unobservable.
    degenerate: conditioning < 1e-9,
  };
}

// ---------------------------------------------------------------------------
// Triangulation
// ---------------------------------------------------------------------------

/**
 * Triangulate a point seen by two cameras, given the second's pose relative to
 * the first. The first camera is at the origin looking down +Z.
 *
 * Direct linear transform: each observation contributes two rows of a
 * homogeneous system, and the point is the null space.
 */
export function triangulateNormalized(
  a: Vec2,
  b: Vec2,
  rotation: number[],
  translation: Vec3,
): Vec3 | null {
  // Camera one: [I | 0]. Camera two: [R | t].
  const p1 = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
  const p2 = [
    rotation[0], rotation[1], rotation[2], translation[0],
    rotation[3], rotation[4], rotation[5], translation[1],
    rotation[6], rotation[7], rotation[8], translation[2],
  ];

  const rows: number[][] = [];
  const addRows = (p: number[], point: Vec2): void => {
    rows.push([
      point.x * p[8] - p[0], point.x * p[9] - p[1],
      point.x * p[10] - p[2], point.x * p[11] - p[3],
    ]);
    rows.push([
      point.y * p[8] - p[4], point.y * p[9] - p[5],
      point.y * p[10] - p[6], point.y * p[11] - p[7],
    ]);
  };
  addRows(p1, a);
  addRows(p2, b);

  const x = nullSpaceVector(rows, 4);
  // A near-zero homogeneous coordinate means the point is at infinity, which
  // happens when the rays are parallel — a real outcome for a distant point
  // seen from a short baseline, not an error.
  if (Math.abs(x[3]) < 1e-12) return null;
  return [x[0] / x[3], x[1] / x[3], x[2] / x[3]];
}

/**
 * Triangulate from any number of views by DLT.
 *
 * `views` gives each camera's world-to-camera transform as a 3x4 row-major
 * matrix, alongside the normalized observation.
 */
export function triangulateMultiView(
  views: { projection: number[]; point: Vec2 }[],
): Vec3 | null {
  if (views.length < 2) return null;
  const rows: number[][] = [];
  for (const { projection: p, point } of views) {
    rows.push([
      point.x * p[8] - p[0], point.x * p[9] - p[1],
      point.x * p[10] - p[2], point.x * p[11] - p[3],
    ]);
    rows.push([
      point.y * p[8] - p[4], point.y * p[9] - p[5],
      point.y * p[10] - p[6], point.y * p[11] - p[7],
    ]);
  }
  const x = nullSpaceVector(rows, 4);
  if (Math.abs(x[3]) < 1e-12) return null;
  return [x[0] / x[3], x[1] / x[3], x[2] / x[3]];
}

// ---------------------------------------------------------------------------
// Matrix helpers (row-major 3x3)
// ---------------------------------------------------------------------------

function columnsToRowMajor(columns: number[][]): number[] {
  return [
    columns[0][0], columns[1][0], columns[2][0],
    columns[0][1], columns[1][1], columns[2][1],
    columns[0][2], columns[1][2], columns[2][2],
  ];
}

function rowMajorToColumnMajorFloat(m: number[]): Float64Array {
  return new Float64Array([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);
}

export function multiply3(a: number[], b: number[]): number[] {
  const out = new Array(9).fill(0);
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += a[r * 3 + k] * b[k * 3 + c];
      out[r * 3 + c] = sum;
    }
  }
  return out;
}

export function transpose3(m: number[]): number[] {
  return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
}

export function determinant3(m: number[]): number {
  return (
    m[0] * (m[4] * m[8] - m[5] * m[7]) -
    m[1] * (m[3] * m[8] - m[5] * m[6]) +
    m[2] * (m[3] * m[7] - m[4] * m[6])
  );
}

export function applyRowMajor(m: number[], v: Vec3): Vec3 {
  return [
    m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
    m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
    m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
  ];
}

/** Quaternion to row-major 3x3. */
export function quatToRowMajor(q: Quat): number[] {
  const m = quat.toMat3(q); // column-major
  return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
}

/** World-to-camera 3x4 row-major from a camera-to-world pose. */
export function projectionFromPose(rotation: Quat, position: Vec3): number[] {
  const worldToCamera = quatToRowMajor(quat.conjugate(rotation));
  const t = applyRowMajor(worldToCamera, position);
  return [
    worldToCamera[0], worldToCamera[1], worldToCamera[2], -t[0],
    worldToCamera[3], worldToCamera[4], worldToCamera[5], -t[1],
    worldToCamera[6], worldToCamera[7], worldToCamera[8], -t[2],
  ];
}

export { mat4 };
