/**
 * EXIF and XMP extraction from JPEG.
 *
 * This is what makes a folder of drone photographs into a capture. A DJI image
 * carries, in its metadata, everything needed for an initial pose: the GPS
 * position of the exposure, the gimbal orientation, the focal length, and the
 * sensor dimensions. Structure-from-motion still has to refine it, but starting
 * from metadata rather than from nothing is the difference between a solve that
 * converges in seconds and one that wanders off.
 *
 * Written from the specifications rather than pulled from a library, because
 * the parsing is a few hundred lines and a dependency here would be a
 * dependency in the browser bundle of a tool meant to be auditable.
 *
 * Two things that bite everyone who writes one of these:
 *
 * **Endianness is per-file and declared inside the TIFF header**, not by the
 * JPEG. Canon writes little-endian, older Nikon big-endian, and a parser that
 * assumes either reads garbage from half the world's cameras.
 *
 * **GPS coordinates are unsigned**, with the hemisphere in a separate tag. A
 * parser that forgets that puts the southern hemisphere in the northern one,
 * which looks plausible on a map until someone checks.
 */

export interface GpsPosition {
  /** Degrees, signed. */
  lat: number;
  lon: number;
  /** Metres above sea level as the camera reported it. */
  altitude?: number;
  /** True when the altitude tag said "below sea level". */
  belowSeaLevel?: boolean;
  /** Horizontal positioning error in metres, when the camera records it. */
  horizontalError?: number;
  /** ISO 8601 UTC, assembled from the GPS date and time stamps. */
  timestamp?: string;
}

export interface CameraMetadata {
  make?: string;
  model?: string;
  /** Actual focal length in millimetres. */
  focalLength?: number;
  /** 35 mm equivalent focal length, when the camera reports it. */
  focalLength35mm?: number;
  /** Physical sensor width in millimetres, derived where possible. */
  sensorWidth?: number;
  imageWidth?: number;
  imageHeight?: number;
  exposureTime?: number;
  iso?: number;
  fNumber?: number;
  /** ISO 8601, from DateTimeOriginal. Local time — EXIF has no zone. */
  captureTime?: string;
  /** EXIF orientation, 1-8. */
  orientation?: number;
}

/**
 * Gimbal and flight attitude, from the DJI XMP namespace.
 *
 * Other manufacturers use their own namespaces; the field names below are DJI's
 * because that is what the overwhelming majority of survey drones write. Yaw is
 * degrees clockwise from true north, pitch is negative looking down.
 */
export interface DroneAttitude {
  gimbalYaw?: number;
  gimbalPitch?: number;
  gimbalRoll?: number;
  flightYaw?: number;
  flightPitch?: number;
  flightRoll?: number;
  /** Height above the take-off point, metres. */
  relativeAltitude?: number;
  /** Absolute altitude, metres. */
  absoluteAltitude?: number;
  /** True when the image carries an RTK-corrected position. */
  rtkFlag?: boolean;
}

export interface ImageMetadata {
  camera: CameraMetadata;
  gps?: GpsPosition;
  drone?: DroneAttitude;
  /** Raw XMP packet, for anything this parser does not model. */
  xmp?: string;
}

// ---------------------------------------------------------------------------
// TIFF/EXIF constants
// ---------------------------------------------------------------------------

/** Bytes per component, indexed by TIFF type code. */
const TYPE_SIZE: Record<number, number> = {
  1: 1, // BYTE
  2: 1, // ASCII
  3: 2, // SHORT
  4: 4, // LONG
  5: 8, // RATIONAL
  6: 1, // SBYTE
  7: 1, // UNDEFINED
  8: 2, // SSHORT
  9: 4, // SLONG
  10: 8, // SRATIONAL
  11: 4, // FLOAT
  12: 8, // DOUBLE
};

