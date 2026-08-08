/**
 * PLY (Stanford polygon format) reader and writer.
 *
 * Generic in the element/property model rather than hard-coded to points or
 * meshes, because PLY is the lingua franca here and it has to carry three quite
 * different payloads without three implementations:
 *
 *   - point clouds        vertex: x y z [red green blue] [nx ny nz] [intensity]
 *   - triangle meshes     vertex + face with a list property
 *   - Gaussian splats     the INRIA convention: f_dc_*, f_rest_*, scale_*, rot_*, opacity
 *
 * All three formats are supported for reading and writing: ascii,
 * binary_little_endian, and binary_big_endian.
 */

import { ByteReader, ByteWriter } from '@pixmyd/core/bytes';
import type { Mesh, PointCloud, SplatCloud } from '@pixmyd/core/bundle';

// ---------------------------------------------------------------------------
// Type model
// ---------------------------------------------------------------------------

export type PlyScalarType =
  | 'int8' | 'uint8' | 'int16' | 'uint16'
  | 'int32' | 'uint32' | 'float32' | 'float64';

/** PLY has two spellings for every scalar. Both appear in the wild. */
const TYPE_ALIASES: Record<string, PlyScalarType> = {
  char: 'int8', int8: 'int8',
  uchar: 'uint8', uint8: 'uint8',
  short: 'int16', int16: 'int16',
  ushort: 'uint16', uint16: 'uint16',
  int: 'int32', int32: 'int32',
  uint: 'uint32', uint32: 'uint32',
  float: 'float32', float32: 'float32',
  double: 'float64', float64: 'float64',
};

/** The spelling to emit. The short names are what most readers expect. */
const CANONICAL_NAME: Record<PlyScalarType, string> = {
  int8: 'char', uint8: 'uchar',
  int16: 'short', uint16: 'ushort',
  int32: 'int', uint32: 'uint',
  float32: 'float', float64: 'double',
};

const TYPE_SIZE: Record<PlyScalarType, number> = {
  int8: 1, uint8: 1,
  int16: 2, uint16: 2,
  int32: 4, uint32: 4,
  float32: 4, float64: 8,
};

export type PlyFormat = 'ascii' | 'binary_little_endian' | 'binary_big_endian';

export interface PlyScalarProperty {
  kind: 'scalar';
  name: string;
  type: PlyScalarType;
}

export interface PlyListProperty {
  kind: 'list';
  name: string;
  /** Type of the leading count. Almost always uchar. */
  countType: PlyScalarType;
  valueType: PlyScalarType;
}

export type PlyProperty = PlyScalarProperty | PlyListProperty;

export interface PlyElement {
  name: string;
  count: number;
  properties: PlyProperty[];
}

export interface PlyHeader {
  format: PlyFormat;
  version: string;
  comments: string[];
  /** `obj_info` lines, which some scanners use for metadata. */
  objInfo: string[];
  elements: PlyElement[];
  /** Byte offset where the data begins. */
  dataOffset: number;
}

/**
 * A parsed element's data. Scalar properties become one typed array each,
 * keyed by property name. List properties become an array of arrays, since
 * their lengths vary per row.
 */
export interface PlyElementData {
  name: string;
  count: number;
  scalars: Map<string, Float64Array>;
  lists: Map<string, number[][]>;
}

export interface PlyFile {
  header: PlyHeader;
  elements: Map<string, PlyElementData>;
}

// ---------------------------------------------------------------------------
// Header parsing
// ---------------------------------------------------------------------------

function normaliseType(token: string): PlyScalarType {
  const t = TYPE_ALIASES[token.toLowerCase()];
  if (!t) throw new Error(`PLY: unknown property type "${token}"`);
  return t;
}

