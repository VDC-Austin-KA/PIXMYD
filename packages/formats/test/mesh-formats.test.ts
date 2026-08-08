import test from 'node:test';
import assert from 'node:assert/strict';
import { writeMeshGlb, writeSplatGlb, parseGlb, readAccessor, PrimitiveMode } from '../src/glb.ts';
import { writeObj, readObj, writePointCloudObj } from '../src/obj.ts';
import { writeMeshFbx, parseFbx, findFbxNode, serializeFbx, P } from '../src/fbx.ts';
import type { Mesh, PointCloud, SplatCloud } from '@pixmyd/core/bundle';

/** A quad: two triangles, four vertices, every optional attribute present. */
function quad(): Mesh {
  return {
    name: 'quad',
    positions: new Float32Array([0, 0, 0, 2, 0, 0, 0, 3, 0, 2, 3, 0]),
    indices: new Uint32Array([0, 1, 2, 2, 1, 3]),
    normals: new Float32Array([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]),
    uvs: new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]),
    colors: new Float32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1]),
  };
}

// ===========================================================================
// GLB
// ===========================================================================

test('GLB container is well formed: magic, version, declared length, chunk padding', () => {
  const bytes = writeMeshGlb(quad());
  assert.equal(bytes.byteLength % 4, 0, 'total length must stay 4-aligned');

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(view.getUint32(0, true), 0x46546c67, 'glTF magic');
  assert.equal(view.getUint32(4, true), 2, 'version 2');
  assert.equal(view.getUint32(8, true), bytes.byteLength, 'declared length matches actual');

  // Walk the chunks and confirm they exactly fill the file.
  let offset = 12;
  const seen: number[] = [];
  while (offset < bytes.byteLength) {
    const len = view.getUint32(offset, true);
    const type = view.getUint32(offset + 4, true);
    assert.equal(len % 4, 0, 'each chunk length must be 4-aligned');
    seen.push(type);
    offset += 8 + len;
  }
  assert.equal(offset, bytes.byteLength, 'chunks must tile the file exactly');
  assert.deepEqual(seen, [0x4e4f534a, 0x004e4942], 'JSON then BIN');
});

test('GLB mesh carries every attribute and a POSITION accessor with min/max', () => {
  const mesh = quad();
  const glb = parseGlb(writeMeshGlb(mesh));
  const prim = glb.json.meshes[0].primitives[0];

  assert.equal(prim.mode, PrimitiveMode.TRIANGLES);
  for (const attr of ['POSITION', 'NORMAL', 'TEXCOORD_0', 'COLOR_0']) {
    assert.ok(attr in prim.attributes, `missing ${attr}`);
  }

  const posAccessor = glb.json.accessors[prim.attributes.POSITION];
  assert.deepEqual(posAccessor.min, [0, 0, 0], 'spec requires min on POSITION');
  assert.deepEqual(posAccessor.max, [2, 3, 0], 'spec requires max on POSITION');

  assert.deepEqual([...readAccessor(glb, prim.attributes.POSITION)], [...mesh.positions]);
  assert.deepEqual([...readAccessor(glb, prim.indices!)], [...mesh.indices]);
});

test('GLB uses uint16 indices when the vertex count allows it', () => {
  const glb = parseGlb(writeMeshGlb(quad()));
  const prim = glb.json.meshes[0].primitives[0];
  assert.equal(glb.json.accessors[prim.indices].componentType, 5123, 'uint16');
});

test('GLB falls back to uint32 indices past 65535 vertices', () => {
  const n = 70000;
  const mesh: Mesh = {
    positions: new Float32Array(n * 3),
    indices: new Uint32Array([0, 1, 69999]),
  };
  const glb = parseGlb(writeMeshGlb(mesh));
  const prim = glb.json.meshes[0].primitives[0];
  assert.equal(glb.json.accessors[prim.indices].componentType, 5125, 'uint32');
  assert.deepEqual([...readAccessor(glb, prim.indices)], [0, 1, 69999]);
});

test('GLB zUpToYUp rotates geometry rather than relabelling it', () => {
  const mesh: Mesh = {
    positions: new Float32Array([1, 2, 3]),
    indices: new Uint32Array([]),
  };
  const glb = parseGlb(writeMeshGlb(mesh, { zUpToYUp: true }));
  const p = readAccessor(glb, glb.json.meshes[0].primitives[0].attributes.POSITION);
  // (x, y, z) -> (x, z, -y)
  assert.deepEqual([...p], [1, 3, -2]);
});

