/**
 * Turning other people's data into a capture bundle.
 *
 * Four sources, each of which arrives in a shape nothing else understands:
 *
 *   drone       a folder of JPEGs with GPS and gimbal angles in their metadata
 *   panoramic   stitched equirectangular frames from a 360 camera
 *   photo       an ordinary folder of photographs, with no pose at all
 *   colmap      an existing reconstruction, as text or as a sparse model
 *
 * The job here is only normalization — produce a `CaptureBundle` with cameras,
 * frames and whatever poses the metadata supports, and let the reconstruction
 * stack take it from there. Nothing in this module infers geometry.
 */

import type {
  CameraModel,
  CaptureBundle,
  CaptureManifest,
  CaptureSourceKind,
  EquirectCamera,
  Frame,
  GnssFix,
  PinholeCamera,
  Pose,
} from '@pixmyd/core/bundle';
import { FixQuality } from '@pixmyd/core/bundle';
import { quat, degToRad, type Quat, type Vec3 } from '@pixmyd/core/math';
import { geodeticToEnu, WGS84, type Geodetic } from '@pixmyd/geo/projection';
import { focalLengthInPixels, readImageMetadata, type ImageMetadata } from './exif.ts';

export interface SourceImage {
  /** Path or name, used as the frame's image URI. */
  name: string;
  bytes: Uint8Array;
}

export interface IngestResult {
  bundle: CaptureBundle;
  /** Per-image problems, so a partial import is explainable. */
  warnings: string[];
}

// ---------------------------------------------------------------------------
// Drone
// ---------------------------------------------------------------------------

export interface DroneIngestOptions {
  name?: string;
  /**
   * Geodetic origin for the local frame. Defaults to the first image's GPS
   * position, which keeps local coordinates small and centred on the site.
   */
  origin?: Geodetic;
  /**
   * Trust the gimbal angles as an initial orientation. On by default: they are
   * good to a degree or so on a survey drone, which is a far better starting
   * point for SfM than nothing.
   */
  useGimbalOrientation?: boolean;
}

/**
 * Convert a drone's yaw/pitch/roll into a camera-to-world rotation.
 *
 * The conversion is the fiddly part and worth spelling out. DJI reports:
 *   yaw    degrees clockwise from true north
 *   pitch  degrees from horizontal, negative looking down
 *   roll   degrees about the optical axis
 *
 * The world frame here is ENU — X east, Y north, Z up. The camera frame is the
 * computer-vision one — X right, Y down, Z forward along the optical axis.
 *
 * A camera at yaw 0, pitch 0 looks north and level, so its +Z maps to +Y(north)
 * and its +Y (down) maps to -Z(up). That is the base orientation; yaw, pitch and
 * roll are applied on top.
 */
export function gimbalToRotation(yawDeg: number, pitchDeg: number, rollDeg: number): Quat {
  // Base: camera looking north and level, in ENU.
  //   camera +X (right) -> world +X (east)
  //   camera +Y (down)  -> world -Z (down)
  //   camera +Z (fwd)   -> world +Y (north)
  // That is a -90 degrees rotation about the world X axis.
  const base = quat.fromAxisAngle([1, 0, 0], -Math.PI / 2);

  // Yaw is clockwise from north, which is *negative* about the ENU up axis,
  // since ENU is right-handed and a positive rotation about +Z goes east-to-north.
  const yaw = quat.fromAxisAngle([0, 0, 1], -degToRad(yawDeg));
  // Pitch is about the camera's own right axis after yaw. Negative pitch looks
  // down, and looking down is a positive rotation about the camera's +X.
  const pitch = quat.fromAxisAngle([1, 0, 0], degToRad(pitchDeg));
  const roll = quat.fromAxisAngle([0, 0, 1], degToRad(rollDeg));

  // world <- yaw <- base <- pitch <- roll
  return quat.normalize(
    quat.multiply(quat.multiply(yaw, base), quat.multiply(pitch, roll)),
  );
}