export function parsePlyHeader(bytes: Uint8Array): PlyHeader {
  const reader = new ByteReader(bytes);
  const magic = reader.line().trim();
  if (magic !== 'ply') throw new Error('PLY: missing "ply" magic on the first line');

  const header: PlyHeader = {
    format: 'ascii',
    version: '1.0',
    comments: [],
    objInfo: [],
    elements: [],
    dataOffset: 0,
  };

  let current: PlyElement | null = null;
  let sawFormat = false;

  for (;;) {
    if (reader.remaining <= 0) throw new Error('PLY: header ended without end_header');
    const line = reader.line().trim();
    if (line === '') continue;
    const parts = line.split(/\s+/);
    const keyword = parts[0];

    if (keyword === 'end_header') {
      header.dataOffset = reader.offset;
      break;
    }

    switch (keyword) {
      case 'format': {
        const fmt = parts[1];
        if (fmt !== 'ascii' && fmt !== 'binary_little_endian' && fmt !== 'binary_big_endian') {
          throw new Error(`PLY: unsupported format "${fmt}"`);
        }
        header.format = fmt;
        header.version = parts[2] ?? '1.0';
        sawFormat = true;
        break;
      }
      case 'comment':
        header.comments.push(line.slice('comment'.length).trim());
        break;
      case 'obj_info':
        header.objInfo.push(line.slice('obj_info'.length).trim());
        break;
      case 'element': {
        current = { name: parts[1], count: Number(parts[2]), properties: [] };
        if (!Number.isFinite(current.count) || current.count < 0) {
          throw new Error(`PLY: bad element count for "${parts[1]}"`);
        }
        header.elements.push(current);
        break;
      }
      case 'property': {
        if (!current) throw new Error('PLY: property outside of an element');
        if (parts[1] === 'list') {
          current.properties.push({
            kind: 'list',
            countType: normaliseType(parts[2]),
            valueType: normaliseType(parts[3]),
            name: parts[4],
          });
        } else {
          current.properties.push({
            kind: 'scalar',
            type: normaliseType(parts[1]),
            name: parts[2],
          });
        }
        break;
      }
      default:
        // Unknown header keywords are ignored rather than fatal — PLY has
        // accumulated vendor extensions and refusing to open a file over one
        // is worse than skipping it.
        break;
    }
  }

  if (!sawFormat) throw new Error('PLY: header has no format line');
  return header;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

function readScalar(view: DataView, offset: number, type: PlyScalarType, le: boolean): number {
  switch (type) {
    case 'int8': return view.getInt8(offset);
    case 'uint8': return view.getUint8(offset);
    case 'int16': return view.getInt16(offset, le);
    case 'uint16': return view.getUint16(offset, le);
    case 'int32': return view.getInt32(offset, le);
    case 'uint32': return view.getUint32(offset, le);
    case 'float32': return view.getFloat32(offset, le);
    case 'float64': return view.getFloat64(offset, le);
  }
}

export function readPly(bytes: Uint8Array): PlyFile {
  const header = parsePlyHeader(bytes);
  const elements = new Map<string, PlyElementData>();

  if (header.format === 'ascii') {
    readAsciiBody(bytes, header, elements);
  } else {
    readBinaryBody(bytes, header, elements);
  }

  return { header, elements };
}

function allocate(el: PlyElement): PlyElementData {
  const data: PlyElementData = {
    name: el.name,
    count: el.count,
    scalars: new Map(),
    lists: new Map(),
  };
  for (const p of el.properties) {
    if (p.kind === 'scalar') data.scalars.set(p.name, new Float64Array(el.count));
    else data.lists.set(p.name, new Array(el.count));
  }
  return data;
}

function readAsciiBody(
  bytes: Uint8Array,
  header: PlyHeader,
  out: Map<string, PlyElementData>,
): void {
  const text = new TextDecoder().decode(bytes.subarray(header.dataOffset));
  // Split on any whitespace: PLY ascii bodies are not reliably one row per line.
  const tokens = text.split(/\s+/).filter((s) => s.length > 0);
  let at = 0;
  const next = (): number => {
    if (at >= tokens.length) throw new Error('PLY: ascii body ended early');
    return Number(tokens[at++]);
  };

  for (const el of header.elements) {
    const data = allocate(el);
    for (let i = 0; i < el.count; i++) {
      for (const p of el.properties) {
        if (p.kind === 'scalar') {
          data.scalars.get(p.name)![i] = next();
        } else {
          const n = next();
          const list = new Array<number>(n);
          for (let k = 0; k < n; k++) list[k] = next();
          data.lists.get(p.name)![i] = list;
        }
      }
    }
    out.set(el.name, data);
  }
}

function readBinaryBody(
  bytes: Uint8Array,
  header: PlyHeader,
  out: Map<string, PlyElementData>,
): void {
  const le = header.format === 'binary_little_endian';
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = header.dataOffset;

  for (const el of header.elements) {
    const data = allocate(el);
    const allScalar = el.properties.every((p) => p.kind === 'scalar');

    if (allScalar) {
      // Fixed-stride fast path: compute offsets once instead of per row.
      const props = el.properties as PlyScalarProperty[];
      const offsets: number[] = [];
      let stride = 0;
      for (const p of props) {
        offsets.push(stride);
        stride += TYPE_SIZE[p.type];
      }
      const needed = stride * el.count;
      if (offset + needed > bytes.byteLength) {
        throw new Error(
          `PLY: truncated body — element "${el.name}" needs ${needed} bytes, ` +
          `${bytes.byteLength - offset} remain`,
        );
      }
      const arrays = props.map((p) => data.scalars.get(p.name)!);
      for (let i = 0; i < el.count; i++) {
        const row = offset + i * stride;
        for (let k = 0; k < props.length; k++) {
          arrays[k][i] = readScalar(view, row + offsets[k], props[k].type, le);
        }
      }
      offset += needed;
    } else {
      for (let i = 0; i < el.count; i++) {
        for (const p of el.properties) {
          if (p.kind === 'scalar') {
            data.scalars.get(p.name)![i] = readScalar(view, offset, p.type, le);
            offset += TYPE_SIZE[p.type];
          } else {
            const n = readScalar(view, offset, p.countType, le);
            offset += TYPE_SIZE[p.countType];
            const list = new Array<number>(n);
            const vsize = TYPE_SIZE[p.valueType];
            for (let k = 0; k < n; k++) {
              list[k] = readScalar(view, offset, p.valueType, le);
              offset += vsize;
            }
            data.lists.get(p.name)![i] = list;
          }
        }
      }
    }
    out.set(el.name, data);
  }
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/** A column of values to write. Length must equal the element's count. */
export interface PlyColumn {
  name: string;
  type: PlyScalarType;
  values: ArrayLike<number>;
}

export interface PlyWriteElement {
  name: string;
  count: number;
  columns: PlyColumn[];
  /** At most one list property per element, which covers every real use. */
  list?: {
    name: string;
    countType: PlyScalarType;
    valueType: PlyScalarType;
    /** Flat values with a fixed run length — the mesh case. */
    flat: ArrayLike<number>;
    runLength: number;
  };
}

export interface PlyWriteOptions {
  format?: PlyFormat;
  comments?: string[];
  objInfo?: string[];
}

function writeScalar(w: ByteWriter, type: PlyScalarType, v: number, le: boolean): void {
  if (!le) {
    // Big-endian output is rare enough that a per-value DataView is acceptable.
    const buf = new DataView(new ArrayBuffer(8));
    switch (type) {
      case 'int8': buf.setInt8(0, v); break;
      case 'uint8': buf.setUint8(0, v); break;
      case 'int16': buf.setInt16(0, v, false); break;
      case 'uint16': buf.setUint16(0, v, false); break;
      case 'int32': buf.setInt32(0, v, false); break;
      case 'uint32': buf.setUint32(0, v >>> 0, false); break;
      case 'float32': buf.setFloat32(0, v, false); break;
      case 'float64': buf.setFloat64(0, v, false); break;
    }
    w.bytes(new Uint8Array(buf.buffer, 0, TYPE_SIZE[type]));
    return;
  }
  switch (type) {
    case 'int8': w.i8(v); break;
    case 'uint8': w.u8(v); break;
    case 'int16': w.i16(v); break;
    case 'uint16': w.u16(v); break;
    case 'int32': w.i32(v); break;
    case 'uint32': w.u32(v >>> 0); break;
    case 'float32': w.f32(v); break;
    case 'float64': w.f64(v); break;
  }
}

/** Integers print without a decimal point; floats keep enough digits to round-trip. */
function asciiValue(type: PlyScalarType, v: number): string {
  if (type === 'float32' || type === 'float64') {
    if (Number.isInteger(v) && Math.abs(v) < 1e15) return v.toFixed(1);
    return String(v);
  }
  return String(Math.round(v));
}

export function writePly(elements: PlyWriteElement[], options: PlyWriteOptions = {}): Uint8Array {
  const format = options.format ?? 'binary_little_endian';
  const w = new ByteWriter(1 << 16);

  // --- header ---
  const lines: string[] = ['ply', `format ${format} 1.0`];
  for (const c of options.comments ?? []) {
    // A newline inside a comment would forge a header line.
    for (const part of c.split(/\r?\n/)) lines.push(`comment ${part}`);
  }
  for (const o of options.objInfo ?? []) lines.push(`obj_info ${o}`);

  for (const el of elements) {
    lines.push(`element ${el.name} ${el.count}`);
    for (const col of el.columns) {
      lines.push(`property ${CANONICAL_NAME[col.type]} ${col.name}`);
    }
    if (el.list) {
      lines.push(
        `property list ${CANONICAL_NAME[el.list.countType]} ` +
        `${CANONICAL_NAME[el.list.valueType]} ${el.list.name}`,
      );
    }
  }
  lines.push('end_header');
  w.ascii(lines.join('\n') + '\n');

  // --- body ---
  const le = format !== 'binary_big_endian';

  for (const el of elements) {
    for (const col of el.columns) {
      if (col.values.length < el.count) {
        throw new Error(
          `PLY: column "${col.name}" has ${col.values.length} values for ${el.count} rows`,
        );
      }
    }

    if (format === 'ascii') {
      const row: string[] = [];
      for (let i = 0; i < el.count; i++) {
        row.length = 0;
        for (const col of el.columns) row.push(asciiValue(col.type, col.values[i]));
        if (el.list) {
          const n = el.list.runLength;
          row.push(String(n));
          for (let k = 0; k < n; k++) {
            row.push(asciiValue(el.list.valueType, el.list.flat[i * n + k]));
          }
        }
        w.ascii(row.join(' ') + '\n');
      }
    } else {
      for (let i = 0; i < el.count; i++) {
        for (const col of el.columns) writeScalar(w, col.type, col.values[i], le);
        if (el.list) {
          const n = el.list.runLength;
          writeScalar(w, el.list.countType, n, le);
          for (let k = 0; k < n; k++) {
            writeScalar(w, el.list.valueType, el.list.flat[i * n + k], le);
          }
        }
      }
    }
  }

  return w.finish();
}

// ---------------------------------------------------------------------------
// Point cloud convenience layer
// ---------------------------------------------------------------------------

export interface PointCloudPlyOptions extends PlyWriteOptions {
  /**
   * float32 halves the file but quantises. At a 1 km extent a float32 step is
   * ~0.06 mm, which is fine — but only because coordinates are local. Export
   * raw survey coordinates as float32 and you lose a foot. See @pixmyd/geo.
   */
  positionType?: 'float32' | 'float64';
}

export function writePointCloudPly(
  cloud: PointCloud,
  options: PointCloudPlyOptions = {},
): Uint8Array {
  const n = cloud.count;
  const posType = options.positionType ?? 'float32';
  const columns: PlyColumn[] = [];

  // De-interleave once rather than allocating a subarray view per axis.
  const xs = new Float64Array(n);
  const ys = new Float64Array(n);
  const zs = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    xs[i] = cloud.positions[i * 3];
    ys[i] = cloud.positions[i * 3 + 1];
    zs[i] = cloud.positions[i * 3 + 2];
  }
  columns.push(
    { name: 'x', type: posType, values: xs },
    { name: 'y', type: posType, values: ys },
    { name: 'z', type: posType, values: zs },
  );

  if (cloud.normals) {
    const nx = new Float32Array(n), ny = new Float32Array(n), nz = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      nx[i] = cloud.normals[i * 3];
      ny[i] = cloud.normals[i * 3 + 1];
      nz[i] = cloud.normals[i * 3 + 2];
    }
    columns.push(
      { name: 'nx', type: 'float32', values: nx },
      { name: 'ny', type: 'float32', values: ny },
      { name: 'nz', type: 'float32', values: nz },
    );
  }

  if (cloud.colors) {
    const r = new Uint8Array(n), g = new Uint8Array(n), b = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      r[i] = cloud.colors[i * 3];
      g[i] = cloud.colors[i * 3 + 1];
      b[i] = cloud.colors[i * 3 + 2];
    }
    columns.push(
      { name: 'red', type: 'uint8', values: r },
      { name: 'green', type: 'uint8', values: g },
      { name: 'blue', type: 'uint8', values: b },
    );
  }

  if (cloud.intensity) {
    columns.push({ name: 'intensity', type: 'float32', values: cloud.intensity });
  }

  const comments = [...(options.comments ?? []), 'generated by PIXMYD'];
  if (cloud.origin) {
    // PLY has nowhere structured to put a georeference, so record it as a comment
    // in a form a human and a parser can both read.
    comments.push(
      `pixmyd origin ${cloud.origin[0]} ${cloud.origin[1]} ${cloud.origin[2]}`,
    );
  }
  if (cloud.crs) {
    comments.push(`pixmyd crs ${cloud.crs.code} unit=${cloud.crs.unit}`);
  }

  return writePly([{ name: 'vertex', count: n, columns }], { ...options, comments });
}

