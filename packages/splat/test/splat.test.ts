import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createScene, sceneFromPoints, render, projectScene, covariance3D, covariance2D,
  evaluateSh, sigmoid, SH_C0, type Camera, type GaussianScene,
} from '../src/gaussian.ts';
import {
  backward, zeroGradients, l1Loss, adamStep, createAdamState,
  densifyAndPrune, train, psnr, renderView, type TrainingView,
} from '../src/train.ts';
import { quat, degToRad, type Quat, type Vec3 } from '@pixmyd/core/math';

const near = (a: number, b: number, tol: number, msg = '') =>
  assert.ok(Math.abs(a - b) < tol, `${msg}: ${a} !~= ${b} (tol ${tol})`);

function camera(options: Partial<Camera> = {}): Camera {
  return {
    rotation: quat.identity(),
    position: [0, 0, -3],
    fx: 40, fy: 40, cx: 15.5, cy: 15.5,
    width: 32, height: 32,
    ...options,
  };
}

/** A few Gaussians in front of the default camera. */
function smallScene(count = 3): GaussianScene {
  const scene = createScene(count, 0);
  for (let i = 0; i < count; i++) {
    scene.positions[i * 3] = (i - (count - 1) / 2) * 0.4;
    scene.positions[i * 3 + 1] = 0.1 * i;
    scene.positions[i * 3 + 2] = 0;
    const s = Math.log(0.15);
    scene.logScales[i * 3] = s;
    scene.logScales[i * 3 + 1] = s;
    scene.logScales[i * 3 + 2] = s;
    scene.logitOpacities[i] = 0.3;
    scene.sh0[i * 3] = (0.7 - 0.5) / SH_C0;
    scene.sh0[i * 3 + 1] = (0.3 - 0.5) / SH_C0;
    scene.sh0[i * 3 + 2] = (0.5 - 0.5) / SH_C0;
  }
  return scene;
}

// ===========================================================================
// Representation
// ===========================================================================

test('an isotropic Gaussian has a diagonal covariance equal to the squared scale', () => {
  const cov = covariance3D(quat.identity(), [2, 3, 4]);
  // (xx, xy, xz, yy, yz, zz)
  near(cov[0], 4, 1e-9, 'xx');
  near(cov[3], 9, 1e-9, 'yy');
  near(cov[5], 16, 1e-9, 'zz');
  near(cov[1], 0, 1e-9, 'xy');
  near(cov[2], 0, 1e-9, 'xz');
  near(cov[4], 0, 1e-9, 'yz');
});

test('covariance is invariant to rotating an isotropic Gaussian', () => {
  const a = covariance3D(quat.identity(), [1.5, 1.5, 1.5]);
  const b = covariance3D(quat.fromAxisAngle([0.3, 1, 0.2], 0.9), [1.5, 1.5, 1.5]);
  for (let i = 0; i < 6; i++) near(a[i], b[i], 1e-9, `entry ${i}`);
});

test('rotating an anisotropic Gaussian does change its covariance', () => {
  // Otherwise the previous test would be passing for the wrong reason.
  const a = covariance3D(quat.identity(), [3, 1, 1]);
  const b = covariance3D(quat.fromAxisAngle([0, 0, 1], Math.PI / 2), [3, 1, 1]);
  assert.ok(Math.abs(a[0] - b[0]) > 1, 'a 90-degree turn should swap the axes');
  near(b[0], 1, 1e-6, 'xx becomes the short axis');
  near(b[3], 9, 1e-6, 'yy becomes the long axis');
});

test('the projected 2D covariance stays invertible for an edge-on Gaussian', () => {
  // A Gaussian flattened to nothing in one axis projects to a degenerate
  // sliver, whose inverse does not exist. The dilation term exists for this.
  const cov = covariance3D(quat.identity(), [1, 1, 1e-8]);
  const worldToCamera = [1, 0, 0, 0, 1, 0, 0, 0, 1];
  const [a, b, c] = covariance2D([0, 0, 5], cov, worldToCamera, 40, 40);
  const determinant = a * c - b * b;
  assert.ok(determinant > 0, `determinant ${determinant} must stay positive`);
});

