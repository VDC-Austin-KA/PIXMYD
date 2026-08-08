import test from 'node:test';
import assert from 'node:assert/strict';
import {
  readPly,
  writePly,
  parsePlyHeader,
  writePointCloudPly,
  readPointCloudPly,
  writeMeshPly,
  writeSplatPly,
  readSplatPly,
  shRestCoeffs,
} from '../src/ply.ts';
import type { Mesh, PointCloud, SplatCloud } from '@pixmyd/core/bundle';

const decode = (b: Uint8Array) => new TextDecoder().decode(b);

test('header parses elements, properties, comments and format', () => {
  const src = new TextEncoder().encode(
    'ply\n' +
      'format ascii 1.0\n' +
      'comment made by hand\n' +
      'obj_info scanner=fake\n' +
      'element vertex 2\n' +
      'property float x\n' +
      'property float y\n' +
      'property float z\n' +
      'property uchar red\n' +
      'element face 1\n' +
      'property list uchar int vertex_indices\n' +
      'end_header\n' +
      '0 0 0 255\n1 1 1 128\n3 0 1 0\n',
  );
  const h = parsePlyHeader(src);
  assert.equal(h.format, 'ascii');
  assert.deepEqual(h.comments, ['made by hand']);
  assert.deepEqual(h.objInfo, ['scanner=fake']);
  assert.equal(h.elements.length, 2);
  assert.equal(h.elements[0].properties.length, 4);
  assert.deepEqual(h.elements[1].properties[0], {
    kind: 'list',
    name: 'vertex_indices',
    countType: 'uint8',
    valueType: 'int32',
  });

  const ply = readPly(src);
  const v = ply.elements.get('vertex')!;
  assert.deepEqual([...v.scalars.get('x')!], [0, 1]);
  assert.deepEqual([...v.scalars.get('red')!], [255, 128]);
  assert.deepEqual(ply.elements.get('face')!.lists.get('vertex_indices')![0], [0, 1, 0]);
});

test('header rejects a file that is not PLY, and one with no format', () => {
  assert.throws(() => parsePlyHeader(new TextEncoder().encode('not a ply\n')), /magic/);
  assert.throws(
    () => parsePlyHeader(new TextEncoder().encode('ply\nelement vertex 1\nend_header\n')),
    /no format/,
  );
});

test('unknown header keywords are skipped rather than fatal', () => {
  const src = new TextEncoder().encode(
    'ply\nformat ascii 1.0\nvendor_thing 42\nelement vertex 1\nproperty float x\nend_header\n5\n',
  );
  const ply = readPly(src);
  assert.deepEqual([...ply.elements.get('vertex')!.scalars.get('x')!], [5]);
});

test('a truncated binary body reports what was missing instead of returning junk', () => {
  const good = writePly([
    { name: 'vertex', count: 100, columns: [{ name: 'x', type: 'float32', values: new Float32Array(100) }] },
  ]);
  const cut = good.subarray(0, good.length - 40);
  assert.throws(() => readPly(cut), /truncated/);
});

for (const format of ['ascii', 'binary_little_endian', 'binary_big_endian'] as const) {
  test(`round trip through ${format}`, () => {
    const n = 64;
    const xs = new Float32Array(n);
    const ids = new Uint32Array(n);
    const bytes = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      xs[i] = Math.sin(i) * 1000;
      ids[i] = i * 7;
      bytes[i] = i * 3 % 256;
    }
    const out = writePly(
      [
        {
          name: 'vertex',
          count: n,
          columns: [
            { name: 'x', type: 'float32', values: xs },
            { name: 'id', type: 'uint32', values: ids },
            { name: 'flag', type: 'uint8', values: bytes },
          ],
        },
      ],
      { format },
    );
    const back = readPly(out);
    assert.equal(back.header.format, format);
    const v = back.elements.get('vertex')!;
    for (let i = 0; i < n; i++) {
      // float32 values survive exactly because they were float32 to begin with
      assert.equal(v.scalars.get('x')![i], xs[i], `x[${i}]`);
      assert.equal(v.scalars.get('id')![i], ids[i], `id[${i}]`);
      assert.equal(v.scalars.get('flag')![i], bytes[i], `flag[${i}]`);
    }
  });
}

