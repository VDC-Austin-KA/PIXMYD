/**
 * LAS 1.4 writer (ASPRS LiDAR exchange format).
 *
 * LAS earns its place for two reasons. It is the format survey and GIS software
 * expects — QGIS, ArcGIS, Civil 3D, PDAL, LAStools all read it natively — and it
 * is the most reliable route into Autodesk ReCap, and therefore into RCS/RCP,
 * which have no public specification. See docs/formats.md.
 *
 * The design decision that matters: LAS stores coordinates as **32-bit signed
 * integers** with a scale and offset applied by the reader:
 *
 *     world = raw * scale + offset
 *
 * That is a feature, not a limitation. An int32 with a 0.001 scale spans
 * +/- 2147 km at exactly millimetre resolution, everywhere in that range —
 * unlike float32, whose resolution collapses to a foot at Texas State Plane
 * northings. Choosing scale and offset well is the whole job, so this writer
 * derives them from the data rather than guessing.
 */

import { ByteWriter } from '@pixmyd/core/bytes';
import type { PointCloud } from '@pixmyd/core/bundle';
import type { Vec3 } from '@pixmyd/core/math';

const HEADER_SIZE_1_4 = 375;

export interface LasWriteOptions {
  /**
   * Quantisation step in metres per axis. 0.001 (1 mm) is the default and is
   * right for terrestrial capture; use 0.0001 for metrology-scale work with a
   * correspondingly smaller extent.
   */
  scale?: Vec3 | number;
  /**
   * World-coordinate offset. Defaults to the cloud's origin, or to the rounded
   * centre of the data when there is none.
   */
  offset?: Vec3;
  /**
   * Point Data Record Format. 2 carries RGB, 3 adds GPS time, 6-8 are the
   * LAS 1.4 formats with a wider return field. Defaults to 3 with colour and
   * time, or 1 without colour.
   */
  format?: 0 | 1 | 2 | 3;
  systemIdentifier?: string;
  generatingSoftware?: string;
  /** Coordinate system as WKT. LAS 1.4 mandates WKT for formats 6 and above. */
  wkt?: string;
}

function normalizeScale(scale: Vec3 | number | undefined): Vec3 {
  if (scale === undefined) return [0.001, 0.001, 0.001];
  return typeof scale === 'number' ? [scale, scale, scale] : scale;
}

/**
 * Pick an offset that keeps every quantised coordinate inside int32.
 *
 * `world` here is already origin-corrected — a PointCloud with an `origin` set
 * stores coordinates relative to it, so world = stored + origin. When there is
 * an origin it is also the natural LAS offset, which makes the stored int32s
 * exactly the local coordinates and keeps the header readable next to a control
 * sheet. Otherwise the offset is the rounded centre of the data.
 */
function chooseOffset(world: Float64Array, count: number, cloud: PointCloud, explicit?: Vec3): Vec3 {
  if (explicit) return explicit;
  if (cloud.origin) return cloud.origin;
  if (count === 0) return [0, 0, 0];
  const min: Vec3 = [Infinity, Infinity, Infinity];
  const max: Vec3 = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < count; i++) {
    for (let a = 0; a < 3; a++) {
      const v = world[i * 3 + a];
      if (v < min[a]) min[a] = v;
      if (v > max[a]) max[a] = v;
    }
  }
  return [
    Math.round((min[0] + max[0]) / 2),
    Math.round((min[1] + max[1]) / 2),
    Math.round((min[2] + max[2]) / 2),
  ];
}

