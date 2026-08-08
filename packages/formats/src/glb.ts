/**
 * glTF 2.0 / GLB writer.
 *
 * Covers the two payloads this toolchain produces:
 *
 *   - textured triangle meshes, the ordinary glTF path
 *   - Gaussian splat scenes via KHR_gaussian_splatting
 *
 * GLB rather than .gltf + sidecars because a capture deliverable that arrives as
 * one file is a deliverable that survives being emailed.
 */

import { ByteWriter, concatBytes } from '@pixmyd/core/bytes';
import type { Mesh, SplatCloud, TextureImage } from '@pixmyd/core/bundle';

const GLB_MAGIC = 0x46546c67; // 'glTF'
const CHUNK_JSON = 0x4e4f534a; // 'JSON'
const CHUNK_BIN = 0x004e4942; // 'BIN\0'

const COMPONENT_TYPE = {
  int8: 5120,
  uint8: 5121,
  int16: 5122,
  uint16: 5123,
  uint32: 5125,
  float32: 5126,
} as const;

type ComponentName = keyof typeof COMPONENT_TYPE;

const COMPONENT_SIZE: Record<ComponentName, number> = {
  int8: 1, uint8: 1, int16: 2, uint16: 2, uint32: 4, float32: 4,
};

type AccessorType = 'SCALAR' | 'VEC2' | 'VEC3' | 'VEC4' | 'MAT4';

const TYPE_COMPONENTS: Record<AccessorType, number> = {
  SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16,
};

const TARGET_ARRAY_BUFFER = 34962;
const TARGET_ELEMENT_ARRAY_BUFFER = 34963;

export const PrimitiveMode = {
  POINTS: 0,
  LINES: 1,
  TRIANGLES: 4,
} as const;

interface GltfAccessor {
  bufferView: number;
  byteOffset?: number;
  componentType: number;
  normalized?: boolean;
  count: number;
  type: AccessorType;
  min?: number[];
  max?: number[];
}

interface GltfBufferView {
  buffer: 0;
  byteOffset: number;
  byteLength: number;
  byteStride?: number;
  target?: number;
}

/** Accumulates buffer views, accessors and the binary blob behind them. */
export class GltfBuilder {
  readonly json: Record<string, unknown> = {
    asset: { version: '2.0', generator: 'PIXMYD' },
  };
  private readonly binChunks: Uint8Array[] = [];
  private binLength = 0;
  readonly bufferViews: GltfBufferView[] = [];
  readonly accessors: GltfAccessor[] = [];
  readonly extensionsUsed = new Set<string>();
  readonly extensionsRequired = new Set<string>();

  /** Append bytes to the binary chunk, 4-byte aligned, and return the view index. */
  addBufferView(data: ArrayBufferView, target?: number, byteStride?: number): number {
    // glTF requires accessor byteOffset to be a multiple of the component size,
    // and it is simplest to keep every view 4-aligned.
    const pad = (4 - (this.binLength % 4)) % 4;
    if (pad > 0) {
      this.binChunks.push(new Uint8Array(pad));
      this.binLength += pad;
    }
    const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    const view: GltfBufferView = {
      buffer: 0,
      byteOffset: this.binLength,
      byteLength: bytes.byteLength,
    };
    if (target !== undefined) view.target = target;
    if (byteStride !== undefined) view.byteStride = byteStride;
    this.binChunks.push(bytes);
    this.binLength += bytes.byteLength;
    this.bufferViews.push(view);
    return this.bufferViews.length - 1;
  }

  addAccessor(
    data: ArrayBufferView,
    component: ComponentName,
    type: AccessorType,
    options: { target?: number; normalized?: boolean; computeBounds?: boolean } = {},
  ): number {
    const componentsPerElement = TYPE_COMPONENTS[type];
    const count =
      data.byteLength / (COMPONENT_SIZE[component] * componentsPerElement);
    if (!Number.isInteger(count)) {
      throw new Error(
        `glTF: ${data.byteLength} bytes is not a whole number of ${type} ${component} elements`,
      );
    }
    const bufferView = this.addBufferView(data, options.target);
    const accessor: GltfAccessor = {
      bufferView,
      componentType: COMPONENT_TYPE[component],
      count,
      type,
    };
    if (options.normalized) accessor.normalized = true;

    // POSITION accessors are required by spec to carry min and max.
    if (options.computeBounds) {
      const arr = data as unknown as ArrayLike<number>;
      const min = new Array(componentsPerElement).fill(Infinity);
      const max = new Array(componentsPerElement).fill(-Infinity);
      for (let i = 0; i < count; i++) {
        for (let c = 0; c < componentsPerElement; c++) {
          const v = arr[i * componentsPerElement + c];
          if (v < min[c]) min[c] = v;
          if (v > max[c]) max[c] = v;
        }
      }
      if (count > 0) {
        accessor.min = min;
        accessor.max = max;
      }
    }

    this.accessors.push(accessor);
    return this.accessors.length - 1;
  }