export function writeMeshPly(mesh: Mesh, options: PlyWriteOptions = {}): Uint8Array {
  const vertexCount = mesh.positions.length / 3;
  const faceCount = mesh.indices.length / 3;
  const columns: PlyColumn[] = [];

  const pick = (src: Float32Array, offset: number, stride = 3): Float32Array => {
    const out = new Float32Array(vertexCount);
    for (let i = 0; i < vertexCount; i++) out[i] = src[i * stride + offset];
    return out;
  };

  columns.push(
    { name: 'x', type: 'float32', values: pick(mesh.positions, 0) },
    { name: 'y', type: 'float32', values: pick(mesh.positions, 1) },
    { name: 'z', type: 'float32', values: pick(mesh.positions, 2) },
  );
  if (mesh.normals) {
    columns.push(
      { name: 'nx', type: 'float32', values: pick(mesh.normals, 0) },
      { name: 'ny', type: 'float32', values: pick(mesh.normals, 1) },
      { name: 'nz', type: 'float32', values: pick(mesh.normals, 2) },
    );
  }
  if (mesh.uvs) {
    columns.push(
      { name: 's', type: 'float32', values: pick(mesh.uvs, 0, 2) },
      { name: 't', type: 'float32', values: pick(mesh.uvs, 1, 2) },
    );
  }
  if (mesh.colors) {
    const toByte = (offset: number): Uint8Array => {
      const out = new Uint8Array(vertexCount);
      for (let i = 0; i < vertexCount; i++) {
        out[i] = Math.max(0, Math.min(255, Math.round(mesh.colors![i * 3 + offset] * 255)));
      }
      return out;
    };
    columns.push(
      { name: 'red', type: 'uint8', values: toByte(0) },
      { name: 'green', type: 'uint8', values: toByte(1) },
      { name: 'blue', type: 'uint8', values: toByte(2) },
    );
  }

  return writePly(
    [
      { name: 'vertex', count: vertexCount, columns },
      {
        name: 'face',
        count: faceCount,
        columns: [],
        list: {
          name: 'vertex_indices',
          countType: 'uint8',
          valueType: 'uint32',
          flat: mesh.indices,
          runLength: 3,
        },
      },
    ],
    { ...options, comments: [...(options.comments ?? []), 'generated by PIXMYD'] },
  );
}