export async function ingestDroneImages(
  images: SourceImage[],
  options: DroneIngestOptions = {},
): Promise<IngestResult> {
  const warnings: string[] = [];
  const cameras: CameraModel[] = [];
  const cameraKeys = new Map<string, number>();
  const frames: Frame[] = [];
  const gnss: GnssFix[] = [];

  // Read metadata first — the origin depends on it.
  const parsed: { image: SourceImage; metadata: ImageMetadata }[] = [];
  for (const image of images) {
    try {
      parsed.push({ image, metadata: readImageMetadata(image.bytes) });
    } catch (error) {
      warnings.push(`${image.name}: ${(error as Error).message}`);
    }
  }

  const firstWithGps = parsed.find((p) => p.metadata.gps);
  // The origin has to be built from the *same* altitude source the frames use.
  // Mixing the barometric absolute altitude into the frames and the GPS
  // altitude into the origin offsets the entire flight vertically by the
  // difference between them, which on a DJI is the take-off elevation.
  const origin: Geodetic | undefined =
    options.origin ??
    (firstWithGps
      ? {
          lat: firstWithGps.metadata.gps!.lat,
          lon: firstWithGps.metadata.gps!.lon,
          height: frameAltitude(firstWithGps.metadata),
        }
      : undefined);

  if (!origin) {
    warnings.push(
      'No image carried a GPS position, so there is no georeference and no initial ' +
      'camera positions. Structure-from-motion will have to solve the whole scene ' +
      'from scratch, and the result will have arbitrary scale and orientation.',
    );
  }

  const useGimbal = options.useGimbalOrientation ?? true;
  let startTime: number | undefined;

  parsed.forEach(({ image, metadata }, index) => {
    const { camera: exifCamera } = metadata;

    // Group images by intrinsics so a two-camera flight produces two models.
    const focal = focalLengthInPixels(exifCamera);
    const width = exifCamera.imageWidth;
    const height = exifCamera.imageHeight;

    if (!width || !height) {
      warnings.push(`${image.name}: no image dimensions in metadata, skipped.`);
      return;
    }
    if (focal === undefined) {
      warnings.push(
        `${image.name}: focal length in pixels could not be derived ` +
        `(model "${exifCamera.model ?? 'unknown'}"). ` +
        'Structure-from-motion will have to solve for it.',
      );
    }

    const key = `${exifCamera.make}|${exifCamera.model}|${width}x${height}|${focal ?? 'unknown'}`;
    let cameraIndex = cameraKeys.get(key);
    if (cameraIndex === undefined) {
      const model: PinholeCamera = {
        model: 'pinhole',
        width,
        height,
        // A camera with no derivable focal length gets a 60-degree guess, which
        // SfM refines. It is flagged in the warnings so nobody mistakes it for
        // a measurement.
        fx: focal ?? width * 0.85,
        fy: focal ?? width * 0.85,
        cx: (width - 1) / 2,
        cy: (height - 1) / 2,
      };
      cameras.push(model);
      cameraIndex = cameras.length - 1;
      cameraKeys.set(key, cameraIndex);
    }

    // Time, relative to the first exposure.
    const captured = metadata.gps?.timestamp ?? exifCamera.captureTime;
    const epoch = captured ? Date.parse(captured) : NaN;
    if (Number.isFinite(epoch) && startTime === undefined) startTime = epoch;
    const t = Number.isFinite(epoch) && startTime !== undefined
      ? (epoch - startTime) / 1000
      : index;

    let pose: Pose | undefined;
    if (metadata.gps && origin) {
      const geodetic: Geodetic = {
        lat: metadata.gps.lat,
        lon: metadata.gps.lon,
        height: frameAltitude(metadata),
      };
      const enu = geodeticToEnu(geodetic, origin, WGS84);

      const attitude = metadata.drone;
      const rotation =
        useGimbal && attitude?.gimbalYaw !== undefined
          ? gimbalToRotation(
              attitude.gimbalYaw,
              attitude.gimbalPitch ?? 0,
              attitude.gimbalRoll ?? 0,
            )
          : quat.identity();

      pose = { t: enu as Vec3, q: rotation };

      const rtk = metadata.drone?.rtkFlag === true;
      gnss.push({
        t,
        lat: metadata.gps.lat,
        lon: metadata.gps.lon,
        height: geodetic.height,
        quality: rtk ? FixQuality.RtkFixed : FixQuality.SinglePoint,
        hAccuracy: metadata.gps.horizontalError,
      });
    }

    frames.push({
      id: String(index).padStart(6, '0'),
      t,
      imageUri: image.name,
      camera: cameraIndex,
      pose,
      // Metadata poses are a starting point, not a solution: the gimbal is
      // good to about a degree and the GPS to metres without RTK.
      poseSource: pose ? 'metadata' : 'none',
      poseWeight: pose ? (metadata.drone?.rtkFlag ? 0.6 : 0.2) : undefined,
      exposure: exifCamera.exposureTime,
      iso: exifCamera.iso,
      meta: {
        make: exifCamera.make,
        model: exifCamera.model,
        gimbalYaw: metadata.drone?.gimbalYaw,
        gimbalPitch: metadata.drone?.gimbalPitch,
        relativeAltitude: metadata.drone?.relativeAltitude,
      },
    });
  });

  const manifest = buildManifest({
    name: options.name ?? 'Drone capture',
    kind: 'drone',
    cameras,
    frameCount: frames.length,
    model: parsed[0]?.metadata.camera.model,
    hasMetricDepth: false,
  });

  if (origin) {
    manifest.notes =
      `Local frame is ENU metres about ${origin.lat.toFixed(7)}, ${origin.lon.toFixed(7)}, ` +
      `${origin.height.toFixed(1)} m ellipsoidal.`;
  }

  return {
    bundle: { manifest, frames, gnss: gnss.length > 0 ? gnss : undefined },
    warnings,
  };
}

