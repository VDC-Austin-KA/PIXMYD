/**
 * One entry point for every export the toolchain offers.
 *
 * Callers ask for a format by name and get back files. The point of routing it
 * all through here is that the awkward decisions — units, axis convention,
 * whether an origin needs to survive — get made once, in one place, instead of
 * being rediscovered at each call site.
 */

import type { Mesh, PointCloud, SplatCloud } from '@pixmyd/core/bundle';
import { writeMeshPly, writePointCloudPly, writeSplatPly } from './ply.ts';
import { writeObj, writePointCloudObj } from './obj.ts';
import { writeMeshGlb, writeSplatGlb } from './glb.ts';
import { writeMeshFbx } from './fbx.ts';
import { writePointCloudE57 } from './e57.ts';
import { writeLas } from './las.ts';

export type MeshFormat = 'glb' | 'obj' | 'fbx' | 'ply';
export type PointFormat = 'ply' | 'e57' | 'las' | 'obj';
export type SplatFormat = 'ply' | 'glb';

export interface ExportFile {
  filename: string;
  bytes: Uint8Array;
  mimeType: string;
}

export interface ExportOptions {
  /** Basename without extension. */
  name?: string;
  /** Source data is Z-up (survey/BIM). Y-up targets get rotated on the way out. */
  zUp?: boolean;
  /** FBX only. Defaults to centimetres — see fbx.ts for why. */
  fbxUnits?: 'cm' | 'm';
  /** LAS/E57 only. Coordinate system as WKT, carried into the file. */
  wkt?: string;
  /** E57/PLY only. float32 coordinates halve the file at the cost of precision. */
  singlePrecision?: boolean;
}

const textEncoder = new TextEncoder();

export function exportMesh(
  mesh: Mesh,
  format: MeshFormat,
  options: ExportOptions = {},
): ExportFile[] {
  const name = options.name ?? mesh.name ?? 'pixmyd';
  switch (format) {
    case 'glb':
      return [{
        filename: `${name}.glb`,
        bytes: writeMeshGlb(mesh, { zUpToYUp: options.zUp, name }),
        mimeType: 'model/gltf-binary',
      }];

    case 'fbx':
      return [{
        filename: `${name}.fbx`,
        bytes: writeMeshFbx(mesh, { zUpToYUp: options.zUp, units: options.fbxUnits, name }),
        mimeType: 'application/octet-stream',
      }];

    case 'ply':
      return [{
        filename: `${name}.ply`,
        bytes: writeMeshPly(mesh),
        mimeType: 'application/octet-stream',
      }];

    case 'obj': {
      // OBJ is three files that reference each other by name, so the material
      // library name has to be decided here and used consistently.
      const result = writeObj(mesh, {
        name,
        materialLibrary: `${name}.mtl`,
        zUpToYUp: options.zUp,
      });
      const files: ExportFile[] = [
        { filename: `${name}.obj`, bytes: textEncoder.encode(result.obj), mimeType: 'text/plain' },
      ];
      if (result.mtl) {
        files.push({
          filename: `${name}.mtl`,
          bytes: textEncoder.encode(result.mtl),
          mimeType: 'text/plain',
        });
      }
      if (result.texture && result.textureFilename) {
        files.push({
          filename: result.textureFilename,
          bytes: result.texture,
          mimeType: mesh.texture!.mimeType,
        });
      }
      return files;
    }
  }
}

