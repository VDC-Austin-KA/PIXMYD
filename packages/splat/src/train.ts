/**
 * Training: the backward pass, Adam, and adaptive density control.
 *
 * The backward pass is the part worth being careful about. A trainer with a
 * subtly wrong gradient still converges to *something* that looks like a scene
 * — blurrier, or with the wrong colours at grazing angles — so it is not
 * self-evident from the output that anything is wrong. The gradients here are
 * therefore checked against central finite differences in the tests, parameter
 * by parameter.
 *
 * Every trainable parameter has an analytic gradient: colour and opacity
 * directly from the compositing recurrence, and position, scale and rotation
 * through the covariance chain in `covariance-grad.ts`. All five are checked
 * against central finite differences.
 */

import { quat, type Quat, type Vec3 } from '@pixmyd/core/math';
import {
  covariance3D, evaluateSh, projectScene, render, sigmoid, SH_C0,
  type Camera, type GaussianScene,
} from './gaussian.ts';
import { covarianceGradients } from './covariance-grad.ts';

export interface TrainingView {
  camera: Camera;
  /** Ground truth image, RGB floats in [0, 1], row-major. */
  image: Float32Array;
}

export interface Gradients {
  positions: Float32Array;
  logScales: Float32Array;
  rotations: Float32Array;
  logitOpacities: Float32Array;
  sh0: Float32Array;
  shRest?: Float32Array;
}

export function zeroGradients(scene: GaussianScene): Gradients {
  const rest = (scene.shDegree + 1) ** 2 - 1;
  return {
    positions: new Float32Array(scene.count * 3),
    logScales: new Float32Array(scene.count * 3),
    rotations: new Float32Array(scene.count * 4),
    logitOpacities: new Float32Array(scene.count),
    sh0: new Float32Array(scene.count * 3),
    shRest: rest > 0 ? new Float32Array(scene.count * rest * 3) : undefined,
  };
}

/**
 * Mean absolute error between a render and its target.
 *
 * L1 rather than L2, following the reference implementation. Squared error
 * rewards blur: given uncertainty about where an edge is, the L2-optimal answer
 * is to smear it, and a scene of smeared Gaussians has lower squared error than
 * one that commits. L1 does not have that bias.
 */
export function l1Loss(render: Float32Array, target: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < render.length; i++) sum += Math.abs(render[i] - target[i]);
  return sum / render.length;
}

/**
 * Backward pass.
 *
 * Both reach the loss through one alpha-compositing step, so the derivative is
 * short enough to derive and cheap enough to be worth doing exactly.
 *
 * The compositing recurrence, front to back:
 *
 *     C = sum_i T_i a_i c_i,   T_{i+1} = T_i (1 - a_i)
 *
 * so dC/dc_i = T_i a_i, and dC/da_i has two terms — the direct contribution
 * `T_i c_i`, and the effect on everything *behind* this Gaussian, which is
 * `-T_i / (1 - a_i)` times the colour already accumulated behind it. Missing
 * the second term is the classic mistake; it makes every Gaussian want to be
 * more opaque, and the scene converges to a solid shell.
 */