// ---------------------------------------------------------------------------
// 360 panoramas
// ---------------------------------------------------------------------------

export interface PanoramicIngestOptions {
  name?: string;
  width: number;
  height: number;
  /**
   * Split each panorama into perspective views before reconstruction.
   *
   * Most structure-from-motion is written for perspective images, and an
   * equirectangular frame breaks the assumptions badly at the poles. Cutting a
   * cube face set gives ordinary pinhole images the rest of the stack already
   * handles. The bundle records both so nothing is lost.
   */
  cubeFaces?: boolean;
  /** Face resolution when cutting. Defaults to a quarter of the panorama width. */
  faceSize?: number;
}

/**
 * The six cube faces as camera-to-world rotations, in the order
 * +X, -X, +Y, -Y, +Z, -Z relative to the panorama's own frame.
 */
export const CUBE_FACE_ROTATIONS: { name: string; rotation: Quat }[] = [
  { name: 'right', rotation: quat.fromAxisAngle([0, 1, 0], Math.PI / 2) },
  { name: 'left', rotation: quat.fromAxisAngle([0, 1, 0], -Math.PI / 2) },
  // Camera axes have +Y pointing *down*, so the face that looks up is the one
  // whose forward axis maps to -Y. Getting these two the wrong way round puts
  // the sky underfoot, which a viewer renders without complaint.
  { name: 'up', rotation: quat.fromAxisAngle([1, 0, 0], Math.PI / 2) },
  { name: 'down', rotation: quat.fromAxisAngle([1, 0, 0], -Math.PI / 2) },
  { name: 'front', rotation: quat.identity() },
  { name: 'back', rotation: quat.fromAxisAngle([0, 1, 0], Math.PI) },
];

/**
 * Ingest stitched 360 frames — an Insta360 X3, a Ricoh Theta, a Quest capture.
 *
 * Poses are left empty. A 360 camera walked through a site has no metadata that
 * says where it was, so structure-from-motion has to solve it, and pretending
 * otherwise would put every frame at the origin.
 */
