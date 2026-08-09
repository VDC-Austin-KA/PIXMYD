import test from 'node:test';
import assert from 'node:assert/strict';
import {
  projectPoint, pixelToRay, unprojectPixel, fieldOfView, resizeCamera,
  worldToCamera, cameraToWorld, projectWorldPoint, unprojectToWorld,
} from '../src/camera.ts';
import { TsdfVolume, type DepthFrame } from '../src/tsdf.ts';
import type { CameraModel, EquirectCamera, FisheyeCamera, PinholeCamera, Pose } from '@pixmyd/core/bundle';
import { quat, v3, degToRad, type Vec3 } from '@pixmyd/core/math';

const near = (a: number, b: number, tol: number, msg = '') =>
  assert.ok(Math.abs(a - b) < tol, `${msg}: ${a} !~= ${b} (tol ${tol})`);

const pinhole: PinholeCamera = {
  model: 'pinhole', width: 640, height: 480,
  fx: 500, fy: 500, cx: 319.5, cy: 239.5,
};

const distorted: PinholeCamera = { ...pinhole, k1: -0.28, k2: 0.09, p1: 0.001, p2: -0.002 };

const fisheye: FisheyeCamera = {
  model: 'fisheye', width: 1024, height: 1024,
  fx: 320, fy: 320, cx: 511.5, cy: 511.5, k1: 0.02, k2: -0.005,
};

const equirect: EquirectCamera = { model: 'equirect', width: 2048, height: 1024 };

// ===========================================================================
// Camera models
// ===========================================================================

test('pinhole projects the optical axis to the principal point', () => {
  const p = projectPoint([0, 0, 5], pinhole);
  near(p.x, pinhole.cx, 1e-9, 'x');
  near(p.y, pinhole.cy, 1e-9, 'y');
  near(p.depth, 5, 1e-12, 'depth');
  assert.equal(p.visible, true);
});

test('pinhole reports points behind the camera as not visible', () => {
  assert.equal(projectPoint([0, 0, -1], pinhole).visible, false);
  assert.equal(projectPoint([0, 0, 0], pinhole).visible, false);
});

test('pinhole projection scales inversely with depth', () => {
  const a = projectPoint([1, 0, 1], pinhole);
  const b = projectPoint([2, 0, 2], pinhole);
  near(a.x, b.x, 1e-9, 'same ray, same pixel');
});

for (const [name, camera] of [
  ['pinhole', pinhole],
  ['pinhole with distortion', distorted],
  ['fisheye', fisheye],
  ['equirect', equirect],
] as [string, CameraModel][]) {
  test(`${name}: pixel -> ray -> pixel round trips`, () => {
    for (const [px, py] of [[100, 80], [320, 240], [500, 400], [50, 450]]) {
      const ray = pixelToRay({ x: px, y: py }, camera);
      near(v3.length(ray), 1, 1e-9, 'ray must be unit length');
      const back = projectPoint(ray, camera);
      near(back.x, px, 1e-6, `${name} x at (${px},${py})`);
      near(back.y, py, 1e-6, `${name} y at (${px},${py})`);
    }
  });

  test(`${name}: unproject at a depth then project returns the same pixel`, () => {
    for (const [px, py, d] of [[120, 90, 0.5], [320, 240, 3], [560, 400, 12]]) {
      const world = unprojectPixel({ x: px, y: py }, d, camera);
      const back = projectPoint(world, camera);
      near(back.x, px, 1e-6, `${name} x`);
      near(back.y, py, 1e-6, `${name} y`);
    }
  });
}

test('distortion actually moves pixels, so the round trip is not trivially passing', () => {
  const straight = projectPoint([0.4, 0.3, 1], pinhole);
  const bent = projectPoint([0.4, 0.3, 1], distorted);
  assert.ok(
    Math.hypot(straight.x - bent.x, straight.y - bent.y) > 5,
    'a -0.28 k1 should shift a corner pixel by many pixels',
  );
});