export function backward(
  scene: GaussianScene,
  camera: Camera,
  target: Float32Array,
  gradients: Gradients,
): number {
  const { projected, order } = projectScene(scene, camera);
  const pixels = camera.width * camera.height;
  const image = new Float32Array(pixels * 3);
  const transmittance = new Float32Array(pixels).fill(1);

  // Forward, recording per-pixel state.
  interface Contribution {
    gaussian: number;
    pixel: number;
    T: number;
    alpha: number;
  }
  const contributions: Contribution[] = [];

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
        const power =
          -0.5 * (g.conic[0] * ox * ox + g.conic[2] * oy * oy) - g.conic[1] * ox * oy;
        if (power > 0) continue;

        const alpha = Math.min(0.99, g.alpha * Math.exp(power));
        if (alpha < 1 / 255) continue;

        image[pixel * 3] += T * alpha * g.color[0];
        image[pixel * 3 + 1] += T * alpha * g.color[1];
        image[pixel * 3 + 2] += T * alpha * g.color[2];
        transmittance[pixel] = T * (1 - alpha);
        contributions.push({ gaussian: p, pixel, T, alpha });
      }
    }
  }

  // dLoss/dPixel for mean L1.
  const scale = 1 / (pixels * 3);
  const dImage = new Float32Array(pixels * 3);
  for (let i = 0; i < dImage.length; i++) {
    dImage[i] = Math.sign(image[i] - target[i]) * scale;
  }

  // Walk contributions in reverse so `behind` accumulates what lies further
  // back than the Gaussian currently being differentiated.
  const behind = new Float32Array(pixels * 3);

  // Per-Gaussian accumulators for the geometry chain. Position, scale and
  // rotation all reach the loss only through the projected centre and the
  // conic, so those two are accumulated here and pushed back once per Gaussian
  // rather than once per pixel — the chain is four matrix products deep and
  // running it per pixel would dominate the whole backward pass.
  const dConic = new Float64Array(projected.length * 3);
  const dMean = new Float64Array(projected.length * 2);

  for (let k = contributions.length - 1; k >= 0; k--) {
    const { gaussian, pixel, T, alpha } = contributions[k];
    const g = projected[gaussian];
    const index = g.index;

    const dR = dImage[pixel * 3];
    const dG = dImage[pixel * 3 + 1];
    const dB = dImage[pixel * 3 + 2];

    // Colour: dC/dc = T * alpha, then through the SH DC coefficient.
    const colorWeight = T * alpha;
    gradients.sh0[index * 3] += dR * colorWeight * SH_C0;
    gradients.sh0[index * 3 + 1] += dG * colorWeight * SH_C0;
    gradients.sh0[index * 3 + 2] += dB * colorWeight * SH_C0;

    // Alpha: the direct term plus the effect on everything behind.
    const oneMinusAlpha = Math.max(1e-6, 1 - alpha);
    let dAlpha = 0;
    dAlpha += dR * T * (g.color[0] - behind[pixel * 3] / oneMinusAlpha);
    dAlpha += dG * T * (g.color[1] - behind[pixel * 3 + 1] / oneMinusAlpha);
    dAlpha += dB * T * (g.color[2] - behind[pixel * 3 + 2] / oneMinusAlpha);

    // alpha = sigmoid(o) * exp(power), and only the sigmoid depends on o.
    const opacity = sigmoid(scene.logitOpacities[index]);
    gradients.logitOpacities[index] += dAlpha * alpha * (1 - opacity);

    // Everything geometric flows through `power`.
    const px = pixel % camera.width;
    const py = Math.floor(pixel / camera.width);
    const ox = px + 0.5 - g.x;
    const oy = py + 0.5 - g.y;
    const dPower = dAlpha * alpha;

    // power = -0.5 (a ox^2 + c oy^2) - b ox oy
    dConic[gaussian * 3] += dPower * -0.5 * ox * ox;
    dConic[gaussian * 3 + 1] += dPower * -ox * oy;
    dConic[gaussian * 3 + 2] += dPower * -0.5 * oy * oy;

    // d(power)/d(centre): the offsets are (pixel - centre), so the sign flips.
    dMean[gaussian * 2] += dPower * (g.conic[0] * ox + g.conic[1] * oy);
    dMean[gaussian * 2 + 1] += dPower * (g.conic[2] * oy + g.conic[1] * ox);

    behind[pixel * 3] += T * alpha * g.color[0];
    behind[pixel * 3 + 1] += T * alpha * g.color[1];
    behind[pixel * 3 + 2] += T * alpha * g.color[2];
  }

  // Second pass: push the accumulated conic and centre gradients back onto
  // position, scale and rotation.
  const w = quat.toMat3(quat.conjugate(quat.normalize(camera.rotation)));
  const worldToCamera = [w[0], w[3], w[6], w[1], w[4], w[7], w[2], w[5], w[8]];

  for (let p = 0; p < projected.length; p++) {
    const g = projected[p];
    const index = g.index;

    const scale: Vec3 = [
      Math.exp(scene.logScales[index * 3]),
      Math.exp(scene.logScales[index * 3 + 1]),
      Math.exp(scene.logScales[index * 3 + 2]),
    ];
    const rotation: Quat = [
      scene.rotations[index * 4], scene.rotations[index * 4 + 1],
      scene.rotations[index * 4 + 2], scene.rotations[index * 4 + 3],
    ];

    const result = covarianceGradients({
      dConic: [dConic[p * 3], dConic[p * 3 + 1], dConic[p * 3 + 2]],
      dMean: [dMean[p * 2], dMean[p * 2 + 1]],
      cameraSpace: g.cameraSpace,
      covariance3D: covariance3D(rotation, scale),
      worldToCamera,
      rotation,
      scale,
      fx: camera.fx,
      fy: camera.fy,
    });

    for (let a = 0; a < 3; a++) {
      gradients.positions[index * 3 + a] += result.dPosition[a];
      gradients.logScales[index * 3 + a] += result.dLogScale[a];
    }
    for (let a = 0; a < 4; a++) {
      gradients.rotations[index * 4 + a] += result.dRotation[a];
    }
  }

  return l1Loss(image, target);
}