/** Read a PLY back into a PointCloud, tolerating the common property spellings. */
export function readPointCloudPly(bytes: Uint8Array): PointCloud {
  const ply = readPly(bytes);
  const vertex = ply.elements.get('vertex');
  if (!vertex) throw new Error('PLY: no vertex element');

  const get = (...names: string[]): Float64Array | undefined => {
    for (const n of names) {
      const a = vertex.scalars.get(n);
      if (a) return a;
    }
    return undefined;
  };

  const x = get('x'), y = get('y'), z = get('z');
  if (!x || !y || !z) throw new Error('PLY: vertex element has no x/y/z');

  const n = vertex.count;
  const positions = new Float64Array(n * 3);
  for (let i = 0; i < n; i++) {
    positions[i * 3] = x[i];
    positions[i * 3 + 1] = y[i];
    positions[i * 3 + 2] = z[i];
  }

  const cloud: PointCloud = { positions, count: n };

  const r = get('red', 'r', 'diffuse_red');
  const g = get('green', 'g', 'diffuse_green');
  const b = get('blue', 'b', 'diffuse_blue');
  if (r && g && b) {
    const colors = new Uint8Array(n * 3);
    for (let i = 0; i < n; i++) {
      colors[i * 3] = r[i];
      colors[i * 3 + 1] = g[i];
      colors[i * 3 + 2] = b[i];
    }
    cloud.colors = colors;
  }

  const nx = get('nx'), ny = get('ny'), nz = get('nz');
  if (nx && ny && nz) {
    const normals = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      normals[i * 3] = nx[i];
      normals[i * 3 + 1] = ny[i];
      normals[i * 3 + 2] = nz[i];
    }
    cloud.normals = normals;
  }

  const intensity = get('intensity', 'scalar_Intensity', 'reflectance');
  if (intensity) cloud.intensity = Float32Array.from(intensity);

  // Recover an origin written by writePointCloudPly.
  for (const c of ply.header.comments) {
    const m = /^pixmyd origin (\S+) (\S+) (\S+)$/.exec(c);
    if (m) cloud.origin = [Number(m[1]), Number(m[2]), Number(m[3])];
  }

  return cloud;
}