test('spherical harmonics at degree 0 give a view-independent colour', () => {
  const scene = smallScene(1);
  const a = evaluateSh(scene, 0, [0, 0, 1]);
  const b = evaluateSh(scene, 0, [1, 0, 0]);
  assert.deepEqual(a, b, 'degree 0 must not depend on direction');
  near(a[0], 0.7, 1e-6, 'the DC term round trips through the 0.5 offset');
});

test('a zero SH scene renders mid grey, not black', () => {
  const scene = createScene(1, 0);
  scene.logScales.fill(Math.log(0.3));
  scene.logitOpacities[0] = 5; // effectively opaque
  const colour = evaluateSh(scene, 0, [0, 0, 1]);
  near(colour[0], 0.5, 1e-9, 'zero coefficients encode mid grey');
});

test('degree 1 harmonics do vary with direction', () => {
  const scene = createScene(1, 1);
  scene.shRest![0] = 1; // first band-1 coefficient, red channel
  const a = evaluateSh(scene, 0, [0, 1, 0]);
  const b = evaluateSh(scene, 0, [0, -1, 0]);
  assert.ok(Math.abs(a[0] - b[0]) > 0.5, 'opposite directions must differ');
});

// ===========================================================================
// Rendering
// ===========================================================================

test('a single opaque Gaussian renders a blob at its projected centre', () => {
  const scene = createScene(1, 0);
  scene.positions.set([0, 0, 0]);
  scene.logScales.fill(Math.log(0.2));
  scene.logitOpacities[0] = 6;
  scene.sh0.set([(1 - 0.5) / SH_C0, 0, 0]); // red

  const cam = camera();
  const result = render(scene, cam);

  // The centre pixel should be brightest and red-dominant.
  const centre = (16 * cam.width + 16) * 3;
  assert.ok(result.image[centre] > 0.5, `centre red ${result.image[centre]}`);
  assert.ok(result.image[centre] > result.image[centre + 1], 'red channel dominates');

  // A corner should be untouched.
  assert.equal(result.image[0], 0, 'the corner should be empty');
  near(result.transmittance[0], 1, 1e-9, 'and fully transmissive');
});

test('a Gaussian behind the camera is not drawn', () => {
  const scene = createScene(1, 0);
  scene.positions.set([0, 0, -10]); // behind a camera at z = -3 looking down +z
  scene.logScales.fill(Math.log(0.5));
  scene.logitOpacities[0] = 6;
  const result = render(scene, camera());
  assert.equal(result.projected.length, 0, 'nothing should project');
  assert.ok(result.image.every((v) => v === 0));
});

test('an opaque Gaussian in front occludes one behind it', () => {
  const scene = createScene(2, 0);
  // Near, opaque, red.
  scene.positions.set([0, 0, 0], 0);
  scene.logitOpacities[0] = 8;
  scene.sh0.set([(1 - 0.5) / SH_C0, (0 - 0.5) / SH_C0, (0 - 0.5) / SH_C0], 0);
  // Far, opaque, green.
  scene.positions.set([0, 0, 2], 3);
  scene.logitOpacities[1] = 8;
  scene.sh0.set([(0 - 0.5) / SH_C0, (1 - 0.5) / SH_C0, (0 - 0.5) / SH_C0], 3);
  scene.logScales.fill(Math.log(0.25));

  const cam = camera();
  const image = render(scene, cam).image;
  const centre = (16 * cam.width + 16) * 3;
  assert.ok(image[centre] > image[centre + 1] * 3, 'the near red Gaussian must win');
});

test('projection sorts front to back', () => {
  const scene = createScene(3, 0);
  scene.positions.set([0, 0, 2], 0);
  scene.positions.set([0, 0, 0], 3);
  scene.positions.set([0, 0, 1], 6);
  scene.logScales.fill(Math.log(0.2));
  const { projected, order } = projectScene(scene, camera());
  const depths = order.map((i) => projected[i].depth);
  for (let i = 1; i < depths.length; i++) {
    assert.ok(depths[i] >= depths[i - 1], 'depths must be ascending');
  }
});

