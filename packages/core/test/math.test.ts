import test from 'node:test';
import assert from 'node:assert/strict';
import { mat4, quat, v3, bounds, degToRad, type Quat, type Vec3 } from '../src/math.ts';
import { ByteWriter, ByteReader } from '../src/bytes.ts';

const close = (a: number, b: number, tol = 1e-9) =>
  assert.ok(Math.abs(a - b) < tol, `${a} !~= ${b} (tol ${tol})`);

const closeVec = (a: Vec3, b: Vec3, tol = 1e-9) => {
  for (let i = 0; i < 3; i++) close(a[i], b[i], tol);
};

test('quaternion rotation matches axis-angle expectation', () => {
  const q = quat.fromAxisAngle([0, 0, 1], degToRad(90));
  closeVec(quat.rotate(q, [1, 0, 0]), [0, 1, 0]);
  closeVec(quat.rotate(q, [0, 1, 0]), [-1, 0, 0]);
  closeVec(quat.rotate(q, [0, 0, 1]), [0, 0, 1]);
});

test('quaternion multiply composes right-to-left', () => {
  const rz = quat.fromAxisAngle([0, 0, 1], degToRad(90));
  const rx = quat.fromAxisAngle([1, 0, 0], degToRad(90));
  // rx applied after rz
  const combined = quat.multiply(rx, rz);
  const stepwise = quat.rotate(rx, quat.rotate(rz, [1, 0, 0]));
  closeVec(quat.rotate(combined, [1, 0, 0]), stepwise);
});

test('quaternion survives a matrix round trip in every Shepperd branch', () => {
  // Each of these lands in a different branch of fromMat3.
  const cases: Quat[] = [
    quat.identity(),
    quat.fromAxisAngle([1, 0, 0], degToRad(179)),
    quat.fromAxisAngle([0, 1, 0], degToRad(179)),
    quat.fromAxisAngle([0, 0, 1], degToRad(179)),
    quat.normalize([0.3, -0.5, 0.7, 0.4]),
  ];
  for (const q of cases) {
    const back = quat.fromMat3(quat.toMat3(q));
    // q and -q are the same rotation; compare via action on a basis.
    for (const p of [[1, 0, 0], [0, 1, 0], [0, 0, 1]] as Vec3[]) {
      closeVec(quat.rotate(back, p), quat.rotate(q, p), 1e-9);
    }
  }
});

test('slerp endpoints and midpoint', () => {
  const a = quat.identity();
  const b = quat.fromAxisAngle([0, 1, 0], degToRad(90));
  closeVec(quat.rotate(quat.slerp(a, b, 0), [1, 0, 0]), [1, 0, 0]);
  closeVec(quat.rotate(quat.slerp(a, b, 1), [1, 0, 0]), quat.rotate(b, [1, 0, 0]));
  const mid = quat.slerp(a, b, 0.5);
  const expected = quat.fromAxisAngle([0, 1, 0], degToRad(45));
  closeVec(quat.rotate(mid, [1, 0, 0]), quat.rotate(expected, [1, 0, 0]), 1e-9);
});

test('mat4 compose then decompose round trips', () => {
  const t: Vec3 = [3, -4, 5.5];
  const r = quat.normalize([0.1, 0.4, -0.2, 0.88]);
  const s: Vec3 = [2, 2, 2];
  const m = mat4.compose(t, r, s);
  const d = mat4.decompose(m);
  closeVec(d.translation, t, 1e-9);
  closeVec(d.scale, s, 1e-9);
  closeVec(quat.rotate(d.rotation, [1, 2, 3]), quat.rotate(r, [1, 2, 3]), 1e-9);
});

test('invertRigid agrees with the general inverse and is exact', () => {
  const m = mat4.compose([10, -3, 7], quat.normalize([0.2, 0.3, 0.1, 0.9]));
  const general = mat4.invert(m)!;
  const rigid = mat4.invertRigid(m);
  for (let i = 0; i < 16; i++) close(rigid[i], general[i], 1e-12);
  // round trip a point
  const p: Vec3 = [1.25, -8, 4];
  closeVec(mat4.transformPoint(rigid, mat4.transformPoint(m, p)), p, 1e-12);
});

