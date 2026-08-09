/**
 * 3D Gaussian splatting: the representation and its differentiable rasterizer.
 *
 * This is a CPU reference implementation. It is deliberately the *reference* —
 * correct, readable, and slow — because the WebGPU path in `gpu.ts` is written
 * against it and checked against it. A trainer whose gradients are subtly wrong
 * still produces something that looks like a scene, so the gradients here are
 * verified against finite differences in the tests, and the GPU path is
 * verified against these.
 *
 * The representation, per Kerbl et al. (2023): a scene is a set of anisotropic
 * 3D Gaussians, each with a position, a covariance factored into a rotation and
 * a per-axis scale, an opacity, and a view-dependent colour expressed in
 * spherical harmonics. Rendering projects each Gaussian to a 2D Gaussian in
 * image space and alpha-composites them front to back.
 *
 * Two parameterisation decisions carry through the whole file, and both exist
 * to keep the optimiser unconstrained:
 *
 *   scale is stored as **log scale** — exp() keeps it positive without a barrier
 *   opacity is stored as a **logit** — sigmoid() keeps it in [0, 1]
 *
 * Gradient descent on the raw values would need projection back into the valid
 * range every step, which stalls exactly where the interesting Gaussians are:
 * near-transparent ones about to be pruned, and near-degenerate ones about to
 * become surface-aligned.
 */

import { quat, type Quat, type Vec3 } from '@pixmyd/core/math';

/** Band-0 spherical harmonic constant: 1 / (2 sqrt(pi)). */
export const SH_C0 = 0.28209479177387814;

/** Band-1 constants. */
export const SH_C1 = 0.4886025119029199;

/** Band-2 constants, in the order the reference implementation uses. */
export const SH_C2 = [
  1.0925484305920792,
  -1.0925484305920792,
  0.31539156525252005,
  -1.0925484305920792,
  0.5462742152960396,
];

export const sigmoid = (x: number): number => 1 / (1 + Math.exp(-x));

/**
 * Trainable scene state.
 *
 * Stored as flat typed arrays rather than an array of objects: the training
 * loop touches every Gaussian every step, and an array of 200,000 objects is
 * both far slower and impossible to hand to the GPU without a repack.
 */
export interface GaussianScene {
  count: number;
  /** xyz per Gaussian. */
  positions: Float32Array;
  /** Log scale per axis. Actual scale is exp(s). */
  logScales: Float32Array;
  /** Rotation quaternion per Gaussian, [x, y, z, w]. */
  rotations: Float32Array;
  /** Logit opacity. Actual alpha is sigmoid(o). */
  logitOpacities: Float32Array;
  /** SH band 0 (DC), three per Gaussian. */
  sh0: Float32Array;
  /** Higher SH bands, coefficient-major per Gaussian. */
  shRest?: Float32Array;
  shDegree: 0 | 1 | 2 | 3;
}

export interface Camera {
  /** World-to-camera rotation is derived from this camera-to-world rotation. */
  rotation: Quat;
  /** Camera centre in world coordinates. */
  position: Vec3;
  /** Focal lengths in pixels. */
  fx: number;
  fy: number;
  cx: number;
  cy: number;
  width: number;
  height: number;
}

export function createScene(count: number, shDegree: 0 | 1 | 2 | 3 = 0): GaussianScene {
  const rest = (shDegree + 1) ** 2 - 1;
  const rotations = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) rotations[i * 4 + 3] = 1; // identity
  return {
    count,
    positions: new Float32Array(count * 3),
    logScales: new Float32Array(count * 3),
    rotations,
    logitOpacities: new Float32Array(count),
    sh0: new Float32Array(count * 3),
    shRest: rest > 0 ? new Float32Array(count * rest * 3) : undefined,
    shDegree,
  };
}

/**
 * Initialise from a point cloud.
 *
 * Scale is set from the mean distance to the nearest few neighbours, which is
 * the standard heuristic and a good one: it makes each Gaussian roughly the size
 * of the gap it has to fill, so the scene starts approximately opaque rather
 * than as a cloud of specks that gradient descent has to grow one at a time.
 */