// ===========================================================================
// Gradients — the tests that actually matter
// ===========================================================================

/**
 * Central finite difference of the loss with respect to one parameter.
 *
 * A trainer with a subtly wrong gradient still converges to something that
 * looks like a scene, so this is the only check that distinguishes a correct
 * backward pass from a plausible one.
 *
 * The step size matters more than it looks. Each Gaussian is rasterised over an
 * integer bounding box derived from its projected radius, and that box jumps by
 * a whole pixel at some perturbation size — a genuine discontinuity in the
 * implementation, not in the mathematics. Around 1e-3 the difference straddles
 * one of those jumps and reports a value up to 20% off; at 1e-4 and below it
 * agrees with the analytic gradient to five figures.
 */
function numericalGradient(
  scene: GaussianScene,
  cam: Camera,
  target: Float32Array,
  parameters: Float32Array,
  index: number,
  step: number,
): number {
  const original = parameters[index];
  parameters[index] = original + step;
  const plus = l1Loss(render(scene, cam).image, target);
  parameters[index] = original - step;
  const minus = l1Loss(render(scene, cam).image, target);
  parameters[index] = original;
  return (plus - minus) / (2 * step);
}

test('colour gradients match finite differences', () => {
  const scene = smallScene(2);
  const cam = camera();
  // A target that is definitely not the current render, so gradients are real.
  const target = new Float32Array(cam.width * cam.height * 3).fill(0.2);

  const gradients = zeroGradients(scene);
  backward(scene, cam, target, gradients);

  for (let i = 0; i < scene.count * 3; i++) {
    const numerical = numericalGradient(scene, cam, target, scene.sh0, i, 1e-3);
    // L1 loss is piecewise linear, so its finite difference is exact away from
    // the kinks; the tolerance covers the few pixels sitting on one.
    near(gradients.sh0[i], numerical, 2e-5, `sh0[${i}]`);
  }
});

test('opacity gradients match finite differences', () => {
  const scene = smallScene(3);
  const cam = camera();
  const target = new Float32Array(cam.width * cam.height * 3).fill(0.6);

  const gradients = zeroGradients(scene);
  backward(scene, cam, target, gradients);

  for (let i = 0; i < scene.count; i++) {
    const numerical = numericalGradient(scene, cam, target, scene.logitOpacities, i, 1e-3);
    near(gradients.logitOpacities[i], numerical, 5e-5, `opacity[${i}]`);
  }
});

/**
 * A target the render can never reach, so the L1 loss has no kinks nearby.
 *
 * L1 is piecewise linear with a corner wherever the render equals the target,
 * and a central finite difference that straddles one of those corners is
 * meaningless. Holding the target strictly above every rendered value keeps
 * `sign(render - target)` constant across the whole perturbation, which makes
 * the finite difference exact rather than merely close — a stricter test, not a
 * looser one. A ramp rather than a constant so the gradient still depends on
 * *where* each Gaussian sits.
 */
function unreachableTarget(cam: Camera): Float32Array {
  const target = new Float32Array(cam.width * cam.height * 3);
  for (let y = 0; y < cam.height; y++) {
    for (let x = 0; x < cam.width; x++) {
      const pixel = (y * cam.width + x) * 3;
      const ramp = 0.9 + 0.1 * (x / cam.width);
      target[pixel] = ramp;
      target[pixel + 1] = ramp;
      target[pixel + 2] = ramp;
    }
  }
  return target;
}

test('position gradients match finite differences, including in depth', () => {
  const scene = smallScene(2);
  const cam = camera();
  const target = unreachableTarget(cam);

  const gradients = zeroGradients(scene);
  backward(scene, cam, target, gradients);

  for (let i = 0; i < scene.count * 3; i++) {
    const numerical = numericalGradient(scene, cam, target, scene.positions, i, 1e-4);
    near(gradients.positions[i], numerical, 2e-6, `position[${i}]`);
  }
});

