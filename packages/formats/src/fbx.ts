/**
 * FBX binary writer (version 7400).
 *
 * FBX is proprietary and has no published specification. This implementation
 * follows the reverse-engineered layout that Blender, Assimp and three.js all
 * agree on, and the output is checked against three.js's FBXLoader in the tests
 * — an independent parser, which is the only meaningful correctness check
 * available without the Autodesk SDK.
 *
 * Layout, for the record:
 *
 *   header     27 bytes: "Kaydara FBX Binary  \0" + 0x1A 0x00 + uint32 version
 *   node       uint32 endOffset, uint32 numProperties, uint32 propertyListLen,
 *              uint8 nameLen, name, properties..., children..., NULL record
 *   NULL       13 zero bytes (4+4+4+1), present only when a node has children
 *   footer     16-byte code, pad to 16, 20 zeros, uint32 version, 120 zeros,
 *              16-byte extension magic
 *
 * Version 7500 widens the first three node header fields to uint64. This writer
 * stays on 7400 deliberately: it is universally supported and keeps offsets in
 * uint32, and nothing here produces files near the 2 GB point where 7500 matters.
 */

import { ByteWriter } from '@pixmyd/core/bytes';
import type { Mesh } from '@pixmyd/core/bundle';

const FBX_VERSION = 7400;
const FBX_HEADER_MAGIC = 'Kaydara FBX Binary  ';

/** Fixed constant that terminates every FBX file. */
const FOOTER_EXTENSION = new Uint8Array([
  0xf8, 0x5a, 0x8c, 0x6a, 0xde, 0xf5, 0xd9, 0x7e,
  0xec, 0xe9, 0x0c, 0xe3, 0x75, 0x8f, 0x29, 0x0b,
]);

/** Seed for the footer code. Importers do not verify it; written for fidelity. */
const FOOTER_SOURCE_ID = new Uint8Array([
  0x58, 0xab, 0xa9, 0xf0, 0x6c, 0xa2, 0xd8, 0x3f,
  0x4d, 0x47, 0x49, 0xa3, 0xb4, 0xb2, 0xe7, 0x3d,
]);

const FOOTER_KEY = new Uint8Array([
  0xe2, 0x4f, 0x7b, 0x5f, 0xcd, 0xe4, 0xc8, 0x6d,
  0xdb, 0xd8, 0xfb, 0xd7, 0x40, 0x58, 0xc6, 0x78,
]);

// ---------------------------------------------------------------------------
// Node model
// ---------------------------------------------------------------------------

export type FbxProperty =
  | { t: 'C'; v: boolean }
  | { t: 'Y'; v: number }
  | { t: 'I'; v: number }
  | { t: 'F'; v: number }
  | { t: 'D'; v: number }
  | { t: 'L'; v: bigint | number }
  | { t: 'S'; v: string }
  | { t: 'R'; v: Uint8Array }
  | { t: 'f'; v: Float32Array }
  | { t: 'd'; v: Float64Array }
  | { t: 'i'; v: Int32Array }
  | { t: 'l'; v: BigInt64Array }
  | { t: 'b'; v: Uint8Array };

export interface FbxNode {
  name: string;
  props?: FbxProperty[];
  children?: FbxNode[];
}

// Shorthand constructors, because building the tree by hand is otherwise unreadable.
export const P = {
  bool: (v: boolean): FbxProperty => ({ t: 'C', v }),
  i16: (v: number): FbxProperty => ({ t: 'Y', v }),
  i32: (v: number): FbxProperty => ({ t: 'I', v }),
  f32: (v: number): FbxProperty => ({ t: 'F', v }),
  f64: (v: number): FbxProperty => ({ t: 'D', v }),
  i64: (v: bigint | number): FbxProperty => ({ t: 'L', v }),
  str: (v: string): FbxProperty => ({ t: 'S', v }),
  raw: (v: Uint8Array): FbxProperty => ({ t: 'R', v }),
  f32a: (v: Float32Array): FbxProperty => ({ t: 'f', v }),
  f64a: (v: Float64Array): FbxProperty => ({ t: 'd', v }),
  i32a: (v: Int32Array): FbxProperty => ({ t: 'i', v }),
  i64a: (v: BigInt64Array): FbxProperty => ({ t: 'l', v }),
} as const;

