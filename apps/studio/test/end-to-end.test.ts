/**
 * End-to-end: a synthetic capture bundle in, real export files out.
 *
 * This is the test that proves the pieces fit. Every other suite checks one
 * package in isolation; this one walks the whole path a user takes — read a
 * bundle off disk, fuse the depth, extract a surface, and write files that
 * independent parsers accept.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { FBXLoader } from 'three/examples/jsm/loaders/FBXLoader.js';
import { readBundle, decodeDepth, type BundleSource } from '../src/lib/bundle-reader.ts';
import { processBundle, ProcessingError } from '../src/lib/pipeline.ts';
import { exportMesh, exportPointCloud } from '@pixmyd/formats/export';
import { readPointCloudPly } from '@pixmyd/formats/ply';
import { readLas } from '@pixmyd/formats/las';
import { readE57Points, depaginate } from '@pixmyd/formats/e57';
import { pixelToRay } from '@pixmyd/recon/camera';
import { quat, type Vec3 } from '@pixmyd/core/math';
import type { CaptureManifest, Frame, PinholeCamera } from '@pixmyd/core/bundle';

const CAMERA: PinholeCamera = {
  model: 'pinhole', width: 64, height: 48, fx: 50, fy: 50, cx: 31.5, cy: 23.5,
};

/**
 * A synthetic capture of a 1 m cube, seen from six faces — the same fixture the
 * recon suite uses, but delivered through the real bundle reader so the JSONL
 * parsing, depth decoding and path resolution are all exercised.
 */
function syntheticBundle(options: { withDepth?: boolean; poseEvery?: number } = {}): BundleSource {
  const withDepth = options.withDepth ?? true;
  const poseEvery = options.poseEvery ?? 1;
  const half = 0.5;

  const files = new Map<string, Uint8Array>();
  const encoder = new TextEncoder();

  const views: { t: Vec3; q: [number, number, number, number] }[] = [
    { t: [0, 0, -2], q: quat.identity() },
    { t: [0, 0, 2], q: quat.fromAxisAngle([0, 1, 0], Math.PI) },
    { t: [-2, 0, 0], q: quat.fromAxisAngle([0, 1, 0], Math.PI / 2) },
    { t: [2, 0, 0], q: quat.fromAxisAngle([0, 1, 0], -Math.PI / 2) },
    { t: [0, -2, 0], q: quat.fromAxisAngle([1, 0, 0], -Math.PI / 2) },
    { t: [0, 2, 0], q: quat.fromAxisAngle([1, 0, 0], Math.PI / 2) },
  ];

  const frames: Frame[] = [];

  views.forEach((view, index) => {
    const id = String(index).padStart(6, '0');

    if (withDepth) {
      // Ray-cast the cube and store uint16 millimetres, exactly as the app does.
      const millimetres = new Uint16Array(CAMERA.width * CAMERA.height);
      for (let py = 0; py < CAMERA.height; py++) {
        for (let px = 0; px < CAMERA.width; px++) {
          const ray = pixelToRay({ x: px + 0.5, y: py + 0.5 }, CAMERA);
          const dir = quat.rotate(view.q, ray);
          let tMin = -Infinity;
          let tMax = Infinity;
          for (let a = 0; a < 3; a++) {
            if (Math.abs(dir[a]) < 1e-9) {
              if (Math.abs(view.t[a]) > half) { tMin = Infinity; break; }
              continue;
            }
            const t1 = (-half - view.t[a]) / dir[a];
            const t2 = (half - view.t[a]) / dir[a];
            tMin = Math.max(tMin, Math.min(t1, t2));
            tMax = Math.min(tMax, Math.max(t1, t2));
          }
          const axial = tMin <= tMax && tMin > 0 ? ray[2] * tMin : 0;
          millimetres[py * CAMERA.width + px] = axial > 0 ? Math.round(axial * 1000) : 0;
        }
      }
      files.set(`depth/${id}.bin`, new Uint8Array(millimetres.buffer.slice(0)));
      files.set(`conf/${id}.bin`, new Uint8Array(CAMERA.width * CAMERA.height).fill(2));
    }

    files.set(`images/${id}.jpg`, new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));

    const frame: Frame = {
      id,
      t: index * 0.5,
      imageUri: `images/${id}.jpg`,
      camera: 0,
      poseSource: index % poseEvery === 0 ? 'vio' : 'none',
      ...(index % poseEvery === 0 ? { pose: { t: view.t, q: view.q } } : {}),
      ...(withDepth
        ? {
            depth: {
              uri: `depth/${id}.bin`,
              width: CAMERA.width,
              height: CAMERA.height,
              encoding: 'uint16-mm' as const,
              confidenceUri: `conf/${id}.bin`,
              camera: CAMERA,
            },
          }
        : {}),
    };
    frames.push(frame);
  });

  const manifest: CaptureManifest = {
    formatVersion: 1,
    id: 'synthetic',
    name: 'Synthetic cube',
    startedAt: new Date(0).toISOString(),
    device: {
      kind: 'ios-lidar',
      model: 'iPhone (synthetic)',
      producer: 'test',
      hasMetricDepth: withDepth,
    },
    cameras: [CAMERA],
    frameCount: frames.length,
  };

  files.set('manifest.json', encoder.encode(JSON.stringify(manifest)));
  files.set('frames.jsonl', encoder.encode(frames.map((f) => JSON.stringify(f)).join('\n') + '\n'));

  return {
    name: 'synthetic',
    async read(path) {
      const file = files.get(path);
      if (!file) throw new Error(`bundle is missing ${path}`);
      return file;
    },
    async readText(path) {
      const file = files.get(path);
      if (!file) throw new Error(`bundle is missing ${path}`);
      return new TextDecoder().decode(file);
    },
    async has(path) {
      return files.has(path);
    },
  };
}

