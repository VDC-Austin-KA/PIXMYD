import test from 'node:test';
import assert from 'node:assert/strict';
import {
  symmetricEigen, essentialFromCorrespondences, decomposeEssential,
  sampsonDistance, triangulateNormalized, triangulateMultiView,
  projectionFromPose, quatToRowMajor, determinant3, multiply3, transpose3,
  type Correspondence, type Vec2,
} from '../src/geometry.ts';
import {
  solvePnpDlt, solvePnpRansac, refinePnp, reproject, reprojectionRms,
  solveLinearSystem, type PnpObservation,
} from '../src/pnp.ts';
import { bundleAdjust, type BaObservation } from '../src/bundle-adjust.ts';
import { quat, v3, degToRad, type Quat, type Vec3 } from '@pixmyd/core/math';

const near = (a: number, b: number, tol: number, msg = '') =>
  assert.ok(Math.abs(a - b) < tol, `${msg}: ${a} !~= ${b} (tol ${tol})`);

/** Deterministic PRNG, so a failure is reproducible. */
function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state / 0x100000000;
  };
}

/** Project a world point into a camera, in normalized coordinates. */
function project(world: Vec3, rotation: Quat, position: Vec3): Vec2 | null {
  const local = quat.rotate(quat.conjugate(rotation), v3.sub(world, position));
  if (local[2] <= 1e-9) return null;
  return { x: local[0] / local[2], y: local[1] / local[2] };
}

/** A cloud of points in front of the origin, filling a frustum. */
function scenePoints(count: number, seed = 1): Vec3[] {
  const random = rng(seed);
  const points: Vec3[] = [];
  for (let i = 0; i < count; i++) {
    points.push([
      (random() - 0.5) * 6,
      (random() - 0.5) * 4,
      4 + random() * 8,
    ]);
  }
  return points;
}

// ===========================================================================
// Linear algebra
// ===========================================================================

test('symmetric eigendecomposition recovers known eigenvalues', () => {
  // diag(1, 2, 3) rotated — eigenvalues are invariant under conjugation.
  const r = quatToRowMajor(quat.fromAxisAngle([1, 1, 1], 0.7));
  const d = [1, 0, 0, 0, 2, 0, 0, 0, 3];
  const a = multiply3(multiply3(r, d), transpose3(r));

  const { values, vectors } = symmetricEigen(a, 3);
  near(values[0], 1, 1e-9, 'smallest');
  near(values[1], 2, 1e-9, 'middle');
  near(values[2], 3, 1e-9, 'largest');

  // Each eigenvector must satisfy A v = lambda v.
  for (let i = 0; i < 3; i++) {
    const v = vectors[i];
    for (let row = 0; row < 3; row++) {
      const av = a[row * 3] * v[0] + a[row * 3 + 1] * v[1] + a[row * 3 + 2] * v[2];
      near(av, values[i] * v[row], 1e-8, `eigenvector ${i} row ${row}`);
    }
  }
});

test('linear solver handles a system needing pivoting', () => {
  // A zero leading pivot: fails immediately without partial pivoting.
  const a = [0, 2, 1, 1, 0, 3, 4, 5, 6];
  const b = [5, 10, 31];
  const x = solveLinearSystem(a, b, 3)!;
  assert.ok(x, 'must solve');
  for (let row = 0; row < 3; row++) {
    const sum = a[row * 3] * x[0] + a[row * 3 + 1] * x[1] + a[row * 3 + 2] * x[2];
    near(sum, b[row], 1e-9, `row ${row}`);
  }
});

test('linear solver reports singularity rather than returning nonsense', () => {
  // Third row is the sum of the first two.
  assert.equal(solveLinearSystem([1, 2, 3, 4, 5, 6, 5, 7, 9], [1, 2, 3], 3), null);
});

// ===========================================================================
// Two-view geometry
// ===========================================================================