test('GLB embeds a texture as a bufferView-backed image', () => {
  const mesh = quad();
  mesh.texture = {
    width: 2,
    height: 2,
    data: new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]),
    mimeType: 'image/png',
  };
  const glb = parseGlb(writeMeshGlb(mesh));
  assert.equal(glb.json.images.length, 1);
  assert.equal(glb.json.images[0].mimeType, 'image/png');
  assert.equal(glb.json.materials[0].pbrMetallicRoughness.baseColorTexture.index, 0);

  const view = glb.json.bufferViews[glb.json.images[0].bufferView];
  const stored = glb.bin.subarray(view.byteOffset, view.byteOffset + view.byteLength);
  assert.deepEqual([...stored], [...mesh.texture.data]);
});

test('parseGlb rejects a truncated file rather than returning partial data', () => {
  const good = writeMeshGlb(quad());
  assert.throws(() => parseGlb(good.subarray(0, good.length - 8)), /header says/);
});

// --- splat GLB ------------------------------------------------------------

function splats(n: number, degree: 0 | 1 | 2 | 3 = 0): SplatCloud {
  const rest = (degree + 1) ** 2 - 1;
  const s: SplatCloud = {
    count: n,
    positions: new Float32Array(n * 3),
    scales: new Float32Array(n * 3),
    rotations: new Float32Array(n * 4),
    opacities: new Float32Array(n),
    sh0: new Float32Array(n * 3),
    shRest: rest ? new Float32Array(n * rest * 3) : undefined,
    shDegree: degree,
  };
  for (let i = 0; i < n; i++) {
    s.positions[i * 3] = i;
    s.scales[i * 3] = Math.log(0.05);
    s.scales[i * 3 + 1] = Math.log(0.02);
    s.scales[i * 3 + 2] = Math.log(0.01);
    s.rotations[i * 4 + 3] = 1;
    s.opacities[i] = 0; // logit 0 -> alpha 0.5
    s.sh0[i * 3] = 0.5;
  }
  return s;
}

test('splat GLB activates opacity and scale, which the extension stores linear', () => {
  const glb = parseGlb(writeSplatGlb(splats(4)));
  const attrs = glb.json.meshes[0].primitives[0].attributes;

  const opacity = readAccessor(glb, attrs['KHR_gaussian_splatting:OPACITY']);
  for (const a of opacity) {
    assert.ok(Math.abs(a - 0.5) < 1e-6, `logit 0 must become alpha 0.5, got ${a}`);
  }

  const scale = readAccessor(glb, attrs['KHR_gaussian_splatting:SCALE']);
  assert.ok(Math.abs(scale[0] - 0.05) < 1e-6, 'log-scale must be exponentiated');
  assert.ok(Math.abs(scale[1] - 0.02) < 1e-6);
  assert.ok(Math.abs(scale[2] - 0.01) < 1e-6);
});

test('splat GLB declares the extension required and uses POINTS mode', () => {
  const glb = parseGlb(writeSplatGlb(splats(3)));
  assert.deepEqual(glb.json.extensionsRequired, ['KHR_gaussian_splatting']);
  assert.deepEqual(glb.json.extensionsUsed, ['KHR_gaussian_splatting']);
  const prim = glb.json.meshes[0].primitives[0];
  assert.equal(prim.mode, PrimitiveMode.POINTS);
  assert.equal(prim.extensions.KHR_gaussian_splatting.kernel, 'ellipse');
  assert.ok('colorSpace' in prim.extensions.KHR_gaussian_splatting);
});

test('splat GLB emits one accessor per SH band coefficient', () => {
  const glb = parseGlb(writeSplatGlb(splats(2, 2)));
  const attrs = glb.json.meshes[0].primitives[0].attributes;
  // degree 2: 3 coefficients at l=1, 5 at l=2
  for (let m = 0; m < 3; m++) {
    assert.ok(`KHR_gaussian_splatting:SH_DEGREE_1_COEF_${m}` in attrs, `l=1 m=${m}`);
  }
  for (let m = 0; m < 5; m++) {
    assert.ok(`KHR_gaussian_splatting:SH_DEGREE_2_COEF_${m}` in attrs, `l=2 m=${m}`);
  }
  assert.ok(!('KHR_gaussian_splatting:SH_DEGREE_3_COEF_0' in attrs));
});

