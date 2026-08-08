/**
 * E57 writer (ASTM E2807).
 *
 * E57 is the point-cloud format that actually crosses vendor boundaries —
 * ReCap, Cyclone, CloudCompare, PDAL, FME and Revit all read it — and unlike
 * PLY it carries a georeference, per-scan poses, and per-point provenance.
 *
 * The file is three layers stacked, and all three have to be right:
 *
 *   1. Paging.  The physical file is 1024-byte pages: 1020 bytes of payload
 *      followed by a little-endian CRC-32C of those 1020 bytes. Every offset
 *      stored in the file is either "logical" (ignoring CRC bytes) or
 *      "physical" (counting them), and mixing them up is the classic way to
 *      produce a file that opens in nothing.
 *
 *   2. XML.  A tree at the end of the file describing the scans, their poses,
 *      bounds, and the *prototype* — the record layout of the point data.
 *
 *   3. CompressedVector.  The binary point data, as a section header followed
 *      by data packets. Each packet holds one bytestream per prototype field.
 *
 * Field encoding here is deliberately restricted to byte-aligned widths —
 * doubles for coordinates, 8-bit integers for colour, floats for intensity.
 * E57's bitpack codec can use arbitrary bit widths, but byte alignment means
 * no bit-level carry state between packets, which removes an entire class of
 * off-by-one corruption for a few percent of file size.
 */

import { ByteWriter } from '@pixmyd/core/bytes';
import type { CrsBlock, PointCloud } from '@pixmyd/core/bundle';
import type { Quat, Vec3 } from '@pixmyd/core/math';

const PAGE_SIZE = 1024;
const LOGICAL_PAGE_SIZE = 1020;
const FILE_HEADER_SIZE = 48;
const COMPRESSED_VECTOR_SECTION = 1;
const DATA_PACKET = 1;
/** Packet length is a uint16 stored minus one, so 64 KiB is the ceiling. */
const DATA_PACKET_MAX = 64 * 1024;

// ---------------------------------------------------------------------------
// CRC-32C (Castagnoli)
// ---------------------------------------------------------------------------

/**
 * E57 uses CRC-32C, not the CRC-32 of zip and PNG. Same structure, different
 * polynomial: 0x1EDC6F41, or 0x82F63B78 in the reflected form used here.
 * A file checksummed with the wrong one is rejected by every conforming reader.
 */
const CRC32C_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0x82f63b78 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