export function writeLas(cloud: PointCloud, options: LasWriteOptions = {}): Uint8Array {
  const scale = normalizeScale(options.scale);

  // Resolve stored coordinates to world coordinates once, up front. A cloud
  // carrying an `origin` stores local offsets from it; everything below —
  // bounds, offset choice, quantisation — has to work in one consistent frame,
  // and mixing the two silently doubles the origin.
  const shift = cloud.origin ?? [0, 0, 0];
  const world = new Float64Array(cloud.count * 3);
  for (let i = 0; i < cloud.count; i++) {
    world[i * 3] = cloud.positions[i * 3] + shift[0];
    world[i * 3 + 1] = cloud.positions[i * 3 + 1] + shift[1];
    world[i * 3 + 2] = cloud.positions[i * 3 + 2] + shift[2];
  }

  const offset = chooseOffset(world, cloud.count, cloud, options.offset);
  const hasColor = cloud.colors !== undefined;
  const hasTime = cloud.timestamps !== undefined;

  const format =
    options.format ?? (hasColor ? (hasTime ? 3 : 2) : hasTime ? 1 : 0);

  // Base record: x,y,z (12) + intensity (2) + flags (1) + classification (1)
  // + scan angle (1) + user data (1) + point source id (2) = 20 bytes.
  let recordLength = 20;
  if (format === 1 || format === 3) recordLength += 8; // GPS time
  if (format === 2 || format === 3) recordLength += 6; // RGB, 16 bits per channel

  // --- bounds, in world units ---
  const min: Vec3 = [Infinity, Infinity, Infinity];
  const max: Vec3 = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < cloud.count; i++) {
    for (let a = 0; a < 3; a++) {
      const v = world[i * 3 + a];
      if (v < min[a]) min[a] = v;
      if (v > max[a]) max[a] = v;
    }
  }
  if (cloud.count === 0) {
    min[0] = min[1] = min[2] = 0;
    max[0] = max[1] = max[2] = 0;
  }

  // Refuse rather than silently wrapping: an int32 overflow here produces points
  // on the far side of the world, and LAS has no way to signal it happened.
  for (let a = 0; a < 3; a++) {
    for (const bound of [min[a], max[a]]) {
      const raw = (bound - offset[a]) / scale[a];
      if (!Number.isFinite(raw) || Math.abs(raw) > 2147483647) {
        throw new Error(
          `LAS: axis ${'xyz'[a]} value ${bound} does not fit int32 at ` +
          `scale ${scale[a]} offset ${offset[a]}. Increase the scale or set an offset.`,
        );
      }
    }
  }

  const w = new ByteWriter(HEADER_SIZE_1_4 + cloud.count * recordLength + 64);

  // --- public header block ---
  w.ascii('LASF');
  w.u16(0); // file source id
  w.u16(options.wkt ? 0x10 : 0); // global encoding: bit 4 = CRS is WKT
  w.u32(0).u16(0).u16(0); // project guid (16 bytes)
  w.fill(0, 8);
  w.u8(1).u8(4); // version 1.4
  const pad = (s: string, n: number): string => s.slice(0, n).padEnd(n, '\0');
  w.ascii(pad(options.systemIdentifier ?? 'PIXMYD', 32));
  w.ascii(pad(options.generatingSoftware ?? 'PIXMYD', 32));

  const now = new Date();
  const startOfYear = Date.UTC(now.getUTCFullYear(), 0, 1);
  const dayOfYear = Math.floor((now.getTime() - startOfYear) / 86400000) + 1;
  w.u16(dayOfYear).u16(now.getUTCFullYear());

  w.u16(HEADER_SIZE_1_4);
  const offsetToDataAt = w.length;
  w.u32(0); // offset to point data, patched below
  w.u32(0); // number of variable length records, patched below
  w.u8(format);
  w.u16(recordLength);
  // Legacy point count: LAS 1.4 keeps these for 1.2 readers, and requires zero
  // when the format is 6 or above. Formats 0-3 must populate them.
  w.u32(Math.min(cloud.count, 0xffffffff));
  for (let i = 0; i < 5; i++) w.u32(i === 0 ? Math.min(cloud.count, 0xffffffff) : 0);

  for (let a = 0; a < 3; a++) w.f64(scale[a]);
  for (let a = 0; a < 3; a++) w.f64(offset[a]);
  // Header order is maxX, minX, maxY, minY, maxZ, minZ — max first, which is
  // the opposite of every other bounds record in this repo.
  for (let a = 0; a < 3; a++) {
    w.f64(max[a]);
    w.f64(min[a]);
  }

  w.u64(0); // start of waveform data packet record
  w.u64(0); // start of first extended VLR
  w.u32(0); // number of extended VLRs
  w.u64(cloud.count); // 1.4 64-bit point count
  for (let i = 0; i < 15; i++) w.u64(i === 0 ? cloud.count : 0);

  if (w.length !== HEADER_SIZE_1_4) {
    throw new Error(`LAS: header is ${w.length} bytes, expected ${HEADER_SIZE_1_4}`);
  }

  // --- variable length records ---
  let vlrCount = 0;
  if (options.wkt) {
    const payload = new TextEncoder().encode(options.wkt + '\0');
    w.u16(0); // reserved
    w.ascii(pad('LASF_Projection', 16));
    w.u16(2112); // OGC coordinate system WKT
    w.u16(payload.length);
    w.ascii(pad('PIXMYD CRS', 32));
    w.bytes(payload);
    vlrCount++;
  }
  w.patchU32(offsetToDataAt + 4, vlrCount);
  w.patchU32(offsetToDataAt, w.length);

  // --- point records ---
  const invScale: Vec3 = [1 / scale[0], 1 / scale[1], 1 / scale[2]];
  for (let i = 0; i < cloud.count; i++) {
    for (let a = 0; a < 3; a++) {
      w.i32(Math.round((world[i * 3 + a] - offset[a]) * invScale[a]));
    }
    // Intensity is a uint16 in LAS; PointCloud carries it normalized.
    const intensity = cloud.intensity
      ? Math.max(0, Math.min(65535, Math.round(cloud.intensity[i] * 65535)))
      : 0;
    w.u16(intensity);
    // Return number 1 of 1, no scan-edge or flight-line flags.
    w.u8(0b00001001);
    w.u8(0); // classification: 0 = created, never classified
    w.i8(0); // scan angle rank
    w.u8(0); // user data
    w.u16(0); // point source id

    if (format === 1 || format === 3) {
      w.f64(cloud.timestamps ? cloud.timestamps[i] : 0);
    }
    if (format === 2 || format === 3) {
      // LAS colour is 16-bit per channel. Scaling by 257 maps 255 to 65535
      // exactly, which multiplying by 256 does not.
      const c = cloud.colors!;
      w.u16(c[i * 3] * 257).u16(c[i * 3 + 1] * 257).u16(c[i * 3 + 2] * 257);
    }
  }

  return w.finish();
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

