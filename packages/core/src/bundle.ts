/**
 * The capture bundle: the one data model every source normalizes into.
 *
 * An iPhone with LiDAR, a Quest 3 passthrough session, a drone's image folder, and
 * an Insta360 X3 .insv all produce different things. They all land here. Everything
 * downstream — SfM, splat training, meshing, export — reads this and only this, which
 * is what stops the pipeline growing a special case per device.
 *
 * On disk a bundle is a directory (or a zip of one):
 *
 *   manifest.json      session, rig, CRS, provenance
 *   frames.jsonl       one JSON object per line, one line per frame
 *   imu.jsonl          raw inertial samples, typically 100-800 Hz
 *   gnss.jsonl         GNSS/RTK fixes with their reported accuracy
 *   control.json       surveyed control points, if any
 *   images/<id>.jpg    colour frames
 *   depth/<id>.bin     depth maps, uint16 millimetres, row-major
 *   conf/<id>.bin      per-pixel depth confidence, uint8
 *
 * JSONL rather than one big array because a capture is appended to in real time and
 * may be interrupted — a truncated last line costs one frame, not the session.
 */

import { mat4 } from './math.ts';
import type { Mat4, Quat, Vec3 } from './math.ts';

export const BUNDLE_FORMAT_VERSION = 1;

// ---------------------------------------------------------------------------
// Camera models
// ---------------------------------------------------------------------------

/**
 * Pinhole with Brown-Conrady distortion. The workhorse: phone cameras, drone
 * cameras, machine vision. Matches COLMAP's OPENCV model and OpenCV's own
 * `cv::calibrateCamera` output, so calibrations transfer without reinterpretation.
 */
export interface PinholeCamera {
  model: 'pinhole';
  width: number;
  height: number;
  /** Focal length in pixels. */
  fx: number;
  fy: number;
  /** Principal point in pixels, origin at the top-left corner of the top-left pixel. */
  cx: number;
  cy: number;
  /** Radial distortion k1, k2, k3. Zero when the source has already undistorted. */
  k1?: number;
  k2?: number;
  k3?: number;
  /** Tangential distortion p1, p2. */
  p1?: number;
  p2?: number;
}

/**
 * Equidistant fisheye (COLMAP OPENCV_FISHEYE / OpenCV `cv::fisheye`).
 * A GoPro, an action cam, or one lens of a 360 rig before stitching.
 */
export interface FisheyeCamera {
  model: 'fisheye';
  width: number;
  height: number;
  fx: number;
  fy: number;
  cx: number;
  cy: number;
  k1?: number;
  k2?: number;
  k3?: number;
  k4?: number;
}

/**
 * Full equirectangular panorama: longitude spans the image width over 2pi,
 * latitude spans the height over pi. This is what an Insta360 X3 or a Ricoh Theta
 * produces after stitching, and it has no focal length — every pixel is a direction.
 */
export interface EquirectCamera {
  model: 'equirect';
  width: number;
  height: number;
  /** Horizontal field of view in radians. 2pi for a full sphere. */
  hfov?: number;
  /** Vertical field of view in radians. pi for a full sphere. */
  vfov?: number;
}

export type CameraModel = PinholeCamera | FisheyeCamera | EquirectCamera;

// ---------------------------------------------------------------------------
// Poses
// ---------------------------------------------------------------------------

/**
 * A rigid pose as camera-to-world: translation is the camera centre in world
 * coordinates, rotation takes camera axes to world axes.
 *
 * Camera axes follow the computer-vision convention — +X right, +Y down,
 * +Z forward along the optical axis — because that is what PnP, COLMAP, and every
 * projection equation in this repo assume. ARKit hands back a +Y-up, -Z-forward
 * matrix; the iOS bridge converts once, on the way in, and nothing downstream
 * has to know.
 */
export interface Pose {
  /** Camera centre in world metres. */
  t: Vec3;
  /** Camera-to-world rotation, [x, y, z, w]. */
  q: Quat;
}