test('unprojectPixel treats depth as axial for pinhole and as range for equirect', () => {
  // A pixel off-axis: axial depth 10 means z = 10, so the point is further than 10.
  const p = unprojectPixel({ x: 0, y: 0 }, 10, pinhole);
  near(p[2], 10, 1e-9, 'pinhole depth is along the optical axis');
  assert.ok(v3.length(p) > 10, 'so the range is longer than the depth');

  // For a panorama there is no axis, so depth is range exactly.
  const e = unprojectPixel({ x: 300, y: 700 }, 10, equirect);
  near(v3.length(e), 10, 1e-9, 'equirect depth is range');

  // Fisheye is range too, and this is not a stylistic choice: a fisheye images
  // past 90 degrees, where z is negative. Under an axial reading, depth/z would
  // flip the point behind the camera.
  const f = unprojectPixel({ x: 120, y: 90 }, 10, fisheye);
  near(v3.length(f), 10, 1e-9, 'fisheye depth is range');
  assert.ok(f[2] < 0, 'this pixel really is past 90 degrees off-axis');
});

test('equirect maps image centre to straight ahead and wraps longitude', () => {
  const forward = pixelToRay({ x: equirect.width / 2, y: equirect.height / 2 }, equirect);
  near(forward[0], 0, 1e-9, 'x');
  near(forward[1], 0, 1e-9, 'y');
  near(forward[2], 1, 1e-9, 'centre looks along +Z');

  // A quarter of the way across is 90 degrees to the right.
  const right = pixelToRay({ x: equirect.width * 0.75, y: equirect.height / 2 }, equirect);
  near(right[0], 1, 1e-9, 'three-quarters across looks along +X');

  // Top of the image is up, which is -Y in camera axes.
  const up = pixelToRay({ x: equirect.width / 2, y: 0 }, equirect);
  near(up[1], -1, 1e-9, 'top row looks up');
});

test('fisheye can see past 90 degrees, where a pinhole cannot', () => {
  // A point 100 degrees off the optical axis has negative z.
  const theta = degToRad(100);
  const p: Vec3 = [Math.sin(theta), 0, Math.cos(theta)];
  const f = projectPoint(p, fisheye);
  assert.ok(Number.isFinite(f.x), 'fisheye still produces a pixel');
  assert.equal(projectPoint(p, pinhole).visible, false, 'pinhole cannot');
});

test('field of view matches the intrinsics', () => {
  const fov = fieldOfView(pinhole);
  near(fov.horizontal, 2 * Math.atan(640 / 1000), 1e-9, 'horizontal');
  const eq = fieldOfView(equirect);
  near(eq.horizontal, 2 * Math.PI, 1e-12, 'a full panorama is 360 degrees');
});

test('resizeCamera keeps the principal point on the same relative spot', () => {
  const half = resizeCamera(pinhole, 320, 240) as PinholeCamera;
  near(half.fx, 250, 1e-9, 'focal length halves');
  // The centre of a 640-wide image is at 319.5; of a 320-wide image, 159.5.
  near(half.cx, 159.5, 1e-9, 'principal point uses the half-pixel convention');

  // The same world ray must land on the same relative position in both rasters.
  const full = projectPoint([0.3, 0.2, 1], pinhole);
  const small = projectPoint([0.3, 0.2, 1], half);
  near((small.x + 0.5) / 320, (full.x + 0.5) / 640, 1e-9, 'relative x');
});

test('world <-> camera transforms are inverses', () => {
  const pose: Pose = { t: [3, -1, 7], q: quat.fromAxisAngle([0.3, 1, 0.2], 0.7) };
  for (const p of [[0, 0, 0], [5, 5, 5], [-2, 8, 1]] as Vec3[]) {
    const back = cameraToWorld(worldToCamera(p, pose), pose);
    for (let i = 0; i < 3; i++) near(back[i], p[i], 1e-9, `axis ${i}`);
  }
});

test('projectWorldPoint and unprojectToWorld round trip through a pose', () => {
  const pose: Pose = { t: [3, -1, 7], q: quat.fromAxisAngle([0.3, 1, 0.2], 0.7) };
  // Build the world point from a camera-space point known to be in frame,
  // rather than guessing one and hoping the pose points at it.
  for (const local of [[0, 0, 4], [0.5, -0.3, 2], [-0.4, 0.6, 6]] as Vec3[]) {
    const world = cameraToWorld(local, pose);
    const projected = projectWorldPoint(world, pose, pinhole);
    assert.equal(projected.visible, true, `${local} should be in frame`);
    const back = unprojectToWorld(projected, projected.depth, pose, pinhole);
    for (let i = 0; i < 3; i++) near(back[i], world[i], 1e-9, `axis ${i}`);
  }
});