export function ingestPanoramas(
  images: SourceImage[],
  options: PanoramicIngestOptions,
): IngestResult {
  const warnings: string[] = [];
  const { width, height } = options;

  if (Math.abs(width / height - 2) > 0.02) {
    warnings.push(
      `These frames are ${width}x${height}, which is not the 2:1 aspect a full ` +
      'equirectangular panorama has. If they are partial panoramas the field of ' +
      'view must be set explicitly or every direction will be wrong.',
    );
  }

  const panorama: EquirectCamera = {
    model: 'equirect',
    width,
    height,
    hfov: 2 * Math.PI,
    vfov: Math.PI,
  };

  const cameras: CameraModel[] = [panorama];
  const frames: Frame[] = [];

  const faceSize = options.faceSize ?? Math.round(width / 4);
  if (options.cubeFaces) {
    // A cube face spans 90 degrees, so its focal length is half the face size.
    const face: PinholeCamera = {
      model: 'pinhole',
      width: faceSize,
      height: faceSize,
      fx: faceSize / 2,
      fy: faceSize / 2,
      cx: (faceSize - 1) / 2,
      cy: (faceSize - 1) / 2,
    };
    cameras.push(face);
  }

  images.forEach((image, index) => {
    if (options.cubeFaces) {
      // Six frames per panorama, each with a known rotation relative to the
      // panorama's own frame. The position is unknown and shared.
      CUBE_FACE_ROTATIONS.forEach((cubeFace, faceIndex) => {
        frames.push({
          id: `${String(index).padStart(6, '0')}-${cubeFace.name}`,
          t: index,
          imageUri: image.name,
          camera: 1,
          poseSource: 'none',
          meta: {
            panoramaIndex: index,
            face: cubeFace.name,
            faceRotation: cubeFace.rotation,
            // Everything needed to cut the face out of the source panorama.
            sourceCamera: 0,
            faceIndex,
          },
        });
      });
    } else {
      frames.push({
        id: String(index).padStart(6, '0'),
        t: index,
        imageUri: image.name,
        camera: 0,
        poseSource: 'none',
      });
    }
  });

  const manifest = buildManifest({
    name: options.name ?? '360 capture',
    kind: 'panoramic-360',
    cameras,
    frameCount: frames.length,
    hasMetricDepth: false,
  });
  manifest.notes =
    'Panoramic capture. No positions are known — structure-from-motion must solve ' +
    'the whole trajectory, and the result will have arbitrary scale until it is ' +
    'fitted to control or to a known distance.';

  return { bundle: { manifest, frames }, warnings };
}

// ---------------------------------------------------------------------------
// Plain photo folders
// ---------------------------------------------------------------------------

export function ingestPhotoFolder(
  images: SourceImage[],
  options: { name?: string } = {},
): IngestResult {
  // A photo folder is the drone path without the drone: the same EXIF reading,
  // and whatever GPS a phone or camera happened to record.
  const warnings: string[] = [];
  const cameras: CameraModel[] = [];
  const cameraKeys = new Map<string, number>();
  const frames: Frame[] = [];

  images.forEach((image, index) => {
    let metadata: ImageMetadata;
    try {
      metadata = readImageMetadata(image.bytes);
    } catch (error) {
      warnings.push(`${image.name}: ${(error as Error).message}`);
      return;
    }

    const { imageWidth: width, imageHeight: height } = metadata.camera;
    if (!width || !height) {
      warnings.push(`${image.name}: no dimensions in metadata, skipped.`);
      return;
    }

    const focal = focalLengthInPixels(metadata.camera);
    const key = `${metadata.camera.model}|${width}x${height}|${focal ?? '?'}`;
    let cameraIndex = cameraKeys.get(key);
    if (cameraIndex === undefined) {
      cameras.push({
        model: 'pinhole',
        width,
        height,
        fx: focal ?? width * 0.85,
        fy: focal ?? width * 0.85,
        cx: (width - 1) / 2,
        cy: (height - 1) / 2,
      });
      cameraIndex = cameras.length - 1;
      cameraKeys.set(key, cameraIndex);
    }

    frames.push({
      id: String(index).padStart(6, '0'),
      t: index,
      imageUri: image.name,
      camera: cameraIndex,
      poseSource: 'none',
      exposure: metadata.camera.exposureTime,
      iso: metadata.camera.iso,
    });
  });

  return {
    bundle: {
      manifest: buildManifest({
        name: options.name ?? 'Photo set',
        kind: 'photo-folder',
        cameras,
        frameCount: frames.length,
        hasMetricDepth: false,
      }),
      frames,
    },
    warnings,
  };
}

// ---------------------------------------------------------------------------
// COLMAP
// ---------------------------------------------------------------------------