export function sceneFromPoints(
  positions: Float32Array | Float64Array,
  colors: Uint8Array | undefined,
  count: number,
  options: { shDegree?: 0 | 1 | 2 | 3; initialOpacity?: number } = {},
): GaussianScene {
  const scene = createScene(count, options.shDegree ?? 0);
  const alpha = options.initialOpacity ?? 0.1;
  const logit = Math.log(alpha / (1 - alpha));

  for (let i = 0; i < count; i++) {
    scene.positions[i * 3] = positions[i * 3];
    scene.positions[i * 3 + 1] = positions[i * 3 + 1];
    scene.positions[i * 3 + 2] = positions[i * 3 + 2];
    scene.logitOpacities[i] = logit;

    if (colors) {
      // The DC coefficient encodes colour as (c - 0.5) / SH_C0, which is the
      // inverse of how the renderer evaluates it.
      for (let channel = 0; channel < 3; channel++) {
        const value = colors[i * 3 + channel] / 255;
        scene.sh0[i * 3 + channel] = (value - 0.5) / SH_C0;
      }
    }
  }

  const spacing = estimateSpacing(positions, count);
  for (let i = 0; i < count; i++) {
    const s = Math.log(Math.max(spacing[i], 1e-4));
    scene.logScales[i * 3] = s;
    scene.logScales[i * 3 + 1] = s;
    scene.logScales[i * 3 + 2] = s;
  }
  return scene;
}

/**
 * Mean distance to the nearest neighbours, on a uniform grid.
 *
 * A full kNN would be O(n log n) with a tree; a grid is O(n) and this only has
 * to be approximately right — it is an initialisation, and the optimiser moves
 * scales within a few hundred steps.
 */
function estimateSpacing(
  positions: Float32Array | Float64Array,
  count: number,
  neighbours = 3,
): Float32Array {
  const out = new Float32Array(count);
  if (count === 0) return out;
  if (count === 1) {
    out[0] = 0.01;
    return out;
  }

  let min = [Infinity, Infinity, Infinity];
  let max = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < count; i++) {
    for (let a = 0; a < 3; a++) {
      const v = positions[i * 3 + a];
      if (v < min[a]) min[a] = v;
      if (v > max[a]) max[a] = v;
    }
  }
  const extent = Math.max(max[0] - min[0], max[1] - min[1], max[2] - min[2], 1e-6);
  // Aim for a handful of points per cell.
  const cells = Math.max(1, Math.floor(Math.cbrt(count / 4)));
  const cellSize = extent / cells;

  const grid = new Map<number, number[]>();
  const key = (x: number, y: number, z: number): number =>
    ((x + 512) * 1024 + (y + 512)) * 1024 + (z + 512);
  const cellOf = (i: number): [number, number, number] => [
    Math.floor((positions[i * 3] - min[0]) / cellSize),
    Math.floor((positions[i * 3 + 1] - min[1]) / cellSize),
    Math.floor((positions[i * 3 + 2] - min[2]) / cellSize),
  ];

  for (let i = 0; i < count; i++) {
    const [cx, cy, cz] = cellOf(i);
    const k = key(cx, cy, cz);
    const list = grid.get(k);
    if (list) list.push(i);
    else grid.set(k, [i]);
  }

  for (let i = 0; i < count; i++) {
    const [cx, cy, cz] = cellOf(i);
    const distances: number[] = [];
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        for (let dz = -1; dz <= 1; dz++) {
          for (const j of grid.get(key(cx + dx, cy + dy, cz + dz)) ?? []) {
            if (j === i) continue;
            distances.push(
              Math.hypot(
                positions[j * 3] - positions[i * 3],
                positions[j * 3 + 1] - positions[i * 3 + 1],
                positions[j * 3 + 2] - positions[i * 3 + 2],
              ),
            );
          }
        }
      }
    }
    if (distances.length === 0) {
      out[i] = cellSize;
      continue;
    }
    distances.sort((a, b) => a - b);
    const take = Math.min(neighbours, distances.length);
    let sum = 0;
    for (let k = 0; k < take; k++) sum += distances[k];
    out[i] = Math.max(sum / take, 1e-4);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Covariance