// ===========================================================================

test('a bundle round trips through the reader with its frames intact', async () => {
  const bundle = await readBundle(syntheticBundle());
  assert.equal(bundle.manifest.name, 'Synthetic cube');
  assert.equal(bundle.frames.length, 6);
  assert.ok(bundle.frames.every((f) => f.pose), 'every frame should carry a pose');
  assert.ok(bundle.frames.every((f) => f.depth), 'every frame should carry depth');
});

test('the reader refuses something that is not a capture, with a usable message', async () => {
  const empty: BundleSource = {
    name: 'empty',
    read: async () => { throw new Error('nope'); },
    readText: async () => { throw new Error('nope'); },
    has: async () => false,
  };
  await assert.rejects(() => readBundle(empty), /no manifest\.json/);
});

test('a truncated final line costs one frame, not the capture', async () => {
  const source = syntheticBundle();
  const good = await source.readText('frames.jsonl');
  // Chop the last line mid-object, exactly as a force-quit would.
  const truncated = good.slice(0, good.length - 40);

  const patched: BundleSource = {
    ...source,
    async readText(path) {
      return path === 'frames.jsonl' ? truncated : source.readText(path);
    },
  };

  const bundle = await readBundle(patched);
  assert.equal(bundle.frames.length, 5, 'the five complete frames should survive');
  assert.equal(bundle.manifest.frameCount, 5, 'the count must reflect reality, not the manifest');
});

test('depth decodes from uint16 millimetres to metres, with zero meaning no measurement', () => {
  const raw = new Uint16Array([0, 1500, 65535]);
  const decoded = decodeDepth(new Uint8Array(raw.buffer.slice(0)), 'uint16-mm', 3, 1);
  assert.equal(decoded[0], 0, 'zero is "no measurement", not zero metres');
  assert.ok(Math.abs(decoded[1] - 1.5) < 1e-6);
  assert.ok(Math.abs(decoded[2] - 65.535) < 1e-3);
});

test('processing a capture produces points and a mesh of the right size', async () => {
  const source = syntheticBundle();
  const bundle = await readBundle(source);

  const stages: string[] = [];
  const result = await processBundle(bundle, source, {
    detail: 'balanced',
    mesh: true,
    onProgress: (stage) => {
      if (stages.at(-1) !== stage) stages.push(stage);
    },
  });

  assert.equal(result.integratedFrames, 6);
  assert.ok(result.points.count > 500, `expected a substantial cloud, got ${result.points.count}`);
  assert.ok(result.mesh, 'meshing was requested');
  assert.ok(result.mesh!.indices.length > 300, 'expected a substantial mesh');
  assert.ok(result.mesh!.normals, 'the mesh should carry normals');

  // The cube is 1 m on a side, dilated by up to a truncation distance.
  let lo = Infinity;
  let hi = -Infinity;
  for (let i = 0; i < result.mesh!.positions.length; i++) {
    lo = Math.min(lo, result.mesh!.positions[i]);
    hi = Math.max(hi, result.mesh!.positions[i]);
  }
  assert.ok(hi - lo > 0.9 && hi - lo < 1.4, `cube spans ${(hi - lo).toFixed(3)} m, expected ~1 m`);

  // Progress must actually be reported, and end at Done.
  assert.ok(stages.includes('Fusing depth'), `stages seen: ${stages.join(', ')}`);
  assert.equal(stages.at(-1), 'Done');
});