const TAG = {
  IMAGE_WIDTH: 0x0100,
  IMAGE_HEIGHT: 0x0101,
  MAKE: 0x010f,
  MODEL: 0x0110,
  ORIENTATION: 0x0112,
  EXIF_IFD: 0x8769,
  GPS_IFD: 0x8825,
  EXPOSURE_TIME: 0x829a,
  F_NUMBER: 0x829d,
  ISO: 0x8827,
  DATE_TIME_ORIGINAL: 0x9003,
  PIXEL_X_DIMENSION: 0xa002,
  PIXEL_Y_DIMENSION: 0xa003,
  FOCAL_LENGTH: 0x920a,
  FOCAL_LENGTH_35MM: 0xa405,
  FOCAL_PLANE_X_RESOLUTION: 0xa20e,
  FOCAL_PLANE_RESOLUTION_UNIT: 0xa210,
} as const;

const GPS_TAG = {
  LAT_REF: 0x0001,
  LAT: 0x0002,
  LON_REF: 0x0003,
  LON: 0x0004,
  ALTITUDE_REF: 0x0005,
  ALTITUDE: 0x0006,
  TIME_STAMP: 0x0007,
  HORIZONTAL_ERROR: 0x001f,
  DATE_STAMP: 0x001d,
} as const;

type TagValue = number | number[] | string;

// ---------------------------------------------------------------------------
// JPEG segment walking
// ---------------------------------------------------------------------------

export interface JpegSegments {
  exif?: Uint8Array;
  xmp?: string;
  /** Extended XMP, which DJI uses when the packet exceeds 64 KB. */
  extendedXmp?: string;
}

/**
 * Walk a JPEG's marker segments and pull out the APP1 payloads.
 *
 * JPEG is a sequence of `0xFF <marker> <length> <payload>` segments until the
 * start-of-scan marker, after which the entropy-coded data runs to the end and
 * cannot be walked this way. Everything of interest is before that.
 */
export function readJpegSegments(bytes: Uint8Array): JpegSegments {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    throw new Error('not a JPEG: missing the start-of-image marker');
  }

  const out: JpegSegments = {};
  const decoder = new TextDecoder('utf-8', { fatal: false });
  let offset = 2;

  while (offset + 4 <= bytes.length) {
    if (bytes[offset] !== 0xff) {
      // Fill bytes are legal between segments; skip them rather than giving up.
      offset++;
      continue;
    }
    const marker = bytes[offset + 1];

    // Start of scan, or end of image: nothing parseable follows.
    if (marker === 0xda || marker === 0xd9) break;
    // Standalone markers carry no length field.
    if (marker >= 0xd0 && marker <= 0xd8) {
      offset += 2;
      continue;
    }

    const length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) break;
    const payload = bytes.subarray(offset + 4, offset + 2 + length);

    if (marker === 0xe1) {
      const header = decoder.decode(payload.subarray(0, 32));
      if (header.startsWith('Exif\0')) {
        out.exif = payload.subarray(6);
      } else if (header.startsWith('http://ns.adobe.com/xap/1.0/\0')) {
        out.xmp = decoder.decode(payload.subarray(29));
      } else if (header.startsWith('http://ns.adobe.com/xmp/extension/\0')) {
        // 35-byte namespace + 32-byte GUID + 4-byte length + 4-byte offset.
        const chunk = decoder.decode(payload.subarray(75));
        out.extendedXmp = (out.extendedXmp ?? '') + chunk;
      }
    }

    offset += 2 + length;
  }

  return out;
}

// ---------------------------------------------------------------------------
// TIFF IFD parsing
// ---------------------------------------------------------------------------

class TiffReader {
  readonly view: DataView;
  readonly littleEndian: boolean;
  readonly bytes: Uint8Array;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    // The byte-order mark is the first thing in the TIFF header and governs
    // every read after it. 'II' is Intel (little), 'MM' is Motorola (big).
    const order = this.view.getUint16(0, false);
    if (order === 0x4949) this.littleEndian = true;
    else if (order === 0x4d4d) this.littleEndian = false;
    else throw new Error('not a TIFF header: bad byte-order mark');

