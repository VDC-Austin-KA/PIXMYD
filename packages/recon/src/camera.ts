/**
 * Camera models: projecting a 3D point to a pixel, and casting a pixel back
 * out as a ray.
 *
 * Three models, because the hardware this toolchain targets genuinely needs all
 * three and they do not reduce to each other:
 *
 *   pinhole    phones, drones, machine vision — with Brown-Conrady distortion
 *   fisheye    action cameras, and each lens of a 360 rig before stitching
 *   equirect   a stitched 360 panorama, where every pixel is a direction and
 *              there is no focal length at all
 *
 * Camera axes are the computer-vision convention: +X right, +Y down, +Z forward
 * along the optical axis. A point is in front of the camera when z > 0.
 */

import { quat, v3, type Vec3 } from '@pixmyd/core/math';
import type {
  CameraModel,
  EquirectCamera,
  FisheyeCamera,
  PinholeCamera,
  Pose,
} from '@pixmyd/core/bundle';

export interface Pixel {
  x: number;
  y: number;
}

export interface ProjectionResult extends Pixel {
  /** Depth along the optical axis, metres. Negative means behind the camera. */
  depth: number;
  /** False when the point is behind the camera or outside the image. */
  visible: boolean;
}

// ---------------------------------------------------------------------------
// Distortion
// ---------------------------------------------------------------------------

/**
 * Brown-Conrady forward distortion, on normalized image coordinates.
 * Matches OpenCV's `projectPoints` and COLMAP's OPENCV model exactly, so a
 * calibration from either transfers without reinterpretation.
 */
function distortBrownConrady(x: number, y: number, c: PinholeCamera): [number, number] {
  const k1 = c.k1 ?? 0, k2 = c.k2 ?? 0, k3 = c.k3 ?? 0;
  const p1 = c.p1 ?? 0, p2 = c.p2 ?? 0;
  if (k1 === 0 && k2 === 0 && k3 === 0 && p1 === 0 && p2 === 0) return [x, y];

  const r2 = x * x + y * y;
  const radial = 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2;
  const dx = 2 * p1 * x * y + p2 * (r2 + 2 * x * x);
  const dy = p1 * (r2 + 2 * y * y) + 2 * p2 * x * y;
  return [x * radial + dx, y * radial + dy];
}

/**
 * Undistort by fixed-point iteration.
 *
 * Brown-Conrady has no closed-form inverse. Iterating x_{n+1} = (x_d - tangential)/radial
 * converges in a handful of passes for any sane lens; it diverges only for
 * distortion so extreme that the mapping is not injective, which is a broken
 * calibration rather than a real camera.
 */
function undistortBrownConrady(
  xd: number,
  yd: number,
  c: PinholeCamera,
  iterations = 20,
): [number, number] {
  const k1 = c.k1 ?? 0, k2 = c.k2 ?? 0, k3 = c.k3 ?? 0;
  const p1 = c.p1 ?? 0, p2 = c.p2 ?? 0;
  if (k1 === 0 && k2 === 0 && k3 === 0 && p1 === 0 && p2 === 0) return [xd, yd];

  let x = xd;
  let y = yd;
  for (let i = 0; i < iterations; i++) {
    const r2 = x * x + y * y;
    const radial = 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2;
    const dx = 2 * p1 * x * y + p2 * (r2 + 2 * x * x);
    const dy = p1 * (r2 + 2 * y * y) + 2 * p2 * x * y;
    const nx = (xd - dx) / radial;
    const ny = (yd - dy) / radial;
    if (Math.abs(nx - x) < 1e-12 && Math.abs(ny - y) < 1e-12) {
      return [nx, ny];
    }
    x = nx;
    y = ny;
  }
  return [x, y];
}

// ---------------------------------------------------------------------------
// Projection
// ---------------------------------------------------------------------------

function projectPinhole(p: Vec3, c: PinholeCamera): ProjectionResult {
  const z = p[2];
  if (z <= 1e-9) {
    return { x: NaN, y: NaN, depth: z, visible: false };
  }
  const [xd, yd] = distortBrownConrady(p[0] / z, p[1] / z, c);
  const x = c.fx * xd + c.cx;
  const y = c.fy * yd + c.cy;
  return {
    x, y, depth: z,
    visible: x >= 0 && x < c.width && y >= 0 && y < c.height,
  };
}