// ---------------------------------------------------------------------------
// Gaussian splat PLY
// ---------------------------------------------------------------------------

/** Coefficient count per colour channel for an SH degree. Degree 3 gives 15 + the DC. */
export function shRestCoeffs(degree: 0 | 1 | 2 | 3): number {
  return (degree + 1) * (degree + 1) - 1;
}

/**
 * Write the INRIA-convention splat PLY that every 3DGS tool reads.
 *
 * Property order is load-bearing: `f_rest_*` is stored channel-major
 * (all R coefficients, then all G, then all B), which is how the reference
 * implementation flattens its `(N, 3, C)` tensor after a transpose. Get this
 * wrong and colours look right at the centre of the scene and wrong at the edges,
 * because only the view-dependent bands are scrambled.
 */
export function writeSplatPly(splats: SplatCloud, options: PlyWriteOptions = {}): Uint8Array {
  const n = splats.count;
  const columns: PlyColumn[] = [];

  const axis = (src: Float32Array, offset: number, stride: number): Float32Array => {
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = src[i * stride + offset];
    return out;
  };

  columns.push(
    { name: 'x', type: 'float32', values: axis(splats.positions, 0, 3) },
    { name: 'y', type: 'float32', values: axis(splats.positions, 1, 3) },
    { name: 'z', type: 'float32', values: axis(splats.positions, 2, 3) },
  );

  // Normals are always written as zero. The reference format includes them and
  // some readers index by position rather than by name, so omitting them breaks
  // more tools than the 12 bytes per splat cost.
  const zeros = new Float32Array(n);
  columns.push(
    { name: 'nx', type: 'float32', values: zeros },
    { name: 'ny', type: 'float32', values: zeros },
    { name: 'nz', type: 'float32', values: zeros },
  );

  columns.push(
    { name: 'f_dc_0', type: 'float32', values: axis(splats.sh0, 0, 3) },
    { name: 'f_dc_1', type: 'float32', values: axis(splats.sh0, 1, 3) },
    { name: 'f_dc_2', type: 'float32', values: axis(splats.sh0, 2, 3) },
  );

  const rest = shRestCoeffs(splats.shDegree);
  if (rest > 0) {
    if (!splats.shRest) throw new Error(`splat PLY: shDegree ${splats.shDegree} needs shRest`);
    const perSplat = rest * 3;
    if (splats.shRest.length < n * perSplat) {
      throw new Error(
        `splat PLY: shRest has ${splats.shRest.length} values, expected ${n * perSplat}`,
      );
    }
    // Storage in SplatCloud is per-splat coefficient-major (c0.rgb, c1.rgb, ...).
    // The PLY convention is channel-major, so transpose on the way out.
    for (let channel = 0; channel < 3; channel++) {
      for (let c = 0; c < rest; c++) {
        const col = new Float32Array(n);
        for (let i = 0; i < n; i++) col[i] = splats.shRest[i * perSplat + c * 3 + channel];
        columns.push({ name: `f_rest_${channel * rest + c}`, type: 'float32', values: col });
      }
    }
  }

  columns.push({ name: 'opacity', type: 'float32', values: splats.opacities });
  columns.push(
    { name: 'scale_0', type: 'float32', values: axis(splats.scales, 0, 3) },
    { name: 'scale_1', type: 'float32', values: axis(splats.scales, 1, 3) },
    { name: 'scale_2', type: 'float32', values: axis(splats.scales, 2, 3) },
  );
  // Rotations are stored w-first in the PLY convention but xyzw in memory.
  columns.push(
    { name: 'rot_0', type: 'float32', values: axis(splats.rotations, 3, 4) },
    { name: 'rot_1', type: 'float32', values: axis(splats.rotations, 0, 4) },
    { name: 'rot_2', type: 'float32', values: axis(splats.rotations, 1, 4) },
    { name: 'rot_3', type: 'float32', values: axis(splats.rotations, 2, 4) },
  );

  return writePly([{ name: 'vertex', count: n, columns }], {
    ...options,
    comments: [...(options.comments ?? []), 'generated by PIXMYD'],
  });
}