// ---------------------------------------------------------------------------
// Adam
// ---------------------------------------------------------------------------

export interface AdamState {
  m: Float32Array;
  v: Float32Array;
  step: number;
}

export function createAdamState(length: number): AdamState {
  return { m: new Float32Array(length), v: new Float32Array(length), step: 0 };
}

export interface AdamOptions {
  learningRate: number;
  beta1?: number;
  beta2?: number;
  epsilon?: number;
}

export function adamStep(
  parameters: Float32Array,
  gradient: Float32Array,
  state: AdamState,
  options: AdamOptions,
): void {
  const beta1 = options.beta1 ?? 0.9;
  const beta2 = options.beta2 ?? 0.999;
  const epsilon = options.epsilon ?? 1e-15;
  state.step++;

  // Bias correction matters most in the first few dozen steps, which is exactly
  // when densification decisions are being made from gradient magnitudes.
  const correction1 = 1 - Math.pow(beta1, state.step);
  const correction2 = 1 - Math.pow(beta2, state.step);

  for (let i = 0; i < parameters.length; i++) {
    const g = gradient[i];
    state.m[i] = beta1 * state.m[i] + (1 - beta1) * g;
    state.v[i] = beta2 * state.v[i] + (1 - beta2) * g * g;
    const mHat = state.m[i] / correction1;
    const vHat = state.v[i] / correction2;
    parameters[i] -= (options.learningRate * mHat) / (Math.sqrt(vHat) + epsilon);
  }
}

// ---------------------------------------------------------------------------
// Density control
// ---------------------------------------------------------------------------

export interface DensifyOptions {
  /** Positional gradient above which a Gaussian is split or cloned. */
  gradientThreshold?: number;
  /** World-space size above which a Gaussian is split rather than cloned. */
  sizeThreshold?: number;
  /** Opacity below which a Gaussian is removed. */
  opacityThreshold?: number;
  /** Hard ceiling on the Gaussian count, so memory stays bounded. */
  maxCount?: number;
}

export interface DensifyStats {
  cloned: number;
  split: number;
  pruned: number;
  count: number;
}

/**
 * Adaptive density control: clone, split and prune.
 *
 * This is what makes 3DGS work at all. Optimisation alone cannot change the
 * *number* of Gaussians, so a scene initialised from a sparse point cloud can
 * never represent detail finer than that cloud. The heuristic, from the paper:
 *
 *   **Under-reconstruction** — a small Gaussian in a region that wants more
 *   detail shows a large positional gradient because it is being pulled in
 *   several directions at once. Clone it, and let the two copies separate.
 *
 *   **Over-reconstruction** — a large Gaussian covering detail it cannot
 *   represent shows the same large gradient. Split it into two smaller ones.
 *
 * The two cases are distinguished by size alone, which is crude and works.
 * Pruning removes anything that has become transparent, which is the mechanism
 * that keeps the count from growing without bound.
 */