/**
 * Object names in *binary* FBX are stored `Name\0\x01Class`, the reverse of the
 * ASCII form `Class::Name`. Parsers truncate the string at the NUL, so getting
 * this backwards yields objects that load but are named "Geometry".
 */
function objectName(name: string, className: string): string {
  return `${name}\u0000\u0001${className}`;
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

function writeProperty(w: ByteWriter, p: FbxProperty): void {
  w.ascii(p.t);
  switch (p.t) {
    case 'C': w.u8(p.v ? 1 : 0); break;
    case 'Y': w.i16(p.v); break;
    case 'I': w.i32(p.v); break;
    case 'F': w.f32(p.v); break;
    case 'D': w.f64(p.v); break;
    case 'L': w.i64(p.v); break;
    case 'S':
    case 'R': {
      const bytes =
        p.t === 'S' ? new TextEncoder().encode(p.v) : p.v;
      w.u32(bytes.length).bytes(bytes);
      break;
    }
    default: {
      // Array property: uint32 length, uint32 encoding, uint32 byteLength, data.
      // Encoding 0 is uncompressed. Encoding 1 is zlib, which would drag a
      // deflate implementation into a package that otherwise has no dependencies
      // — and these files are written once and read once, not shipped over a wire.
      const view = p.v as ArrayBufferView & { length: number };
      w.u32(view.length).u32(0).u32(view.byteLength).typed(view);
      break;
    }
  }
}

function writeNode(w: ByteWriter, node: FbxNode): void {
  const nameBytes = new TextEncoder().encode(node.name);
  const props = node.props ?? [];
  const children = node.children ?? [];

  const endOffsetAt = w.length;
  w.u32(0); // endOffset, back-patched
  w.u32(props.length);
  const propsLenAt = w.length;
  w.u32(0); // propertyListLen, back-patched
  w.u8(nameBytes.length).bytes(nameBytes);

  const propsStart = w.length;
  for (const p of props) writeProperty(w, p);
  w.patchU32(propsLenAt, w.length - propsStart);

  if (children.length > 0) {
    for (const c of children) writeNode(w, c);
    // A node with children is terminated by a 13-byte NULL record. A node
    // without children must NOT have one — an extra sentinel shifts every
    // subsequent offset and the file parses as truncated.
    w.fill(0, 13);
  }

  w.patchU32(endOffsetAt, w.length);
}

/** The XOR-with-carry cipher the footer code is built with. */
function encrypt(dst: Uint8Array, src: Uint8Array): void {
  let carry = 0x64;
  for (let i = 0; i < 16; i++) {
    dst[i] = dst[i] ^ (carry ^ src[i]);
    carry = dst[i];
  }
}

function footerCode(date: Date): Uint8Array {
  const pad = (n: number, width: number) => String(n).padStart(width, '0');
  const stamp =
    pad(date.getSeconds(), 2) +
    pad(date.getMonth() + 1, 2) +
    pad(date.getHours(), 2) +
    pad(date.getDate(), 2) +
    pad(Math.floor(date.getMilliseconds() / 10), 2) +
    pad(date.getFullYear(), 4) +
    pad(date.getMinutes(), 2);
  const stampBytes = new TextEncoder().encode(stamp);

  const code = FOOTER_SOURCE_ID.slice();
  encrypt(code, stampBytes);
  encrypt(code, FOOTER_KEY);
  encrypt(code, stampBytes);
  return code;
}

export function serializeFbx(root: FbxNode[], date = new Date()): Uint8Array {
  const w = new ByteWriter(1 << 18);

  // --- header ---
  w.ascii(FBX_HEADER_MAGIC).u8(0x00).u8(0x1a).u8(0x00);
  w.u32(FBX_VERSION);

  for (const node of root) writeNode(w, node);
  // Top-level list is terminated by its own NULL record.
  w.fill(0, 13);

  // --- footer ---
  //
  // 160 bytes plus alignment padding:
  //   16  footer code
  //   1-16 padding to a 16-byte boundary (never zero — always at least one byte)
  //   4   zeros
  //   4   version
  //   120 zeros
  //   16  extension magic
  //
  // The total size is load-bearing, not cosmetic. Parsers decide they have
  // reached the end of the node list by comparing the remaining bytes against
  // this fixed footer length; a footer even 16 bytes too long leaves them
  // convinced another node follows, and they parse the footer as one.
  w.bytes(footerCode(date));
  w.fill(0, 16 - (w.length % 16));
  w.fill(0, 4);
  w.u32(FBX_VERSION);
  w.fill(0, 120);
  w.bytes(FOOTER_EXTENSION);

  return w.finish();
}

// ---------------------------------------------------------------------------
// Mesh document
// ---------------------------------------------------------------------------

export interface FbxWriteOptions {
  name?: string;
  /**
   * FBX's native unit is the centimetre, and importers that ignore
   * `UnitScaleFactor` — which is most of them — treat raw values as centimetres.
   * Writing centimetres by default means a 3 m wall arrives 3 m tall everywhere
   * instead of 3 cm tall in half the tools. Choose 'm' only if the consumer is
   * known to honour the header.
   */
  units?: 'cm' | 'm';
  /** Rotate a Z-up source into FBX's Y-up convention. */
  zUpToYUp?: boolean;
  /** Fixed timestamp, so a test can produce byte-identical output. */
  date?: Date;
}

let nextId = 1000000;
function allocateId(): bigint {
  return BigInt(nextId++);
}

function properties70(entries: FbxNode[]): FbxNode {
  return { name: 'Properties70', children: entries };
}

function propInt(name: string, value: number): FbxNode {
  return {
    name: 'P',
    props: [P.str(name), P.str('int'), P.str('Integer'), P.str(''), P.i32(value)],
  };
}

function propDouble(name: string, value: number): FbxNode {
  return {
    name: 'P',
    props: [P.str(name), P.str('double'), P.str('Number'), P.str(''), P.f64(value)],
  };
}

function propColor(name: string, r: number, g: number, b: number): FbxNode {
  return {
    name: 'P',
    props: [
      P.str(name), P.str('Color'), P.str(''), P.str('A'),
      P.f64(r), P.f64(g), P.f64(b),
    ],
  };
}

export function writeMeshFbx(mesh: Mesh, options: FbxWriteOptions = {}): Uint8Array {
  const name = options.name ?? mesh.name ?? 'pixmyd';
  const scale = (options.units ?? 'cm') === 'cm' ? 100 : 1;
  const vertexCount = mesh.positions.length / 3;
  const triangleCount = mesh.indices.length / 3;

  // --- geometry arrays ---
  const vertices = new Float64Array(vertexCount * 3);
  for (let i = 0; i < vertexCount; i++) {
    const x = mesh.positions[i * 3];
    const y = mesh.positions[i * 3 + 1];
    const z = mesh.positions[i * 3 + 2];
    if (options.zUpToYUp) {
      vertices[i * 3] = x * scale;
      vertices[i * 3 + 1] = z * scale;
      vertices[i * 3 + 2] = -y * scale;
    } else {
      vertices[i * 3] = x * scale;
      vertices[i * 3 + 1] = y * scale;
      vertices[i * 3 + 2] = z * scale;
    }
  }

  // FBX marks the last corner of each polygon by bitwise-negating its index,
  // which is how a flat array encodes variable-length faces.
  const polygonVertexIndex = new Int32Array(mesh.indices.length);
  for (let f = 0; f < triangleCount; f++) {
    polygonVertexIndex[f * 3] = mesh.indices[f * 3];
    polygonVertexIndex[f * 3 + 1] = mesh.indices[f * 3 + 1];
    polygonVertexIndex[f * 3 + 2] = ~mesh.indices[f * 3 + 2];
  }

  const geometryChildren: FbxNode[] = [
    { name: 'Vertices', props: [P.f64a(vertices)] },
    { name: 'PolygonVertexIndex', props: [P.i32a(polygonVertexIndex)] },
    { name: 'GeometryVersion', props: [P.i32(124)] },
  ];

  const layerElements: FbxNode[] = [];

  if (mesh.normals) {
    const normals = new Float64Array(vertexCount * 3);
    for (let i = 0; i < vertexCount; i++) {
      const x = mesh.normals[i * 3];
      const y = mesh.normals[i * 3 + 1];
      const z = mesh.normals[i * 3 + 2];
      if (options.zUpToYUp) {
        normals[i * 3] = x;
        normals[i * 3 + 1] = z;
        normals[i * 3 + 2] = -y;
      } else {
        normals[i * 3] = x;
        normals[i * 3 + 1] = y;
        normals[i * 3 + 2] = z;
      }
    }
    geometryChildren.push({
      name: 'LayerElementNormal',
      props: [P.i32(0)],
      children: [
        { name: 'Version', props: [P.i32(101)] },
        { name: 'Name', props: [P.str('')] },
        { name: 'MappingInformationType', props: [P.str('ByVertice')] },
        { name: 'ReferenceInformationType', props: [P.str('Direct')] },
        { name: 'Normals', props: [P.f64a(normals)] },
      ],
    });
    layerElements.push({
      name: 'LayerElement',
      children: [
        { name: 'Type', props: [P.str('LayerElementNormal')] },
        { name: 'TypedIndex', props: [P.i32(0)] },
      ],
    });
  }

  if (mesh.uvs) {
    const uv = new Float64Array(vertexCount * 2);
    for (let i = 0; i < vertexCount; i++) {
      uv[i * 2] = mesh.uvs[i * 2];
      // FBX's V axis points up, image space points down.
      uv[i * 2 + 1] = 1 - mesh.uvs[i * 2 + 1];
    }
    geometryChildren.push({
      name: 'LayerElementUV',
      props: [P.i32(0)],
      children: [
        { name: 'Version', props: [P.i32(101)] },
        { name: 'Name', props: [P.str('UVMap')] },
        { name: 'MappingInformationType', props: [P.str('ByPolygonVertex')] },
        { name: 'ReferenceInformationType', props: [P.str('IndexToDirect')] },
        { name: 'UV', props: [P.f64a(uv)] },
        { name: 'UVIndex', props: [P.i32a(Int32Array.from(mesh.indices))] },
      ],
    });
    layerElements.push({
      name: 'LayerElement',
      children: [
        { name: 'Type', props: [P.str('LayerElementUV')] },
        { name: 'TypedIndex', props: [P.i32(0)] },
      ],
    });
  }

  if (mesh.colors) {
    // FBX vertex colour carries alpha; scans have none, so it is written as 1.
    const colors = new Float64Array(vertexCount * 4);
    for (let i = 0; i < vertexCount; i++) {
      colors[i * 4] = mesh.colors[i * 3];
      colors[i * 4 + 1] = mesh.colors[i * 3 + 1];
      colors[i * 4 + 2] = mesh.colors[i * 3 + 2];
      colors[i * 4 + 3] = 1;
    }
    geometryChildren.push({
      name: 'LayerElementColor',
      props: [P.i32(0)],
      children: [
        { name: 'Version', props: [P.i32(101)] },
        { name: 'Name', props: [P.str('VertexColors')] },
        { name: 'MappingInformationType', props: [P.str('ByVertice')] },
        { name: 'ReferenceInformationType', props: [P.str('Direct')] },
        { name: 'Colors', props: [P.f64a(colors)] },
      ],
    });
    layerElements.push({
      name: 'LayerElement',
      children: [
        { name: 'Type', props: [P.str('LayerElementColor')] },
        { name: 'TypedIndex', props: [P.i32(0)] },
      ],
    });
  }

  // Every polygon uses material 0.
  geometryChildren.push({
    name: 'LayerElementMaterial',
    props: [P.i32(0)],
    children: [
      { name: 'Version', props: [P.i32(101)] },
      { name: 'Name', props: [P.str('')] },
      { name: 'MappingInformationType', props: [P.str('AllSame')] },
      { name: 'ReferenceInformationType', props: [P.str('IndexToDirect')] },
      { name: 'Materials', props: [P.i32a(new Int32Array([0]))] },
    ],
  });
  layerElements.push({
    name: 'LayerElement',
    children: [
      { name: 'Type', props: [P.str('LayerElementMaterial')] },
      { name: 'TypedIndex', props: [P.i32(0)] },
    ],
  });

  geometryChildren.push({
    name: 'Layer',
    props: [P.i32(0)],
    children: [{ name: 'Version', props: [P.i32(100)] }, ...layerElements],
  });

  // --- object ids ---
  const geometryId = allocateId();
  const modelId = allocateId();
  const materialId = allocateId();

  const objects: FbxNode = {
    name: 'Objects',
    children: [
      {
        name: 'Geometry',
        props: [P.i64(geometryId), P.str(objectName(name, 'Geometry')), P.str('Mesh')],
        children: geometryChildren,
      },
      {
        name: 'Model',
        props: [P.i64(modelId), P.str(objectName(name, 'Model')), P.str('Mesh')],
        children: [
          { name: 'Version', props: [P.i32(232)] },
          properties70([
            {
              name: 'P',
              props: [
                P.str('DefaultAttributeIndex'), P.str('int'), P.str('Integer'),
                P.str(''), P.i32(0),
              ],
            },
            {
              name: 'P',
              props: [
                P.str('Lcl Scaling'), P.str('Lcl Scaling'), P.str(''), P.str('A'),
                P.f64(1), P.f64(1), P.f64(1),
              ],
            },
          ]),
          { name: 'Shading', props: [P.bool(true)] },
          { name: 'Culling', props: [P.str('CullingOff')] },
        ],
      },
      {
        name: 'Material',
        props: [P.i64(materialId), P.str(objectName(`${name}-material`, 'Material')), P.str('')],
        children: [
          { name: 'Version', props: [P.i32(102)] },
          { name: 'ShadingModel', props: [P.str('phong')] },
          { name: 'MultiLayer', props: [P.i32(0)] },
          properties70([
            propColor('DiffuseColor', 1, 1, 1),
            propColor('AmbientColor', 0.2, 0.2, 0.2),
            propColor('SpecularColor', 0, 0, 0),
            propDouble('Shininess', 2),
            propDouble('Opacity', 1),
          ]),
        ],
      },
    ],
  };

  const connections: FbxNode = {
    name: 'Connections',
    children: [
      // Model is parented to the scene root, which is always id 0.
      { name: 'C', props: [P.str('OO'), P.i64(modelId), P.i64(0)] },
      { name: 'C', props: [P.str('OO'), P.i64(geometryId), P.i64(modelId)] },
      { name: 'C', props: [P.str('OO'), P.i64(materialId), P.i64(modelId)] },
    ],
  };

  const root: FbxNode[] = [
    {
      name: 'FBXHeaderExtension',
      children: [
        { name: 'FBXHeaderVersion', props: [P.i32(1003)] },
        { name: 'FBXVersion', props: [P.i32(FBX_VERSION)] },
        { name: 'Creator', props: [P.str('PIXMYD')] },
      ],
    },
    { name: 'Creator', props: [P.str('PIXMYD')] },
    {
      name: 'GlobalSettings',
      children: [
        { name: 'Version', props: [P.i32(1000)] },
        properties70([
          propInt('UpAxis', 1),
          propInt('UpAxisSign', 1),
          propInt('FrontAxis', 2),
          propInt('FrontAxisSign', 1),
          propInt('CoordAxis', 0),
          propInt('CoordAxisSign', 1),
          propInt('OriginalUpAxis', 1),
          propInt('OriginalUpAxisSign', 1),
          propDouble('UnitScaleFactor', scale === 100 ? 1 : 100),
          propDouble('OriginalUnitScaleFactor', scale === 100 ? 1 : 100),
        ]),
      ],
    },
    {
      name: 'Definitions',
      children: [
        { name: 'Version', props: [P.i32(100)] },
        { name: 'Count', props: [P.i32(3)] },
        {
          name: 'ObjectType',
          props: [P.str('Geometry')],
          children: [{ name: 'Count', props: [P.i32(1)] }],
        },
        {
          name: 'ObjectType',
          props: [P.str('Model')],
          children: [{ name: 'Count', props: [P.i32(1)] }],
        },
        {
          name: 'ObjectType',
          props: [P.str('Material')],
          children: [{ name: 'Count', props: [P.i32(1)] }],
        },
      ],
    },
    objects,
    connections,
  ];

  return serializeFbx(root, options.date);
}

// ---------------------------------------------------------------------------
// Reading back, for tests
// ---------------------------------------------------------------------------

export interface ParsedFbxNode {
  name: string;
  props: unknown[];
  children: ParsedFbxNode[];
}

/**
 * A minimal reader, used to prove the writer's offsets are self-consistent.
 * `parseFbx` walking the whole tree without running off the end is a real check:
 * every endOffset has to land exactly on the next node's first byte.
 */
export function parseFbx(bytes: Uint8Array): ParsedFbxNode[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const magic = new TextDecoder().decode(bytes.subarray(0, 20));
  if (magic !== FBX_HEADER_MAGIC) throw new Error('FBX: bad magic');
  const version = view.getUint32(23, true);
  if (version >= 7500) throw new Error('FBX: uint64 offsets (>=7500) not supported here');

  let offset = 27;
  const nodes: ParsedFbxNode[] = [];
  for (;;) {
    const node = readNode();
    if (!node) break;
    nodes.push(node);
  }
  return nodes;

  function readNode(): ParsedFbxNode | null {
    const endOffset = view.getUint32(offset, true);
    const numProps = view.getUint32(offset + 4, true);
    const propsLen = view.getUint32(offset + 8, true);
    const nameLen = view.getUint8(offset + 12);
    if (endOffset === 0) {
      offset += 13;
      return null;
    }
    offset += 13;
    const name = new TextDecoder().decode(bytes.subarray(offset, offset + nameLen));
    offset += nameLen;

    const propsStart = offset;
    const props: unknown[] = [];
    for (let i = 0; i < numProps; i++) props.push(readProperty());
    if (offset - propsStart !== propsLen) {
      throw new Error(
        `FBX: node "${name}" declared propertyListLen ${propsLen} but consumed ${offset - propsStart}`,
      );
    }

    const children: ParsedFbxNode[] = [];
    while (offset < endOffset) {
      const child = readNode();
      if (!child) break;
      children.push(child);
    }
    if (offset !== endOffset) {
      throw new Error(`FBX: node "${name}" ended at ${offset}, endOffset said ${endOffset}`);
    }
    return { name, props, children };
  }

  function readProperty(): unknown {
    const type = String.fromCharCode(view.getUint8(offset));
    offset += 1;
    switch (type) {
      case 'C': { const v = view.getUint8(offset) !== 0; offset += 1; return v; }
      case 'Y': { const v = view.getInt16(offset, true); offset += 2; return v; }
      case 'I': { const v = view.getInt32(offset, true); offset += 4; return v; }
      case 'F': { const v = view.getFloat32(offset, true); offset += 4; return v; }
      case 'D': { const v = view.getFloat64(offset, true); offset += 8; return v; }
      case 'L': { const v = view.getBigInt64(offset, true); offset += 8; return v; }
      case 'S':
      case 'R': {
        const len = view.getUint32(offset, true);
        offset += 4;
        const data = bytes.subarray(offset, offset + len);
        offset += len;
        return type === 'S' ? new TextDecoder().decode(data) : data.slice();
      }
      default: {
        const length = view.getUint32(offset, true);
        const encoding = view.getUint32(offset + 4, true);
        const byteLength = view.getUint32(offset + 8, true);
        offset += 12;
        if (encoding !== 0) throw new Error('FBX: compressed arrays not supported here');
        const raw = bytes.slice(offset, offset + byteLength);
        offset += byteLength;
        switch (type) {
          case 'f': return new Float32Array(raw.buffer, 0, length);
          case 'd': return new Float64Array(raw.buffer, 0, length);
          case 'i': return new Int32Array(raw.buffer, 0, length);
          case 'l': return new BigInt64Array(raw.buffer, 0, length);
          case 'b': return raw;
          default: throw new Error(`FBX: unknown property type "${type}"`);
        }
      }
    }
  }
}

/** Depth-first search for the first node with a given name. */
export function findFbxNode(nodes: ParsedFbxNode[], name: string): ParsedFbxNode | null {
  for (const n of nodes) {
    if (n.name === name) return n;
    const found = findFbxNode(n.children, name);
    if (found) return found;
  }
  return null;
}