test('splat GLB maxShDegree drops higher bands', () => {
  const glb = parseGlb(writeSplatGlb(splats(2, 3), { maxShDegree: 1 }));
  const attrs = glb.json.meshes[0].primitives[0].attributes;
  assert.ok('KHR_gaussian_splatting:SH_DEGREE_1_COEF_0' in attrs);
  assert.ok(!('KHR_gaussian_splatting:SH_DEGREE_2_COEF_0' in attrs));
});

// ===========================================================================
// OBJ
// ===========================================================================

test('OBJ uses 1-based indices and flips V for image space', () => {
  const { obj } = writeObj(quad(), { materialLibrary: 'quad.mtl' });
  const lines = obj.split('\n');
  assert.ok(lines.includes('v 0 0 0 1 0 0'), 'vertex with colour extension');
  assert.ok(lines.includes('mtllib quad.mtl'));
  assert.ok(lines.includes('f 1/1/1 2/2/2 3/3/3'), '1-based, position/uv/normal');
  // uv (0,0) becomes vt 0 1
  assert.ok(lines.includes('vt 0 1'), 'V must be flipped');
});

test('OBJ omits uv and normal slots it does not have', () => {
  const { obj } = writeObj({
    positions: new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]),
    indices: new Uint32Array([0, 1, 2]),
  });
  assert.ok(obj.split('\n').includes('f 1 2 3'), 'no slashes when there is nothing to reference');
});

test('OBJ round trips through readObj', () => {
  const mesh = quad();
  const back = readObj(writeObj(mesh).obj);
  assert.equal(back.indices.length, mesh.indices.length);
  // Positions come back re-indexed by unique face corner, so compare the
  // triangles they describe rather than the raw arrays.
  const tri = (m: Mesh, f: number): number[] => {
    const out: number[] = [];
    for (let c = 0; c < 3; c++) {
      const i = m.indices[f * 3 + c];
      out.push(m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]);
    }
    return out;
  };
  for (let f = 0; f < 2; f++) assert.deepEqual(tri(back, f), tri(mesh, f));
  assert.ok(back.normals && back.uvs && back.colors, 'attributes survive the trip');
});

test('OBJ reader triangulates a quad face with a fan', () => {
  const mesh = readObj('v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n');
  assert.equal(mesh.indices.length, 6, 'one quad becomes two triangles');
  assert.deepEqual([...mesh.indices], [0, 1, 2, 0, 2, 3]);
});

test('OBJ reader handles negative (relative) indices', () => {
  const mesh = readObj('v 0 0 0\nv 1 0 0\nv 1 1 0\nf -3 -2 -1\n');
  assert.deepEqual([...mesh.indices], [0, 1, 2]);
  assert.deepEqual([...mesh.positions], [0, 0, 0, 1, 0, 0, 1, 1, 0]);
});

test('OBJ MTL references the texture file when there is one', () => {
  const mesh = quad();
  mesh.texture = { width: 1, height: 1, data: new Uint8Array([1]), mimeType: 'image/jpeg' };
  const result = writeObj(mesh, { materialLibrary: 'quad.mtl', name: 'quad' });
  assert.match(result.mtl!, /map_Kd quad\.jpg/);
  assert.equal(result.textureFilename, 'quad.jpg');
  assert.deepEqual([...result.texture!], [1]);
});

