/**
 * Truncated signed distance field fusion.
 *
 * This is the path from an iPhone LiDAR capture to a metric mesh, and it is the
 * one part of the reconstruction stack that does not need to guess at anything:
 * the depth is measured, the poses come from ARKit, and fusing them is
 * arithmetic. Photogrammetry and splatting infer geometry; this integrates it.
 *
 * The method is Curless & Levoy (1996), still the standard: for each depth
 * frame, walk the voxels it can see, compute the signed distance from the voxel
 * to the measured surface along the viewing ray, truncate it to a band, and
 * accumulate a weighted running average. Averaging is what turns noisy 10 mm
 * sensor readings into a surface good to a couple of millimetres — the noise is
 * zero-mean and the surface is not.
 *
 * Two deliberate choices worth stating:
 *
 * **Sparse blocks, not a dense grid.** A dense 5 cm grid over a 30 m room is
 * 216 million voxels, nearly all of them empty air. Blocks of 8^3 voxels
 * allocated on demand keep it to the surface shell.
 *
 * **Confidence gates integration.** ARKit reports per-pixel confidence, and low
 * confidence is not a slightly worse measurement — it is frequently a hallucinated
 * one, at a depth discontinuity or on a dark or specular surface. Averaging it in
 * pulls the surface off the wall.
 */

import { v3, bounds as boundsOps, type Bounds, type Vec3 } from '@pixmyd/core/math';
import type { CameraModel, Pose } from '@pixmyd/core/bundle';
import { unprojectPixel, worldToCamera, projectPoint } from './camera.ts';

/** Voxels per block edge. 8 gives 512 voxels per block. */
export const BLOCK_SIZE = 8;
const BLOCK_VOXELS = BLOCK_SIZE * BLOCK_SIZE * BLOCK_SIZE;

export interface TsdfOptions {
  /** Voxel edge length in metres. 0.02-0.05 suits room-scale LiDAR capture. */
  voxelSize?: number;
  /**
   * Truncation distance in metres. The band either side of the surface within
   * which the field is stored. Should be a few voxels — too small and thin
   * surfaces are missed, too large and opposite faces of a wall interfere.
   * Defaults to 3 voxels.
   */
  truncation?: number;
  /** Depth readings beyond this are ignored. LiDAR on a phone is good to ~5 m. */
  maxDepth?: number;
  minDepth?: number;
  /** Minimum ARKit confidence to integrate: 0 low, 1 medium, 2 high. */
  minConfidence?: number;
  /**
   * Weight readings by 1/depth^2. Depth noise grows with range, so a reading at
   * 4 m should not outvote one at 0.5 m.
   */
  weightByDepth?: boolean;
}

interface Block {
  /** Block coordinates (in blocks, not voxels). */
  bx: number;
  by: number;
  bz: number;
  /** Truncated signed distance, normalized to [-1, 1] by the truncation band. */
  sdf: Float32Array;
  weight: Float32Array;
  colorR: Float32Array;
  colorG: Float32Array;
  colorB: Float32Array;
}

export interface DepthFrame {
  depth: Float32Array;
  width: number;
  height: number;
  camera: CameraModel;
  pose: Pose;
  /** Per-pixel confidence, same dimensions as depth. 0/1/2. */
  confidence?: Uint8Array;
  /** Optional RGB, 3 bytes per pixel, at the depth resolution. */
  color?: Uint8Array;
}

export class TsdfVolume {
  readonly voxelSize: number;
  readonly truncation: number;
  private readonly options: Required<Omit<TsdfOptions, 'voxelSize' | 'truncation'>>;
  private readonly blocks = new Map<number, Block>();
  private frameCount = 0;

  constructor(options: TsdfOptions = {}) {
    this.voxelSize = options.voxelSize ?? 0.03;
    this.truncation = options.truncation ?? this.voxelSize * 3;
    this.options = {
      maxDepth: options.maxDepth ?? 5,
      minDepth: options.minDepth ?? 0.15,
      minConfidence: options.minConfidence ?? 1,
      weightByDepth: options.weightByDepth ?? true,
    };
  }