test('essential matrix satisfies the epipolar constraint on its own data', () => {
  const rotation = quat.fromAxisAngle([0, 1, 0], degToRad(12));
  const position: Vec3 = [1.2, 0.1, 0.3];
  const points = scenePoints(20, 7);

  const correspondences: Correspondence[] = [];
  for (const world of points) {
    const a = project(world, quat.identity(), [0, 0, 0]);
    const b = project(world, rotation, position);
    if (a && b) correspondences.push({ a, b });
  }
  assert.ok(correspondences.length >= 8);

  const e = essentialFromCorrespondences(correspondences);
  for (const { a, b } of correspondences) {
    assert.ok(
      sampsonDistance(e, a, b) < 1e-14,
      `epipolar residual ${sampsonDistance(e, a, b)} should be numerically zero`,
    );
  }
});

test('an essential matrix has two equal singular values and one zero', () => {
  // This is the defining property. The raw eight-point solution has none of it,
  // and skipping the projection yields a "rotation" that is not one.
  const rotation = quat.fromAxisAngle([0.2, 1, 0.1], degToRad(20));
  const position: Vec3 = [2, 0.5, -0.4];
  const correspondences: Correspondence[] = [];
  for (const world of scenePoints(30, 11)) {
    const a = project(world, quat.identity(), [0, 0, 0]);
    const b = project(world, rotation, position);
    if (a && b) correspondences.push({ a, b });
  }

  const e = essentialFromCorrespondences(correspondences);
  // Singular values are the square roots of the eigenvalues of EᵀE.
  const ete = new Array(9).fill(0);
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += e[k * 3 + i] * e[k * 3 + j];
      ete[i * 3 + j] = sum;
    }
  }
  const sigma = symmetricEigen(ete, 3).values.map((v) => Math.sqrt(Math.max(0, v)));
  // Relative to the non-zero singular values: Jacobi converges to about 1e-8
  // relative, and an absolute tolerance here would just be testing the
  // eigensolver's iteration count.
  near(sigma[0] / sigma[2], 0, 1e-7, 'smallest singular value must be zero');
  near(sigma[1] / sigma[2], 1, 1e-7, 'the other two must be equal');
});

test('relative pose is recovered from the essential matrix, up to baseline scale', () => {
  const rotation = quat.fromAxisAngle([0.1, 1, 0.2], degToRad(15));
  const position: Vec3 = [1.5, 0.2, 0.6];

  const correspondences: Correspondence[] = [];
  for (const world of scenePoints(40, 3)) {
    const a = project(world, quat.identity(), [0, 0, 0]);
    const b = project(world, rotation, position);
    if (a && b) correspondences.push({ a, b });
  }

  const e = essentialFromCorrespondences(correspondences);
  const pose = decomposeEssential(e, correspondences)!;
  assert.ok(pose, 'a pose must be recovered');

  // The decomposition gives world-to-camera for the second view; compare its
  // action against the true inverse rotation.
  const expected = quat.conjugate(rotation);
  for (const probe of [[1, 0, 0], [0, 1, 0], [0, 0, 1]] as Vec3[]) {
    const actual = quat.rotate(pose.rotation, probe);
    const truth = quat.rotate(expected, probe);
    for (let i = 0; i < 3; i++) near(actual[i], truth[i], 1e-6, 'rotation');
  }

  // Translation is only determined up to scale — a two-view solve cannot see
  // the baseline length. Compare directions.
  const trueTranslation = v3.normalize(
    v3.negate(quat.rotate(quat.conjugate(rotation), position)),
  );
  const dot = Math.abs(v3.dot(v3.normalize(pose.translation), trueTranslation));
  near(dot, 1, 1e-6, 'translation direction');
});

test('a pure rotation is rejected rather than solved wrongly', () => {
  // With no baseline the essential matrix carries no translation information,
  // and every candidate decomposition is equally (in)valid. Returning a
  // confident answer here would inject a fabricated translation into the
  // reconstruction.
  const rotation = quat.fromAxisAngle([0, 1, 0], degToRad(10));
  const correspondences: Correspondence[] = [];
  for (const world of scenePoints(30, 5)) {
    const a = project(world, quat.identity(), [0, 0, 0]);
    const b = project(world, rotation, [0, 0, 0]);
    if (a && b) correspondences.push({ a, b });
  }
  const e = essentialFromCorrespondences(correspondences);
  const pose = decomposeEssential(e, correspondences);
  assert.equal(pose, null, 'a zero-baseline pair must not yield a pose');
});