test('log-scale gradients match finite differences', () => {
  // Scale reaches the loss only through the projected covariance, so this is
  // the test that the whole conic chain is right. Without it the trainer
  // optimises colour and leaves geometry mushy — which looks like it worked.
  const scene = smallScene(2);
  const cam = camera();
  const target = unreachableTarget(cam);

  const gradients = zeroGradients(scene);
  backward(scene, cam, target, gradients);

  for (let i = 0; i < scene.count * 3; i++) {
    const numerical = numericalGradient(scene, cam, target, scene.logScales, i, 1e-4);
    near(gradients.logScales[i], numerical, 2e-6, `logScale[${i}]`);
  }
});

test('rotation gradients match finite differences on an anisotropic Gaussian', () => {
  // An isotropic Gaussian has no rotation gradient at all — its covariance is
  // invariant — so the Gaussians here are deliberately elongated.
  const scene = smallScene(2);
  for (let i = 0; i < scene.count; i++) {
    scene.logScales[i * 3] = Math.log(0.3);
    scene.logScales[i * 3 + 1] = Math.log(0.1);
    scene.logScales[i * 3 + 2] = Math.log(0.15);
    const r = quat.normalize([0.2, 0.3, 0.1, 0.9]);
    scene.rotations.set(r, i * 4);
  }
  const cam = camera();
  const target = unreachableTarget(cam);

  const gradients = zeroGradients(scene);
  backward(scene, cam, target, gradients);

  for (let i = 0; i < scene.count * 4; i++) {
    // Rotation needs a smaller step than position or scale: turning an
    // elongated Gaussian changes its projected radius, so its integer footprint
    // jumps at a smaller perturbation than translating it does.
    const numerical = numericalGradient(scene, cam, target, scene.rotations, i, 1e-5);
    near(gradients.rotations[i], numerical, 5e-6, `rotation[${i}]`);
  }
});

test('the alpha gradient includes the effect on Gaussians behind it', () => {
  // Two overlapping Gaussians. If the backward pass drops the "everything
  // behind" term, every Gaussian wants to be more opaque and the scene
  // converges to a solid shell. With the term present, making the front one
  // more opaque *hides* the one behind, and the gradient reflects that.
  const scene = createScene(2, 0);
  scene.positions.set([0, 0, 0], 0);
  scene.positions.set([0, 0, 1], 3);
  scene.logScales.fill(Math.log(0.25));
  scene.logitOpacities[0] = 0;
  scene.logitOpacities[1] = 0;
  // Front is black, back is white.
  scene.sh0.set([-0.5 / SH_C0, -0.5 / SH_C0, -0.5 / SH_C0], 0);
  scene.sh0.set([0.5 / SH_C0, 0.5 / SH_C0, 0.5 / SH_C0], 3);

  const cam = camera();
  // Target is bright: the optimiser should want the *front* Gaussian to become
  // more transparent so the white one behind shows through.
  const target = new Float32Array(cam.width * cam.height * 3).fill(0.9);

  const gradients = zeroGradients(scene);
  backward(scene, cam, target, gradients);

  const numerical = numericalGradient(scene, cam, target, scene.logitOpacities, 0, 1e-3);
  near(gradients.logitOpacities[0], numerical, 5e-5, 'front opacity');
  assert.ok(
    gradients.logitOpacities[0] > 0,
    'a positive gradient means descent reduces the front opacity, revealing what is behind',
  );
});

test('gradients are zero when the render already matches the target', () => {
  const scene = smallScene(2);
  const cam = camera();
  const target = render(scene, cam).image;

  const gradients = zeroGradients(scene);
  const loss = backward(scene, cam, target, gradients);
  near(loss, 0, 1e-9, 'loss');

  // L1 has a kink at zero and sign(0) is 0, so an exact match gives exactly
  // zero gradient rather than something small.
  for (let i = 0; i < gradients.sh0.length; i++) {
    near(gradients.sh0[i], 0, 1e-12, `sh0[${i}]`);
  }
});

// ===========================================================================
// Optimisation
// ===========================================================================