export interface LasHeader {
  versionMajor: number;
  versionMinor: number;
  pointDataFormat: number;
  pointDataRecordLength: number;
  pointCount: number;
  scale: Vec3;
  offset: Vec3;
  min: Vec3;
  max: Vec3;
  offsetToPointData: number;
  systemIdentifier: string;
  generatingSoftware: string;
}

export function readLasHeader(bytes: Uint8Array): LasHeader {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (new TextDecoder().decode(bytes.subarray(0, 4)) !== 'LASF') {
    throw new Error('LAS: bad signature');
  }
  const trim = (s: string) => s.replace(/\0.*$/, '');
  const legacyCount = v.getUint32(107, true);
  const versionMinor = v.getUint8(25);
  return {
    versionMajor: v.getUint8(24),
    versionMinor,
    systemIdentifier: trim(new TextDecoder().decode(bytes.subarray(26, 58))),
    generatingSoftware: trim(new TextDecoder().decode(bytes.subarray(58, 90))),
    offsetToPointData: v.getUint32(96, true),
    pointDataFormat: v.getUint8(104),
    pointDataRecordLength: v.getUint16(105, true),
    // 1.4 moved the authoritative count to a 64-bit field at byte 247.
    pointCount: versionMinor >= 4 ? Number(v.getBigUint64(247, true)) : legacyCount,
    scale: [v.getFloat64(131, true), v.getFloat64(139, true), v.getFloat64(147, true)],
    offset: [v.getFloat64(155, true), v.getFloat64(163, true), v.getFloat64(171, true)],
    max: [v.getFloat64(179, true), v.getFloat64(195, true), v.getFloat64(211, true)],
    min: [v.getFloat64(187, true), v.getFloat64(203, true), v.getFloat64(219, true)],
  };
}

export function readLas(bytes: Uint8Array): PointCloud {
  const header = readLasHeader(bytes);
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const n = header.pointCount;
  const positions = new Float64Array(n * 3);
  const format = header.pointDataFormat;
  const hasColor = format === 2 || format === 3;
  const hasTime = format === 1 || format === 3;
  const colors = hasColor ? new Uint8Array(n * 3) : undefined;
  const intensity = new Float32Array(n);
  const timestamps = hasTime ? new Float64Array(n) : undefined;

  for (let i = 0; i < n; i++) {
    const at = header.offsetToPointData + i * header.pointDataRecordLength;
    for (let a = 0; a < 3; a++) {
      positions[i * 3 + a] = v.getInt32(at + a * 4, true) * header.scale[a] + header.offset[a];
    }
    intensity[i] = v.getUint16(at + 12, true) / 65535;
    let cursor = at + 20;
    if (hasTime) {
      timestamps![i] = v.getFloat64(cursor, true);
      cursor += 8;
    }
    if (hasColor) {
      colors![i * 3] = Math.round(v.getUint16(cursor, true) / 257);
      colors![i * 3 + 1] = Math.round(v.getUint16(cursor + 2, true) / 257);
      colors![i * 3 + 2] = Math.round(v.getUint16(cursor + 4, true) / 257);
    }
  }

  const cloud: PointCloud = { positions, count: n, intensity };
  if (colors) cloud.colors = colors;
  if (timestamps) cloud.timestamps = timestamps;
  return cloud;
}