test('the recovered rotation is a rotation, not a reflection', () => {
  const rotation = quat.fromAxisAngle([1, 0.3, 0.2], degToRad(25));
  const position: Vec3 = [-1.8, 0.4, 0.2];
  const correspondences: Correspondence[] = [];
  for (const world of scenePoints(40, 13)) {
    const a = project(world, quat.identity(), [0, 0, 0]);
    const b = project(world, rotation, position);
    if (a && b) correspondences.push({ a, b });
  }
  const pose = decomposeEssential(
    essentialFromCorrespondences(correspondences), correspondences,
  )!;
  near(determinant3(quatToRowMajor(pose.rotation)), 1, 1e-9, 'determinant must be +1');
});

// ===========================================================================
// Triangulation
// ===========================================================================

test('two-view triangulation recovers points exactly without noise', () => {
  const rotation = quat.fromAxisAngle([0, 1, 0], degToRad(20));
  const position: Vec3 = [2, 0, 0];
  const worldToCamera = quatToRowMajor(quat.conjugate(rotation));
  const t = v3.negate(
    [
      worldToCamera[0] * position[0] + worldToCamera[1] * position[1] + worldToCamera[2] * position[2],
      worldToCamera[3] * position[0] + worldToCamera[4] * position[1] + worldToCamera[5] * position[2],
      worldToCamera[6] * position[0] + worldToCamera[7] * position[1] + worldToCamera[8] * position[2],
    ] as Vec3,
  );

  for (const world of scenePoints(15, 17)) {
    const a = project(world, quat.identity(), [0, 0, 0]);
    const b = project(world, rotation, position);
    if (!a || !b) continue;
    const recovered = triangulateNormalized(a, b, worldToCamera, t)!;
    assert.ok(recovered, 'triangulation must succeed');
    for (let i = 0; i < 3; i++) near(recovered[i], world[i], 1e-8, `axis ${i}`);
  }
});

test('multi-view triangulation improves on two views under noise', () => {
  const random = rng(29);
  const world: Vec3 = [0.7, -0.3, 6];
  const poses: { rotation: Quat; position: Vec3 }[] = [];
  for (let i = 0; i < 6; i++) {
    poses.push({
      rotation: quat.fromAxisAngle([0, 1, 0], degToRad(i * 6 - 15)),
      position: [i * 0.8 - 2, 0, 0],
    });
  }

  const noise = 0.002;
  const views = poses.map((pose) => {
    const p = project(world, pose.rotation, pose.position)!;
    return {
      projection: projectionFromPose(pose.rotation, pose.position),
      point: { x: p.x + (random() - 0.5) * noise, y: p.y + (random() - 0.5) * noise },
    };
  });

  const fromTwo = triangulateMultiView(views.slice(0, 2))!;
  const fromAll = triangulateMultiView(views)!;

  const errorTwo = v3.distance(fromTwo, world);
  const errorAll = v3.distance(fromAll, world);
  assert.ok(
    errorAll < errorTwo,
    `six views (${errorAll.toFixed(5)}) should beat two (${errorTwo.toFixed(5)})`,
  );
});

test('parallel rays report failure rather than a point at infinity', () => {
  // Both cameras at the same place: the rays never converge.
  const identity = [1, 0, 0, 0, 1, 0, 0, 0, 1];
  const result = triangulateNormalized({ x: 0.1, y: 0 }, { x: 0.1, y: 0 }, identity, [0, 0, 0]);
  assert.equal(result, null);
});

// ===========================================================================
// PnP
// ===========================================================================

