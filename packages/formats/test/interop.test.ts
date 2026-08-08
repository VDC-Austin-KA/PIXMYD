/**
 * Interoperability tests: our output, somebody else's parser.
 *
 * A writer validated only by its own reader proves the two agree, not that the
 * file is correct. These tests run the bytes through three.js's FBXLoader and
 * GLTFLoader — independent implementations written from the same reverse
 * engineering that Blender and Assimp rely on. If geometry survives them, the
 * files open in the tools an engineer actually uses.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { FBXLoader } from 'three/examples/jsm/loaders/FBXLoader.js';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { writeMeshFbx } from '../src/fbx.ts';
import { writeMeshGlb } from '../src/glb.ts';
import type { Mesh } from '@pixmyd/core/bundle';

/** An L-shaped prism: asymmetric, so a transposed or mirrored axis shows up. */
function lShape(): Mesh {
  const positions = new Float32Array([
    0, 0, 0, 4, 0, 0, 4, 1, 0, 0, 1, 0,
    0, 1, 0, 1, 1, 0, 1, 3, 0, 0, 3, 0,
  ]);
  const indices = new Uint32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]);
  const normals = new Float32Array(8 * 3);
  for (let i = 0; i < 8; i++) normals[i * 3 + 2] = 1;
  const uvs = new Float32Array([0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1]);
  return { name: 'lshape', positions, indices, normals, uvs };
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

test('three.js FBXLoader parses our FBX and recovers the geometry', () => {
  const mesh = lShape();
  // Write metres so the comparison is against the source numbers directly.
  const bytes = writeMeshFbx(mesh, { units: 'm', name: 'lshape' });

  const loader = new FBXLoader();
  const group = loader.parse(toArrayBuffer(bytes), '');

  const meshes: any[] = [];
  group.traverse((o: any) => {
    if (o.isMesh) meshes.push(o);
  });
  assert.equal(meshes.length, 1, 'exactly one mesh should come back');

  const geometry = meshes[0].geometry;
  const position = geometry.getAttribute('position');
  // FBXLoader expands to non-indexed triangles: 4 triangles x 3 corners.
  assert.equal(position.count, 12, 'four triangles worth of corners');

  // Rebuild the triangles the loader produced and compare as a set against ours.
  const loaded = new Set<string>();
  for (let t = 0; t < 4; t++) {
    const corners: string[] = [];
    for (let c = 0; c < 3; c++) {
      const i = t * 3 + c;
      corners.push(
        `${position.getX(i).toFixed(4)},${position.getY(i).toFixed(4)},${position.getZ(i).toFixed(4)}`,
      );
    }
    loaded.add(corners.join('|'));
  }

  const expected = new Set<string>();
  for (let t = 0; t < 4; t++) {
    const corners: string[] = [];
    for (let c = 0; c < 3; c++) {
      const i = mesh.indices[t * 3 + c];
      corners.push(
        `${mesh.positions[i * 3].toFixed(4)},` +
        `${mesh.positions[i * 3 + 1].toFixed(4)},` +
        `${mesh.positions[i * 3 + 2].toFixed(4)}`,
      );
    }
    expected.add(corners.join('|'));
  }

  assert.deepEqual([...loaded].sort(), [...expected].sort(), 'triangles must match exactly');
});

test('three.js FBXLoader reads back the name we wrote', () => {
  const group = new FBXLoader().parse(
    toArrayBuffer(writeMeshFbx(lShape(), { name: 'stair-core' })),
    '',
  );
  const names: string[] = [];
  group.traverse((o: any) => {
    if (o.isMesh) names.push(o.name);
  });
  // The loader truncates the binary name at its NUL, so the class suffix is gone.
  assert.deepEqual(names, ['stair-core']);
});

test('three.js FBXLoader recovers normals and UVs', () => {
  const group = new FBXLoader().parse(
    toArrayBuffer(writeMeshFbx(lShape(), { units: 'm' })),
    '',
  );
  let geometry: any = null;
  group.traverse((o: any) => {
    if (o.isMesh) geometry = o.geometry;
  });
  assert.ok(geometry.getAttribute('normal'), 'normals must survive');
  assert.ok(geometry.getAttribute('uv'), 'uvs must survive');

  const normal = geometry.getAttribute('normal');
  for (let i = 0; i < normal.count; i++) {
    assert.ok(Math.abs(normal.getZ(i) - 1) < 1e-5, `normal ${i} should point +Z`);
  }
});

test('three.js FBXLoader sees centimetre output as 100x the metre output', () => {
  const parse = (units: 'cm' | 'm'): number => {
    const group = new FBXLoader().parse(
      toArrayBuffer(writeMeshFbx(lShape(), { units })),
      '',
    );
    let maxX = -Infinity;
    group.traverse((o: any) => {
      if (!o.isMesh) return;
      const p = o.geometry.getAttribute('position');
      for (let i = 0; i < p.count; i++) maxX = Math.max(maxX, p.getX(i));
    });
    return maxX;
  };
  // The loader does not apply UnitScaleFactor, so raw values differ by 100.
  assert.ok(Math.abs(parse('m') - 4) < 1e-4, 'metres: the L is 4 units long');
  assert.ok(Math.abs(parse('cm') - 400) < 1e-2, 'centimetres: 400 units');
});

test('three.js GLTFLoader parses our GLB and recovers indexed geometry', async () => {
  const mesh = lShape();
  const glb = writeMeshGlb(mesh);

  const gltf: any = await new Promise((resolve, reject) => {
    new GLTFLoader().parse(toArrayBuffer(glb), '', resolve, reject);
  });

  const meshes: any[] = [];
  gltf.scene.traverse((o: any) => {
    if (o.isMesh) meshes.push(o);
  });
  assert.equal(meshes.length, 1);

  const geometry = meshes[0].geometry;
  const position = geometry.getAttribute('position');
  assert.equal(position.count, 8, 'GLB keeps the mesh indexed, so 8 vertices');
  assert.deepEqual([...geometry.index.array], [...mesh.indices]);

  for (let i = 0; i < 8; i++) {
    assert.ok(Math.abs(position.getX(i) - mesh.positions[i * 3]) < 1e-6, `x[${i}]`);
    assert.ok(Math.abs(position.getY(i) - mesh.positions[i * 3 + 1]) < 1e-6, `y[${i}]`);
    assert.ok(Math.abs(position.getZ(i) - mesh.positions[i * 3 + 2]) < 1e-6, `z[${i}]`);
  }
  assert.ok(geometry.getAttribute('normal'), 'normals');
  assert.ok(geometry.getAttribute('uv'), 'uvs');
});

test('three.js GLTFLoader accepts a GLB with vertex colours', async () => {
  const mesh = lShape();
  mesh.colors = new Float32Array(8 * 3).fill(0.5);
  const gltf: any = await new Promise((resolve, reject) => {
    new GLTFLoader().parse(toArrayBuffer(writeMeshGlb(mesh)), '', resolve, reject);
  });
  let found = false;
  gltf.scene.traverse((o: any) => {
    if (o.isMesh && o.geometry.getAttribute('color')) found = true;
  });
  assert.ok(found, 'COLOR_0 must arrive as a color attribute');
});