/**
 * Import a COLMAP text reconstruction.
 *
 * COLMAP is the reference open photogrammetry pipeline and its text format is
 * the de-facto interchange for "here is a solved scene". Supporting it means a
 * user with an existing reconstruction from any tool that can export COLMAP —
 * which is most of them — can bring it here and use the export layer.
 *
 * The convention trap: COLMAP stores **world-to-camera** rotation as a
 * quaternion in `qw qx qy qz` order, and its translation is the world origin
 * expressed in camera coordinates — not the camera position. Reading them as
 * camera-to-world puts every camera in the wrong place in a way that still
 * looks like a plausible trajectory.
 */
export function ingestColmap(
  camerasText: string,
  imagesText: string,
  options: { name?: string } = {},
): IngestResult {
  const warnings: string[] = [];
  const cameras: CameraModel[] = [];
  const cameraIdToIndex = new Map<number, number>();

  for (const line of camerasText.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const parts = trimmed.split(/\s+/);
    // CAMERA_ID MODEL WIDTH HEIGHT PARAMS...
    const id = Number(parts[0]);
    const model = parts[1];
    const width = Number(parts[2]);
    const height = Number(parts[3]);
    const params = parts.slice(4).map(Number);

    let camera: CameraModel | undefined;
    switch (model) {
      case 'SIMPLE_PINHOLE':
        camera = { model: 'pinhole', width, height, fx: params[0], fy: params[0], cx: params[1], cy: params[2] };
        break;
      case 'PINHOLE':
        camera = { model: 'pinhole', width, height, fx: params[0], fy: params[1], cx: params[2], cy: params[3] };
        break;
      case 'SIMPLE_RADIAL':
        camera = { model: 'pinhole', width, height, fx: params[0], fy: params[0], cx: params[1], cy: params[2], k1: params[3] };
        break;
      case 'RADIAL':
        camera = { model: 'pinhole', width, height, fx: params[0], fy: params[0], cx: params[1], cy: params[2], k1: params[3], k2: params[4] };
        break;
      case 'OPENCV':
        camera = {
          model: 'pinhole', width, height,
          fx: params[0], fy: params[1], cx: params[2], cy: params[3],
          k1: params[4], k2: params[5], p1: params[6], p2: params[7],
        };
        break;
      case 'OPENCV_FISHEYE':
        camera = {
          model: 'fisheye', width, height,
          fx: params[0], fy: params[1], cx: params[2], cy: params[3],
          k1: params[4], k2: params[5], k3: params[6], k4: params[7],
        };
        break;
      default:
        warnings.push(`Camera ${id}: COLMAP model "${model}" is not supported, skipped.`);
    }

    if (camera) {
      cameras.push(camera);
      cameraIdToIndex.set(id, cameras.length - 1);
    }
  }

  const frames: Frame[] = [];
  const lines = imagesText.split('\n');
  let index = 0;

  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const parts = trimmed.split(/\s+/);
    // Images alternate: a pose line, then a line of 2D observations.
    // A pose line has at least 10 fields and ends with a filename.
    if (parts.length < 10) continue;

    const qw = Number(parts[1]), qx = Number(parts[2]);
    const qy = Number(parts[3]), qz = Number(parts[4]);
    const tx = Number(parts[5]), ty = Number(parts[6]), tz = Number(parts[7]);
    const cameraId = Number(parts[8]);
    const name = parts.slice(9).join(' ');

    const cameraIndex = cameraIdToIndex.get(cameraId);
    if (cameraIndex === undefined) {
      warnings.push(`${name}: references unknown camera ${cameraId}, skipped.`);
      i++; // skip the observations line too
      continue;
    }

    // COLMAP gives world-to-camera. Invert it to get the camera pose.
    const worldToCamera: Quat = [qx, qy, qz, qw];
    const cameraToWorld = quat.conjugate(quat.normalize(worldToCamera));
    // Camera centre C = -R^T * t.
    const rotated = quat.rotate(cameraToWorld, [tx, ty, tz]);
    const position: Vec3 = [-rotated[0], -rotated[1], -rotated[2]];

    frames.push({
      id: String(index).padStart(6, '0'),
      t: index,
      imageUri: name,
      camera: cameraIndex,
      pose: { t: position, q: cameraToWorld },
      poseSource: 'sfm',
      poseWeight: 1,
    });
    index++;
    i++; // the next line is the observation list
  }

  if (frames.length === 0) {
    warnings.push('No images were read. Check that this is a COLMAP text model, not binary.');
  }

  return {
    bundle: {
      manifest: buildManifest({
        name: options.name ?? 'COLMAP import',
        kind: 'colmap',
        cameras,
        frameCount: frames.length,
        hasMetricDepth: false,
      }),
      frames,
    },
    warnings,
  };
}