test('DLT PnP recovers a known pose from clean observations', () => {
  const rotation = quat.fromAxisAngle([0.2, 1, 0.15], degToRad(35));
  const position: Vec3 = [1.5, -0.8, -3];

  const observations: PnpObservation[] = [];
  for (const world of scenePoints(20, 23)) {
    const image = project(world, rotation, position);
    if (image) observations.push({ world, image });
  }

  const solution = solvePnpDlt(observations)!;
  assert.ok(solution, 'DLT must solve');
  assert.ok(solution.rms < 1e-8, `rms ${solution.rms} should be numerically zero`);
  for (let i = 0; i < 3; i++) near(solution.position[i], position[i], 1e-6, `position ${i}`);
});

test('DLT PnP refuses fewer than six points', () => {
  const observations: PnpObservation[] = scenePoints(5, 31).map((world) => ({
    world,
    image: project(world, quat.identity(), [0, 0, -5])!,
  }));
  assert.equal(solvePnpDlt(observations), null);
});

test('nonlinear refinement improves a perturbed pose', () => {
  const rotation = quat.fromAxisAngle([0.1, 1, 0.3], degToRad(20));
  const position: Vec3 = [0.5, 0.2, -4];
  const observations: PnpObservation[] = [];
  for (const world of scenePoints(30, 41)) {
    const image = project(world, rotation, position);
    if (image) observations.push({ world, image });
  }

  // Start 5 degrees and 200 mm off.
  const start = {
    rotation: quat.multiply(rotation, quat.fromAxisAngle([1, 0.2, 0], degToRad(5))),
    position: v3.add(position, [0.2, -0.15, 0.1]),
  };
  const before = reprojectionRms(observations, start.rotation, start.position);
  const refined = refinePnp(observations, start);

  assert.ok(refined.rms < before / 100, `rms ${before} -> ${refined.rms}`);
  for (let i = 0; i < 3; i++) near(refined.position[i], position[i], 1e-5, `position ${i}`);
});

test('refinement never accepts a step that makes the fit worse', () => {
  const rotation = quat.identity();
  const position: Vec3 = [0, 0, -5];
  const observations: PnpObservation[] = [];
  for (const world of scenePoints(12, 43)) {
    const image = project(world, rotation, position);
    if (image) observations.push({ world, image });
  }
  // A deliberately terrible starting guess.
  const start = {
    rotation: quat.fromAxisAngle([1, 0, 0], degToRad(80)),
    position: [5, 5, 5] as Vec3,
  };
  const before = reprojectionRms(observations, start.rotation, start.position);
  const refined = refinePnp(observations, start);
  assert.ok(refined.rms <= before, 'refinement must be monotone');
});

test('RANSAC PnP survives a third of the matches being outliers', () => {
  const random = rng(53);
  const rotation = quat.fromAxisAngle([0.3, 1, 0.1], degToRad(28));
  const position: Vec3 = [2, -1, -6];

  const observations: PnpObservation[] = [];
  const points = scenePoints(60, 59);
  points.forEach((world, index) => {
    const image = project(world, rotation, position);
    if (!image) return;
    if (index % 3 === 0) {
      // A gross mismatch: a plausible-looking image point from nowhere near
      // this 3D point. Least squares has a breakdown point of zero, so even
      // one of these drags an unprotected solve arbitrarily far.
      observations.push({
        world,
        image: { x: (random() - 0.5) * 2, y: (random() - 0.5) * 2 },
      });
    } else {
      observations.push({ world, image });
    }
  });

  const solution = solvePnpRansac(observations, { threshold: 0.002, seed: 12345 })!;
  assert.ok(solution, 'RANSAC must find a solution');
  assert.ok(
    solution.inliers.length > observations.length * 0.55,
    `expected most points to be inliers, got ${solution.inliers.length}/${observations.length}`,
  );
  for (let i = 0; i < 3; i++) {
    near(solution.position[i], position[i], 0.02, `position ${i}`);
  }

  // The unprotected solve must actually be worse, or the test proves nothing.
  const naive = solvePnpDlt(observations);
  const naiveError = naive ? v3.distance(naive.position, position) : Infinity;
  assert.ok(
    naiveError > v3.distance(solution.position, position) * 5,
    `RANSAC (${v3.distance(solution.position, position).toFixed(4)}) should clearly beat ` +
    `plain DLT (${naiveError.toFixed(4)})`,
  );
});