  get blockCount(): number {
    return this.blocks.size;
  }

  get integratedFrames(): number {
    return this.frameCount;
  }

  /**
   * Hash block coordinates into a Map key.
   *
   * A 21-bit signed field per axis packed into a double covers +/- 1 million
   * blocks per axis, which at 8 voxels of 30 mm is +/- 250 km. Using a number
   * rather than a string key matters: this is called several times per voxel per
   * frame and string hashing would dominate the profile.
   */
  private static key(bx: number, by: number, bz: number): number {
    const OFFSET = 1 << 20;
    return ((bx + OFFSET) * 2097152 + (by + OFFSET)) * 2097152 + (bz + OFFSET);
  }

  private getOrCreateBlock(bx: number, by: number, bz: number): Block {
    const k = TsdfVolume.key(bx, by, bz);
    let block = this.blocks.get(k);
    if (!block) {
      block = {
        bx, by, bz,
        sdf: new Float32Array(BLOCK_VOXELS),
        weight: new Float32Array(BLOCK_VOXELS),
        colorR: new Float32Array(BLOCK_VOXELS),
        colorG: new Float32Array(BLOCK_VOXELS),
        colorB: new Float32Array(BLOCK_VOXELS),
      };
      this.blocks.set(k, block);
    }
    return block;
  }

  private getBlock(bx: number, by: number, bz: number): Block | undefined {
    return this.blocks.get(TsdfVolume.key(bx, by, bz));
  }

  /**
   * Integrate one depth frame.
   *
   * Rather than sweeping the whole volume per frame, this walks the *pixels* and
   * carves a short segment of the ray around each measurement. That makes the
   * cost proportional to observed surface area instead of to volume, which is
   * the difference between interactive and not.
   */
  integrate(frame: DepthFrame): void {
    const { depth, width, height, camera, pose, confidence, color } = frame;
    const { maxDepth, minDepth, minConfidence, weightByDepth } = this.options;
    const trunc = this.truncation;
    const inv = 1 / this.voxelSize;

    // Step along the ray by half a voxel so no voxel in the band is skipped.
    const step = this.voxelSize * 0.5;
    const stepCount = Math.ceil((2 * trunc) / step);

    for (let py = 0; py < height; py++) {
      for (let px = 0; px < width; px++) {
        const i = py * width + px;
        const d = depth[i];
        if (!(d > minDepth && d < maxDepth)) continue;
        if (confidence && confidence[i] < minConfidence) continue;

        // Surface point and the ray it sits on, both in world space.
        const localSurface = unprojectPixel({ x: px + 0.5, y: py + 0.5 }, d, camera);
        const rayLength = v3.length(localSurface);
        if (rayLength < 1e-9) continue;

        const worldSurface = v3.add(rotateByPose(localSurface, pose), pose.t);
        const worldRay = v3.normalize(v3.sub(worldSurface, pose.t));

        const weightBase = weightByDepth ? Math.min(1, 1 / (d * d)) : 1;
        const confidenceWeight = confidence ? (confidence[i] + 1) / 3 : 1;
        const weight = weightBase * confidenceWeight;

        let r = 0, g = 0, b = 0;
        if (color) {
          r = color[i * 3] / 255;
          g = color[i * 3 + 1] / 255;
          b = color[i * 3 + 2] / 255;
        }

        // March from trunc in front of the surface to trunc behind it.
        for (let s = 0; s <= stepCount; s++) {
          const along = -trunc + s * step;
          const p = v3.add(worldSurface, v3.scale(worldRay, along));

          const vx = Math.floor(p[0] * inv);
          const vy = Math.floor(p[1] * inv);
          const vz = Math.floor(p[2] * inv);

          // Signed distance is measured along the *viewing ray*, positive in
          // front of the surface (toward the camera). This is the projective
          // SDF; it is only exact where the ray meets the surface head-on, and
          // that approximation is why grazing views produce a thicker band.
          const voxelCentre: Vec3 = [
            (vx + 0.5) * this.voxelSize,
            (vy + 0.5) * this.voxelSize,
            (vz + 0.5) * this.voxelSize,
          ];
          // Signed distance along the viewing ray: positive in front of the
          // surface (nearer the camera), negative behind it.
          const sdf = rayLength - v3.distance(voxelCentre, pose.t);
          if (sdf < -trunc) continue;
          const normalized = Math.max(-1, Math.min(1, sdf / trunc));

          this.updateVoxel(vx, vy, vz, normalized, weight, r, g, b, color !== undefined);
        }
      }
    }
    this.frameCount++;
  }