test('multiply applies the right operand first', () => {
  const translate = mat4.fromTranslation([10, 0, 0]);
  const rotate = mat4.fromRotation(quat.fromAxisAngle([0, 0, 1], degToRad(90)));
  // translate * rotate: rotate the point, then translate it
  const tr = mat4.multiply(translate, rotate);
  closeVec(mat4.transformPoint(tr, [1, 0, 0]), [10, 1, 0], 1e-9);
  // rotate * translate: translate first, then rotate the whole thing
  const rt = mat4.multiply(rotate, translate);
  closeVec(mat4.transformPoint(rt, [1, 0, 0]), [0, 11, 0], 1e-9);
});

test('lookAt puts the target on the negative z axis of view space', () => {
  const view = mat4.lookAt([0, 0, 10], [0, 0, 0], [0, 1, 0]);
  const p = mat4.transformPoint(view, [0, 0, 0]);
  closeVec(p, [0, 0, -10], 1e-9);
});

test('lookAt tolerates an up vector parallel to the view direction', () => {
  const view = mat4.lookAt([0, 10, 0], [0, 0, 0], [0, 1, 0]);
  assert.ok(Number.isFinite(view[0]), 'degenerate up must not produce NaN');
  const p = mat4.transformPoint(view, [0, 0, 0]);
  close(p[2], -10, 1e-9);
});

test('bounds cubify keeps the centre and takes the longest axis', () => {
  const b = bounds.cubify({ min: [0, 0, 0], max: [30, 6, 20] });
  closeVec(bounds.center(b), [15, 3, 10], 1e-9);
  const s = bounds.size(b);
  closeVec(s, [30, 30, 30], 1e-9);
});

test('bounds from an interleaved array', () => {
  const b = bounds.fromPositions([1, 2, 3, -4, 5, -6, 0, 0, 0]);
  closeVec(b.min, [-4, 0, -6]);
  closeVec(b.max, [1, 5, 3]);
});

test('v3 basics', () => {
  closeVec(v3.cross([1, 0, 0], [0, 1, 0]), [0, 0, 1]);
  close(v3.dot([1, 2, 3], [4, 5, 6]), 32);
  close(v3.length([3, 4, 0]), 5);
  assert.deepEqual(v3.normalize([0, 0, 0]), [0, 0, 0]);
});

test('ByteWriter round trips through ByteReader', () => {
  const w = new ByteWriter(4);
  w.u8(0xab).u16(0x1234).u32(0xdeadbeef).f32(1.5).f64(-2.25).i32(-7);
  w.ascii('pixmyd');
  w.u64(1234567890123n);
  const r = new ByteReader(w.finish());
  assert.equal(r.u8(), 0xab);
  assert.equal(r.u16(), 0x1234);
  assert.equal(r.u32(), 0xdeadbeef);
  assert.equal(r.f32(), 1.5);
  assert.equal(r.f64(), -2.25);
  assert.equal(r.i32(), -7);
  assert.equal(r.ascii(6), 'pixmyd');
  assert.equal(r.u64(), 1234567890123n);
  assert.equal(r.remaining, 0);
});

test('ByteWriter grows past its initial capacity', () => {
  const w = new ByteWriter(2);
  for (let i = 0; i < 1000; i++) w.u32(i);
  assert.equal(w.length, 4000);
  const r = new ByteReader(w.finish());
  for (let i = 0; i < 1000; i++) assert.equal(r.u32(), i);
});

test('patchU32 back-patches a size written earlier', () => {
  const w = new ByteWriter();
  const at = w.length;
  w.u32(0);
  w.ascii('payload');
  w.patchU32(at, w.length - at - 4);
  const r = new ByteReader(w.finish());
  assert.equal(r.u32(), 7);
  assert.equal(r.ascii(7), 'payload');
});

test('align pads to the requested boundary', () => {
  const w = new ByteWriter();
  w.ascii('abc').align(4, 0x20);
  assert.equal(w.length, 4);
  assert.equal(w.finish()[3], 0x20);
});

test('ByteReader.line handles both LF and CRLF', () => {
  const r = new ByteReader(new TextEncoder().encode('ply\r\nformat ascii 1.0\nend\n'));
  assert.equal(r.line(), 'ply');
  assert.equal(r.line(), 'format ascii 1.0');
  assert.equal(r.line(), 'end');
});