test('RANSAC is deterministic for a given seed', () => {
  const observations: PnpObservation[] = [];
  const rotation = quat.fromAxisAngle([0, 1, 0], degToRad(10));
  const position: Vec3 = [1, 0, -5];
  for (const world of scenePoints(40, 61)) {
    const image = project(world, rotation, position);
    if (image) observations.push({ world, image });
  }
  const a = solvePnpRansac(observations, { seed: 999 })!;
  const b = solvePnpRansac(observations, { seed: 999 })!;
  // A reconstruction that differs run to run cannot be checked against control.
  assert.deepEqual(a.position, b.position);
  assert.deepEqual(a.inliers, b.inliers);
});

// ===========================================================================
// Bundle adjustment
// ===========================================================================

/** A synthetic reconstruction: cameras on an arc, points in front of them. */
function syntheticProblem(options: {
  cameraCount: number;
  pointCount: number;
  noise: number;
  seed: number;
}) {
  const random = rng(options.seed);
  const truthCameras = [];
  for (let i = 0; i < options.cameraCount; i++) {
    const angle = degToRad(-30 + (60 * i) / Math.max(1, options.cameraCount - 1));
    truthCameras.push({
      rotation: quat.fromAxisAngle([0, 1, 0], angle),
      position: [Math.sin(angle) * 6, 0, -Math.cos(angle) * 6] as Vec3,
    });
  }

  const truthPoints = scenePoints(options.pointCount, options.seed + 1)
    .map((p): Vec3 => [p[0], p[1], p[2] - 6]);

  const observations: BaObservation[] = [];
  truthCameras.forEach((camera, c) => {
    truthPoints.forEach((point, p) => {
      const image = project(point, camera.rotation, camera.position);
      if (!image) return;
      if (Math.abs(image.x) > 1.2 || Math.abs(image.y) > 1.2) return;
      observations.push({
        camera: c,
        point: p,
        x: image.x + (random() - 0.5) * options.noise,
        y: image.y + (random() - 0.5) * options.noise,
      });
    });
  });

  return { truthCameras, truthPoints, observations, random };
}

test('bundle adjustment reduces reprojection error from a perturbed start', () => {
  const { truthCameras, truthPoints, observations, random } = syntheticProblem({
    cameraCount: 6, pointCount: 40, noise: 0, seed: 71,
  });

  // Perturb everything except the first two cameras, which fix the gauge.
  const cameras = truthCameras.map((camera, i) => ({
    rotation: i < 2
      ? camera.rotation
      : quat.multiply(camera.rotation, quat.fromAxisAngle([
          random() - 0.5, random() - 0.5, random() - 0.5,
        ], degToRad(2))),
    position: i < 2
      ? camera.position
      : v3.add(camera.position, [
          (random() - 0.5) * 0.2, (random() - 0.5) * 0.2, (random() - 0.5) * 0.2,
        ]),
    fixed: i < 2,
  }));
  const points = truthPoints.map((p): Vec3 => [
    p[0] + (random() - 0.5) * 0.15,
    p[1] + (random() - 0.5) * 0.15,
    p[2] + (random() - 0.5) * 0.15,
  ]);

  const result = bundleAdjust({ cameras, points, observations }, { iterations: 40 });

  assert.ok(result.finalRms < result.initialRms, 'error must decrease');
  assert.ok(
    result.finalRms < result.initialRms / 50,
    `rms ${result.initialRms.toExponential(2)} -> ${result.finalRms.toExponential(2)} ` +
    'should be a large improvement on noise-free data',
  );
});

