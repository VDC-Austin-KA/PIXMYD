/**
 * Small linear-algebra kernel: vectors, quaternions, 4x4 matrices, rigid poses.
 *
 * Matrices are column-major (the glTF and OpenGL convention) so a Mat4 can go
 * straight into a GLB node or a GPU uniform without a transpose. Element `m[c*4+r]`
 * is row `r` of column `c`.
 *
 * Quaternions are stored [x, y, z, w] — also the glTF convention.
 */

export type Vec2 = [number, number];
export type Vec3 = [number, number, number];
export type Quat = [number, number, number, number];
/** Column-major 4x4. */
export type Mat4 = Float64Array;
/** Column-major 3x3. */
export type Mat3 = Float64Array;

export const EPSILON = 1e-12;

// ---------------------------------------------------------------------------
// Vec3
// ---------------------------------------------------------------------------

export const v3 = {
  add(a: Vec3, b: Vec3): Vec3 {
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
  },
  sub(a: Vec3, b: Vec3): Vec3 {
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  },
  scale(a: Vec3, s: number): Vec3 {
    return [a[0] * s, a[1] * s, a[2] * s];
  },
  mul(a: Vec3, b: Vec3): Vec3 {
    return [a[0] * b[0], a[1] * b[1], a[2] * b[2]];
  },
  dot(a: Vec3, b: Vec3): number {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  },
  cross(a: Vec3, b: Vec3): Vec3 {
    return [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
    ];
  },
  length(a: Vec3): number {
    return Math.hypot(a[0], a[1], a[2]);
  },
  lengthSq(a: Vec3): number {
    return a[0] * a[0] + a[1] * a[1] + a[2] * a[2];
  },
  distance(a: Vec3, b: Vec3): number {
    return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
  },
  normalize(a: Vec3): Vec3 {
    const l = Math.hypot(a[0], a[1], a[2]);
    if (l < EPSILON) return [0, 0, 0];
    return [a[0] / l, a[1] / l, a[2] / l];
  },
  lerp(a: Vec3, b: Vec3, t: number): Vec3 {
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
  },
  negate(a: Vec3): Vec3 {
    return [-a[0], -a[1], -a[2]];
  },
} as const;

// ---------------------------------------------------------------------------
// Quaternion  [x, y, z, w]
// ---------------------------------------------------------------------------