test('point cloud round trips with colour, normals and intensity', () => {
  const n = 50;
  const cloud: PointCloud = {
    count: n,
    positions: new Float64Array(n * 3),
    colors: new Uint8Array(n * 3),
    normals: new Float32Array(n * 3),
    intensity: new Float32Array(n),
    origin: [2120000, 13720000, 0],
  };
  for (let i = 0; i < n; i++) {
    cloud.positions[i * 3] = i * 0.125;
    cloud.positions[i * 3 + 1] = -i * 0.25;
    cloud.positions[i * 3 + 2] = i;
    cloud.colors![i * 3] = i * 5 % 256;
    cloud.colors![i * 3 + 1] = 255 - (i % 256);
    cloud.colors![i * 3 + 2] = 7;
    cloud.normals![i * 3 + 1] = 1;
    cloud.intensity![i] = i / n;
  }

  const bytes = writePointCloudPly(cloud, { positionType: 'float64' });
  const back = readPointCloudPly(bytes);
  assert.equal(back.count, n);
  for (let i = 0; i < n * 3; i++) {
    assert.equal(back.positions[i], cloud.positions[i], `position[${i}]`);
    assert.equal(back.colors![i], cloud.colors![i], `color[${i}]`);
  }
  assert.deepEqual(back.origin, [2120000, 13720000, 0]);
});

test('point cloud origin is preserved through the comment channel', () => {
  const cloud: PointCloud = {
    count: 1,
    positions: new Float64Array([1, 2, 3]),
    origin: [2120000, 13720000, 150.5],
  };
  const text = decode(writePointCloudPly(cloud, { format: 'ascii' }));
  assert.match(text, /comment pixmyd origin 2120000 13720000 150\.5/);
  assert.deepEqual(readPointCloudPly(writePointCloudPly(cloud)).origin, [2120000, 13720000, 150.5]);
});

test('mesh writes a face element with a triangle list', () => {
  const mesh: Mesh = {
    positions: new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]),
    indices: new Uint32Array([0, 1, 2, 2, 1, 3]),
    normals: new Float32Array([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]),
  };
  const ply = readPly(writeMeshPly(mesh));
  assert.equal(ply.elements.get('vertex')!.count, 4);
  const faces = ply.elements.get('face')!;
  assert.equal(faces.count, 2);
  assert.deepEqual(faces.lists.get('vertex_indices')![0], [0, 1, 2]);
  assert.deepEqual(faces.lists.get('vertex_indices')![1], [2, 1, 3]);
});

test('mesh vertex colours are quantised and clamped to a byte', () => {
  const mesh: Mesh = {
    positions: new Float32Array([0, 0, 0]),
    indices: new Uint32Array([]),
    // deliberately out of range on both ends
    colors: new Float32Array([1.5, -0.2, 0.5]),
  };
  const v = readPly(writeMeshPly(mesh)).elements.get('vertex')!;
  assert.equal(v.scalars.get('red')![0], 255);
  assert.equal(v.scalars.get('green')![0], 0);
  assert.equal(v.scalars.get('blue')![0], 128);
});

test('comments containing a newline cannot forge a header line', () => {
  const bytes = writePointCloudPly(
    { count: 1, positions: new Float64Array([0, 0, 0]) },
    { format: 'ascii', comments: ['harmless\nelement injected 99'] },
  );
  const header = parsePlyHeader(bytes);
  assert.equal(header.elements.length, 1, 'only the vertex element should exist');
  assert.ok(header.comments.includes('element injected 99'));
});

// --- splats ---------------------------------------------------------------