test('fixed cameras do not move, which is what anchors the gauge', () => {
  // Without at least one fixed camera the problem has a seven-parameter gauge
  // freedom — the whole reconstruction can translate, rotate and scale with no
  // change in reprojection error, and the solve wanders.
  const { truthCameras, truthPoints, observations } = syntheticProblem({
    cameraCount: 4, pointCount: 25, noise: 0, seed: 83,
  });

  const cameras = truthCameras.map((camera, i) => ({
    ...camera,
    fixed: i === 0,
    position: i === 0 ? camera.position : v3.add(camera.position, [0.1, 0.05, -0.08]),
  }));

  const result = bundleAdjust(
    { cameras, points: truthPoints.map((p) => [...p] as Vec3), observations },
    { iterations: 30 },
  );

  assert.deepEqual(
    result.cameras[0].position, truthCameras[0].position,
    'a fixed camera must be returned untouched',
  );
  assert.deepEqual(result.cameras[0].rotation, truthCameras[0].rotation);
});

test('bundle adjustment recovers the true geometry when the gauge is anchored', () => {
  const { truthCameras, truthPoints, observations, random } = syntheticProblem({
    cameraCount: 5, pointCount: 35, noise: 0, seed: 97,
  });

  // Fix two cameras, so position, orientation and scale are all determined.
  const cameras = truthCameras.map((camera, i) => ({
    rotation: camera.rotation,
    position: i < 2
      ? camera.position
      : v3.add(camera.position, [
          (random() - 0.5) * 0.3, (random() - 0.5) * 0.3, (random() - 0.5) * 0.3,
        ]),
    fixed: i < 2,
  }));

  const result = bundleAdjust(
    { cameras, points: truthPoints.map((p) => [...p] as Vec3), observations },
    { iterations: 60 },
  );

  for (let i = 2; i < result.cameras.length; i++) {
    const error = v3.distance(result.cameras[i].position, truthCameras[i].position);
    assert.ok(error < 0.02, `camera ${i} is ${error.toFixed(4)} from truth`);
  }
});

test('the Huber loss stops one outlier observation dominating', () => {
  const { truthCameras, truthPoints, observations } = syntheticProblem({
    cameraCount: 5, pointCount: 30, noise: 0, seed: 101,
  });

  // Corrupt a single observation badly.
  const corrupted = observations.map((o, i) =>
    i === 10 ? { ...o, x: o.x + 3, y: o.y - 2 } : o,
  );

  const cameras = truthCameras.map((camera, i) => ({ ...camera, fixed: i < 2 }));
  const points = truthPoints.map((p) => [...p] as Vec3);

  const robust = bundleAdjust({ cameras, points, observations: corrupted },
    { iterations: 30, huber: 0.01 });
  // A huge Huber threshold is effectively plain least squares.
  const naive = bundleAdjust({ cameras, points, observations: corrupted },
    { iterations: 30, huber: 1e6 });

  const displacement = (result: typeof robust): number => {
    let worst = 0;
    for (let i = 2; i < result.cameras.length; i++) {
      worst = Math.max(worst, v3.distance(result.cameras[i].position, truthCameras[i].position));
    }
    return worst;
  };

  assert.ok(
    displacement(robust) < displacement(naive),
    `robust (${displacement(robust).toFixed(4)}) should beat least squares ` +
    `(${displacement(naive).toFixed(4)}) with an outlier present`,
  );
});

test('bundle adjustment handles an empty problem without throwing', () => {
  const result = bundleAdjust({ cameras: [], points: [], observations: [] });
  assert.equal(result.iterations, 0);
  assert.deepEqual(result.cameras, []);
});

test('a problem with every camera fixed returns immediately', () => {
  const { truthCameras, truthPoints, observations } = syntheticProblem({
    cameraCount: 3, pointCount: 10, noise: 0, seed: 103,
  });
  const result = bundleAdjust({
    cameras: truthCameras.map((c) => ({ ...c, fixed: true })),
    points: truthPoints.map((p) => [...p] as Vec3),
    observations,
  });
  assert.equal(result.iterations, 0, 'nothing is free to move');
});