    if (this.view.getUint16(2, this.littleEndian) !== 42) {
      throw new Error('not a TIFF header: bad magic');
    }
  }

  get firstIfdOffset(): number {
    return this.view.getUint32(4, this.littleEndian);
  }

  /** Read one IFD into a tag map, and return the offset of the next IFD. */
  readIfd(offset: number): { tags: Map<number, TagValue>; next: number } {
    const tags = new Map<number, TagValue>();
    if (offset + 2 > this.bytes.length) return { tags, next: 0 };

    const count = this.view.getUint16(offset, this.littleEndian);
    let cursor = offset + 2;

    for (let i = 0; i < count; i++) {
      if (cursor + 12 > this.bytes.length) break;
      const tag = this.view.getUint16(cursor, this.littleEndian);
      const type = this.view.getUint16(cursor + 2, this.littleEndian);
      const components = this.view.getUint32(cursor + 4, this.littleEndian);
      const size = (TYPE_SIZE[type] ?? 0) * components;

      // Values of four bytes or fewer are stored inline in the entry itself;
      // anything larger is an offset into the file.
      const valueOffset = size <= 4
        ? cursor + 8
        : this.view.getUint32(cursor + 8, this.littleEndian);

      if (size > 0 && valueOffset + size <= this.bytes.length) {
        const value = this.readValue(type, components, valueOffset);
        if (value !== undefined) tags.set(tag, value);
      }
      cursor += 12;
    }

    const next = cursor + 4 <= this.bytes.length
      ? this.view.getUint32(cursor, this.littleEndian)
      : 0;
    return { tags, next };
  }

  private readValue(type: number, components: number, offset: number): TagValue | undefined {
    const le = this.littleEndian;
    switch (type) {
      case 2: {
        // ASCII, NUL-terminated. Trailing NULs are part of the padding.
        const raw = this.bytes.subarray(offset, offset + components);
        const end = raw.indexOf(0);
        return new TextDecoder('utf-8', { fatal: false })
          .decode(end >= 0 ? raw.subarray(0, end) : raw);
      }
      case 1:
      case 7: {
        const out: number[] = [];
        for (let i = 0; i < components; i++) out.push(this.bytes[offset + i]);
        return components === 1 ? out[0] : out;
      }
      case 3: {
        const out: number[] = [];
        for (let i = 0; i < components; i++) out.push(this.view.getUint16(offset + i * 2, le));
        return components === 1 ? out[0] : out;
      }
      case 4: {
        const out: number[] = [];
        for (let i = 0; i < components; i++) out.push(this.view.getUint32(offset + i * 4, le));
        return components === 1 ? out[0] : out;
      }
      case 9: {
        const out: number[] = [];
        for (let i = 0; i < components; i++) out.push(this.view.getInt32(offset + i * 4, le));
        return components === 1 ? out[0] : out;
      }
      case 5:
      case 10: {
        // Rationals are a numerator/denominator pair. A zero denominator is
        // legal in the wild and means "unknown", not infinity.
        const out: number[] = [];
        for (let i = 0; i < components; i++) {
          const at = offset + i * 8;
          const numerator = type === 5
            ? this.view.getUint32(at, le)
            : this.view.getInt32(at, le);
          const denominator = type === 5
            ? this.view.getUint32(at + 4, le)
            : this.view.getInt32(at + 4, le);
          out.push(denominator === 0 ? 0 : numerator / denominator);
        }
        return components === 1 ? out[0] : out;
      }
      case 11: {
        const out: number[] = [];
        for (let i = 0; i < components; i++) out.push(this.view.getFloat32(offset + i * 4, le));
        return components === 1 ? out[0] : out;
      }
      case 12: {
        const out: number[] = [];
        for (let i = 0; i < components; i++) out.push(this.view.getFloat64(offset + i * 8, le));
        return components === 1 ? out[0] : out;
      }
      default:
        return undefined;
    }
  }
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