test('point cloud OBJ writes vertices with no faces', () => {
  const cloud: PointCloud = {
    count: 2,
    positions: new Float64Array([0, 0, 0, 1, 2, 3]),
    colors: new Uint8Array([255, 0, 0, 0, 255, 0]),
    origin: [100, 200, 0],
  };
  const text = writePointCloudObj(cloud);
  assert.ok(!text.includes('\nf '), 'a point cloud has no faces');
  assert.match(text, /# pixmyd origin 100 200 0/);
  assert.ok(text.split('\n').includes('v 1 2 3 0 1 0'));
});

// ===========================================================================
// FBX
// ===========================================================================

test('FBX header and footer are exactly as specified', () => {
  const bytes = writeMeshFbx(quad());
  assert.equal(new TextDecoder().decode(bytes.subarray(0, 20)), 'Kaydara FBX Binary  ');
  assert.equal(bytes[20], 0x00);
  assert.equal(bytes[21], 0x1a);
  assert.equal(bytes[22], 0x00);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(view.getUint32(23, true), 7400);

  const magic = [0xf8, 0x5a, 0x8c, 0x6a, 0xde, 0xf5, 0xd9, 0x7e,
    0xec, 0xe9, 0x0c, 0xe3, 0x75, 0x8f, 0x29, 0x0b];
  assert.deepEqual([...bytes.subarray(bytes.length - 16)], magic, 'footer extension magic');
});

test('FBX node offsets are self-consistent end to end', () => {
  // parseFbx throws if any endOffset or propertyListLen disagrees with the bytes,
  // so simply completing the walk is the assertion.
  const nodes = parseFbx(writeMeshFbx(quad()));
  const names = nodes.map((n) => n.name);
  assert.deepEqual(names, [
    'FBXHeaderExtension', 'Creator', 'GlobalSettings', 'Definitions', 'Objects', 'Connections',
  ]);
});

test('FBX leaf nodes carry no NULL sentinel, parent nodes do', () => {
  // A single childless node: 13 header bytes + name + props, then the top-level
  // NULL record. If writeNode wrongly appended a sentinel to the leaf, parseFbx
  // would report an endOffset mismatch.
  const bytes = serializeFbx([{ name: 'Leaf', props: [P.i32(7)] }]);
  const nodes = parseFbx(bytes);
  assert.equal(nodes.length, 1);
  assert.deepEqual(nodes[0].props, [7]);
  assert.equal(nodes[0].children.length, 0);
});

test('FBX encodes polygon ends by bitwise negation', () => {
  const nodes = parseFbx(writeMeshFbx(quad()));
  const pvi = findFbxNode(nodes, 'PolygonVertexIndex')!.props[0] as Int32Array;
  // triangles [0,1,2] and [2,1,3] -> last index of each is ~i
  assert.deepEqual([...pvi], [0, 1, ~2, 2, 1, ~3]);
});

test('FBX writes centimetres by default so a 3 m edge is not imported as 3 cm', () => {
  const nodes = parseFbx(writeMeshFbx(quad()));
  const vertices = findFbxNode(nodes, 'Vertices')!.props[0] as Float64Array;
  // quad is 2 m x 3 m -> 200 x 300 cm
  assert.deepEqual([...vertices.slice(0, 6)], [0, 0, 0, 200, 0, 0]);

  const metres = parseFbx(writeMeshFbx(quad(), { units: 'm' }));
  const mv = findFbxNode(metres, 'Vertices')!.props[0] as Float64Array;
  assert.deepEqual([...mv.slice(0, 6)], [0, 0, 0, 2, 0, 0]);
});

test('FBX object names use the binary Name\\0\\x01Class convention', () => {
  const nodes = parseFbx(writeMeshFbx(quad(), { name: 'wall' }));
  const geometry = findFbxNode(nodes, 'Geometry')!;
  assert.equal(geometry.props[1], 'wall Geometry');
  assert.equal(geometry.props[2], 'Mesh');
});

test('FBX connects geometry and material to the model, and the model to the root', () => {
  const nodes = parseFbx(writeMeshFbx(quad()));
  const connections = nodes.find((n) => n.name === 'Connections')!;
  assert.equal(connections.children.length, 3);
  const modelToRoot = connections.children[0];
  assert.equal(modelToRoot.props[0], 'OO');
  assert.equal(modelToRoot.props[2], 0n, 'scene root is id 0');
  // geometry and material both attach to the model
  const modelId = modelToRoot.props[1];
  assert.equal(connections.children[1].props[2], modelId);
  assert.equal(connections.children[2].props[2], modelId);
});

test('FBX layer elements are declared for every attribute present', () => {
  const nodes = parseFbx(writeMeshFbx(quad()));
  for (const n of ['LayerElementNormal', 'LayerElementUV', 'LayerElementColor', 'LayerElementMaterial']) {
    assert.ok(findFbxNode(nodes, n), `missing ${n}`);
  }
  const layer = findFbxNode(nodes, 'Layer')!;
  const declared = layer.children
    .filter((c) => c.name === 'LayerElement')
    .map((c) => c.children.find((x) => x.name === 'Type')!.props[0]);
  assert.deepEqual(declared, [
    'LayerElementNormal', 'LayerElementUV', 'LayerElementColor', 'LayerElementMaterial',
  ]);
});

test('FBX omits layer elements for attributes the mesh lacks', () => {
  const nodes = parseFbx(
    writeMeshFbx({
      positions: new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]),
      indices: new Uint32Array([0, 1, 2]),
    }),
  );
  assert.equal(findFbxNode(nodes, 'LayerElementNormal'), null);
  assert.equal(findFbxNode(nodes, 'LayerElementUV'), null);
  assert.ok(findFbxNode(nodes, 'LayerElementMaterial'), 'material layer is always present');
});