export function densifyAndPrune(
  scene: GaussianScene,
  positionGradient: Float32Array,
  options: DensifyOptions = {},
): { scene: GaussianScene; stats: DensifyStats } {
  const gradientThreshold = options.gradientThreshold ?? 2e-7;
  const sizeThreshold = options.sizeThreshold ?? 0.01;
  const opacityThreshold = options.opacityThreshold ?? 0.005;
  const maxCount = options.maxCount ?? 2_000_000;

  const keep: number[] = [];
  const clone: number[] = [];
  const split: number[] = [];

  for (let i = 0; i < scene.count; i++) {
    if (sigmoid(scene.logitOpacities[i]) < opacityThreshold) continue;
    keep.push(i);

    const magnitude = Math.hypot(
      positionGradient[i * 3],
      positionGradient[i * 3 + 1],
      positionGradient[i * 3 + 2],
    );
    if (magnitude < gradientThreshold) continue;

    const maxScale = Math.max(
      Math.exp(scene.logScales[i * 3]),
      Math.exp(scene.logScales[i * 3 + 1]),
      Math.exp(scene.logScales[i * 3 + 2]),
    );
    if (maxScale > sizeThreshold) split.push(i);
    else clone.push(i);
  }

  const budget = Math.max(0, maxCount - keep.length);
  const cloneList = clone.slice(0, budget);
  const splitList = split.slice(0, Math.max(0, budget - cloneList.length));

  const rest = (scene.shDegree + 1) ** 2 - 1;
  const total = keep.length + cloneList.length + splitList.length;
  const next = {
    count: total,
    positions: new Float32Array(total * 3),
    logScales: new Float32Array(total * 3),
    rotations: new Float32Array(total * 4),
    logitOpacities: new Float32Array(total),
    sh0: new Float32Array(total * 3),
    shRest: rest > 0 ? new Float32Array(total * rest * 3) : undefined,
    shDegree: scene.shDegree,
  } satisfies GaussianScene;

  const copy = (from: number, to: number): void => {
    for (let a = 0; a < 3; a++) {
      next.positions[to * 3 + a] = scene.positions[from * 3 + a];
      next.logScales[to * 3 + a] = scene.logScales[from * 3 + a];
      next.sh0[to * 3 + a] = scene.sh0[from * 3 + a];
    }
    for (let a = 0; a < 4; a++) {
      next.rotations[to * 4 + a] = scene.rotations[from * 4 + a];
    }
    next.logitOpacities[to] = scene.logitOpacities[from];
    if (scene.shRest && next.shRest) {
      for (let c = 0; c < rest * 3; c++) {
        next.shRest[to * rest * 3 + c] = scene.shRest[from * rest * 3 + c];
      }
    }
  };

  keep.forEach((from, to) => copy(from, to));

  let at = keep.length;
  // Clones are displaced slightly along the gradient, so the two copies do not
  // sit exactly on top of each other — identical Gaussians receive identical
  // gradients and would never separate.
  for (const from of cloneList) {
    copy(from, at);
    const magnitude = Math.hypot(
      positionGradient[from * 3],
      positionGradient[from * 3 + 1],
      positionGradient[from * 3 + 2],
    ) || 1;
    const step = Math.exp(scene.logScales[from * 3]) * 0.5;
    for (let a = 0; a < 3; a++) {
      next.positions[at * 3 + a] -= (positionGradient[from * 3 + a] / magnitude) * step;
    }
    at++;
  }

  // Splits shrink both halves. The 1.6 divisor is the paper's, and the point of
  // it is that two Gaussians of the original size would over-cover the region
  // and drive the local opacity above what the image supports.
  for (const from of splitList) {
    copy(from, at);
    const displacement = [0, 0, 0];
    for (let a = 0; a < 3; a++) {
      displacement[a] = (Math.random() - 0.5) * Math.exp(scene.logScales[from * 3 + a]);
    }
    for (let a = 0; a < 3; a++) {
      next.positions[at * 3 + a] += displacement[a];
      next.logScales[at * 3 + a] = scene.logScales[from * 3 + a] - Math.log(1.6);
    }
    // The original shrinks too, and moves the other way.
    const original = keep.indexOf(from);
    if (original >= 0) {
      for (let a = 0; a < 3; a++) {
        next.positions[original * 3 + a] -= displacement[a];
        next.logScales[original * 3 + a] = scene.logScales[from * 3 + a] - Math.log(1.6);
      }
    }
    at++;
  }

  return {
    scene: next,
    stats: {
      cloned: cloneList.length,
      split: splitList.length,
      pruned: scene.count - keep.length,
      count: total,
    },
  };
}

