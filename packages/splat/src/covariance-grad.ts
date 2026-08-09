/**
 * Gradients through the covariance projection.
 *
 * This is the chain that makes 3DGS actually optimise geometry rather than just
 * colour. Every parameter that shapes a Gaussian — its position in depth, its
 * three scales, its rotation — reaches the loss only through the *projected 2D
 * covariance*, and the path is four matrix products deep:
 *
 *     rotation, log-scale  ->  Sigma3D = R S S' R'
 *     Sigma3D, depth       ->  Sigma2D = T Sigma3D T',   T = J W
 *     Sigma2D              ->  conic   = inverse(Sigma2D)
 *     conic                ->  alpha   = opacity * exp(-0.5 x' conic x)
 *
 * Leaving it out is a specific, plausible-looking failure. Position gradients
 * computed only through the projected *centre* are roughly right laterally and
 * badly wrong in depth, because depth mostly changes a Gaussian's apparent
 * size, not where its centre lands. A trainer built that way converges to a
 * scene with correct colours and mushy geometry, which looks like it worked.
 *
 * All matrices here are row-major.
 */

import { quat, type Quat, type Vec3 } from '@pixmyd/core/math';

export interface CovarianceGradientInput {
  /** dL/d(conic), for the three entries (a, b, c) of the symmetric inverse. */
  dConic: [number, number, number];
  /** dL/d(image-space centre), in pixels. */
  dMean: [number, number];
  /** The Gaussian's position in camera space. */
  cameraSpace: Vec3;
  /** 3D covariance, six upper-triangular entries (xx, xy, xz, yy, yz, zz). */
  covariance3D: number[];
  /** World-to-camera rotation, row-major. */
  worldToCamera: number[];
  /** Rotation quaternion, [x, y, z, w]. */
  rotation: Quat;
  /** Actual per-axis scale (already exponentiated). */
  scale: Vec3;
  fx: number;
  fy: number;
}

export interface CovarianceGradientOutput {
  /** dL/d(world position). */
  dPosition: Vec3;
  /** dL/d(log scale), per axis. */
  dLogScale: Vec3;
  /** dL/d(quaternion), [x, y, z, w]. */
  dRotation: [number, number, number, number];
}

/**
 * Propagate a conic and centre gradient back to position, scale and rotation.
 */