// ---------------------------------------------------------------------------

/**
 * 3D covariance from a rotation and a per-axis scale: `Sigma = R S S^T R^T`.
 * Returned as the six upper-triangular entries (xx, xy, xz, yy, yz, zz), since
 * covariance is symmetric and storing nine wastes a third of the bandwidth.
 */
export function covariance3D(rotation: Quat, scale: Vec3): number[] {
  const r = quat.toMat3(quat.normalize(rotation)); // column-major
  // M = R * S, columns scaled.
  const m = [
    r[0] * scale[0], r[1] * scale[0], r[2] * scale[0],
    r[3] * scale[1], r[4] * scale[1], r[5] * scale[1],
    r[6] * scale[2], r[7] * scale[2], r[8] * scale[2],
  ];
  // Sigma = M M^T
  const xx = m[0] * m[0] + m[3] * m[3] + m[6] * m[6];
  const xy = m[0] * m[1] + m[3] * m[4] + m[6] * m[7];
  const xz = m[0] * m[2] + m[3] * m[5] + m[6] * m[8];
  const yy = m[1] * m[1] + m[4] * m[4] + m[7] * m[7];
  const yz = m[1] * m[2] + m[4] * m[5] + m[7] * m[8];
  const zz = m[2] * m[2] + m[5] * m[5] + m[8] * m[8];
  return [xx, xy, xz, yy, yz, zz];
}

/**
 * Project a 3D covariance into 2D image space.
 *
 * `Sigma_2D = J W Sigma W^T J^T`, where W is the world-to-camera rotation and J
 * is the Jacobian of the perspective projection at this point. The projection
 * is nonlinear, so J is a local linearisation — which is why a Gaussian near the
 * image edge renders slightly wrong in every implementation of this, including
 * the reference one.
 *
 * A small isotropic term is added to the diagonal. Without it a Gaussian seen
 * edge-on projects to a degenerate 1D sliver whose inverse does not exist, and
 * the rasterizer divides by zero.
 */
export function covariance2D(
  cameraSpace: Vec3,
  covariance: number[],
  worldToCamera: number[],
  fx: number,
  fy: number,
): [number, number, number] {
  const [x, y, z] = cameraSpace;
  const invZ = 1 / z;
  const invZ2 = invZ * invZ;

  // Perspective Jacobian, 2x3.
  const J = [
    fx * invZ, 0, -fx * x * invZ2,
    0, fy * invZ, -fy * y * invZ2,
  ];

  // T = J * W, 2x3.
  const T = new Array(6).fill(0);
  for (let r = 0; r < 2; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += J[r * 3 + k] * worldToCamera[k * 3 + c];
      T[r * 3 + c] = sum;
    }
  }

  // Full 3x3 covariance from the six stored entries.
  const [sxx, sxy, sxz, syy, syz, szz] = covariance;
  const S = [sxx, sxy, sxz, sxy, syy, syz, sxz, syz, szz];

  // Sigma_2D = T S T^T
  const TS = new Array(6).fill(0);
  for (let r = 0; r < 2; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += T[r * 3 + k] * S[k * 3 + c];
      TS[r * 3 + c] = sum;
    }
  }

  let a = 0, b = 0, c2 = 0;
  for (let k = 0; k < 3; k++) {
    a += TS[k] * T[k];
    b += TS[k] * T[3 + k];
    c2 += TS[3 + k] * T[3 + k];
  }

  // Dilate by a third of a pixel in each direction, so an edge-on Gaussian
  // stays invertible and still covers at least one pixel.
  return [a + 0.3, b, c2 + 0.3];
}

// ---------------------------------------------------------------------------
// Spherical harmonics
// ---------------------------------------------------------------------------

/**
 * Evaluate the view-dependent colour for one Gaussian.
 *
 * `direction` is the unit vector from the camera toward the Gaussian. The 0.5
 * offset is part of the convention: SH coefficients encode colour relative to
 * mid grey, so a scene with all-zero coefficients renders as 0.5 rather than
 * black.
 */