const asNumber = (value: TagValue | undefined): number | undefined =>
  typeof value === 'number' ? value : undefined;

const asString = (value: TagValue | undefined): string | undefined =>
  typeof value === 'string' ? value.trim() || undefined : undefined;

/** EXIF dates are `YYYY:MM:DD HH:MM:SS` with no timezone. */
function exifDateToIso(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const match = /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(value);
  if (!match) return undefined;
  const [, y, mo, d, h, mi, s] = match;
  return `${y}-${mo}-${d}T${h}:${mi}:${s}`;
}

/** Degrees/minutes/seconds triple plus a hemisphere letter to signed degrees. */
function dmsToDegrees(dms: TagValue | undefined, ref: string | undefined): number | undefined {
  if (!Array.isArray(dms) || dms.length < 3) return undefined;
  const degrees = dms[0] + dms[1] / 60 + dms[2] / 3600;
  if (!Number.isFinite(degrees)) return undefined;
  // The magnitude is unsigned; the hemisphere lives in a separate tag.
  const negative = ref === 'S' || ref === 'W';
  return negative ? -degrees : degrees;
}

export function parseExif(exifBytes: Uint8Array): ImageMetadata {
  const reader = new TiffReader(exifBytes);
  const { tags: ifd0 } = reader.readIfd(reader.firstIfdOffset);

  const camera: CameraMetadata = {
    make: asString(ifd0.get(TAG.MAKE)),
    model: asString(ifd0.get(TAG.MODEL)),
    orientation: asNumber(ifd0.get(TAG.ORIENTATION)),
    imageWidth: asNumber(ifd0.get(TAG.IMAGE_WIDTH)),
    imageHeight: asNumber(ifd0.get(TAG.IMAGE_HEIGHT)),
  };

  // The EXIF sub-IFD holds nearly everything useful.
  const exifOffset = asNumber(ifd0.get(TAG.EXIF_IFD));
  let exifTags = new Map<number, TagValue>();
  if (exifOffset !== undefined) {
    exifTags = reader.readIfd(exifOffset).tags;
    camera.focalLength = asNumber(exifTags.get(TAG.FOCAL_LENGTH));
    camera.focalLength35mm = asNumber(exifTags.get(TAG.FOCAL_LENGTH_35MM));
    camera.exposureTime = asNumber(exifTags.get(TAG.EXPOSURE_TIME));
    camera.fNumber = asNumber(exifTags.get(TAG.F_NUMBER));
    camera.iso = asNumber(exifTags.get(TAG.ISO));
    camera.captureTime = exifDateToIso(asString(exifTags.get(TAG.DATE_TIME_ORIGINAL)));
    camera.imageWidth = asNumber(exifTags.get(TAG.PIXEL_X_DIMENSION)) ?? camera.imageWidth;
    camera.imageHeight = asNumber(exifTags.get(TAG.PIXEL_Y_DIMENSION)) ?? camera.imageHeight;
  }

  // Sensor width, in descending order of reliability.
  camera.sensorWidth = deriveSensorWidth(camera, exifTags);

  const metadata: ImageMetadata = { camera };

  const gpsOffset = asNumber(ifd0.get(TAG.GPS_IFD));
  if (gpsOffset !== undefined) {
    const { tags } = reader.readIfd(gpsOffset);
    const lat = dmsToDegrees(tags.get(GPS_TAG.LAT), asString(tags.get(GPS_TAG.LAT_REF)));
    const lon = dmsToDegrees(tags.get(GPS_TAG.LON), asString(tags.get(GPS_TAG.LON_REF)));

    if (lat !== undefined && lon !== undefined) {
      // AltitudeRef 1 means below sea level, and the altitude itself is
      // unsigned — the same trap as the hemisphere.
      const belowSeaLevel = asNumber(tags.get(GPS_TAG.ALTITUDE_REF)) === 1;
      const rawAltitude = asNumber(tags.get(GPS_TAG.ALTITUDE));

      const gps: GpsPosition = { lat, lon };
      if (rawAltitude !== undefined) {
        gps.altitude = belowSeaLevel ? -rawAltitude : rawAltitude;
        gps.belowSeaLevel = belowSeaLevel;
      }
      const error = asNumber(tags.get(GPS_TAG.HORIZONTAL_ERROR));
      if (error !== undefined) gps.horizontalError = error;

      // GPS time is UTC and split across two tags.
      const date = asString(tags.get(GPS_TAG.DATE_STAMP));
      const time = tags.get(GPS_TAG.TIME_STAMP);
      if (date && Array.isArray(time) && time.length >= 3) {
        const pad = (n: number) => String(Math.floor(n)).padStart(2, '0');
        gps.timestamp =
          `${date.replace(/:/g, '-')}T${pad(time[0])}:${pad(time[1])}:${pad(time[2])}Z`;
      }
      metadata.gps = gps;
    }
  }

  return metadata;
}