  /** Serialize to a GLB container. */
  finish(): Uint8Array {
    const bin = concatBytes(this.binChunks);

    this.json.bufferViews = this.bufferViews;
    this.json.accessors = this.accessors;
    this.json.buffers = bin.byteLength > 0 ? [{ byteLength: bin.byteLength }] : [];
    if (this.extensionsUsed.size > 0) this.json.extensionsUsed = [...this.extensionsUsed];
    if (this.extensionsRequired.size > 0) {
      this.json.extensionsRequired = [...this.extensionsRequired];
    }

    const jsonBytes = new TextEncoder().encode(JSON.stringify(this.json));
    // JSON chunk pads with spaces, BIN chunk pads with zeros — both per spec.
    const jsonPad = (4 - (jsonBytes.byteLength % 4)) % 4;
    const binPad = (4 - (bin.byteLength % 4)) % 4;

    const total =
      12 +
      8 + jsonBytes.byteLength + jsonPad +
      (bin.byteLength > 0 ? 8 + bin.byteLength + binPad : 0);

    const w = new ByteWriter(total);
    w.u32(GLB_MAGIC).u32(2).u32(total);
    w.u32(jsonBytes.byteLength + jsonPad).u32(CHUNK_JSON).bytes(jsonBytes).fill(0x20, jsonPad);
    if (bin.byteLength > 0) {
      w.u32(bin.byteLength + binPad).u32(CHUNK_BIN).bytes(bin).fill(0, binPad);
    }
    return w.finish();
  }
}

// ---------------------------------------------------------------------------
// Meshes
// ---------------------------------------------------------------------------

export interface GlbMeshOptions {
  /**
   * glTF is Y-up. Survey and BIM data is Z-up. Set this when the mesh is still
   * in a Z-up frame and it will be rotated on the way out, rather than arriving
   * in Blender lying on its side.
   */
  zUpToYUp?: boolean;
  /** Metallic-roughness values for the generated material. */
  metallic?: number;
  roughness?: number;
  /** Draw both sides. Scanned geometry frequently has inconsistent winding. */
  doubleSided?: boolean;
  name?: string;
}

function rotateZUpToYUp(positions: Float32Array): Float32Array {
  // (x, y, z)_zup -> (x, z, -y)_yup
  const out = new Float32Array(positions.length);
  for (let i = 0; i < positions.length; i += 3) {
    out[i] = positions[i];
    out[i + 1] = positions[i + 2];
    out[i + 2] = -positions[i + 1];
  }
  return out;
}

export function writeMeshGlb(mesh: Mesh, options: GlbMeshOptions = {}): Uint8Array {
  const b = new GltfBuilder();

  const positions = options.zUpToYUp ? rotateZUpToYUp(mesh.positions) : mesh.positions;
  const attributes: Record<string, number> = {
    POSITION: b.addAccessor(positions, 'float32', 'VEC3', {
      target: TARGET_ARRAY_BUFFER,
      computeBounds: true,
    }),
  };

  if (mesh.normals) {
    const normals = options.zUpToYUp ? rotateZUpToYUp(mesh.normals) : mesh.normals;
    attributes.NORMAL = b.addAccessor(normals, 'float32', 'VEC3', {
      target: TARGET_ARRAY_BUFFER,
    });
  }
  if (mesh.uvs) {
    attributes.TEXCOORD_0 = b.addAccessor(mesh.uvs, 'float32', 'VEC2', {
      target: TARGET_ARRAY_BUFFER,
    });
  }
  if (mesh.colors) {
    // glTF COLOR_0 is linear; Mesh.colors is documented linear, so no conversion.
    attributes.COLOR_0 = b.addAccessor(mesh.colors, 'float32', 'VEC3', {
      target: TARGET_ARRAY_BUFFER,
    });
  }

  // Emit uint16 indices when they fit — halves the index buffer and every
  // renderer supports it, whereas uint32 needs an extension on WebGL1 targets.
  const vertexCount = positions.length / 3;
  const indexData: ArrayBufferView =
    vertexCount <= 65535 ? Uint16Array.from(mesh.indices) : mesh.indices;
  const indices = b.addAccessor(
    indexData,
    vertexCount <= 65535 ? 'uint16' : 'uint32',
    'SCALAR',
    { target: TARGET_ELEMENT_ARRAY_BUFFER },
  );

  const material: Record<string, unknown> = {
    name: 'pixmyd-surface',
    pbrMetallicRoughness: {
      baseColorFactor: [1, 1, 1, 1],
      metallicFactor: options.metallic ?? 0,
      roughnessFactor: options.roughness ?? 1,
    },
    doubleSided: options.doubleSided ?? true,
  };

  if (mesh.texture) {
    const imageView = b.addBufferView(mesh.texture.data);
    b.json.images = [{ bufferView: imageView, mimeType: mesh.texture.mimeType }];
    b.json.samplers = [{ magFilter: 9729, minFilter: 9987, wrapS: 10497, wrapT: 10497 }];
    b.json.textures = [{ sampler: 0, source: 0 }];
    (material.pbrMetallicRoughness as Record<string, unknown>).baseColorTexture = { index: 0 };
  }

  b.json.materials = [material];
  b.json.meshes = [
    {
      name: options.name ?? mesh.name ?? 'pixmyd-mesh',
      primitives: [{ attributes, indices, material: 0, mode: PrimitiveMode.TRIANGLES }],
    },
  ];
  b.json.nodes = [{ mesh: 0, name: options.name ?? mesh.name ?? 'pixmyd-mesh' }];
  b.json.scenes = [{ nodes: [0] }];
  b.json.scene = 0;

  return b.finish();
}