export function evaluateSh(
  scene: GaussianScene,
  index: number,
  direction: Vec3,
  degree = scene.shDegree,
): [number, number, number] {
  const out: [number, number, number] = [
    SH_C0 * scene.sh0[index * 3] + 0.5,
    SH_C0 * scene.sh0[index * 3 + 1] + 0.5,
    SH_C0 * scene.sh0[index * 3 + 2] + 0.5,
  ];

  if (degree === 0 || !scene.shRest) return out;

  const rest = (scene.shDegree + 1) ** 2 - 1;
  const base = index * rest * 3;
  const [x, y, z] = direction;

  const coefficient = (c: number, channel: number): number =>
    scene.shRest![base + c * 3 + channel];

  for (let channel = 0; channel < 3; channel++) {
    let value = 0;
    // Band 1
    value += -SH_C1 * y * coefficient(0, channel);
    value += SH_C1 * z * coefficient(1, channel);
    value += -SH_C1 * x * coefficient(2, channel);

    if (degree >= 2) {
      const xx = x * x, yy = y * y, zz = z * z;
      const xy = x * y, yz = y * z, xz = x * z;
      value += SH_C2[0] * xy * coefficient(3, channel);
      value += SH_C2[1] * yz * coefficient(4, channel);
      value += SH_C2[2] * (2 * zz - xx - yy) * coefficient(5, channel);
      value += SH_C2[3] * xz * coefficient(6, channel);
      value += SH_C2[4] * (xx - yy) * coefficient(7, channel);
    }
    out[channel] += value;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

export interface RenderResult {
  /** RGB, three floats per pixel, row-major. */
  image: Float32Array;
  /** Accumulated transmittance per pixel — 1 means nothing was drawn. */
  transmittance: Float32Array;
  /** Per-Gaussian projected data, retained for the backward pass. */
  projected: ProjectedGaussian[];
  /** Draw order, back to front by depth. */
  order: number[];
}

export interface ProjectedGaussian {
  index: number;
  /** Image-space centre, pixels. */
  x: number;
  y: number;
  depth: number;
  /** Inverse of the 2D covariance: (a, b, c) of the symmetric inverse. */
  conic: [number, number, number];
  alpha: number;
  color: [number, number, number];
  /** Pixel radius covered, from the covariance eigenvalues. */
  radius: number;
  cameraSpace: Vec3;
}

/**
 * Project every Gaussian into image space and sort them.
 *
 * Sorting is by depth, and it is *global* rather than per-tile. The reference
 * implementation sorts per tile, which is both faster and more correct at tile
 * boundaries; a global sort is simpler and adequate for a reference whose job is
 * to be checkable.
 */
export function projectScene(scene: GaussianScene, camera: Camera): {
  projected: ProjectedGaussian[];
  order: number[];
} {
  const inverseRotation = quat.conjugate(quat.normalize(camera.rotation));
  const w = quat.toMat3(inverseRotation); // column-major world-to-camera
  // Row-major, which is what covariance2D expects.
  const worldToCamera = [w[0], w[3], w[6], w[1], w[4], w[7], w[2], w[5], w[8]];

  const projected: ProjectedGaussian[] = [];

  for (let i = 0; i < scene.count; i++) {
    const dx = scene.positions[i * 3] - camera.position[0];
    const dy = scene.positions[i * 3 + 1] - camera.position[1];
    const dz = scene.positions[i * 3 + 2] - camera.position[2];

    const cameraSpace: Vec3 = [
      worldToCamera[0] * dx + worldToCamera[1] * dy + worldToCamera[2] * dz,
      worldToCamera[3] * dx + worldToCamera[4] * dy + worldToCamera[5] * dz,
      worldToCamera[6] * dx + worldToCamera[7] * dy + worldToCamera[8] * dz,
    ];
    // Behind the camera, or so close that the projection Jacobian is nonsense.
    if (cameraSpace[2] < 0.01) continue;

    const scale: Vec3 = [
      Math.exp(scene.logScales[i * 3]),
      Math.exp(scene.logScales[i * 3 + 1]),
      Math.exp(scene.logScales[i * 3 + 2]),
    ];
    const rotation: Quat = [
      scene.rotations[i * 4], scene.rotations[i * 4 + 1],
      scene.rotations[i * 4 + 2], scene.rotations[i * 4 + 3],
    ];

    const cov3d = covariance3D(rotation, scale);
    const [a, b, c] = covariance2D(cameraSpace, cov3d, worldToCamera, camera.fx, camera.fy);

    const determinant = a * c - b * b;
    if (determinant <= 1e-12) continue;
    const invDet = 1 / determinant;
    const conic: [number, number, number] = [c * invDet, -b * invDet, a * invDet];

    // Screen-space extent: three sigma along the major axis of the covariance.
    const mid = 0.5 * (a + c);
    const spread = Math.sqrt(Math.max(0.1, mid * mid - determinant));
    const radius = Math.ceil(3 * Math.sqrt(Math.max(mid + spread, mid - spread)));

    const x = camera.fx * cameraSpace[0] / cameraSpace[2] + camera.cx;
    const y = camera.fy * cameraSpace[1] / cameraSpace[2] + camera.cy;

    // Cull anything whose footprint misses the image entirely.
    if (x + radius < 0 || x - radius >= camera.width) continue;
    if (y + radius < 0 || y - radius >= camera.height) continue;

    const length = Math.hypot(dx, dy, dz);
    const direction: Vec3 = length > 1e-12
      ? [dx / length, dy / length, dz / length]
      : [0, 0, 1];

    projected.push({
      index: i,
      x, y,
      depth: cameraSpace[2],
      conic,
      alpha: sigmoid(scene.logitOpacities[i]),
      color: evaluateSh(scene, i, direction),
      radius,
      cameraSpace,
    });
  }

  // Front to back, which is the order alpha compositing needs.
  const order = projected.map((_, i) => i).sort((a, b) => projected[a].depth - projected[b].depth);
  return { projected, order };
}

/**
 * Render the scene.
 *
 * Front-to-back alpha compositing with an early-out once transmittance falls
 * below a threshold. The early-out is not merely an optimisation — without it,
 * every Gaussian behind an opaque surface receives gradient, and the optimiser
 * spends its budget refining geometry nobody can see.
 */
export function render(scene: GaussianScene, camera: Camera): RenderResult {
  const { projected, order } = projectScene(scene, camera);
  const pixels = camera.width * camera.height;
  const image = new Float32Array(pixels * 3);
  const transmittance = new Float32Array(pixels).fill(1);

  for (const p of order) {
    const g = projected[p];
    const minX = Math.max(0, Math.floor(g.x - g.radius));
    const maxX = Math.min(camera.width - 1, Math.ceil(g.x + g.radius));
    const minY = Math.max(0, Math.floor(g.y - g.radius));
    const maxY = Math.min(camera.height - 1, Math.ceil(g.y + g.radius));

    for (let py = minY; py <= maxY; py++) {
      for (let px = minX; px <= maxX; px++) {
        const pixel = py * camera.width + px;
        const T = transmittance[pixel];
        if (T < 1e-4) continue;

        const ox = px + 0.5 - g.x;
        const oy = py + 0.5 - g.y;
        // Mahalanobis distance under the projected covariance.
        const power =
          -0.5 * (g.conic[0] * ox * ox + g.conic[2] * oy * oy) - g.conic[1] * ox * oy;
        if (power > 0) continue;

        const alpha = Math.min(0.99, g.alpha * Math.exp(power));
        if (alpha < 1 / 255) continue;

        image[pixel * 3] += T * alpha * g.color[0];
        image[pixel * 3 + 1] += T * alpha * g.color[1];
        image[pixel * 3 + 2] += T * alpha * g.color[2];
        transmittance[pixel] = T * (1 - alpha);
      }
    }
  }

  return { image, transmittance, projected, order };
}