function makeSplats(n: number, shDegree: 0 | 1 | 2 | 3): SplatCloud {
  const rest = shRestCoeffs(shDegree);
  const s: SplatCloud = {
    count: n,
    positions: new Float32Array(n * 3),
    scales: new Float32Array(n * 3),
    rotations: new Float32Array(n * 4),
    opacities: new Float32Array(n),
    sh0: new Float32Array(n * 3),
    shRest: rest > 0 ? new Float32Array(n * rest * 3) : undefined,
    shDegree,
  };
  for (let i = 0; i < n; i++) {
    s.positions[i * 3] = i;
    s.positions[i * 3 + 1] = -i * 0.5;
    s.positions[i * 3 + 2] = i * 0.25;
    s.scales[i * 3] = Math.log(0.01 + i * 0.001);
    s.scales[i * 3 + 1] = -3;
    s.scales[i * 3 + 2] = -3.5;
    // a distinguishable non-identity quaternion in xyzw memory order
    s.rotations[i * 4] = 0.1;
    s.rotations[i * 4 + 1] = 0.2;
    s.rotations[i * 4 + 2] = 0.3;
    s.rotations[i * 4 + 3] = 0.9;
    s.opacities[i] = i * 0.01 - 2;
    s.sh0[i * 3] = 0.5;
    s.sh0[i * 3 + 1] = -0.25;
    s.sh0[i * 3 + 2] = 0.125;
    for (let c = 0; c < rest; c++) {
      for (let ch = 0; ch < 3; ch++) {
        // unique per (splat, coefficient, channel) so a transpose bug cannot hide
        s.shRest![i * rest * 3 + c * 3 + ch] = i * 100 + c * 10 + ch;
      }
    }
  }
  return s;
}

for (const degree of [0, 1, 2, 3] as const) {
  test(`splat PLY round trips at SH degree ${degree}`, () => {
    const original = makeSplats(24, degree);
    const back = readSplatPly(writeSplatPly(original));

    assert.equal(back.count, original.count);
    assert.equal(back.shDegree, degree, 'degree must be recovered from the property count');
    assert.deepEqual([...back.positions], [...original.positions]);
    assert.deepEqual([...back.scales], [...original.scales]);
    assert.deepEqual([...back.opacities], [...original.opacities]);
    assert.deepEqual([...back.sh0], [...original.sh0]);
    // rotations survive the w-first <-> xyzw swap
    assert.deepEqual([...back.rotations], [...original.rotations]);
    if (degree > 0) {
      assert.deepEqual([...back.shRest!], [...original.shRest!]);
    } else {
      assert.equal(back.shRest, undefined);
    }
  });
}

test('splat PLY uses the channel-major f_rest layout the reference tools expect', () => {
  const s = makeSplats(1, 1); // 3 coefficients per channel, 9 total
  const v = readPly(writeSplatPly(s)).elements.get('vertex')!;
  // channel-major: f_rest_0..2 are R's three coefficients, 3..5 G's, 6..8 B's
  assert.equal(v.scalars.get('f_rest_0')![0], 0); // coeff 0, channel 0
  assert.equal(v.scalars.get('f_rest_1')![0], 10); // coeff 1, channel 0
  assert.equal(v.scalars.get('f_rest_2')![0], 20); // coeff 2, channel 0
  assert.equal(v.scalars.get('f_rest_3')![0], 1); // coeff 0, channel 1
  assert.equal(v.scalars.get('f_rest_6')![0], 2); // coeff 0, channel 2
});

test('splat PLY names the rotation quaternion w first', () => {
  const s = makeSplats(1, 0);
  const v = readPly(writeSplatPly(s)).elements.get('vertex')!;
  assert.equal(v.scalars.get('rot_0')![0], Math.fround(0.9), 'rot_0 is w');
  assert.equal(v.scalars.get('rot_1')![0], Math.fround(0.1), 'rot_1 is x');
});

test('splat PLY writes zero normals for reader compatibility', () => {
  const v = readPly(writeSplatPly(makeSplats(3, 0))).elements.get('vertex')!;
  assert.ok(v.scalars.has('nx') && v.scalars.has('ny') && v.scalars.has('nz'));
  assert.deepEqual([...v.scalars.get('nx')!], [0, 0, 0]);
});

test('splat PLY refuses an SH degree it has no coefficients for', () => {
  const s = makeSplats(4, 2);
  s.shRest = undefined;
  assert.throws(() => writeSplatPly(s), /needs shRest/);
});

test('a column shorter than the row count is refused rather than silently padded', () => {
  assert.throws(
    () =>
      writePly([
        { name: 'vertex', count: 10, columns: [{ name: 'x', type: 'float32', values: new Float32Array(3) }] },
      ]),
    /3 values for 10 rows/,
  );
});