/** Write a COLMAP text model, for handing a bundle to another pipeline. */
export function exportColmap(bundle: CaptureBundle): { cameras: string; images: string } {
  const cameraLines = ['# Camera list with one line of data per camera:',
    '#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]'];

  bundle.manifest.cameras.forEach((camera, index) => {
    if (camera.model === 'pinhole') {
      cameraLines.push(
        `${index + 1} OPENCV ${camera.width} ${camera.height} ` +
        `${camera.fx} ${camera.fy} ${camera.cx} ${camera.cy} ` +
        `${camera.k1 ?? 0} ${camera.k2 ?? 0} ${camera.p1 ?? 0} ${camera.p2 ?? 0}`,
      );
    } else if (camera.model === 'fisheye') {
      cameraLines.push(
        `${index + 1} OPENCV_FISHEYE ${camera.width} ${camera.height} ` +
        `${camera.fx} ${camera.fy} ${camera.cx} ${camera.cy} ` +
        `${camera.k1 ?? 0} ${camera.k2 ?? 0} ${camera.k3 ?? 0} ${camera.k4 ?? 0}`,
      );
    }
    // Equirectangular has no COLMAP equivalent; such frames are dropped by the
    // image loop below rather than written as a camera COLMAP cannot use.
  });

  const imageLines = ['# Image list with two lines of data per image:',
    '#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME',
    '#   POINTS2D[] as (X, Y, POINT3D_ID)'];

  let id = 1;
  for (const frame of bundle.frames) {
    if (!frame.pose) continue;
    const camera = bundle.manifest.cameras[frame.camera];
    if (!camera || camera.model === 'equirect') continue;

    // Invert camera-to-world back into COLMAP's world-to-camera.
    const worldToCamera = quat.conjugate(frame.pose.q);
    const rotated = quat.rotate(worldToCamera, frame.pose.t);
    const translation: Vec3 = [-rotated[0], -rotated[1], -rotated[2]];

    imageLines.push(
      `${id} ${worldToCamera[3]} ${worldToCamera[0]} ${worldToCamera[1]} ${worldToCamera[2]} ` +
      `${translation[0]} ${translation[1]} ${translation[2]} ` +
      `${frame.camera + 1} ${frame.imageUri}`,
    );
    // COLMAP requires the observations line even when empty.
    imageLines.push('');
    id++;
  }

  return { cameras: cameraLines.join('\n') + '\n', images: imageLines.join('\n') + '\n' };
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

/**
 * The altitude to use for a frame.
 *
 * The drone's absolute altitude is barometric and far less noisy than the GPS
 * altitude, which is the weakest axis of any fix. Preferring it is right — but
 * it must be preferred *consistently*, including when choosing the origin.
 */
function frameAltitude(metadata: ImageMetadata): number {
  return metadata.drone?.absoluteAltitude ?? metadata.gps?.altitude ?? 0;
}

function buildManifest(spec: {
  name: string;
  kind: CaptureSourceKind;
  cameras: CameraModel[];
  frameCount: number;
  model?: string;
  hasMetricDepth: boolean;
}): CaptureManifest {
  return {
    formatVersion: 1,
    id: crypto.randomUUID(),
    name: spec.name,
    startedAt: new Date().toISOString(),
    device: {
      kind: spec.kind,
      model: spec.model,
      producer: 'PIXMYD ingest',
      hasMetricDepth: spec.hasMetricDepth,
    },
    cameras: spec.cameras,
    frameCount: spec.frameCount,
  };
}