/**
 * Physical sensor width in millimetres.
 *
 * Needed to turn a focal length in millimetres into one in pixels, which is
 * what a camera model actually wants. Three routes, best first:
 *
 * 1. Focal plane resolution — the sensor's own pixel pitch. Exact when present.
 * 2. The 35 mm equivalent focal length, which implies a crop factor.
 * 3. A lookup for drones that report neither, which is most of them.
 */
function deriveSensorWidth(
  camera: CameraMetadata,
  exifTags: Map<number, TagValue>,
): number | undefined {
  const resolution = asNumber(exifTags.get(TAG.FOCAL_PLANE_X_RESOLUTION));
  const unit = asNumber(exifTags.get(TAG.FOCAL_PLANE_RESOLUTION_UNIT));
  if (resolution && resolution > 0 && camera.imageWidth) {
    // Unit 2 is inches, 3 is centimetres, 4 millimetres. 2 is the common case.
    const millimetresPerUnit = unit === 3 ? 10 : unit === 4 ? 1 : 25.4;
    const width = (camera.imageWidth / resolution) * millimetresPerUnit;
    if (width > 1 && width < 100) return width;
  }

  if (camera.focalLength && camera.focalLength35mm && camera.focalLength35mm > 0) {
    // A full frame is 36 mm wide; the ratio of focal lengths is the crop factor.
    const cropFactor = camera.focalLength35mm / camera.focalLength;
    if (cropFactor > 0.5 && cropFactor < 20) return 36 / cropFactor;
  }

  const model = camera.model?.toUpperCase();
  if (model) {
    for (const [key, width] of Object.entries(DRONE_SENSOR_WIDTHS)) {
      if (model.includes(key)) return width;
    }
  }
  return undefined;
}

/**
 * Sensor widths for drones that report neither focal plane resolution nor a
 * 35 mm equivalent. Millimetres.
 *
 * A wrong entry here is a wrong focal length, which SfM will partly absorb into
 * a wrong scale — so these are only a fallback, and the solve refines them.
 */
const DRONE_SENSOR_WIDTHS: Record<string, number> = {
  'FC220': 6.16, // Mavic Pro
  'FC330': 6.17, // Phantom 4
  'FC6310': 13.2, // Phantom 4 Pro
  'FC6360': 13.2, // Phantom 4 Multispectral
  'FC3170': 6.16, // Mavic Air 2
  'FC3411': 17.3, // Air 2S
  'FC7303': 6.4, // Mini 2
  'L1D-20C': 13.2, // Mavic 2 Pro (Hasselblad)
  'M3M': 17.3, // Mavic 3 Multispectral
  'M3E': 17.3, // Mavic 3 Enterprise
  'ZENMUSE P1': 35.9,
  'ZENMUSE L2': 17.3,
};