export function covarianceGradients(
  input: CovarianceGradientInput,
): CovarianceGradientOutput {
  const { cameraSpace, worldToCamera, fx, fy } = input;
  const [x, y, z] = cameraSpace;
  const invZ = 1 / z;
  const invZ2 = invZ * invZ;
  const invZ3 = invZ2 * invZ;

  // --- conic -> Sigma2D ---
  //
  // conic = M^-1 for the 2x2 symmetric M. dM = -M^-1 dConic M^-1, so
  // dL/dM = -conic (dL/dConic) conic, with everything symmetric.
  const [ca, cb, cc] = [input.dConic[0], input.dConic[1], input.dConic[2]];
  // Rebuild Sigma2D from the 3D covariance so the inverse is consistent.
  const [ta, tb, tc] = project2D(input, invZ, invZ2);
  const determinant = ta * tc - tb * tb;
  if (!(Math.abs(determinant) > 1e-20)) {
    return { dPosition: [0, 0, 0], dLogScale: [0, 0, 0], dRotation: [0, 0, 0, 0] };
  }
  const invDet = 1 / determinant;
  const conic = [tc * invDet, -tb * invDet, ta * invDet];

  // dL/dSigma2D = -C (dL/dC) C, expanded for the symmetric 2x2 case. The
  // off-diagonal appears twice in the quadratic form, hence the factor of two
  // handling on `cb`.
  const g = [ca, cb * 0.5, cb * 0.5, cc]; // dL/dConic as a full 2x2
  const C = [conic[0], conic[1], conic[1], conic[2]];
  const CG = mul2(C, g);
  const CGC = mul2(CG, C);
  const dSigma2D = [-CGC[0], -CGC[1], -CGC[2], -CGC[3]];

  // --- Sigma2D -> T and Sigma3D ---
  //
  // Sigma2D = T A T' with A = W Sigma3D W' and T = J W, so working directly in
  // terms of T avoids forming W Sigma W' twice.
  const [sxx, sxy, sxz, syy, syz, szz] = input.covariance3D;
  const Sigma3D = [sxx, sxy, sxz, sxy, syy, syz, sxz, syz, szz];

  const J = [
    fx * invZ, 0, -fx * x * invZ2,
    0, fy * invZ, -fy * y * invZ2,
  ];
  const T = mul23(J, worldToCamera); // 2x3

  // dL/dT = 2 (dL/dSigma2D) T Sigma3D.
  //
  // Sigma3D, not W Sigma3D W'. Those are the two ways to factor the projection —
  // Sigma2D = T Sigma3D T' with T = J W, or Sigma2D = J A J' with A = W Sigma3D W'
  // — and each has its own derivative. Taking T from one and the inner matrix
  // from the other yields a gradient that is right in the lateral directions
  // and wrong in depth, because W only fails to commute where the view
  // direction is involved.
  const dT = new Array(6).fill(0);
  const TS3 = mul23by33(T, Sigma3D);
  for (let r = 0; r < 2; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 2; k++) sum += dSigma2D[r * 2 + k] * TS3[k * 3 + c];
      dT[r * 3 + c] = 2 * sum;
    }
  }

  // dL/dSigma3D = W' T' (dL/dSigma2D) T W
  const dSigma3D = new Array(9).fill(0);
  {
    // TW = T (already J W), so Sigma2D = TW Sigma3D TW'.
    const M = T; // 2x3
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        let sum = 0;
        for (let i = 0; i < 2; i++) {
          for (let j = 0; j < 2; j++) {
            sum += M[i * 3 + r] * dSigma2D[i * 2 + j] * M[j * 3 + c];
          }
        }
        dSigma3D[r * 3 + c] = sum;
      }
    }
  }

  // --- T -> J -> camera-space position ---
  //
  // T = J W, so dL/dJ = dL/dT W'.
  const dJ = new Array(6).fill(0);
  for (let r = 0; r < 2; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += dT[r * 3 + k] * worldToCamera[c * 3 + k];
      dJ[r * 3 + c] = sum;
    }
  }

  // J's dependence on the camera-space position. Only three entries vary.
  //   dJ/dx: J[0][2] = -fx/z^2
  //   dJ/dy: J[1][2] = -fy/z^2
  //   dJ/dz: J[0][0] = -fx/z^2, J[1][1] = -fy/z^2,
  //          J[0][2] = 2 fx x/z^3, J[1][2] = 2 fy y/z^3
  const dCameraFromCovariance: Vec3 = [
    dJ[2] * (-fx * invZ2),
    dJ[5] * (-fy * invZ2),
    dJ[0] * (-fx * invZ2) +
      dJ[4] * (-fy * invZ2) +
      dJ[2] * (2 * fx * x * invZ3) +
      dJ[5] * (2 * fy * y * invZ3),
  ];

  // The projected centre also depends on the camera-space position.
  const dCameraFromMean: Vec3 = [
    input.dMean[0] * fx * invZ,
    input.dMean[1] * fy * invZ,
    input.dMean[0] * (-fx * x * invZ2) + input.dMean[1] * (-fy * y * invZ2),
  ];

  const dCamera: Vec3 = [
    dCameraFromCovariance[0] + dCameraFromMean[0],
    dCameraFromCovariance[1] + dCameraFromMean[1],
    dCameraFromCovariance[2] + dCameraFromMean[2],
  ];

  // Camera space to world: the position enters through W (X - C), so the
  // gradient transposes back through W.
  const dPosition: Vec3 = [
    worldToCamera[0] * dCamera[0] + worldToCamera[3] * dCamera[1] + worldToCamera[6] * dCamera[2],
    worldToCamera[1] * dCamera[0] + worldToCamera[4] * dCamera[1] + worldToCamera[7] * dCamera[2],
    worldToCamera[2] * dCamera[0] + worldToCamera[5] * dCamera[1] + worldToCamera[8] * dCamera[2],
  ];

  // --- Sigma3D -> scale and rotation ---
  //
  // Sigma3D = M M' with M = R S, so dL/dM = 2 (dL/dSigma3D) M.
  const R = quatToRowMajor(quat.normalize(input.rotation));
  const S = input.scale;
  const M = [
    R[0] * S[0], R[1] * S[1], R[2] * S[2],
    R[3] * S[0], R[4] * S[1], R[5] * S[2],
    R[6] * S[0], R[7] * S[1], R[8] * S[2],
  ];

  const dM = new Array(9).fill(0);
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += dSigma3D[r * 3 + k] * M[k * 3 + c];
      dM[r * 3 + c] = 2 * sum;
    }
  }

  // M = R S with S diagonal, so dL/ds_i is the i-th diagonal of R' dL/dM.
  const dScale: Vec3 = [0, 0, 0];
  for (let i = 0; i < 3; i++) {
    let sum = 0;
    for (let k = 0; k < 3; k++) sum += R[k * 3 + i] * dM[k * 3 + i];
    dScale[i] = sum;
  }
  // Stored as log scale, so multiply through by the scale itself.
  const dLogScale: Vec3 = [
    dScale[0] * S[0], dScale[1] * S[1], dScale[2] * S[2],
  ];

  // dL/dR = dL/dM S', with S diagonal.
  const dR = [
    dM[0] * S[0], dM[1] * S[1], dM[2] * S[2],
    dM[3] * S[0], dM[4] * S[1], dM[5] * S[2],
    dM[6] * S[0], dM[7] * S[1], dM[8] * S[2],
  ];
  const dRotation = rotationMatrixGradientToQuaternion(input.rotation, dR);

  return { dPosition, dLogScale, dRotation };
}