export function crc32c(bytes: Uint8Array, start = 0, end = bytes.length): number {
  let crc = 0xffffffff;
  for (let i = start; i < end; i++) {
    crc = CRC32C_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// ---------------------------------------------------------------------------
// Logical <-> physical addressing
// ---------------------------------------------------------------------------

/** Physical offset of a logical byte, accounting for the 4-byte CRC on each page. */
export function logicalToPhysical(logical: number): number {
  const page = Math.floor(logical / LOGICAL_PAGE_SIZE);
  return page * PAGE_SIZE + (logical % LOGICAL_PAGE_SIZE);
}

export function physicalToLogical(physical: number): number {
  const page = Math.floor(physical / PAGE_SIZE);
  return page * LOGICAL_PAGE_SIZE + (physical % PAGE_SIZE);
}

/** Split the logical stream into CRC-checked pages. The last page is zero-filled. */
export function paginate(logical: Uint8Array): Uint8Array {
  const pageCount = Math.max(1, Math.ceil(logical.length / LOGICAL_PAGE_SIZE));
  const out = new Uint8Array(pageCount * PAGE_SIZE);
  const view = new DataView(out.buffer);
  for (let p = 0; p < pageCount; p++) {
    const src = p * LOGICAL_PAGE_SIZE;
    const dst = p * PAGE_SIZE;
    const n = Math.min(LOGICAL_PAGE_SIZE, Math.max(0, logical.length - src));
    out.set(logical.subarray(src, src + n), dst);
    // Trailing bytes of the final page stay zero and are covered by the CRC.
    view.setUint32(dst + LOGICAL_PAGE_SIZE, crc32c(out, dst, dst + LOGICAL_PAGE_SIZE), true);
  }
  return out;
}

/** Verify and strip the paging layer. Used by the reader and by the tests. */
export function depaginate(physical: Uint8Array, { verify = true } = {}): Uint8Array {
  if (physical.length % PAGE_SIZE !== 0) {
    throw new Error(`E57: file length ${physical.length} is not a multiple of ${PAGE_SIZE}`);
  }
  const pageCount = physical.length / PAGE_SIZE;
  const out = new Uint8Array(pageCount * LOGICAL_PAGE_SIZE);
  const view = new DataView(physical.buffer, physical.byteOffset, physical.byteLength);
  for (let p = 0; p < pageCount; p++) {
    const src = p * PAGE_SIZE;
    if (verify) {
      const stored = view.getUint32(src + LOGICAL_PAGE_SIZE, true);
      const actual = crc32c(physical, src, src + LOGICAL_PAGE_SIZE);
      if (stored !== actual) {
        throw new Error(
          `E57: checksum mismatch on page ${p} ` +
          `(stored 0x${stored.toString(16)}, computed 0x${actual.toString(16)})`,
        );
      }
    }
    out.set(physical.subarray(src, src + LOGICAL_PAGE_SIZE), p * LOGICAL_PAGE_SIZE);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Prototype fields
// ---------------------------------------------------------------------------

type FieldEncoding =
  | { kind: 'float'; precision: 'single' | 'double' }
  | { kind: 'integer'; min: number; max: number };

interface E57Field {
  name: string;
  encoding: FieldEncoding;
  /** Bytes per record. Restricted to 1, 2, 4 or 8 so packets stay byte-aligned. */
  width: number;
  read: (index: number) => number;
  /** Reported in the prototype so readers can size their buffers. */
  min?: number;
  max?: number;
}

function fieldWidth(encoding: FieldEncoding): number {
  if (encoding.kind === 'float') return encoding.precision === 'double' ? 8 : 4;
  const span = encoding.max - encoding.min;
  if (span <= 0xff) return 1;
  if (span <= 0xffff) return 2;
  if (span <= 0xffffffff) return 4;
  return 8;
}

function encodeField(field: E57Field, start: number, count: number): Uint8Array {
  const out = new Uint8Array(count * field.width);
  const view = new DataView(out.buffer);
  const { encoding, width } = field;
  for (let i = 0; i < count; i++) {
    const v = field.read(start + i);
    if (encoding.kind === 'float') {
      if (width === 8) view.setFloat64(i * 8, v, true);
      else view.setFloat32(i * 4, v, true);
    } else {
      // Integers are stored as the offset from the declared minimum.
      const raw = Math.round(v) - encoding.min;
      switch (width) {
        case 1: view.setUint8(i, raw); break;
        case 2: view.setUint16(i * 2, raw, true); break;
        case 4: view.setUint32(i * 4, raw >>> 0, true); break;
        default: view.setBigUint64(i * 8, BigInt(raw), true); break;
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// XML
// ---------------------------------------------------------------------------

function xmlEscape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function stringNode(name: string, value: string, indent: string): string {
  // CDATA cannot contain "]]>", so split any occurrence across two sections.
  const safe = value.replace(/]]>/g, ']]]]><![CDATA[>');
  return `${indent}<${name} type="String"><![CDATA[${safe}]]></${name}>`;
}

function floatNode(name: string, value: number, indent: string): string {
  return `${indent}<${name} type="Float" precision="double">${value}</${name}>`;
}

function prototypeXml(fields: E57Field[], indent: string): string {
  return fields
    .map((f) => {
      if (f.encoding.kind === 'float') {
        const attrs =
          `type="Float" precision="${f.encoding.precision}"` +
          (f.min !== undefined ? ` minimum="${f.min}" maximum="${f.max}"` : '');
        return `${indent}<${f.name} ${attrs}/>`;
      }
      return (
        `${indent}<${f.name} type="Integer" ` +
        `minimum="${f.encoding.min}" maximum="${f.encoding.max}"/>`
      );
    })
    .join('\n');
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

export interface E57Scan {
  /** Point data. Coordinates are relative to `cloud.origin` if it is set. */
  cloud: PointCloud;
  name?: string;
  guid?: string;
  /**
   * Sensor pose for this scan, applied by the reader on top of the stored
   * coordinates. Leave unset for an already-registered cloud.
   */
  pose?: { translation: Vec3; rotation: Quat };
  /** Where the scanner stood, if it is meaningful. Written as acquisitionStart. */
  acquisitionStart?: string;
  sensorModel?: string;
  sensorVendor?: string;
}

export interface E57WriteOptions {
  /** File-level guid. Generated if absent. */
  guid?: string;
  /**
   * Free-text coordinate system description. Conventionally a WKT or PROJ
   * string. Readers will not reproject from it, but a surveyor opening the file
   * needs to know what frame the numbers are in.
   */
  coordinateMetadata?: string;
  /** float32 coordinates halve the file. Only safe for local, small-extent data. */
  coordinatePrecision?: 'single' | 'double';
  /** Fixed guid generator, so a test can produce byte-identical output. */
  makeGuid?: () => string;
}

function defaultGuid(): string {
  return `{${crypto.randomUUID().toUpperCase()}}`;
}

function buildFields(cloud: PointCloud, precision: 'single' | 'double'): E57Field[] {
  const fields: E57Field[] = [];
  const axes = ['cartesianX', 'cartesianY', 'cartesianZ'];
  for (let a = 0; a < 3; a++) {
    let min = Infinity;
    let max = -Infinity;
    for (let i = 0; i < cloud.count; i++) {
      const v = cloud.positions[i * 3 + a];
      if (v < min) min = v;
      if (v > max) max = v;
    }
    if (cloud.count === 0) {
      min = 0;
      max = 0;
    }
    const encoding: FieldEncoding = { kind: 'float', precision };
    fields.push({
      name: axes[a],
      encoding,
      width: fieldWidth(encoding),
      min,
      max,
      read: (i) => cloud.positions[i * 3 + a],
    });
  }

  if (cloud.colors) {
    const channels = ['colorRed', 'colorGreen', 'colorBlue'];
    for (let c = 0; c < 3; c++) {
      const encoding: FieldEncoding = { kind: 'integer', min: 0, max: 255 };
      fields.push({
        name: channels[c],
        encoding,
        width: fieldWidth(encoding),
        read: (i) => cloud.colors![i * 3 + c],
      });
    }
  }

  if (cloud.intensity) {
    const encoding: FieldEncoding = { kind: 'float', precision: 'single' };
    fields.push({
      name: 'intensity',
      encoding,
      width: fieldWidth(encoding),
      min: 0,
      max: 1,
      read: (i) => cloud.intensity![i],
    });
  }

  return fields;
}

interface BuiltSection {
  bytes: Uint8Array;
  /** Offset within `bytes` of the dataPhysicalOffset field, patched once placed. */
  dataOffsetAt: number;
}

/** Serialize one CompressedVector section: 32-byte header plus data packets. */
function buildSection(fields: E57Field[], recordCount: number): BuiltSection {
  const w = new ByteWriter(1 << 16);

  // Section header, back-patched once the packets are laid out.
  w.u8(COMPRESSED_VECTOR_SECTION).fill(0, 7);
  const sectionLengthAt = w.length;
  w.u64(0);
  const dataOffsetAt = w.length;
  w.u64(0); // dataPhysicalOffset, patched by the caller which knows our placement
  w.u64(0); // indexPhysicalOffset: no index packets are written

  const bytesPerRecord = fields.reduce((sum, f) => sum + f.width, 0);
  const headerBytes = 6 + 2 * fields.length;
  // Leave room for the 4-byte alignment pad, then round down to whole records.
  let recordsPerPacket = Math.floor((DATA_PACKET_MAX - headerBytes - 4) / bytesPerRecord);
  // Each bytestream length is a uint16, so no single field may exceed 65535 bytes.
  for (const f of fields) {
    recordsPerPacket = Math.min(recordsPerPacket, Math.floor(0xffff / f.width));
  }
  recordsPerPacket = Math.max(1, recordsPerPacket);

  for (let start = 0; start < recordCount; start += recordsPerPacket) {
    const count = Math.min(recordsPerPacket, recordCount - start);
    const streams = fields.map((f) => encodeField(f, start, count));

    const payload = streams.reduce((sum, s) => sum + s.length, 0);
    const unpadded = headerBytes + payload;
    const padded = Math.ceil(unpadded / 4) * 4;
    if (padded > DATA_PACKET_MAX) {
      throw new Error(`E57: packet of ${padded} bytes exceeds the 64 KiB limit`);
    }

    w.u8(DATA_PACKET);
    w.u8(0); // packetFlags
    w.u16(padded - 1); // packetLogicalLengthMinus1
    w.u16(fields.length);
    for (const s of streams) w.u16(s.length);
    for (const s of streams) w.bytes(s);
    w.fill(0, padded - unpadded);
  }

  // sectionLogicalLength must be a multiple of 4 or readers reject the header.
  const sectionLength = Math.ceil(w.length / 4) * 4;
  w.fill(0, sectionLength - w.length);
  w.patchU64(sectionLengthAt, sectionLength);

  return { bytes: w.finish(), dataOffsetAt };
}

export function writeE57(scans: E57Scan[], options: E57WriteOptions = {}): Uint8Array {
  const makeGuid = options.makeGuid ?? defaultGuid;
  const precision = options.coordinatePrecision ?? 'double';

  // --- lay out the logical stream ---
  const logical = new ByteWriter(1 << 20);
  logical.fill(0, FILE_HEADER_SIZE); // header, patched at the end

  interface Placed {
    scan: E57Scan;
    fields: E57Field[];
    sectionLogicalOffset: number;
    guid: string;
  }
  const placed: Placed[] = [];

  for (const input of scans) {
    // Sections start on a 4-byte boundary.
    logical.align(4);
    // A cloud carrying an `origin` stores local coordinates. E57's own mechanism
    // for that is the scan pose, which readers apply — so the origin becomes a
    // pose translation rather than a note in the metadata. Keeping the stored
    // numbers small is also what protects them from float rounding.
    const scan: E57Scan =
      input.cloud.origin && !input.pose
        ? { ...input, pose: { translation: input.cloud.origin, rotation: [0, 0, 0, 1] } }
        : input;
    const fields = buildFields(scan.cloud, precision);
    const { bytes: section, dataOffsetAt } = buildSection(fields, scan.cloud.count);
    const sectionLogicalOffset = logical.length;

    // dataPhysicalOffset points at the first data packet, which sits immediately
    // after the 32-byte section header — expressed physically, not logically.
    const firstPacketLogical = sectionLogicalOffset + 32;
    new DataView(section.buffer, section.byteOffset, section.byteLength).setBigUint64(
      dataOffsetAt,
      BigInt(logicalToPhysical(firstPacketLogical)),
      true,
    );

    logical.bytes(section);
    placed.push({ scan, fields, sectionLogicalOffset, guid: scan.guid ?? makeGuid() });
  }

  // --- XML ---
  const fileGuid = options.guid ?? makeGuid();
  const xml: string[] = [];
  xml.push('<?xml version="1.0" encoding="UTF-8"?>');
  xml.push('<e57Root type="Structure" xmlns="http://www.astm.org/COMMIT/E57/2010-e57-v1.0">');
  xml.push(stringNode('formatName', 'ASTM E57 3D Imaging Data File', '  '));
  xml.push(stringNode('guid', fileGuid, '  '));
  xml.push('  <versionMajor type="Integer">1</versionMajor>');
  xml.push('  <versionMinor type="Integer">0</versionMinor>');
  xml.push(stringNode('e57LibraryVersion', 'PIXMYD', '  '));
  xml.push(stringNode('creationDateTime', new Date().toISOString(), '  '));
  if (options.coordinateMetadata) {
    xml.push(stringNode('coordinateMetadata', options.coordinateMetadata, '  '));
  }
  xml.push('  <data3D type="Vector" allowHeterogeneousChildren="1">');

  for (const p of placed) {
    const { scan, fields } = p;
    xml.push('    <vectorChild type="Structure">');
    xml.push(stringNode('guid', p.guid, '      '));
    xml.push(stringNode('name', scan.name ?? 'scan', '      '));
    if (scan.sensorVendor) xml.push(stringNode('sensorVendor', scan.sensorVendor, '      '));
    if (scan.sensorModel) xml.push(stringNode('sensorModel', scan.sensorModel, '      '));
    if (scan.acquisitionStart) {
      xml.push('      <acquisitionStart type="Structure">');
      xml.push(stringNode('dateTimeValue', scan.acquisitionStart, '        '));
      xml.push('      </acquisitionStart>');
    }

    if (scan.pose) {
      const [qx, qy, qz, qw] = scan.pose.rotation;
      const [tx, ty, tz] = scan.pose.translation;
      xml.push('      <pose type="Structure">');
      xml.push('        <rotation type="Structure">');
      xml.push(floatNode('w', qw, '          '));
      xml.push(floatNode('x', qx, '          '));
      xml.push(floatNode('y', qy, '          '));
      xml.push(floatNode('z', qz, '          '));
      xml.push('        </rotation>');
      xml.push('        <translation type="Structure">');
      xml.push(floatNode('x', tx, '          '));
      xml.push(floatNode('y', ty, '          '));
      xml.push(floatNode('z', tz, '          '));
      xml.push('        </translation>');
      xml.push('      </pose>');
    }

    xml.push('      <cartesianBounds type="Structure">');
    const axisNames = ['x', 'y', 'z'];
    for (let a = 0; a < 3; a++) {
      xml.push(floatNode(`${axisNames[a]}Minimum`, fields[a].min ?? 0, '        '));
      xml.push(floatNode(`${axisNames[a]}Maximum`, fields[a].max ?? 0, '        '));
    }
    xml.push('      </cartesianBounds>');

    const physical = logicalToPhysical(p.sectionLogicalOffset);
    xml.push(
      `      <points type="CompressedVector" fileOffset="${physical}" ` +
      `recordCount="${scan.cloud.count}">`,
    );
    xml.push('        <prototype type="Structure">');
    xml.push(prototypeXml(fields, '          '));
    xml.push('        </prototype>');
    xml.push('        <codecs type="Vector" allowHeterogeneousChildren="1"/>');
    xml.push('      </points>');
    xml.push('    </vectorChild>');
  }

  xml.push('  </data3D>');
  xml.push('  <images2D type="Vector" allowHeterogeneousChildren="1"/>');
  xml.push('</e57Root>');

  const xmlBytes = new TextEncoder().encode(xml.join('\n'));
  logical.align(4);
  const xmlLogicalOffset = logical.length;
  logical.bytes(xmlBytes);

  // --- patch the file header ---
  const stream = logical.subarray();
  const header = new DataView(stream.buffer, stream.byteOffset, FILE_HEADER_SIZE);
  const signature = new TextEncoder().encode('ASTM-E57');
  stream.set(signature, 0);
  header.setUint32(8, 1, true); // majorVersion
  header.setUint32(12, 0, true); // minorVersion
  const totalPhysical = Math.ceil(stream.length / LOGICAL_PAGE_SIZE) * PAGE_SIZE;
  header.setBigUint64(16, BigInt(totalPhysical), true); // filePhysicalLength
  header.setBigUint64(24, BigInt(logicalToPhysical(xmlLogicalOffset)), true);
  header.setBigUint64(32, BigInt(xmlBytes.length), true); // xmlLogicalLength
  header.setBigUint64(40, BigInt(PAGE_SIZE), true);

  return paginate(stream);
}

/** Convenience wrapper for the common case of one cloud, one file. */
export function writePointCloudE57(
  cloud: PointCloud,
  options: E57WriteOptions & { name?: string } = {},
): Uint8Array {
  const coordinateMetadata =
    options.coordinateMetadata ?? (cloud.crs ? describeCrs(cloud.crs, cloud.origin) : undefined);
  return writeE57([{ cloud, name: options.name ?? 'scan' }], {
    ...options,
    coordinateMetadata,
  });
}

function describeCrs(crs: CrsBlock, origin?: Vec3): string {
  const parts = [`code=${crs.code}`, `unit=${crs.unit}`, `metresPerUnit=${crs.metresPerUnit}`];
  if (crs.verticalDatum) parts.push(`verticalDatum=${crs.verticalDatum}`);
  if (crs.geoidModel) parts.push(`geoid=${crs.geoidModel}`);
  if (origin) parts.push(`localOrigin=${origin.join(',')}`);
  return parts.join('; ');
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

export interface E57Header {
  majorVersion: number;
  minorVersion: number;
  filePhysicalLength: number;
  xmlPhysicalOffset: number;
  xmlLogicalLength: number;
  pageSize: number;
}

export function readE57Header(physical: Uint8Array): E57Header {
  const signature = new TextDecoder().decode(physical.subarray(0, 8));
  if (signature !== 'ASTM-E57') throw new Error(`E57: bad signature "${signature}"`);
  const v = new DataView(physical.buffer, physical.byteOffset, physical.byteLength);
  return {
    majorVersion: v.getUint32(8, true),
    minorVersion: v.getUint32(12, true),
    filePhysicalLength: Number(v.getBigUint64(16, true)),
    xmlPhysicalOffset: Number(v.getBigUint64(24, true)),
    xmlLogicalLength: Number(v.getBigUint64(32, true)),
    pageSize: Number(v.getBigUint64(40, true)),
  };
}

export function readE57Xml(physical: Uint8Array): string {
  const header = readE57Header(physical);
  const logical = depaginate(physical);
  const start = physicalToLogical(header.xmlPhysicalOffset);
  return new TextDecoder().decode(logical.subarray(start, start + header.xmlLogicalLength));
}

/**
 * Read the points back. Deliberately narrow: it handles the subset this writer
 * produces (byte-aligned fields, no index packets), which is enough to prove
 * the write path round-trips and to re-import our own files.
 */
export function readE57Points(physical: Uint8Array, scanIndex = 0): PointCloud {
  const xml = readE57Xml(physical);
  const logical = depaginate(physical);

  // Split per scan first. Searching the whole document for a pose or a prototype
  // would find the first one every time, which is correct only for scanIndex 0.
  const scanBlocks = [...xml.matchAll(/<vectorChild type="Structure">([\s\S]*?)<\/vectorChild>/g)]
    .map((m) => m[1]);
  const scanXml = scanBlocks[scanIndex];
  if (scanXml === undefined) throw new Error(`E57: no scan at index ${scanIndex}`);

  const pointsMatch = /<points type="CompressedVector"([\s\S]*?)<\/points>/.exec(scanXml);
  if (!pointsMatch) throw new Error(`E57: scan ${scanIndex} has no points section`);

  const attrs = pointsMatch[1];
  const fileOffset = Number(/fileOffset="(\d+)"/.exec(pointsMatch[0])![1]);
  const recordCount = Number(/recordCount="(\d+)"/.exec(pointsMatch[0])![1]);

  // Rebuild the prototype in declaration order.
  const proto = /<prototype type="Structure">([\s\S]*?)<\/prototype>/.exec(attrs)![1];
  interface ReadField {
    name: string;
    width: number;
    kind: 'float' | 'integer';
    min: number;
  }
  const fields: ReadField[] = [];
  for (const m of proto.matchAll(/<(\w+)\s+([^/>]*)\/>/g)) {
    const name = m[1];
    const a = m[2];
    if (/type="Float"/.test(a)) {
      const single = /precision="single"/.test(a);
      fields.push({ name, width: single ? 4 : 8, kind: 'float', min: 0 });
    } else {
      const min = Number(/minimum="(-?\d+)"/.exec(a)?.[1] ?? 0);
      const max = Number(/maximum="(-?\d+)"/.exec(a)?.[1] ?? 255);
      const span = max - min;
      const width = span <= 0xff ? 1 : span <= 0xffff ? 2 : span <= 0xffffffff ? 4 : 8;
      fields.push({ name, width, kind: 'integer', min });
    }
  }

  const sectionLogical = physicalToLogical(fileOffset);
  const view = new DataView(logical.buffer, logical.byteOffset, logical.byteLength);
  const sectionId = view.getUint8(sectionLogical);
  if (sectionId !== COMPRESSED_VECTOR_SECTION) {
    throw new Error(`E57: expected a CompressedVector section, found id ${sectionId}`);
  }

  const columns = new Map<string, Float64Array>();
  for (const f of fields) columns.set(f.name, new Float64Array(recordCount));

  let offset = sectionLogical + 32;
  let record = 0;
  while (record < recordCount) {
    const packetType = view.getUint8(offset);
    const packetLength = view.getUint16(offset + 2, true) + 1;
    if (packetType !== DATA_PACKET) {
      offset += packetLength;
      continue;
    }
    const bytestreamCount = view.getUint16(offset + 4, true);
    if (bytestreamCount !== fields.length) {
      throw new Error(
        `E57: packet declares ${bytestreamCount} bytestreams, prototype has ${fields.length}`,
      );
    }
    const lengths: number[] = [];
    for (let i = 0; i < bytestreamCount; i++) {
      lengths.push(view.getUint16(offset + 6 + i * 2, true));
    }
    let cursor = offset + 6 + bytestreamCount * 2;
    const countInPacket = lengths[0] / fields[0].width;

    for (let i = 0; i < fields.length; i++) {
      const f = fields[i];
      const column = columns.get(f.name)!;
      for (let k = 0; k < countInPacket; k++) {
        const at = cursor + k * f.width;
        let value: number;
        if (f.kind === 'float') {
          value = f.width === 8 ? view.getFloat64(at, true) : view.getFloat32(at, true);
        } else {
          value =
            f.width === 1 ? view.getUint8(at)
              : f.width === 2 ? view.getUint16(at, true)
                : f.width === 4 ? view.getUint32(at, true)
                  : Number(view.getBigUint64(at, true));
          value += f.min;
        }
        column[record + k] = value;
      }
      cursor += lengths[i];
    }

    record += countInPacket;
    offset += packetLength;
  }

  const positions = new Float64Array(recordCount * 3);
  const x = columns.get('cartesianX')!;
  const y = columns.get('cartesianY')!;
  const z = columns.get('cartesianZ')!;
  for (let i = 0; i < recordCount; i++) {
    positions[i * 3] = x[i];
    positions[i * 3 + 1] = y[i];
    positions[i * 3 + 2] = z[i];
  }

  const cloud: PointCloud = { positions, count: recordCount };

  // Recover the origin the writer stored as a pose translation, so a round trip
  // through E57 returns the same local-coordinates-plus-origin split it started with.
  const pose = /<pose type="Structure">([\s\S]*?)<\/pose>/.exec(scanXml);
  const translation = pose && /<translation type="Structure">([\s\S]*?)<\/translation>/.exec(pose[1]);
  if (translation) {
    const axis = (name: string): number =>
      Number(new RegExp(`<${name} type="Float"[^>]*>([^<]*)<`).exec(translation[1])?.[1] ?? 0);
    const t: [number, number, number] = [axis('x'), axis('y'), axis('z')];
    if (t[0] !== 0 || t[1] !== 0 || t[2] !== 0) cloud.origin = t;
  }

  if (columns.has('colorRed')) {
    const r = columns.get('colorRed')!;
    const g = columns.get('colorGreen')!;
    const b = columns.get('colorBlue')!;
    const colors = new Uint8Array(recordCount * 3);
    for (let i = 0; i < recordCount; i++) {
      colors[i * 3] = r[i];
      colors[i * 3 + 1] = g[i];
      colors[i * 3 + 2] = b[i];
    }
    cloud.colors = colors;
  }
  if (columns.has('intensity')) {
    cloud.intensity = Float32Array.from(columns.get('intensity')!);
  }

  return cloud;
}