/** How a pose was arrived at. Drives how much the solver is allowed to move it. */
export type PoseSource =
  /** Device VIO/SLAM (ARKit, ARCore, WebXR). Locally excellent, drifts globally. */
  | 'vio'
  /** Structure-from-motion solved by this toolchain. */
  | 'sfm'
  /** Read from file metadata — EXIF GPS + gimbal yaw/pitch/roll on a drone. */
  | 'metadata'
  /** Solved against surveyed control. Treated as fixed. */
  | 'control'
  /** No pose yet. */
  | 'none';

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

export interface DepthMap {
  /** Path relative to the bundle root. */
  uri: string;
  width: number;
  height: number;
  /** `uint16` millimetres is the compact default; `float32` metres for imported data. */
  encoding: 'uint16-mm' | 'float32-m';
  /** Per-pixel confidence map, uint8. ARKit gives 0=low, 1=medium, 2=high. */
  confidenceUri?: string;
  /**
   * Depth is usually captured at a lower resolution than colour (ARKit gives
   * 256x192 against a 1920x1440 frame). This is the camera model for the depth
   * raster itself; omit it when depth is already registered to the colour frame.
   */
  camera?: CameraModel;
  /** Sensor floor and ceiling in metres. Samples outside are not measurements. */
  minRange?: number;
  maxRange?: number;
}