export function exportPointCloud(
  cloud: PointCloud,
  format: PointFormat,
  options: ExportOptions = {},
): ExportFile[] {
  const name = options.name ?? 'pixmyd';
  switch (format) {
    case 'ply':
      return [{
        filename: `${name}.ply`,
        bytes: writePointCloudPly(cloud, {
          positionType: options.singlePrecision ? 'float32' : 'float64',
        }),
        mimeType: 'application/octet-stream',
      }];

    case 'e57':
      return [{
        filename: `${name}.e57`,
        bytes: writePointCloudE57(cloud, {
          name,
          coordinatePrecision: options.singlePrecision ? 'single' : 'double',
          coordinateMetadata: options.wkt,
        }),
        mimeType: 'application/octet-stream',
      }];

    case 'las':
      return [{
        filename: `${name}.las`,
        bytes: writeLas(cloud, { wkt: options.wkt }),
        mimeType: 'application/octet-stream',
      }];

    case 'obj':
      return [{
        filename: `${name}.obj`,
        bytes: textEncoder.encode(writePointCloudObj(cloud, { zUpToYUp: options.zUp })),
        mimeType: 'text/plain',
      }];
  }
}

export function exportSplats(
  splats: SplatCloud,
  format: SplatFormat,
  options: ExportOptions = {},
): ExportFile[] {
  const name = options.name ?? 'pixmyd';
  switch (format) {
    case 'ply':
      return [{
        filename: `${name}.ply`,
        bytes: writeSplatPly(splats),
        mimeType: 'application/octet-stream',
      }];
    case 'glb':
      return [{
        filename: `${name}.glb`,
        bytes: writeSplatGlb(splats, { zUpToYUp: options.zUp, name }),
        mimeType: 'model/gltf-binary',
      }];
  }
}

// ---------------------------------------------------------------------------
// RCS / RCP
// ---------------------------------------------------------------------------

/**
 * Autodesk ReCap's RCS (scan) and RCP (project) formats are proprietary and
 * have **no published specification**. There is no open reader or writer, and
 * Autodesk provides no redistributable library for producing them.
 *
 * Guessing at the layout would produce files that fail to open, which is worse
 * than not offering the format — a deliverable that silently does not work
 * costs more than one that is honestly absent. So PIXMYD does not write RCS.
 *
 * What it does instead is make the conversion a one-step, scriptable operation
 * from a format that is fully specified. `rcsBridgeInstructions()` returns the
 * exact commands. The E57 that goes in carries the georeference, the per-scan
 * poses and the colour, so nothing is lost in the hop.
 */
export interface RcsBridge {
  /** The file to hand to the converter. */
  source: ExportFile;
  /** Human-readable steps, in preference order. */
  routes: { name: string; requires: string; steps: string[] }[];
}

export function rcsBridgeInstructions(
  cloud: PointCloud,
  options: ExportOptions = {},
): RcsBridge {
  const name = options.name ?? 'pixmyd';
  // E57 is the right carrier: ReCap imports it natively and it is the only
  // one of our outputs that keeps georeference, pose and colour together.
  const [source] = exportPointCloud(cloud, 'e57', options);

  return {
    source,
    routes: [
      {
        name: 'ReCap command line',
        requires: 'Autodesk ReCap Pro on Windows',
        steps: [
          `Export ${source.filename} from PIXMYD.`,
          'Run:  "C:\\Program Files\\Autodesk\\ReCap\\Recap.exe" ' +
          `/import "${source.filename}" /output "${name}.rcp"`,
          `ReCap writes ${name}.rcp alongside a Support folder of .rcs scans.`,
          'The .rcp is what AutoCAD, Revit and Navisworks attach.',
        ],
      },
      {
        name: 'ReCap desktop',
        requires: 'Autodesk ReCap Pro, any platform it runs on',
        steps: [
          'New Project > Import Point Cloud.',
          `Select ${source.filename}.`,
          'Leave "Apply structure" on to keep the per-scan poses.',
          'Index, then Launch Project. ReCap writes the .rcp and .rcs files.',
        ],
      },
      {
        name: 'Autodesk Platform Services',
        requires: 'An APS account with Model Derivative enabled',
        steps: [
          `Upload ${source.filename} to an OSS bucket.`,
          'POST a Model Derivative job targeting the RCP output format.',
          'Poll the manifest and download the derivative when it reports success.',
          'This is the route to automate if the conversion has to run unattended.',
        ],
      },
    ],
  };
}