export function readSplatPly(bytes: Uint8Array): SplatCloud {
  const ply = readPly(bytes);
  const vertex = ply.elements.get('vertex');
  if (!vertex) throw new Error('splat PLY: no vertex element');
  const n = vertex.count;

  const need = (name: string): Float64Array => {
    const a = vertex.scalars.get(name);
    if (!a) throw new Error(`splat PLY: missing property "${name}"`);
    return a;
  };

  const positions = new Float32Array(n * 3);
  const [px, py, pz] = [need('x'), need('y'), need('z')];
  for (let i = 0; i < n; i++) {
    positions[i * 3] = px[i];
    positions[i * 3 + 1] = py[i];
    positions[i * 3 + 2] = pz[i];
  }

  const sh0 = new Float32Array(n * 3);
  const [d0, d1, d2] = [need('f_dc_0'), need('f_dc_1'), need('f_dc_2')];
  for (let i = 0; i < n; i++) {
    sh0[i * 3] = d0[i];
    sh0[i * 3 + 1] = d1[i];
    sh0[i * 3 + 2] = d2[i];
  }

  // Degree is implied by how many f_rest_* properties are present.
  let restCount = 0;
  while (vertex.scalars.has(`f_rest_${restCount}`)) restCount++;
  const perChannel = restCount / 3;
  let shDegree: 0 | 1 | 2 | 3 = 0;
  for (const d of [3, 2, 1] as const) {
    if (shRestCoeffs(d) === perChannel) {
      shDegree = d;
      break;
    }
  }
  if (restCount > 0 && shRestCoeffs(shDegree) !== perChannel) {
    throw new Error(`splat PLY: ${restCount} f_rest properties is not a whole SH degree`);
  }

  let shRest: Float32Array | undefined;
  if (shDegree > 0) {
    const rest = shRestCoeffs(shDegree);
    shRest = new Float32Array(n * rest * 3);
    for (let channel = 0; channel < 3; channel++) {
      for (let c = 0; c < rest; c++) {
        const src = need(`f_rest_${channel * rest + c}`);
        for (let i = 0; i < n; i++) shRest[i * rest * 3 + c * 3 + channel] = src[i];
      }
    }
  }

  const scales = new Float32Array(n * 3);
  const [s0, s1, s2] = [need('scale_0'), need('scale_1'), need('scale_2')];
  for (let i = 0; i < n; i++) {
    scales[i * 3] = s0[i];
    scales[i * 3 + 1] = s1[i];
    scales[i * 3 + 2] = s2[i];
  }

  const rotations = new Float32Array(n * 4);
  const [r0, r1, r2, r3] = [need('rot_0'), need('rot_1'), need('rot_2'), need('rot_3')];
  for (let i = 0; i < n; i++) {
    // PLY is w,x,y,z; memory is x,y,z,w
    rotations[i * 4] = r1[i];
    rotations[i * 4 + 1] = r2[i];
    rotations[i * 4 + 2] = r3[i];
    rotations[i * 4 + 3] = r0[i];
  }

  return {
    count: n,
    positions,
    scales,
    rotations,
    opacities: Float32Array.from(need('opacity')),
    sh0,
    shRest,
    shDegree,
  };
}