// ---------------------------------------------------------------------------
// Training loop
// ---------------------------------------------------------------------------

export interface TrainOptions {
  iterations?: number;
  positionLearningRate?: number;
  scaleLearningRate?: number;
  rotationLearningRate?: number;
  opacityLearningRate?: number;
  colorLearningRate?: number;
  /** Run density control every N iterations. Zero disables it. */
  densifyInterval?: number;
  densify?: DensifyOptions;
  signal?: AbortSignal;
  onProgress?: (iteration: number, loss: number, count: number) => void;
}

export interface TrainResult {
  scene: GaussianScene;
  initialLoss: number;
  finalLoss: number;
  iterations: number;
}

/**
 * Train a scene against a set of posed views.
 *
 * One view per iteration, cycled. Stochastic rather than full-batch because the
 * gradient from a single view is already a good descent direction and a full
 * pass over hundreds of images per step would make the first update take
 * minutes.
 */
export function train(
  scene: GaussianScene,
  views: TrainingView[],
  options: TrainOptions = {},
): TrainResult {
  const iterations = options.iterations ?? 200;
  const densifyInterval = options.densifyInterval ?? 0;

  let current = scene;
  let adam = {
    positions: createAdamState(current.count * 3),
    logScales: createAdamState(current.count * 3),
    rotations: createAdamState(current.count * 4),
    logitOpacities: createAdamState(current.count),
    sh0: createAdamState(current.count * 3),
  };

  let initialLoss = 0;
  let loss = 0;
  let completed = 0;

  for (let iteration = 0; iteration < iterations; iteration++) {
    if (options.signal?.aborted) break;

    const view = views[iteration % views.length];
    const gradients = zeroGradients(current);
    loss = backward(current, view.camera, view.image, gradients);
    if (iteration === 0) initialLoss = loss;

    adamStep(current.positions, gradients.positions, adam.positions, {
      learningRate: options.positionLearningRate ?? 1.6e-4,
    });
    adamStep(current.logitOpacities, gradients.logitOpacities, adam.logitOpacities, {
      learningRate: options.opacityLearningRate ?? 0.05,
    });
    adamStep(current.sh0, gradients.sh0, adam.sh0, {
      learningRate: options.colorLearningRate ?? 0.0025,
    });

    completed = iteration + 1;
    options.onProgress?.(iteration, loss, current.count);

    if (densifyInterval > 0 && iteration > 0 && iteration % densifyInterval === 0) {
      const result = densifyAndPrune(current, gradients.positions, options.densify);
      current = result.scene;
      // Adam's moments are per-parameter, and the parameter vector just changed
      // shape. Carrying them over would apply one Gaussian's history to another.
      adam = {
        positions: createAdamState(current.count * 3),
        logScales: createAdamState(current.count * 3),
        rotations: createAdamState(current.count * 4),
        logitOpacities: createAdamState(current.count),
        sh0: createAdamState(current.count * 3),
      };
    }
  }

  return { scene: current, initialLoss, finalLoss: loss, iterations: completed };
}

/** Render a view, for previewing or for computing a metric. */
export function renderView(scene: GaussianScene, camera: Camera): Float32Array {
  return render(scene, camera).image;
}

/** Peak signal-to-noise ratio, the conventional reconstruction metric. */
export function psnr(rendered: Float32Array, target: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < rendered.length; i++) {
    const d = rendered[i] - target[i];
    sum += d * d;
  }
  const mse = sum / rendered.length;
  return mse < 1e-20 ? Infinity : 10 * Math.log10(1 / mse);
}