/** The projected 2D covariance, matching `covariance2D` in gaussian.ts. */
function project2D(
  input: CovarianceGradientInput,
  invZ: number,
  invZ2: number,
): [number, number, number] {
  const [x, y] = input.cameraSpace;
  const { fx, fy, worldToCamera } = input;
  const J = [
    fx * invZ, 0, -fx * x * invZ2,
    0, fy * invZ, -fy * y * invZ2,
  ];
  const T = mul23(J, worldToCamera);
  const [sxx, sxy, sxz, syy, syz, szz] = input.covariance3D;
  const S = [sxx, sxy, sxz, sxy, syy, syz, sxz, syz, szz];

  const TS = mul23by33(T, S);
  let a = 0, b = 0, c = 0;
  for (let k = 0; k < 3; k++) {
    a += TS[k] * T[k];
    b += TS[k] * T[3 + k];
    c += TS[3 + k] * T[3 + k];
  }
  // The same dilation the forward pass applies.
  return [a + 0.3, b, c + 0.3];
}

function mul2(a: number[], b: number[]): number[] {
  return [
    a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
    a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
  ];
}

/** 2x3 times 3x3. */
function mul23(a: number[], b: number[]): number[] {
  const out = new Array(6).fill(0);
  for (let r = 0; r < 2; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += a[r * 3 + k] * b[k * 3 + c];
      out[r * 3 + c] = sum;
    }
  }
  return out;
}

const mul23by33 = mul23;

function mul33(a: number[], b: number[]): number[] {
  const out = new Array(9).fill(0);
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += a[r * 3 + k] * b[k * 3 + c];
      out[r * 3 + c] = sum;
    }
  }
  return out;
}

/** a times b transposed, both 3x3. */
function mul33t(a: number[], b: number[]): number[] {
  const out = new Array(9).fill(0);
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = 0; k < 3; k++) sum += a[r * 3 + k] * b[c * 3 + k];
      out[r * 3 + c] = sum;
    }
  }
  return out;
}

export function quatToRowMajor(q: Quat): number[] {
  const m = quat.toMat3(q); // column-major
  return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
}

/**
 * Push a rotation-matrix gradient back onto the quaternion.
 *
 * Derived by differentiating the standard quaternion-to-matrix formula entry by
 * entry. Written out rather than looped because the terms do not share a
 * pattern worth abstracting, and an error in any one of them is a rotation that
 * drifts in a single axis — which reads as motion blur, not as a bug.
 */
function rotationMatrixGradientToQuaternion(
  q: Quat,
  dR: number[],
): [number, number, number, number] {
  const [x, y, z, w] = quat.normalize(q);

  // R, row-major, in terms of the quaternion:
  //   R0 = 1 - 2(y^2 + z^2)   R1 = 2(xy - wz)         R2 = 2(xz + wy)
  //   R3 = 2(xy + wz)         R4 = 1 - 2(x^2 + z^2)   R5 = 2(yz - wx)
  //   R6 = 2(xz - wy)         R7 = 2(yz + wx)         R8 = 1 - 2(x^2 + y^2)
  //
  // Each partial below is those nine expressions differentiated with respect to
  // one component. Written out rather than looped: the terms share no pattern
  // worth abstracting, and a mistake in any one of them is a rotation that
  // drifts along a single axis, which reads as motion blur rather than as a bug.
  const dx =
    2 * y * dR[1] + 2 * z * dR[2] + 2 * y * dR[3] - 4 * x * dR[4] -
    2 * w * dR[5] + 2 * z * dR[6] + 2 * w * dR[7] - 4 * x * dR[8];

  const dy =
    -4 * y * dR[0] + 2 * x * dR[1] + 2 * w * dR[2] + 2 * x * dR[3] +
    2 * z * dR[5] - 2 * w * dR[6] + 2 * z * dR[7] - 4 * y * dR[8];

  const dz =
    -4 * z * dR[0] - 2 * w * dR[1] + 2 * x * dR[2] + 2 * w * dR[3] -
    4 * z * dR[4] + 2 * y * dR[5] + 2 * x * dR[6] + 2 * y * dR[7];

  const dw =
    -2 * z * dR[1] + 2 * y * dR[2] + 2 * z * dR[3] -
    2 * x * dR[5] - 2 * y * dR[6] + 2 * x * dR[7];

  // Push back through the normalisation.
  //
  // The rotation matrix is built from the *normalised* quaternion, so
  // perturbing one stored component changes all four normalised ones. The
  // Jacobian of q/|q| is (I - qhat qhat') / |q|, which projects out the radial
  // direction — a change purely along q rescales it and leaves the rotation
  // untouched, so it must contribute no gradient. Omitting this leaves the
  // rotation gradient about 15% wrong and pointing slightly off-axis, which
  // shows up as Gaussians that never quite settle onto surfaces.
  const length = Math.hypot(q[0], q[1], q[2], q[3]) || 1;
  const raw = [dx, dy, dz, dw];
  const qhat = [x, y, z, w];
  const radial = qhat[0] * raw[0] + qhat[1] * raw[1] + qhat[2] * raw[2] + qhat[3] * raw[3];

  return [
    (raw[0] - qhat[0] * radial) / length,
    (raw[1] - qhat[1] * radial) / length,
    (raw[2] - qhat[2] * radial) / length,
    (raw[3] - qhat[3] * radial) / length,
  ];
}