export interface Frame {
  /** Stable within a bundle. Also the basename of the image and depth files. */
  id: string;
  /** Seconds since the session epoch in `CaptureManifest.startedAt`. */
  t: number;
  /** Path to the colour image, relative to the bundle root. */
  imageUri: string;
  /** Index into `CaptureManifest.cameras`. */
  camera: number;
  pose?: Pose;
  poseSource: PoseSource;
  /**
   * Solver weight in [0, 1]. VIO poses from a well-tracked segment get 1;
   * a frame captured during ARKit's `limited` tracking state gets less.
   */
  poseWeight?: number;
  depth?: DepthMap;
  /** Exposure in seconds and ISO, for photometric consistency checks. */
  exposure?: number;
  iso?: number;
  /** Estimated motion blur extent in pixels. Blurry frames are poor SfM anchors. */
  blur?: number;
  /** The GNSS fix nearest this frame in time, already interpolated. */
  gnss?: GnssFix;
  /** Free-form, for source-specific data worth keeping but not worth modelling. */
  meta?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// GNSS
// ---------------------------------------------------------------------------

/**
 * RTK fix quality, following the NMEA GGA quality indicator. The distinction that
 * matters operationally is 4 vs everything else: only an integer-ambiguity fix is
 * centimetre work. A float solution looks fine on screen and is decimetres out.
 */
export const FixQuality = {
  Invalid: 0,
  SinglePoint: 1,
  DGPS: 2,
  PPS: 3,
  RtkFixed: 4,
  RtkFloat: 5,
  DeadReckoning: 6,
  Manual: 7,
  Simulation: 8,
} as const;

export type FixQuality = (typeof FixQuality)[keyof typeof FixQuality];

export interface GnssFix {
  /** Seconds since the session epoch. */
  t: number;
  /** Degrees, WGS84. */
  lat: number;
  lon: number;
  /** Metres above the ellipsoid. */
  height: number;
  /** Metres above the geoid (orthometric), when the receiver reports separation. */
  orthometricHeight?: number;
  /** Geoid separation in metres: ellipsoidal = orthometric + separation. */
  geoidSeparation?: number;
  quality: FixQuality;
  satellites?: number;
  hdop?: number;
  /** 1-sigma horizontal and vertical accuracy in metres, as reported. */
  hAccuracy?: number;
  vAccuracy?: number;
  /**
   * Lever arm from the GNSS antenna phase centre to the camera centre, expressed
   * in device body axes, metres. A pole-mounted viDoc sits ~200 mm above and behind
   * the phone camera; ignoring that is a systematic 200 mm error in every frame.
   */
  leverArm?: Vec3;
}

// ---------------------------------------------------------------------------
// IMU
// ---------------------------------------------------------------------------

export interface ImuSample {
  t: number;
  /** Angular rate in rad/s, device body axes. */
  gyro: Vec3;
  /** Specific force in m/s^2, device body axes, gravity included. */
  accel: Vec3;
  /** Magnetic field in microtesla, when present. Unreliable indoors and near steel. */
  mag?: Vec3;
}

// ---------------------------------------------------------------------------
// Control
// ---------------------------------------------------------------------------

/**
 * A surveyed point: known project coordinates, and where it was observed.
 * The pair drives the Horn solve in @pixmyd/geo.
 */
export interface ControlPoint {
  /** The point number a surveyor would recognise. */
  id: string;
  /** Coordinates in the project CRS and units — not metres, not local. */
  project: Vec3;
  /** Where it was observed in the capture's own local frame, metres. */
  observed?: Vec3;
  /** 'gcp' constrains the solve; 'checkpoint' is withheld and used to grade it. */
  role: 'gcp' | 'checkpoint';
  description?: string;
  /** 1-sigma survey accuracy in project units. Weights the solve. */
  sigma?: number;
}

// ---------------------------------------------------------------------------
// Coordinate reference
// ---------------------------------------------------------------------------

export interface CrsBlock {
  /** e.g. 'EPSG:6588' or the Autodesk code 'TX83-SCF'. */
  code: string;
  name?: string;
  /** Never the string 'feet'. The US survey foot and international foot differ. */
  unit: 'metre' | 'usSurveyFoot' | 'internationalFoot';
  metresPerUnit: number;
  /**
   * The floating origin, in project units. Local metres are
   * `(project - origin) * metresPerUnit`, remapped to Y-up.
   *
   * Texas State Plane northings run to 13.7 million ftUS, where a float32 step is
   * a full foot. Without this the geometry snaps to a foot lattice before any
   * shader runs. See docs/coordinates.md.
   */
  origin?: Vec3;
  /** Vertical datum, e.g. 'NAVD88'. */
  verticalDatum?: string;
  /** Geoid model used to convert ellipsoidal to orthometric, e.g. 'GEOID18'. */
  geoidModel?: string;
}

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

export type CaptureSourceKind =
  | 'ios-lidar'
  | 'ios-photo'
  | 'android-arcore'
  | 'webxr-depth'
  | 'drone'
  | 'panoramic-360'
  | 'video'
  | 'photo-folder'
  | 'colmap'
  | 'terrestrial-scanner';

export interface DeviceInfo {
  kind: CaptureSourceKind;
  /** e.g. 'iPhone 15 Pro', 'Meta Quest 3', 'DJI Mavic 3E', 'Insta360 X3'. */
  model?: string;
  os?: string;
  /** App or importer that produced the bundle. */
  producer?: string;
  /** True when a real depth sensor contributed, as opposed to inferred depth. */
  hasMetricDepth?: boolean;
  /** e.g. 'Emlid Reach RX', 'viDoc RTK rover'. */
  gnssReceiver?: string;
}

export interface CaptureManifest {
  formatVersion: number;
  /** Stable id for this capture. */
  id: string;
  name: string;
  /** ISO 8601. All frame/IMU/GNSS timestamps are seconds relative to this. */
  startedAt: string;
  device: DeviceInfo;
  /** Indexed by `Frame.camera`. */
  cameras: CameraModel[];
  crs?: CrsBlock;
  /**
   * Transform from the capture's local frame to the project frame in local metres.
   * Written by the georeferencing step; absent until then.
   */
  toProject?: {
    matrix: number[]; // 16, column-major
    /** RMS residual of the solve, metres. The number the user has to see. */
    rms: number;
    method: 'gnss' | 'control' | 'manual' | 'scale-only';
    /** Control point ids the solve used. */
    usedControl?: string[];
  };
  frameCount: number;
  /** Metres, in the capture's local frame. */
  bounds?: { min: Vec3; max: Vec3 };
  notes?: string;
}

/** A bundle fully loaded into memory. Large captures stream instead. */
export interface CaptureBundle {
  manifest: CaptureManifest;
  frames: Frame[];
  imu?: ImuSample[];
  gnss?: GnssFix[];
  control?: ControlPoint[];
}

// ---------------------------------------------------------------------------
// Products
// ---------------------------------------------------------------------------

/** An indexed triangle mesh. Attribute arrays are parallel; `indices` addresses them. */
export interface Mesh {
  positions: Float32Array;
  indices: Uint32Array;
  normals?: Float32Array;
  /** Linear-space RGB in [0, 1], three per vertex. */
  colors?: Float32Array;
  uvs?: Float32Array;
  texture?: TextureImage;
  name?: string;
}

export interface TextureImage {
  width: number;
  height: number;
  /** Encoded bytes — a PNG or JPEG file, not raw pixels. */
  data: Uint8Array;
  mimeType: 'image/png' | 'image/jpeg' | 'image/webp';
}

/** A point cloud. Optional channels are present or absent together across all points. */
export interface PointCloud {
  positions: Float32Array | Float64Array;
  /** 0-255 per channel. */
  colors?: Uint8Array;
  /** 0-1, normalized reflectance. */
  intensity?: Float32Array;
  normals?: Float32Array;
  /** Seconds, per point — a moving scanner's points are not simultaneous. */
  timestamps?: Float64Array;
  /** Point count, in case arrays are over-allocated. */
  count: number;
  /**
   * Coordinates are stored relative to this origin, in metres. Exporters that
   * carry a georeference (E57, LAS) add it back; those that do not (PLY, OBJ) keep
   * the local values and record the origin in a sidecar.
   */
  origin?: Vec3;
  crs?: CrsBlock;
}

/**
 * A 3D Gaussian splat scene, in the storage layout the PLY convention uses:
 * raw (pre-activation) opacity and scale, so a trained model round-trips exactly.
 */
export interface SplatCloud {
  count: number;
  /** xyz per splat. */
  positions: Float32Array;
  /** Log-scale per axis. Actual scale is exp(s). */
  scales: Float32Array;
  /** Rotation quaternion per splat, [x, y, z, w] in storage order w,x,y,z on PLY. */
  rotations: Float32Array;
  /** Logit opacity. Actual alpha is sigmoid(o). */
  opacities: Float32Array;
  /** Spherical harmonic band 0 (DC), 3 per splat. */
  sh0: Float32Array;
  /** Higher SH bands, `shDegree` implies the count. Row-major per splat. */
  shRest?: Float32Array;
  /** 0 gives flat colour; 3 gives full view-dependence at 45 coefficients per splat. */
  shDegree: 0 | 1 | 2 | 3;
  origin?: Vec3;
  crs?: CrsBlock;
}

/** Everything a finished capture can produce. */
export interface ReconstructionResult {
  splats?: SplatCloud;
  mesh?: Mesh;
  points?: PointCloud;
  manifest: CaptureManifest;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function emptyManifest(name: string, device: DeviceInfo): CaptureManifest {
  return {
    formatVersion: BUNDLE_FORMAT_VERSION,
    id: crypto.randomUUID(),
    name,
    startedAt: new Date().toISOString(),
    device,
    cameras: [],
    frameCount: 0,
  };
}

/** Camera-to-world matrix for a pose. */
export function poseToMatrix(pose: Pose): Mat4 {
  return mat4.compose(pose.t, pose.q, [1, 1, 1]);
}

/** World-to-camera matrix — the one projection actually needs. */
export function poseToViewMatrix(pose: Pose): Mat4 {
  return mat4.invertRigid(mat4.compose(pose.t, pose.q, [1, 1, 1]));
}

export function matrixToPose(m: Mat4): Pose {
  const { translation, rotation } = mat4.decompose(m);
  return { t: translation, q: rotation };
}

/** Frames that carry a pose good enough to project with. */
export function posedFrames(bundle: CaptureBundle): Frame[] {
  return bundle.frames.filter((f) => f.pose !== undefined && f.poseSource !== 'none');
}

/** Frames that carry a real depth measurement, not an inferred one. */
export function depthFrames(bundle: CaptureBundle): Frame[] {
  return bundle.frames.filter((f) => f.depth !== undefined);
}