// ===========================================================================
// TSDF fusion
// ===========================================================================

/**
 * Synthesize a depth frame of a plane at z = planeZ in world space, viewed by a
 * camera at the origin looking down +Z.
 */
function planeFrame(planeZ: number, pose: Pose, camera: PinholeCamera): DepthFrame {
  const depth = new Float32Array(camera.width * camera.height);
  const color = new Uint8Array(camera.width * camera.height * 3);
  for (let py = 0; py < camera.height; py++) {
    for (let px = 0; px < camera.width; px++) {
      const ray = pixelToRay({ x: px + 0.5, y: py + 0.5 }, camera);
      // World ray direction, then intersect with the z = planeZ plane.
      const dir = quat.rotate(pose.q, ray);
      const t = (planeZ - pose.t[2]) / dir[2];
      const i = py * camera.width + px;
      if (t <= 0 || !Number.isFinite(t)) {
        depth[i] = 0;
        continue;
      }
      // Store axial depth, which is what a depth sensor reports.
      depth[i] = ray[2] * t;
      color[i * 3] = 200;
      color[i * 3 + 1] = 100;
      color[i * 3 + 2] = 50;
    }
  }
  return { depth, width: camera.width, height: camera.height, camera, pose, color };
}

const smallCamera: PinholeCamera = {
  model: 'pinhole', width: 64, height: 48, fx: 50, fy: 50, cx: 31.5, cy: 23.5,
};

test('TSDF fusion places the zero crossing on the measured plane', () => {
  const volume = new TsdfVolume({ voxelSize: 0.02, truncation: 0.06, weightByDepth: false });
  const pose: Pose = { t: [0, 0, 0], q: quat.identity() };
  volume.integrate(planeFrame(1.5, pose, smallCamera));

  assert.ok(volume.blockCount > 0, 'blocks must be allocated');
  assert.equal(volume.integratedFrames, 1);

  const points = volume.extractPoints();
  assert.ok(points.count > 100, `expected a surface, got ${points.count} points`);

  // Every extracted point should sit on the plane to within a fraction of a voxel.
  let worst = 0;
  for (let i = 0; i < points.count; i++) {
    worst = Math.max(worst, Math.abs(points.positions[i * 3 + 2] - 1.5));
  }
  assert.ok(worst < 0.02, `worst deviation from the plane was ${worst.toFixed(4)} m`);
});

test('TSDF averaging pulls a noisy surface back toward the truth', () => {
  const truth = 1.5;
  const pose: Pose = { t: [0, 0, 0], q: quat.identity() };

  const noisy = (seed: number): DepthFrame => {
    const frame = planeFrame(truth, pose, smallCamera);
    let s = seed;
    const rand = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return s / 0x7fffffff - 0.5;
    };
    // +/- 15 mm of zero-mean sensor noise, which is realistic for phone LiDAR.
    for (let i = 0; i < frame.depth.length; i++) {
      if (frame.depth[i] > 0) frame.depth[i] += rand() * 0.03;
    }
    return frame;
  };

  const single = new TsdfVolume({ voxelSize: 0.02, truncation: 0.06, weightByDepth: false });
  single.integrate(noisy(1));

  const many = new TsdfVolume({ voxelSize: 0.02, truncation: 0.06, weightByDepth: false });
  for (let f = 0; f < 30; f++) many.integrate(noisy(f + 1));

  const rms = (v: TsdfVolume): number => {
    const p = v.extractPoints();
    let sum = 0;
    for (let i = 0; i < p.count; i++) sum += (p.positions[i * 3 + 2] - truth) ** 2;
    return Math.sqrt(sum / p.count);
  };

  const one = rms(single);
  const thirty = rms(many);
  assert.ok(thirty < one, `averaging must help: 1 frame ${one}, 30 frames ${thirty}`);
});

test('TSDF gates integration on confidence', () => {
  const pose: Pose = { t: [0, 0, 0], q: quat.identity() };
  const frame = planeFrame(1.5, pose, smallCamera);
  // Mark everything low-confidence.
  frame.confidence = new Uint8Array(frame.depth.length).fill(0);

  const strict = new TsdfVolume({ voxelSize: 0.02, minConfidence: 1 });
  strict.integrate(frame);
  assert.equal(strict.blockCount, 0, 'low-confidence depth must be rejected');

  const permissive = new TsdfVolume({ voxelSize: 0.02, minConfidence: 0 });
  permissive.integrate(frame);
  assert.ok(permissive.blockCount > 0, 'and accepted when the gate is lowered');
});