  private updateVoxel(
    vx: number, vy: number, vz: number,
    sdf: number, weight: number,
    r: number, g: number, b: number, hasColor: boolean,
  ): void {
    const bx = Math.floor(vx / BLOCK_SIZE);
    const by = Math.floor(vy / BLOCK_SIZE);
    const bz = Math.floor(vz / BLOCK_SIZE);
    const block = this.getOrCreateBlock(bx, by, bz);

    const lx = vx - bx * BLOCK_SIZE;
    const ly = vy - by * BLOCK_SIZE;
    const lz = vz - bz * BLOCK_SIZE;
    const idx = (lz * BLOCK_SIZE + ly) * BLOCK_SIZE + lx;

    const w0 = block.weight[idx];
    const w1 = w0 + weight;
    // Running weighted average — Curless & Levoy's incremental form.
    block.sdf[idx] = (block.sdf[idx] * w0 + sdf * weight) / w1;
    if (hasColor) {
      block.colorR[idx] = (block.colorR[idx] * w0 + r * weight) / w1;
      block.colorG[idx] = (block.colorG[idx] * w0 + g * weight) / w1;
      block.colorB[idx] = (block.colorB[idx] * w0 + b * weight) / w1;
    }
    block.weight[idx] = w1;
  }

  /** Sample the field at integer voxel coordinates. Returns null where unseen. */
  sample(vx: number, vy: number, vz: number): { sdf: number; weight: number; color: Vec3 } | null {
    const bx = Math.floor(vx / BLOCK_SIZE);
    const by = Math.floor(vy / BLOCK_SIZE);
    const bz = Math.floor(vz / BLOCK_SIZE);
    const block = this.getBlock(bx, by, bz);
    if (!block) return null;
    const lx = vx - bx * BLOCK_SIZE;
    const ly = vy - by * BLOCK_SIZE;
    const lz = vz - bz * BLOCK_SIZE;
    const idx = (lz * BLOCK_SIZE + ly) * BLOCK_SIZE + lx;
    if (block.weight[idx] === 0) return null;
    return {
      sdf: block.sdf[idx],
      weight: block.weight[idx],
      color: [block.colorR[idx], block.colorG[idx], block.colorB[idx]],
    };
  }

  /** World-space bounds of every allocated block. */
  bounds(): Bounds {
    const b = boundsOps.empty();
    for (const block of this.blocks.values()) {
      boundsOps.expand(b, [
        block.bx * BLOCK_SIZE * this.voxelSize,
        block.by * BLOCK_SIZE * this.voxelSize,
        block.bz * BLOCK_SIZE * this.voxelSize,
      ]);
      boundsOps.expand(b, [
        (block.bx + 1) * BLOCK_SIZE * this.voxelSize,
        (block.by + 1) * BLOCK_SIZE * this.voxelSize,
        (block.bz + 1) * BLOCK_SIZE * this.voxelSize,
      ]);
    }
    return b;
  }