// ---------------------------------------------------------------------------
// Gaussian splats
// ---------------------------------------------------------------------------

const KHR_SPLAT = 'KHR_gaussian_splatting';

export interface GlbSplatOptions {
  zUpToYUp?: boolean;
  /**
   * Highest SH degree to emit. Clamped to what the cloud carries. Dropping to 0
   * makes the file roughly a quarter of the size and the scene view-independent,
   * which is often what a coordination deliverable wants.
   */
  maxShDegree?: 0 | 1 | 2 | 3;
  name?: string;
}

const sigmoid = (x: number): number => 1 / (1 + Math.exp(-x));

/**
 * Write a splat scene as GLB.
 *
 * The extension stores *activated* values — linear opacity in [0,1] and actual
 * scale in world units — whereas training and the PLY convention store the raw
 * pre-activation parameters (logit opacity, log scale). The conversion happens
 * here. Skipping it produces a file that loads without error and renders as an
 * opaque blob, which is the kind of bug that survives review.
 */
export function writeSplatGlb(splats: SplatCloud, options: GlbSplatOptions = {}): Uint8Array {
  const b = new GltfBuilder();
  const n = splats.count;

  const positions = options.zUpToYUp
    ? rotateZUpToYUp(splats.positions)
    : splats.positions;

  // exp() the log-scales into world units.
  const scale = new Float32Array(n * 3);
  for (let i = 0; i < n * 3; i++) scale[i] = Math.exp(splats.scales[i]);
  if (options.zUpToYUp) {
    // Scale is a per-axis extent, so the axis swap applies but the sign does not.
    for (let i = 0; i < n; i++) {
      const y = scale[i * 3 + 1];
      scale[i * 3 + 1] = scale[i * 3 + 2];
      scale[i * 3 + 2] = y;
    }
  }

  // sigmoid() the logit opacities into linear alpha.
  const opacity = new Float32Array(n);
  for (let i = 0; i < n; i++) opacity[i] = sigmoid(splats.opacities[i]);

  let rotations = splats.rotations;
  if (options.zUpToYUp) {
    // Compose each splat rotation with the -90 degrees about X that takes Z-up to Y-up.
    const h = Math.SQRT1_2; // cos(45 deg) = sin(45 deg)
    const qx = -h, qw = h; // quaternion (-sin45, 0, 0, cos45)
    rotations = new Float32Array(n * 4);
    for (let i = 0; i < n; i++) {
      const x = splats.rotations[i * 4];
      const y = splats.rotations[i * 4 + 1];
      const z = splats.rotations[i * 4 + 2];
      const w = splats.rotations[i * 4 + 3];
      rotations[i * 4] = qw * x + qx * w;
      rotations[i * 4 + 1] = qw * y - qx * z;
      rotations[i * 4 + 2] = qw * z + qx * y;
      rotations[i * 4 + 3] = qw * w - qx * x;
    }
  }

  const attributes: Record<string, number> = {
    POSITION: b.addAccessor(positions, 'float32', 'VEC3', {
      target: TARGET_ARRAY_BUFFER,
      computeBounds: true,
    }),
    [`${KHR_SPLAT}:ROTATION`]: b.addAccessor(rotations, 'float32', 'VEC4', {
      target: TARGET_ARRAY_BUFFER,
    }),
    [`${KHR_SPLAT}:SCALE`]: b.addAccessor(scale, 'float32', 'VEC3', {
      target: TARGET_ARRAY_BUFFER,
    }),
    [`${KHR_SPLAT}:OPACITY`]: b.addAccessor(opacity, 'float32', 'SCALAR', {
      target: TARGET_ARRAY_BUFFER,
    }),
    [`${KHR_SPLAT}:SH_DEGREE_0_COEF_0`]: b.addAccessor(splats.sh0, 'float32', 'VEC3', {
      target: TARGET_ARRAY_BUFFER,
    }),
  };

  const degree = Math.min(
    options.maxShDegree ?? splats.shDegree,
    splats.shDegree,
  ) as 0 | 1 | 2 | 3;

  if (degree > 0 && splats.shRest) {
    // Coefficients per degree band: 3 at l=1, 5 at l=2, 7 at l=3.
    const totalRest = (splats.shDegree + 1) ** 2 - 1;
    let coeff = 0;
    for (let l = 1; l <= degree; l++) {
      const bandSize = 2 * l + 1;
      for (let m = 0; m < bandSize; m++, coeff++) {
        const out = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) {
          const src = i * totalRest * 3 + coeff * 3;
          out[i * 3] = splats.shRest[src];
          out[i * 3 + 1] = splats.shRest[src + 1];
          out[i * 3 + 2] = splats.shRest[src + 2];
        }
        attributes[`${KHR_SPLAT}:SH_DEGREE_${l}_COEF_${m}`] = b.addAccessor(
          out,
          'float32',
          'VEC3',
          { target: TARGET_ARRAY_BUFFER },
        );
      }
    }
  }

  b.extensionsUsed.add(KHR_SPLAT);
  // Required, not merely used: without splat support a viewer would draw the
  // scene as a cloud of unlit points and misrepresent it as a successful load.
  b.extensionsRequired.add(KHR_SPLAT);

  b.json.meshes = [
    {
      name: options.name ?? 'pixmyd-splats',
      primitives: [
        {
          attributes,
          mode: PrimitiveMode.POINTS,
          extensions: {
            [KHR_SPLAT]: {
              kernel: 'ellipse',
              // SH coefficients are linear-light; the viewer applies the transfer.
              colorSpace: 'lin_rec709_display',
              projection: 'perspective',
              sortingMethod: 'cameraDistance',
            },
          },
        },
      ],
    },
  ];
  b.json.nodes = [{ mesh: 0, name: options.name ?? 'pixmyd-splats' }];
  b.json.scenes = [{ nodes: [0] }];
  b.json.scene = 0;

  return b.finish();
}