test('Adam moves a parameter toward reducing a quadratic', () => {
  const parameters = new Float32Array([5]);
  const state = createAdamState(1);
  for (let i = 0; i < 400; i++) {
    // d/dx of (x - 2)^2
    const gradient = new Float32Array([2 * (parameters[0] - 2)]);
    adamStep(parameters, gradient, state, { learningRate: 0.1 });
  }
  near(parameters[0], 2, 0.01, 'should converge to the minimum');
});

test('Adam applies bias correction, so the first step is a full learning rate', () => {
  const parameters = new Float32Array([0]);
  const state = createAdamState(1);
  adamStep(parameters, new Float32Array([1]), state, { learningRate: 0.1 });
  // Without bias correction the first step would be roughly 0.1 * 0.1 = 0.01.
  near(parameters[0], -0.1, 1e-4, 'first step should be the full learning rate');
});

test('training reduces the loss on a scene it can represent', () => {
  // The target is a render of a known scene; the trainee starts with the wrong
  // colours and has to find them.
  const truth = smallScene(3);
  const cam = camera();
  const views: TrainingView[] = [{ camera: cam, image: render(truth, cam).image }];

  const scene = smallScene(3);
  scene.sh0.fill(0); // all mid grey, which is wrong

  const before = l1Loss(render(scene, cam).image, views[0].image);
  const result = train(scene, views, { iterations: 150, colorLearningRate: 0.05 });

  assert.ok(result.finalLoss < before, 'loss must decrease');
  assert.ok(
    result.finalLoss < before * 0.35,
    `loss ${before.toExponential(2)} -> ${result.finalLoss.toExponential(2)}`,
  );
});

test('training improves PSNR across several views', () => {
  const truth = smallScene(3);
  const cameras = [
    camera(),
    camera({ position: [0.6, 0, -3], rotation: quat.fromAxisAngle([0, 1, 0], degToRad(-8)) }),
    camera({ position: [-0.6, 0, -3], rotation: quat.fromAxisAngle([0, 1, 0], degToRad(8)) }),
  ];
  const views: TrainingView[] = cameras.map((c) => ({ camera: c, image: render(truth, c).image }));

  const scene = smallScene(3);
  scene.sh0.fill(0);

  const psnrBefore = psnr(renderView(scene, cameras[0]), views[0].image);
  train(scene, views, { iterations: 200, colorLearningRate: 0.05 });
  const psnrAfter = psnr(renderView(scene, cameras[0]), views[0].image);

  assert.ok(psnrAfter > psnrBefore + 3, `PSNR ${psnrBefore.toFixed(1)} -> ${psnrAfter.toFixed(1)} dB`);
});

test('training can be cancelled', () => {
  const scene = smallScene(2);
  const cam = camera();
  const views: TrainingView[] = [{ camera: cam, image: new Float32Array(cam.width * cam.height * 3) }];
  const controller = new AbortController();
  controller.abort();
  const result = train(scene, views, { iterations: 100, signal: controller.signal });
  assert.equal(result.iterations, 0);
});

// ===========================================================================
// Density control
// ===========================================================================

test('transparent Gaussians are pruned', () => {
  const scene = smallScene(4);
  scene.logitOpacities[1] = -20; // effectively invisible
  scene.logitOpacities[3] = -20;

  const gradient = new Float32Array(scene.count * 3);
  const { scene: next, stats } = densifyAndPrune(scene, gradient, { opacityThreshold: 0.005 });

  assert.equal(stats.pruned, 2);
  assert.equal(next.count, 2);
});

test('a small Gaussian with a large gradient is cloned, not split', () => {
  const scene = smallScene(1);
  scene.logScales.fill(Math.log(0.001)); // small
  const gradient = new Float32Array([1, 0, 0]);

  const { stats } = densifyAndPrune(scene, gradient, {
    gradientThreshold: 1e-6, sizeThreshold: 0.01,
  });
  assert.equal(stats.cloned, 1);
  assert.equal(stats.split, 0);
});