test('frames with no pose are skipped and counted rather than silently dropped', async () => {
  // Only every third frame has a pose.
  const source = syntheticBundle({ poseEvery: 3 });
  const bundle = await readBundle(source);
  const result = await processBundle(bundle, source, { detail: 'fast', mesh: false });

  assert.equal(result.integratedFrames, 2, 'frames 0 and 3 carry poses');
  assert.equal(result.skipped.noPose, 4);
  assert.equal(result.skipped.noDepth, 0);
});

test('a capture with no depth fails with an explanation rather than an empty file', async () => {
  const source = syntheticBundle({ withDepth: false });
  const bundle = await readBundle(source);

  await assert.rejects(
    () => processBundle(bundle, source, { detail: 'fast', mesh: false }),
    (error: unknown) => {
      assert.ok(error instanceof ProcessingError);
      assert.match(error.message, /No frames could be fused/);
      // The hint is the part that tells the user what to do about it.
      assert.match(error.hint ?? '', /structure-from-motion/);
      return true;
    },
  );
});

test('processing can be cancelled mid-run', async () => {
  const source = syntheticBundle();
  const bundle = await readBundle(source);
  const controller = new AbortController();
  controller.abort();

  await assert.rejects(
    () => processBundle(bundle, source, { detail: 'fast', mesh: false, signal: controller.signal }),
    /Cancelled/,
  );
});

test('every export format writes a file that parses back', async () => {
  const source = syntheticBundle();
  const bundle = await readBundle(source);
  const result = await processBundle(bundle, source, { detail: 'balanced', mesh: true });

  // --- point formats ---
  const [ply] = exportPointCloud(result.points, 'ply', { name: 'cube' });
  assert.equal(ply.filename, 'cube.ply');
  assert.equal(readPointCloudPly(ply.bytes).count, result.points.count);

  const [las] = exportPointCloud(result.points, 'las', { name: 'cube' });
  assert.equal(readLas(las.bytes).count, result.points.count);

  const [e57] = exportPointCloud(result.points, 'e57', { name: 'cube' });
  // depaginate verifies every CRC-32C page checksum in the file.
  assert.doesNotThrow(() => depaginate(e57.bytes));
  assert.equal(readE57Points(e57.bytes).count, result.points.count);

  // --- mesh formats ---
  const [glb] = exportMesh(result.mesh!, 'glb', { name: 'cube' });
  assert.equal(new TextDecoder().decode(glb.bytes.subarray(0, 4)), 'glTF');

  const objFiles = exportMesh(result.mesh!, 'obj', { name: 'cube' });
  assert.deepEqual(objFiles.map((f) => f.filename), ['cube.obj', 'cube.mtl']);
  assert.match(new TextDecoder().decode(objFiles[0].bytes), /^v /m);

  const [fbx] = exportMesh(result.mesh!, 'fbx', { name: 'cube' });
  // Parse it with three.js — an independent implementation.
  const buffer = fbx.bytes.buffer.slice(
    fbx.bytes.byteOffset,
    fbx.bytes.byteOffset + fbx.bytes.byteLength,
  ) as ArrayBuffer;
  const group = new FBXLoader().parse(buffer, '');
  let meshCount = 0;
  group.traverse((object: { isMesh?: boolean }) => {
    if (object.isMesh) meshCount++;
  });
  assert.equal(meshCount, 1, 'three.js should find exactly one mesh in the FBX');
});

test('exported point counts agree across every format', async () => {
  const source = syntheticBundle();
  const bundle = await readBundle(source);
  const result = await processBundle(bundle, source, { detail: 'fast', mesh: false });

  const counts = [
    readPointCloudPly(exportPointCloud(result.points, 'ply', {})[0].bytes).count,
    readLas(exportPointCloud(result.points, 'las', {})[0].bytes).count,
    readE57Points(exportPointCloud(result.points, 'e57', {})[0].bytes).count,
  ];
  assert.deepEqual(counts, [result.points.count, result.points.count, result.points.count]);
});
