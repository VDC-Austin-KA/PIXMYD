/**
 * The processing pipeline: a bundle in, a deliverable out.
 *
 * Runs entirely in the browser. That is the whole point of the project — the
 * deliverable is produced by the machine in front of you and never depends on
 * somebody else's cloud being up, in business, or willing to give it back.
 *
 * Progress is reported honestly, including the stage name, because "processing"
 * with a spinner for eight minutes is indistinguishable from a hang.
 */

import type { CaptureBundle, Mesh, PointCloud } from '@pixmyd/core/bundle';
import { TsdfVolume, extractSurface } from '@pixmyd/recon/tsdf';
import type { PinholeCamera } from '@pixmyd/core/bundle';
import { decodeDepth, type BundleSource } from './bundle-reader.ts';

export type Detail = 'fast' | 'balanced' | 'fine';

export const DETAIL_LEVELS: Record<Detail, { voxelSize: number; label: string; note: string }> = {
  fast: {
    voxelSize: 0.05,
    label: 'Fast',
    note: '50 mm voxels. Quick, and enough for volumes and context.',
  },
  balanced: {
    voxelSize: 0.025,
    label: 'Balanced',
    note: '25 mm voxels. The right default for as-built documentation.',
  },
  fine: {
    voxelSize: 0.012,
    label: 'Fine',
    note: '12 mm voxels. Slow and memory-hungry — a single room, not a floorplate.',
  },
};

export interface ProcessOptions {
  detail: Detail;
  /** Produce a mesh as well as a point cloud. Meshing roughly doubles the time. */
  mesh: boolean;
  /** Reject depth readings below this ARKit confidence: 0 low, 1 medium, 2 high. */
  minConfidence?: number;
  signal?: AbortSignal;
  onProgress?: (stage: string, fraction: number) => void;
}

export interface ProcessResult {
  points: PointCloud;
  mesh?: Mesh;
  /** Frames that carried usable depth and a pose. */
  integratedFrames: number;
  /** Frames skipped, with the reason, so a poor result is explainable. */
  skipped: { noPose: number; noDepth: number; unreadable: number };
  voxelSize: number;
  elapsedMs: number;
}

export class ProcessingError extends Error {
  /** What the user can do about it. Shown under the message. */
  readonly hint?: string;

  constructor(message: string, hint?: string) {
    super(message);
    this.name = 'ProcessingError';
    this.hint = hint;
  }
}

export async function processBundle(
  bundle: CaptureBundle,
  source: BundleSource,
  options: ProcessOptions,
): Promise<ProcessResult> {
  const started = performance.now();
  const voxelSize = DETAIL_LEVELS[options.detail].voxelSize;
  const report = options.onProgress ?? (() => {});

  const volume = new TsdfVolume({
    voxelSize,
    truncation: voxelSize * 3,
    minConfidence: options.minConfidence ?? 1,
  });

  const skipped = { noPose: 0, noDepth: 0, unreadable: 0 };
  let integrated = 0;

  report('Reading frames', 0);

  for (let i = 0; i < bundle.frames.length; i++) {
    if (options.signal?.aborted) throw new DOMException('Cancelled', 'AbortError');

    const frame = bundle.frames[i];
    if (!frame.pose) {
      skipped.noPose++;
      continue;
    }
    if (!frame.depth) {
      skipped.noDepth++;
      continue;
    }

    try {
      const depthBytes = await source.read(frame.depth.uri);
      const depth = decodeDepth(
        depthBytes,
        frame.depth.encoding,
        frame.depth.width,
        frame.depth.height,
      );

      let confidence: Uint8Array | undefined;
      if (frame.depth.confidenceUri) {
        confidence = await source.read(frame.depth.confidenceUri);
      }

      const camera = frame.depth.camera ?? bundle.manifest.cameras[frame.camera];
      if (!camera || camera.model !== 'pinhole') {
        skipped.unreadable++;
        continue;
      }

      volume.integrate({
        depth,
        width: frame.depth.width,
        height: frame.depth.height,
        camera: camera as PinholeCamera,
        pose: frame.pose,
        confidence,
      });
      integrated++;
    } catch {
      // One unreadable frame should not end a twenty-minute capture. Count it,
      // and let the caller decide whether the total is acceptable.
      skipped.unreadable++;
    }

    if (i % 4 === 0) {
      // Fusion is the bulk of the work; meshing is the remainder.
      const span = options.mesh ? 0.7 : 0.9;
      report('Fusing depth', 0.02 + span * (i / bundle.frames.length));
      // Yield so the progress bar actually paints. Without this the browser
      // shows a frozen page for the whole run and users kill the tab.
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  }

  if (integrated === 0) {
    throw new ProcessingError(
      'No frames could be fused.',
      skipped.noDepth > 0
        ? 'This capture has no depth data. Photogrammetry-only reconstruction needs ' +
          'structure-from-motion, which is not built yet — see the README.'
        : 'Every frame was missing a pose or unreadable. The capture may be truncated.',
    );
  }

  report('Extracting points', options.mesh ? 0.74 : 0.93);
  const extracted = volume.extractPoints();
  const points: PointCloud = {
    positions: extracted.positions,
    colors: extracted.colors.length > 0 ? extracted.colors : undefined,
    count: extracted.count,
  };

  let mesh: Mesh | undefined;
  if (options.mesh) {
    report('Building surface', 0.8);
    await new Promise((resolve) => setTimeout(resolve, 0));
    mesh = extractSurface(volume, { minComponentTriangles: 32 });
    if (mesh.indices.length === 0) mesh = undefined;
  }

  report('Done', 1);

  return {
    points,
    mesh,
    integratedFrames: integrated,
    skipped,
    voxelSize,
    elapsedMs: performance.now() - started,
  };
}

/**
 * A rough time estimate.
 *
 * Deliberately labelled rough in the UI. It is a linear model fitted to nothing
 * — the constant is a guess — but a wrong estimate that sets expectations beats
 * no estimate, and users make different choices when they know it is minutes
 * rather than seconds.
 */
export function estimateSeconds(frameCount: number, detail: Detail, mesh: boolean): number {
  const perFrame = { fast: 0.05, balanced: 0.12, fine: 0.4 }[detail];
  return Math.max(1, frameCount * perFrame * (mesh ? 1.6 : 1));
}