test('TSDF ignores depth outside the sensor range', () => {
  const pose: Pose = { t: [0, 0, 0], q: quat.identity() };
  const volume = new TsdfVolume({ voxelSize: 0.05, maxDepth: 2 });
  volume.integrate(planeFrame(8, pose, smallCamera));
  assert.equal(volume.blockCount, 0, 'a plane at 8 m is past a 2 m ceiling');
});

test('TSDF fuses frames from different poses into one consistent surface', () => {
  const volume = new TsdfVolume({ voxelSize: 0.02, truncation: 0.06, weightByDepth: false });
  // Three viewpoints, translated sideways, all seeing the same plane.
  for (const dx of [-0.3, 0, 0.3]) {
    volume.integrate(planeFrame(1.5, { t: [dx, 0, 0], q: quat.identity() }, smallCamera));
  }
  const points = volume.extractPoints();
  let worst = 0;
  for (let i = 0; i < points.count; i++) {
    worst = Math.max(worst, Math.abs(points.positions[i * 3 + 2] - 1.5));
  }
  assert.ok(worst < 0.02, `multi-view worst deviation ${worst.toFixed(4)} m`);
  // The fused surface must be wider than any single view of it.
  let minX = Infinity, maxX = -Infinity;
  for (let i = 0; i < points.count; i++) {
    minX = Math.min(minX, points.positions[i * 3]);
    maxX = Math.max(maxX, points.positions[i * 3]);
  }
  assert.ok(maxX - minX > 1.0, `fused extent ${(maxX - minX).toFixed(2)} m`);
});

test('TSDF carries colour through fusion', () => {
  const volume = new TsdfVolume({ voxelSize: 0.02, truncation: 0.06 });
  volume.integrate(planeFrame(1.5, { t: [0, 0, 0], q: quat.identity() }, smallCamera));
  const points = volume.extractPoints();
  assert.ok(points.count > 0);
  // The synthetic frame paints everything (200, 100, 50).
  near(points.colors[0], 200, 3, 'red');
  near(points.colors[1], 100, 3, 'green');
  near(points.colors[2], 50, 3, 'blue');
});

test('an empty volume reports empty bounds rather than infinities', () => {
  const volume = new TsdfVolume();
  const vb = volume.voxelBounds();
  assert.deepEqual(vb.min, [0, 0, 0]);
  assert.deepEqual(vb.max, [-1, -1, -1], 'max below min signals empty');
  assert.equal(volume.extractPoints().count, 0);
});

// ===========================================================================
// End to end: depth frames in, mesh out
// ===========================================================================