// ---------------------------------------------------------------------------
// XMP
// ---------------------------------------------------------------------------

/**
 * Pull a value from an XMP packet, trying both the attribute and element forms.
 *
 * XMP permits the same property as either an attribute on `rdf:Description` or
 * a child element, and DJI has used both across firmware generations. Handling
 * only one silently loses attitude on half the fleet.
 */
function xmpValue(xmp: string, name: string): string | undefined {
  const attribute = new RegExp(`${name}\\s*=\\s*"([^"]*)"`, 'i').exec(xmp);
  if (attribute) return attribute[1];
  const element = new RegExp(`<${name}>([^<]*)</${name}>`, 'i').exec(xmp);
  if (element) return element[1];
  return undefined;
}

function xmpNumber(xmp: string, name: string): number | undefined {
  const raw = xmpValue(xmp, name);
  if (raw === undefined) return undefined;
  // DJI writes explicit plus signs: "+12.30".
  const value = Number(raw.trim().replace(/^\+/, ''));
  return Number.isFinite(value) ? value : undefined;
}

export function parseXmp(xmp: string): DroneAttitude {
  const attitude: DroneAttitude = {
    gimbalYaw: xmpNumber(xmp, 'drone-dji:GimbalYawDegree'),
    gimbalPitch: xmpNumber(xmp, 'drone-dji:GimbalPitchDegree'),
    gimbalRoll: xmpNumber(xmp, 'drone-dji:GimbalRollDegree'),
    flightYaw: xmpNumber(xmp, 'drone-dji:FlightYawDegree'),
    flightPitch: xmpNumber(xmp, 'drone-dji:FlightPitchDegree'),
    flightRoll: xmpNumber(xmp, 'drone-dji:FlightRollDegree'),
    relativeAltitude: xmpNumber(xmp, 'drone-dji:RelativeAltitude'),
    absoluteAltitude: xmpNumber(xmp, 'drone-dji:AbsoluteAltitude'),
  };

  const rtk = xmpValue(xmp, 'drone-dji:RtkFlag');
  if (rtk !== undefined) attitude.rtkFlag = rtk.trim() !== '0';

  // Strip the keys that were absent so callers can test with `in`.
  for (const key of Object.keys(attitude) as (keyof DroneAttitude)[]) {
    if (attitude[key] === undefined) delete attitude[key];
  }
  return attitude;
}

/** Read everything this module understands from a JPEG. */
export function readImageMetadata(bytes: Uint8Array): ImageMetadata {
  const segments = readJpegSegments(bytes);

  let metadata: ImageMetadata = { camera: {} };
  if (segments.exif) {
    try {
      metadata = parseExif(segments.exif);
    } catch {
      // A malformed EXIF block should not lose the XMP alongside it — the
      // attitude is often the more useful half for a drone image.
    }
  }

  const xmp = (segments.xmp ?? '') + (segments.extendedXmp ?? '');
  if (xmp) {
    metadata.xmp = xmp;
    const drone = parseXmp(xmp);
    if (Object.keys(drone).length > 0) metadata.drone = drone;
  }

  return metadata;
}

/**
 * Focal length in pixels, which is what a pinhole camera model needs.
 *
 * Returns undefined rather than guessing when the sensor width is unknown. A
 * fabricated focal length produces a reconstruction that is self-consistent and
 * the wrong scale, which is worse than refusing — SfM can solve for focal
 * length, but only if it is told the value is unknown.
 */
export function focalLengthInPixels(camera: CameraMetadata): number | undefined {
  if (!camera.imageWidth) return undefined;

  if (camera.focalLength && camera.sensorWidth) {
    return (camera.focalLength / camera.sensorWidth) * camera.imageWidth;
  }
  if (camera.focalLength35mm) {
    // The 35 mm equivalent is defined against a 36 mm frame width.
    return (camera.focalLength35mm / 36) * camera.imageWidth;
  }
  return undefined;
}