function projectFisheye(p: Vec3, c: FisheyeCamera): ProjectionResult {
  const [X, Y, Z] = p;
  const r = Math.hypot(X, Y);
  // theta is the angle from the optical axis. An equidistant fisheye maps it
  // linearly to image radius, which is why it can see past 180 degrees where a
  // pinhole cannot represent anything at all.
  const theta = Math.atan2(r, Z);
  const t2 = theta * theta;
  const k1 = c.k1 ?? 0, k2 = c.k2 ?? 0, k3 = c.k3 ?? 0, k4 = c.k4 ?? 0;
  const thetaD =
    theta * (1 + k1 * t2 + k2 * t2 * t2 + k3 * t2 * t2 * t2 + k4 * t2 * t2 * t2 * t2);

  // On the optical axis r is zero and the scale is the limit thetaD/r -> 1/Z.
  const scale = r > 1e-12 ? thetaD / r : 0;
  const x = c.fx * X * scale + c.cx;
  const y = c.fy * Y * scale + c.cy;
  return {
    x, y,
    // Range, not axial depth — a fisheye sees past 90 deg, where z is negative
    // and axial depth is meaningless. Matches what unprojectPixel expects.
    depth: Math.hypot(X, Y, Z),
    // A fisheye lens genuinely images beyond the hemisphere, so visibility is
    // decided by the frame, not by an artificial 90 deg cutoff.
    visible: x >= 0 && x < c.width && y >= 0 && y < c.height,
  };
}

function projectEquirect(p: Vec3, c: EquirectCamera): ProjectionResult {
  const length = v3.length(p);
  if (length < 1e-12) return { x: NaN, y: NaN, depth: 0, visible: false };
  const [X, Y, Z] = p;
  // Longitude measured from +Z (forward), increasing toward +X (right).
  const lon = Math.atan2(X, Z);
  // Latitude from the horizon; +Y is down in camera axes, so negate.
  const lat = Math.asin(-Y / length);

  const hfov = c.hfov ?? 2 * Math.PI;
  const vfov = c.vfov ?? Math.PI;
  const x = (lon / hfov + 0.5) * c.width;
  const y = (0.5 - lat / vfov) * c.height;

  return {
    x, y,
    // For a panorama "depth" is range, not axial distance — there is no axis.
    depth: length,
    visible: x >= 0 && x < c.width && y >= 0 && y < c.height,
  };
}

export function projectPoint(p: Vec3, camera: CameraModel): ProjectionResult {
  switch (camera.model) {
    case 'pinhole': return projectPinhole(p, camera);
    case 'fisheye': return projectFisheye(p, camera);
    case 'equirect': return projectEquirect(p, camera);
  }
}

// ---------------------------------------------------------------------------
// Unprojection
// ---------------------------------------------------------------------------

/** Unit ray through a pixel, in camera axes. */
export function pixelToRay(pixel: Pixel, camera: CameraModel): Vec3 {
  switch (camera.model) {
    case 'pinhole': {
      const [x, y] = undistortBrownConrady(
        (pixel.x - camera.cx) / camera.fx,
        (pixel.y - camera.cy) / camera.fy,
        camera,
      );
      return v3.normalize([x, y, 1]);
    }
    case 'fisheye': {
      const x = (pixel.x - camera.cx) / camera.fx;
      const y = (pixel.y - camera.cy) / camera.fy;
      const thetaD = Math.hypot(x, y);
      if (thetaD < 1e-12) return [0, 0, 1];
      // Invert the theta polynomial by fixed-point iteration.
      let theta = thetaD;
      const k1 = camera.k1 ?? 0, k2 = camera.k2 ?? 0;
      const k3 = camera.k3 ?? 0, k4 = camera.k4 ?? 0;
      for (let i = 0; i < 20; i++) {
        const t2 = theta * theta;
        const f =
          theta * (1 + k1 * t2 + k2 * t2 * t2 + k3 * t2 * t2 * t2 + k4 * t2 * t2 * t2 * t2);
        const df =
          1 + 3 * k1 * t2 + 5 * k2 * t2 * t2 + 7 * k3 * t2 * t2 * t2 + 9 * k4 * t2 * t2 * t2 * t2;
        const step = (f - thetaD) / df;
        theta -= step;
        if (Math.abs(step) < 1e-14) break;
      }
      const sinTheta = Math.sin(theta);
      return [(x / thetaD) * sinTheta, (y / thetaD) * sinTheta, Math.cos(theta)];
    }
    case 'equirect': {
      const hfov = camera.hfov ?? 2 * Math.PI;
      const vfov = camera.vfov ?? Math.PI;
      const lon = (pixel.x / camera.width - 0.5) * hfov;
      const lat = (0.5 - pixel.y / camera.height) * vfov;
      const cosLat = Math.cos(lat);
      return [cosLat * Math.sin(lon), -Math.sin(lat), cosLat * Math.cos(lon)];
    }
  }
}