export const quat = {
  identity(): Quat {
    return [0, 0, 0, 1];
  },

  /** Hamilton product: the rotation `b` followed by the rotation `a`. */
  multiply(a: Quat, b: Quat): Quat {
    const [ax, ay, az, aw] = a;
    const [bx, by, bz, bw] = b;
    return [
      aw * bx + ax * bw + ay * bz - az * by,
      aw * by - ax * bz + ay * bw + az * bx,
      aw * bz + ax * by - ay * bx + az * bw,
      aw * bw - ax * bx - ay * by - az * bz,
    ];
  },

  conjugate(q: Quat): Quat {
    return [-q[0], -q[1], -q[2], q[3]];
  },

  normalize(q: Quat): Quat {
    const l = Math.hypot(q[0], q[1], q[2], q[3]);
    if (l < EPSILON) return [0, 0, 0, 1];
    return [q[0] / l, q[1] / l, q[2] / l, q[3] / l];
  },

  dot(a: Quat, b: Quat): number {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  },

  fromAxisAngle(axis: Vec3, radians: number): Quat {
    const n = v3.normalize(axis);
    const h = radians / 2;
    const s = Math.sin(h);
    return [n[0] * s, n[1] * s, n[2] * s, Math.cos(h)];
  },

  /** Rotate a vector by a unit quaternion. */
  rotate(q: Quat, p: Vec3): Vec3 {
    // t = 2 * (qv x p);  p' = p + qw*t + qv x t
    const [x, y, z, w] = q;
    const tx = 2 * (y * p[2] - z * p[1]);
    const ty = 2 * (z * p[0] - x * p[2]);
    const tz = 2 * (x * p[1] - y * p[0]);
    return [
      p[0] + w * tx + (y * tz - z * ty),
      p[1] + w * ty + (z * tx - x * tz),
      p[2] + w * tz + (x * ty - y * tx),
    ];
  },

  /** Shortest-arc spherical interpolation. */
  slerp(a: Quat, b: Quat, t: number): Quat {
    let cos = quat.dot(a, b);
    let end: Quat = b;
    if (cos < 0) {
      cos = -cos;
      end = [-b[0], -b[1], -b[2], -b[3]];
    }
    if (cos > 0.9995) {
      return quat.normalize([
        a[0] + (end[0] - a[0]) * t,
        a[1] + (end[1] - a[1]) * t,
        a[2] + (end[2] - a[2]) * t,
        a[3] + (end[3] - a[3]) * t,
      ]);
    }
    const theta = Math.acos(cos);
    const sin = Math.sin(theta);
    const wa = Math.sin((1 - t) * theta) / sin;
    const wb = Math.sin(t * theta) / sin;
    return [
      a[0] * wa + end[0] * wb,
      a[1] * wa + end[1] * wb,
      a[2] * wa + end[2] * wb,
      a[3] * wa + end[3] * wb,
    ];
  },

  /**
   * Extract a unit quaternion from a rotation matrix.
   * Shepperd's method: pick the largest diagonal case so the divisor is never small.
   */
  fromMat3(m: Mat3 | Float64Array): Quat {
    const m00 = m[0], m10 = m[1], m20 = m[2];
    const m01 = m[3], m11 = m[4], m21 = m[5];
    const m02 = m[6], m12 = m[7], m22 = m[8];
    const trace = m00 + m11 + m22;
    if (trace > 0) {
      const s = Math.sqrt(trace + 1) * 2;
      return [(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s];
    }
    if (m00 > m11 && m00 > m22) {
      const s = Math.sqrt(1 + m00 - m11 - m22) * 2;
      return [0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s];
    }
    if (m11 > m22) {
      const s = Math.sqrt(1 + m11 - m00 - m22) * 2;
      return [(m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s];
    }
    const s = Math.sqrt(1 + m22 - m00 - m11) * 2;
    return [(m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s];
  },

  toMat3(q: Quat): Mat3 {
    const [x, y, z, w] = quat.normalize(q);
    const x2 = x + x, y2 = y + y, z2 = z + z;
    const xx = x * x2, xy = x * y2, xz = x * z2;
    const yy = y * y2, yz = y * z2, zz = z * z2;
    const wx = w * x2, wy = w * y2, wz = w * z2;
    // column-major
    return new Float64Array([
      1 - (yy + zz), xy + wz, xz - wy,
      xy - wz, 1 - (xx + zz), yz + wx,
      xz + wy, yz - wx, 1 - (xx + yy),
    ]);
  },
} as const;

// ---------------------------------------------------------------------------
// Mat4 (column-major)
// ---------------------------------------------------------------------------

export const mat4 = {
  identity(): Mat4 {
    return new Float64Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
  },

  clone(m: Mat4): Mat4 {
    return new Float64Array(m);
  },

  /** a * b — apply `b` first, then `a`. */
  multiply(a: Mat4, b: Mat4): Mat4 {
    const out = new Float64Array(16);
    for (let c = 0; c < 4; c++) {
      const b0 = b[c * 4], b1 = b[c * 4 + 1], b2 = b[c * 4 + 2], b3 = b[c * 4 + 3];
      for (let r = 0; r < 4; r++) {
        out[c * 4 + r] =
          a[r] * b0 + a[4 + r] * b1 + a[8 + r] * b2 + a[12 + r] * b3;
      }
    }
    return out;
  },

  fromTranslation(t: Vec3): Mat4 {
    const m = mat4.identity();
    m[12] = t[0]; m[13] = t[1]; m[14] = t[2];
    return m;
  },

  fromScale(s: Vec3): Mat4 {
    const m = mat4.identity();
    m[0] = s[0]; m[5] = s[1]; m[10] = s[2];
    return m;
  },

  fromRotation(q: Quat): Mat4 {
    const r = quat.toMat3(q);
    return new Float64Array([
      r[0], r[1], r[2], 0,
      r[3], r[4], r[5], 0,
      r[6], r[7], r[8], 0,
      0, 0, 0, 1,
    ]);
  },

  /** Compose T * R * S, the glTF TRS order. */
  compose(translation: Vec3, rotation: Quat, scale: Vec3 = [1, 1, 1]): Mat4 {
    const r = quat.toMat3(rotation);
    return new Float64Array([
      r[0] * scale[0], r[1] * scale[0], r[2] * scale[0], 0,
      r[3] * scale[1], r[4] * scale[1], r[5] * scale[1], 0,
      r[6] * scale[2], r[7] * scale[2], r[8] * scale[2], 0,
      translation[0], translation[1], translation[2], 1,
    ]);
  },

  /** Split a TRS matrix back into its parts. Assumes no shear. */
  decompose(m: Mat4): { translation: Vec3; rotation: Quat; scale: Vec3 } {
    const translation: Vec3 = [m[12], m[13], m[14]];
    let sx = Math.hypot(m[0], m[1], m[2]);
    const sy = Math.hypot(m[4], m[5], m[6]);
    const sz = Math.hypot(m[8], m[9], m[10]);
    // A negative determinant means one axis is mirrored; put the flip on X by convention.
    if (mat4.determinant(m) < 0) sx = -sx;
    const inv = (s: number) => (Math.abs(s) < EPSILON ? 0 : 1 / s);
    const ix = inv(sx), iy = inv(sy), iz = inv(sz);
    const r = new Float64Array([
      m[0] * ix, m[1] * ix, m[2] * ix,
      m[4] * iy, m[5] * iy, m[6] * iy,
      m[8] * iz, m[9] * iz, m[10] * iz,
    ]);
    return { translation, rotation: quat.normalize(quat.fromMat3(r)), scale: [sx, sy, sz] };
  },

  determinant(m: Mat4): number {
    const b0 = m[0] * m[5] - m[1] * m[4];
    const b1 = m[0] * m[6] - m[2] * m[4];
    const b2 = m[0] * m[7] - m[3] * m[4];
    const b3 = m[1] * m[6] - m[2] * m[5];
    const b4 = m[1] * m[7] - m[3] * m[5];
    const b5 = m[2] * m[7] - m[3] * m[6];
    const b6 = m[8] * m[13] - m[9] * m[12];
    const b7 = m[8] * m[14] - m[10] * m[12];
    const b8 = m[8] * m[15] - m[11] * m[12];
    const b9 = m[9] * m[14] - m[10] * m[13];
    const b10 = m[9] * m[15] - m[11] * m[13];
    const b11 = m[10] * m[15] - m[11] * m[14];
    return b0 * b11 - b1 * b10 + b2 * b9 + b3 * b8 - b4 * b7 + b5 * b6;
  },

  invert(m: Mat4): Mat4 | null {
    const a00 = m[0], a01 = m[1], a02 = m[2], a03 = m[3];
    const a10 = m[4], a11 = m[5], a12 = m[6], a13 = m[7];
    const a20 = m[8], a21 = m[9], a22 = m[10], a23 = m[11];
    const a30 = m[12], a31 = m[13], a32 = m[14], a33 = m[15];

    const b00 = a00 * a11 - a01 * a10;
    const b01 = a00 * a12 - a02 * a10;
    const b02 = a00 * a13 - a03 * a10;
    const b03 = a01 * a12 - a02 * a11;
    const b04 = a01 * a13 - a03 * a11;
    const b05 = a02 * a13 - a03 * a12;
    const b06 = a20 * a31 - a21 * a30;
    const b07 = a20 * a32 - a22 * a30;
    const b08 = a20 * a33 - a23 * a30;
    const b09 = a21 * a32 - a22 * a31;
    const b10 = a21 * a33 - a23 * a31;
    const b11 = a22 * a33 - a23 * a32;

    const det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    if (Math.abs(det) < 1e-300) return null;
    const d = 1 / det;

    return new Float64Array([
      (a11 * b11 - a12 * b10 + a13 * b09) * d,
      (a02 * b10 - a01 * b11 - a03 * b09) * d,
      (a31 * b05 - a32 * b04 + a33 * b03) * d,
      (a22 * b04 - a21 * b05 - a23 * b03) * d,
      (a12 * b08 - a10 * b11 - a13 * b07) * d,
      (a00 * b11 - a02 * b08 + a03 * b07) * d,
      (a32 * b02 - a30 * b05 - a33 * b01) * d,
      (a20 * b05 - a22 * b02 + a23 * b01) * d,
      (a10 * b10 - a11 * b08 + a13 * b06) * d,
      (a01 * b08 - a00 * b10 - a03 * b06) * d,
      (a30 * b04 - a31 * b02 + a33 * b00) * d,
      (a21 * b02 - a20 * b04 - a23 * b00) * d,
      (a11 * b07 - a10 * b09 - a12 * b06) * d,
      (a00 * b09 - a01 * b07 + a02 * b06) * d,
      (a31 * b01 - a30 * b03 - a32 * b00) * d,
      (a20 * b03 - a21 * b01 + a22 * b00) * d,
    ]);
  },

  /** Inverse of a rigid transform (rotation + translation only). Exact and cheap. */
  invertRigid(m: Mat4): Mat4 {
    const out = new Float64Array(16);
    // transpose the rotation block
    out[0] = m[0]; out[1] = m[4]; out[2] = m[8];
    out[4] = m[1]; out[5] = m[5]; out[6] = m[9];
    out[8] = m[2]; out[9] = m[6]; out[10] = m[10];
    // -Rᵀ t
    out[12] = -(m[0] * m[12] + m[1] * m[13] + m[2] * m[14]);
    out[13] = -(m[4] * m[12] + m[5] * m[13] + m[6] * m[14]);
    out[14] = -(m[8] * m[12] + m[9] * m[13] + m[10] * m[14]);
    out[15] = 1;
    return out;
  },

  transformPoint(m: Mat4, p: Vec3): Vec3 {
    const x = p[0], y = p[1], z = p[2];
    const w = m[3] * x + m[7] * y + m[11] * z + m[15];
    const iw = Math.abs(w) < EPSILON ? 1 : 1 / w;
    return [
      (m[0] * x + m[4] * y + m[8] * z + m[12]) * iw,
      (m[1] * x + m[5] * y + m[9] * z + m[13]) * iw,
      (m[2] * x + m[6] * y + m[10] * z + m[14]) * iw,
    ];
  },

  /** Transform a direction — ignores translation. */
  transformDirection(m: Mat4, d: Vec3): Vec3 {
    const x = d[0], y = d[1], z = d[2];
    return [
      m[0] * x + m[4] * y + m[8] * z,
      m[1] * x + m[5] * y + m[9] * z,
      m[2] * x + m[6] * y + m[10] * z,
    ];
  },

  transpose(m: Mat4): Mat4 {
    return new Float64Array([
      m[0], m[4], m[8], m[12],
      m[1], m[5], m[9], m[13],
      m[2], m[6], m[10], m[14],
      m[3], m[7], m[11], m[15],
    ]);
  },

  /** Right-handed perspective with a reversed-Z-friendly finite far plane. */
  perspective(fovYRadians: number, aspect: number, near: number, far: number): Mat4 {
    const f = 1 / Math.tan(fovYRadians / 2);
    const nf = 1 / (near - far);
    return new Float64Array([
      f / aspect, 0, 0, 0,
      0, f, 0, 0,
      0, 0, (far + near) * nf, -1,
      0, 0, 2 * far * near * nf, 0,
    ]);
  },

  lookAt(eye: Vec3, target: Vec3, up: Vec3 = [0, 1, 0]): Mat4 {
    const z = v3.normalize(v3.sub(eye, target));
    let x = v3.cross(up, z);
    if (v3.lengthSq(x) < 1e-12) {
      // up is parallel to the view direction — pick any perpendicular axis
      x = v3.cross(Math.abs(z[1]) < 0.9 ? [0, 1, 0] : [1, 0, 0], z);
    }
    x = v3.normalize(x);
    const y = v3.cross(z, x);
    return new Float64Array([
      x[0], y[0], z[0], 0,
      x[1], y[1], z[1], 0,
      x[2], y[2], z[2], 0,
      -v3.dot(x, eye), -v3.dot(y, eye), -v3.dot(z, eye), 1,
    ]);
  },
} as const;

// ---------------------------------------------------------------------------
// Axis-aligned bounds
// ---------------------------------------------------------------------------

export interface Bounds {
  min: Vec3;
  max: Vec3;
}

export const bounds = {
  empty(): Bounds {
    return {
      min: [Infinity, Infinity, Infinity],
      max: [-Infinity, -Infinity, -Infinity],
    };
  },

  isEmpty(b: Bounds): boolean {
    return b.min[0] > b.max[0] || b.min[1] > b.max[1] || b.min[2] > b.max[2];
  },

  expand(b: Bounds, p: Vec3): Bounds {
    for (let i = 0; i < 3; i++) {
      if (p[i] < b.min[i]) b.min[i] = p[i];
      if (p[i] > b.max[i]) b.max[i] = p[i];
    }
    return b;
  },

  /** Accumulate an interleaved XYZ position array. */
  fromPositions(xyz: ArrayLike<number>, stride = 3): Bounds {
    const b = bounds.empty();
    for (let i = 0; i + 2 < xyz.length; i += stride) {
      if (xyz[i] < b.min[0]) b.min[0] = xyz[i];
      if (xyz[i] > b.max[0]) b.max[0] = xyz[i];
      if (xyz[i + 1] < b.min[1]) b.min[1] = xyz[i + 1];
      if (xyz[i + 1] > b.max[1]) b.max[1] = xyz[i + 1];
      if (xyz[i + 2] < b.min[2]) b.min[2] = xyz[i + 2];
      if (xyz[i + 2] > b.max[2]) b.max[2] = xyz[i + 2];
    }
    return b;
  },

  center(b: Bounds): Vec3 {
    return [
      (b.min[0] + b.max[0]) / 2,
      (b.min[1] + b.max[1]) / 2,
      (b.min[2] + b.max[2]) / 2,
    ];
  },

  size(b: Bounds): Vec3 {
    return [b.max[0] - b.min[0], b.max[1] - b.min[1], b.max[2] - b.min[2]];
  },

  /** Grow to a cube about the centre — an octree root must be cubic. */
  cubify(b: Bounds): Bounds {
    const c = bounds.center(b);
    const s = bounds.size(b);
    const h = Math.max(s[0], s[1], s[2]) / 2;
    return {
      min: [c[0] - h, c[1] - h, c[2] - h],
      max: [c[0] + h, c[1] + h, c[2] + h],
    };
  },

  contains(b: Bounds, p: Vec3): boolean {
    return (
      p[0] >= b.min[0] && p[0] <= b.max[0] &&
      p[1] >= b.min[1] && p[1] <= b.max[1] &&
      p[2] >= b.min[2] && p[2] <= b.max[2]
    );
  },
} as const;

export function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

export function degToRad(d: number): number {
  return (d * Math.PI) / 180;
}

export function radToDeg(r: number): number {
  return (r * 180) / Math.PI;
}