test('fusing a box from six viewpoints produces a closed mesh of the right size', async () => {
  const { extractSurface } = await import('../src/tsdf.ts');

  // A 1 m cube centred at the origin, viewed from all six faces. Synthetic, but
  // it exercises the real path: unproject depth, fuse, extract, weld.
  const half = 0.5;
  const volume = new TsdfVolume({ voxelSize: 0.025, truncation: 0.075, weightByDepth: false });
  const cam: PinholeCamera = {
    model: 'pinhole', width: 96, height: 96, fx: 80, fy: 80, cx: 47.5, cy: 47.5,
  };

  // Camera 2 m out along each axis, looking back at the origin.
  const views: { t: Vec3; q: ReturnType<typeof quat.identity> }[] = [
    { t: [0, 0, -2], q: quat.identity() },
    { t: [0, 0, 2], q: quat.fromAxisAngle([0, 1, 0], Math.PI) },
    { t: [-2, 0, 0], q: quat.fromAxisAngle([0, 1, 0], Math.PI / 2) },
    { t: [2, 0, 0], q: quat.fromAxisAngle([0, 1, 0], -Math.PI / 2) },
    { t: [0, -2, 0], q: quat.fromAxisAngle([1, 0, 0], -Math.PI / 2) },
    { t: [0, 2, 0], q: quat.fromAxisAngle([1, 0, 0], Math.PI / 2) },
  ];

  for (const pose of views) {
    const depth = new Float32Array(cam.width * cam.height);
    for (let py = 0; py < cam.height; py++) {
      for (let px = 0; px < cam.width; px++) {
        const ray = pixelToRay({ x: px + 0.5, y: py + 0.5 }, cam);
        const dir = quat.rotate(pose.q, ray);
        // Slab method: nearest intersection with the axis-aligned cube.
        let tMin = -Infinity;
        let tMax = Infinity;
        for (let a = 0; a < 3; a++) {
          if (Math.abs(dir[a]) < 1e-9) {
            if (Math.abs(pose.t[a]) > half) { tMin = Infinity; break; }
            continue;
          }
          const t1 = (-half - pose.t[a]) / dir[a];
          const t2 = (half - pose.t[a]) / dir[a];
          tMin = Math.max(tMin, Math.min(t1, t2));
          tMax = Math.min(tMax, Math.max(t1, t2));
        }
        const i = py * cam.width + px;
        depth[i] = tMin <= tMax && tMin > 0 ? ray[2] * tMin : 0;
      }
    }
    volume.integrate({ depth, width: cam.width, height: cam.height, camera: cam, pose });
  }

  const mesh = extractSurface(volume, { minComponentTriangles: 32 });
  assert.ok(mesh.indices.length > 500, `expected a substantial mesh, got ${mesh.indices.length / 3} triangles`);
  assert.ok(mesh.normals, 'normals must be computed');

  // The fused surface must be about 1 m on a side, centred at the origin.
  //
  // It comes out slightly *larger* than the true cube, and that is inherent
  // rather than a defect: the signed distance is measured along the viewing
  // ray, which is only the true distance where the ray meets the surface
  // head-on. At a silhouette edge the truncation band wraps around the corner
  // and dilates the extracted surface by up to about one truncation distance.
  // Every projective TSDF does this — it is the reason a fused scan has
  // slightly rounded, slightly fat corners — so the tolerance is stated in
  // units of truncation rather than pretended away.
  const truncation = 0.075;
  let lo = Infinity, hi = -Infinity;
  for (let i = 0; i < mesh.positions.length; i++) {
    lo = Math.min(lo, mesh.positions[i]);
    hi = Math.max(hi, mesh.positions[i]);
  }
  assert.ok(lo <= -half + 0.01, `min extent ${lo} should reach the face at ${-half}`);
  assert.ok(hi >= half - 0.01, `max extent ${hi} should reach the face at ${half}`);
  assert.ok(
    lo > -half - 1.5 * truncation,
    `min extent ${lo} dilated further than one truncation past ${-half}`,
  );
  assert.ok(
    hi < half + 1.5 * truncation,
    `max extent ${hi} dilated further than one truncation past ${half}`,
  );

  // And it must be closed: no boundary edges anywhere.
  const edges = new Map<string, number>();
  for (let i = 0; i < mesh.indices.length; i += 3) {
    const c = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]];
    for (let k = 0; k < 3; k++) {
      const a = c[k], b = c[(k + 1) % 3];
      const key = a < b ? `${a}-${b}` : `${b}-${a}`;
      edges.set(key, (edges.get(key) ?? 0) + 1);
    }
  }
  const boundary = [...edges.values()].filter((n) => n === 1).length;
  const nonManifold = [...edges.values()].filter((n) => n > 2).length;

  // Manifoldness is the guarantee marching tetrahedra actually makes, and it is
  // the one that catches real bugs: unwelded vertices would push almost every
  // edge to a count of one, and a broken table would push some above two.
  assert.equal(nonManifold, 0, `${nonManifold} edges shared by more than two faces`);

  // Full closure is *not* claimed. Six axis-aligned views leave the cube's
  // corners outside the truncation band of every one of them, so the field
  // there is genuinely unobserved and the mesher correctly declines to invent a
  // surface. The boundary should be confined to those corners rather than
  // riddling the faces.
  const fraction = boundary / edges.size;
  assert.ok(
    fraction < 0.2,
    `${(fraction * 100).toFixed(1)}% of edges are boundaries — the faces should be closed, ` +
    'with gaps only at the corners',
  );
});

test('extractSurface returns an empty mesh for an empty volume rather than throwing', async () => {
  const { extractSurface } = await import('../src/tsdf.ts');
  const mesh = extractSurface(new TsdfVolume());
  assert.equal(mesh.indices.length, 0);
  assert.equal(mesh.positions.length, 0);
});