  /** Voxel index range covering the allocated blocks, inclusive. */
  voxelBounds(): { min: [number, number, number]; max: [number, number, number] } {
    let minX = Infinity, minY = Infinity, minZ = Infinity;
    let maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity;
    for (const block of this.blocks.values()) {
      minX = Math.min(minX, block.bx * BLOCK_SIZE);
      minY = Math.min(minY, block.by * BLOCK_SIZE);
      minZ = Math.min(minZ, block.bz * BLOCK_SIZE);
      maxX = Math.max(maxX, (block.bx + 1) * BLOCK_SIZE - 1);
      maxY = Math.max(maxY, (block.by + 1) * BLOCK_SIZE - 1);
      maxZ = Math.max(maxZ, (block.bz + 1) * BLOCK_SIZE - 1);
    }
    if (!Number.isFinite(minX)) {
      return { min: [0, 0, 0], max: [-1, -1, -1] };
    }
    return { min: [minX, minY, minZ], max: [maxX, maxY, maxZ] };
  }

  /**
   * Extract the observed surface as points at zero crossings.
   *
   * Cheaper than meshing and often what is actually wanted — a point cloud
   * export does not need a surface at all.
   */
  extractPoints(minWeight = 0): {
    positions: Float64Array;
    colors: Uint8Array;
    count: number;
  } {
    // `minWeight` is in accumulated-weight units, which are not observation
    // counts: with `weightByDepth` on, one reading at 1.5 m contributes 0.44,
    // so a threshold of 1 would silently discard a whole single-pass capture.
    // Zero means "every voxel that was ever observed" — `sample` already
    // rejects untouched voxels. Raise it to demand repeated observation.
    const positions: number[] = [];
    const colors: number[] = [];
    const { min, max } = this.voxelBounds();

    for (let vz = min[2]; vz <= max[2]; vz++) {
      for (let vy = min[1]; vy <= max[1]; vy++) {
        for (let vx = min[0]; vx <= max[0]; vx++) {
          const here = this.sample(vx, vy, vz);
          if (!here || here.weight < minWeight) continue;
          // Emit where the field crosses zero along +X, +Y or +Z.
          for (const [dx, dy, dz] of [[1, 0, 0], [0, 1, 0], [0, 0, 1]] as const) {
            const next = this.sample(vx + dx, vy + dy, vz + dz);
            if (!next || next.weight < minWeight) continue;
            if (here.sdf === next.sdf) continue;
            if ((here.sdf > 0) === (next.sdf > 0)) continue;
            const t = here.sdf / (here.sdf - next.sdf);
            positions.push(
              (vx + 0.5 + dx * t) * this.voxelSize,
              (vy + 0.5 + dy * t) * this.voxelSize,
              (vz + 0.5 + dz * t) * this.voxelSize,
            );
            const c = t < 0.5 ? here.color : next.color;
            colors.push(
              Math.round(c[0] * 255),
              Math.round(c[1] * 255),
              Math.round(c[2] * 255),
            );
          }
        }
      }
    }

    return {
      positions: Float64Array.from(positions),
      colors: Uint8Array.from(colors),
      count: positions.length / 3,
    };
  }
}

/** Rotate a camera-space vector into world space using the pose quaternion. */
function rotateByPose(local: Vec3, pose: Pose): Vec3 {
  const [x, y, z, w] = pose.q;
  const tx = 2 * (y * local[2] - z * local[1]);
  const ty = 2 * (z * local[0] - x * local[2]);
  const tz = 2 * (x * local[1] - y * local[0]);
  return [
    local[0] + w * tx + (y * tz - z * ty),
    local[1] + w * ty + (z * tx - x * tz),
    local[2] + w * tz + (x * ty - y * tx),
  ];
}

/** True when the point projects inside the frame and is in front of the camera. */
export function isVisible(world: Vec3, pose: Pose, camera: CameraModel): boolean {
  return projectPoint(worldToCamera(world, pose), camera).visible;
}