test('a large Gaussian with a large gradient is split, and both halves shrink', () => {
  const scene = smallScene(1);
  scene.logScales.fill(Math.log(0.5)); // large
  const gradient = new Float32Array([1, 0, 0]);

  const { scene: next, stats } = densifyAndPrune(scene, gradient, {
    gradientThreshold: 1e-6, sizeThreshold: 0.01,
  });
  assert.equal(stats.split, 1);
  assert.equal(next.count, 2);
  // Two Gaussians of the original size would over-cover the region.
  for (let i = 0; i < 2; i++) {
    assert.ok(
      Math.exp(next.logScales[i * 3]) < 0.5,
      `half ${i} should be smaller than the original`,
    );
  }
});

test('a clone is displaced, so the two copies can separate', () => {
  // Identical Gaussians receive identical gradients and would never diverge.
  const scene = smallScene(1);
  scene.logScales.fill(Math.log(0.001));
  const { scene: next } = densifyAndPrune(scene, new Float32Array([1, 0, 0]), {
    gradientThreshold: 1e-6,
  });
  const separation = Math.hypot(
    next.positions[0] - next.positions[3],
    next.positions[1] - next.positions[4],
    next.positions[2] - next.positions[5],
  );
  assert.ok(separation > 0, 'the clone must not sit exactly on the original');
});

test('density control respects a maximum count', () => {
  const scene = smallScene(10);
  scene.logScales.fill(Math.log(0.001));
  const gradient = new Float32Array(scene.count * 3).fill(1);
  const { scene: next } = densifyAndPrune(scene, gradient, {
    gradientThreshold: 1e-9, maxCount: 12,
  });
  assert.ok(next.count <= 12, `count ${next.count} must respect the ceiling`);
});

test('nothing is densified when gradients are below the threshold', () => {
  const scene = smallScene(5);
  const { scene: next, stats } = densifyAndPrune(scene, new Float32Array(15), {
    gradientThreshold: 1e-3,
  });
  assert.equal(stats.cloned, 0);
  assert.equal(stats.split, 0);
  assert.equal(next.count, 5);
});

// ===========================================================================
// Initialisation
// ===========================================================================

test('a scene built from points takes their positions and colours', () => {
  const positions = new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]);
  const colors = new Uint8Array([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]);
  const scene = sceneFromPoints(positions, colors, 4);

  assert.equal(scene.count, 4);
  assert.deepEqual([...scene.positions], [...positions]);
  // The DC coefficient must round-trip back through the renderer's convention.
  const red = evaluateSh(scene, 0, [0, 0, 1]);
  near(red[0], 1, 1e-5, 'red channel');
  near(red[1], 0, 1e-5, 'green channel');
});

test('initial scale follows local point spacing', () => {
  // Two clusters at very different densities. The dense one should get smaller
  // Gaussians, or it starts out over-covered and the optimiser has to undo it.
  const positions: number[] = [];
  for (let i = 0; i < 20; i++) positions.push(i * 0.01, 0, 0);
  for (let i = 0; i < 20; i++) positions.push(10 + i * 1.0, 0, 0);
  const scene = sceneFromPoints(Float32Array.from(positions), undefined, 40);

  const denseScale = Math.exp(scene.logScales[5 * 3]);
  const sparseScale = Math.exp(scene.logScales[30 * 3]);
  assert.ok(
    sparseScale > denseScale * 5,
    `sparse ${sparseScale.toFixed(4)} should be well above dense ${denseScale.toFixed(4)}`,
  );
});

test('a single point does not produce a degenerate scale', () => {
  const scene = sceneFromPoints(new Float32Array([1, 2, 3]), undefined, 1);
  assert.ok(Number.isFinite(scene.logScales[0]), 'scale must be finite');
  assert.ok(Math.exp(scene.logScales[0]) > 0, 'and positive');
});

test('an empty point cloud produces an empty scene rather than throwing', () => {
  const scene = sceneFromPoints(new Float32Array(0), undefined, 0);
  assert.equal(scene.count, 0);
  assert.equal(render(scene, camera()).projected.length, 0);
});