// ---------------------------------------------------------------------------
// Reading back, for tests and for round-tripping
// ---------------------------------------------------------------------------

export interface ParsedGlb {
  json: Record<string, any>;
  bin: Uint8Array;
}

export function parseGlb(bytes: Uint8Array): ParsedGlb {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== GLB_MAGIC) throw new Error('GLB: bad magic');
  const version = view.getUint32(4, true);
  if (version !== 2) throw new Error(`GLB: unsupported version ${version}`);
  const declaredLength = view.getUint32(8, true);
  if (declaredLength !== bytes.byteLength) {
    throw new Error(
      `GLB: header says ${declaredLength} bytes, buffer is ${bytes.byteLength}`,
    );
  }

  let offset = 12;
  let json: Record<string, any> | null = null;
  let bin = new Uint8Array(0);

  while (offset + 8 <= bytes.byteLength) {
    const chunkLength = view.getUint32(offset, true);
    const chunkType = view.getUint32(offset + 4, true);
    const data = bytes.subarray(offset + 8, offset + 8 + chunkLength);
    if (chunkType === CHUNK_JSON) json = JSON.parse(new TextDecoder().decode(data));
    else if (chunkType === CHUNK_BIN) bin = data;
    offset += 8 + chunkLength;
  }

  if (!json) throw new Error('GLB: no JSON chunk');
  return { json, bin };
}

/** Pull an accessor back out as a typed array. Used by tests and by the importer. */
export function readAccessor(glb: ParsedGlb, index: number): Float32Array | Uint32Array {
  const accessor = glb.json.accessors[index];
  const view = glb.json.bufferViews[accessor.bufferView];
  const components = TYPE_COMPONENTS[accessor.type as AccessorType];
  const start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
  const count = accessor.count * components;
  // The bin chunk is not guaranteed 4-aligned within the outer buffer, so copy
  // rather than aliasing — a misaligned typed-array view throws.
  switch (accessor.componentType) {
    case COMPONENT_TYPE.float32:
      return new Float32Array(glb.bin.slice(start, start + count * 4).buffer);
    case COMPONENT_TYPE.uint32:
      return new Uint32Array(glb.bin.slice(start, start + count * 4).buffer);
    case COMPONENT_TYPE.uint16: {
      const u16 = new Uint16Array(glb.bin.slice(start, start + count * 2).buffer);
      return Uint32Array.from(u16);
    }
    default:
      throw new Error(`GLB: unhandled componentType ${accessor.componentType}`);
  }
}

/** Convenience for callers that have a texture but no mesh-level material yet. */
export function textureFromPng(data: Uint8Array, width: number, height: number): TextureImage {
  return { data, width, height, mimeType: 'image/png' };
}