/**
 * A pixel and its depth back to a 3D point in camera axes.
 *
 * What `depth` means is per-model, and the difference is not cosmetic:
 *
 * **pinhole** — depth along the optical axis (the z coordinate). This is what a
 * depth sensor reports, and it is *not* the distance to the point: a pixel in
 * the corner of the frame at "2 m depth" is further than 2 m away. Treating one
 * as the other pulls the edges of every frame toward the camera.
 *
 * **fisheye and equirect** — range, the distance along the ray. Axial depth is
 * not merely inconvenient for these, it is undefined: both can see past 90 deg
 * from the optical axis, where z is zero and then negative, so depth/z blows up
 * and then flips the point to the opposite side of the camera.
 */
export function unprojectPixel(pixel: Pixel, depth: number, camera: CameraModel): Vec3 {
  const ray = pixelToRay(pixel, camera);
  if (camera.model !== 'pinhole') return v3.scale(ray, depth);
  // ray is a unit vector, so scaling by depth/ray.z converts range to axial depth.
  const z = ray[2];
  if (Math.abs(z) < 1e-12) return v3.scale(ray, depth);
  return v3.scale(ray, depth / z);
}

/**
 * The depth value `unprojectPixel` expects for a point already in camera axes —
 * axial for pinhole, range otherwise. Use this rather than reaching for
 * `ProjectionResult.depth`, which reports the same quantity but is easy to
 * misapply when the model is not known at the call site.
 */
export function depthForModel(cameraSpacePoint: Vec3, camera: CameraModel): number {
  return camera.model === 'pinhole' ? cameraSpacePoint[2] : v3.length(cameraSpacePoint);
}

// ---------------------------------------------------------------------------
// World-space helpers
// ---------------------------------------------------------------------------

/** World point to camera axes. */
export function worldToCamera(world: Vec3, pose: Pose): Vec3 {
  return quat.rotate(quat.conjugate(pose.q), v3.sub(world, pose.t));
}

/** Camera-axes point to world. */
export function cameraToWorld(local: Vec3, pose: Pose): Vec3 {
  return v3.add(quat.rotate(pose.q, local), pose.t);
}

export function projectWorldPoint(
  world: Vec3,
  pose: Pose,
  camera: CameraModel,
): ProjectionResult {
  return projectPoint(worldToCamera(world, pose), camera);
}

/** Pixel + depth to a world point. */
export function unprojectToWorld(
  pixel: Pixel,
  depth: number,
  pose: Pose,
  camera: CameraModel,
): Vec3 {
  return cameraToWorld(unprojectPixel(pixel, depth, camera), pose);
}

// ---------------------------------------------------------------------------
// Field of view
// ---------------------------------------------------------------------------

/** Horizontal and vertical field of view in radians. */
export function fieldOfView(camera: CameraModel): { horizontal: number; vertical: number } {
  switch (camera.model) {
    case 'pinhole':
      return {
        horizontal: 2 * Math.atan(camera.width / (2 * camera.fx)),
        vertical: 2 * Math.atan(camera.height / (2 * camera.fy)),
      };
    case 'fisheye':
      // Equidistant: image radius is proportional to angle, so the half-FOV is
      // the half-width in normalized units directly.
      return {
        horizontal: 2 * (camera.width / (2 * camera.fx)),
        vertical: 2 * (camera.height / (2 * camera.fy)),
      };
    case 'equirect':
      return {
        horizontal: camera.hfov ?? 2 * Math.PI,
        vertical: camera.vfov ?? Math.PI,
      };
  }
}

/**
 * Scale a camera to a different raster size.
 *
 * Depth maps arrive at a fraction of the colour resolution — ARKit gives
 * 256x192 against a 1920x1440 frame — and the intrinsics have to be scaled to
 * match or every reprojection is off by the ratio.
 */
export function resizeCamera(camera: CameraModel, width: number, height: number): CameraModel {
  const sx = width / camera.width;
  const sy = height / camera.height;
  switch (camera.model) {
    case 'pinhole':
      return {
        ...camera, width, height,
        fx: camera.fx * sx, fy: camera.fy * sy,
        // The principal point is a pixel *coordinate*, so it scales about the
        // corner with the same half-pixel convention as the raster itself.
        cx: (camera.cx + 0.5) * sx - 0.5,
        cy: (camera.cy + 0.5) * sy - 0.5,
      };
    case 'fisheye':
      return {
        ...camera, width, height,
        fx: camera.fx * sx, fy: camera.fy * sy,
        cx: (camera.cx + 0.5) * sx - 0.5,
        cy: (camera.cy + 0.5) * sy - 0.5,
      };
    case 'equirect':
      return { ...camera, width, height };
  }
}
