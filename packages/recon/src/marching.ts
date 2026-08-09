/**
 * Surface extraction from a signed distance field, by marching tetrahedra.
 *
 * **Why tetrahedra rather than cubes.** Marching cubes needs a 256-entry
 * triangle table, and several of its cases are genuinely ambiguous — the same
 * corner signs admit more than one topology, and picking wrong punches a hole
 * in the surface. Marching tetrahedra decomposes each cube into six tetrahedra,
 * each of which has only 16 sign combinations and no ambiguity at all: a
 * tetrahedron's four corners can only ever separate one vertex from three, or
 * two from two. The surface is watertight by construction.
 *
 * The cost is roughly twice the triangle count for the same field, and slightly
 * less regular triangles. For scan-to-mesh that is the right trade: a hole in an
 * as-built is a defect somebody has to go back to site to fix, and a decimator
 * can remove triangles later but nothing can invent missing surface.
 *
 * The decomposition below splits the cube along the 0-6 main diagonal, which is
 * the standard choice — every tetrahedron shares that edge, so adjacent cubes
 * agree on their shared faces and no cracks appear between them.
 */

import type { Mesh } from '@pixmyd/core/bundle';
import type { Vec3 } from '@pixmyd/core/math';

/**
 * Samples a scalar field. Return `null` where the field is unobserved — that is
 * different from "far from the surface", and the mesher must not interpolate
 * across the gap and invent geometry in a region nobody looked at.
 */
export type FieldSampler = (x: number, y: number, z: number) => number | null;

/** Optional colour lookup at a grid point, RGB in [0, 1]. */
export type ColorSampler = (x: number, y: number, z: number) => Vec3 | null;

export interface MarchOptions {
  /** Inclusive grid bounds, in voxel indices. */
  min: [number, number, number];
  max: [number, number, number];
  /** World size of one voxel, metres. */
  voxelSize: number;
  /**
   * World position of voxel (0,0,0)'s *centre*. TSDF volumes index from the
   * origin, so this is usually half a voxel.
   */
  originOffset?: number;
  /** Isovalue to extract. Zero for a signed distance field. */
  isolevel?: number;
  color?: ColorSampler;
}

/**
 * How close a sample may get to the isolevel before it is displaced.
 *
 * Small enough to be far below any real measurement precision (this is a
 * fraction of a micrometre against a millimetre-scale field), large enough that
 * float arithmetic cannot land back on the isolevel afterwards.
 */
const ISOLEVEL_EPSILON = 1e-7;

/** Corner offsets of a cube, in the canonical order used by the tables below. */
const CUBE_CORNERS: readonly [number, number, number][] = [
  [0, 0, 0], // 0
  [1, 0, 0], // 1
  [1, 1, 0], // 2
  [0, 1, 0], // 3
  [0, 0, 1], // 4
  [1, 0, 1], // 5
  [1, 1, 1], // 6
  [0, 1, 1], // 7
];

/**
 * Six tetrahedra tiling the cube, all sharing the 0-6 diagonal.
 *
 * Sharing one diagonal across every tetrahedron is what makes neighbouring
 * cubes agree: each face of the cube is split by a diagonal that the adjacent
 * cube derives the same way, so the two surfaces meet exactly.
 */
const TETRAHEDRA: readonly [number, number, number, number][] = [
  [0, 5, 1, 6],
  [0, 1, 2, 6],
  [0, 2, 3, 6],
  [0, 3, 7, 6],
  [0, 7, 4, 6],
  [0, 4, 5, 6],
];

/** The six edges of a tetrahedron, as index pairs into its four corners. */
const TET_EDGES: readonly [number, number][] = [
  [0, 1], [1, 2], [2, 0], [0, 3], [1, 3], [2, 3],
];

/**
 * Which tetrahedron edges the surface crosses, per sign mask.
 *
 * The mask has one bit per corner, set when that corner is inside (field below
 * the isolevel). Each entry lists edge indices in triples; two triples means two
 * triangles. Cases 0 and 15 are empty — wholly inside or wholly outside.
 *
 * Only three shapes exist, which is the whole appeal of tetrahedra:
 *   - one corner separated from three  -> one triangle
 *   - two corners separated from two   -> two triangles (a quad)
 *   - all four on one side             -> nothing
 */
const TET_TRIANGLES: readonly (readonly number[])[] = [
  [],              // 0000
  [0, 3, 2],       // 0001  corner 0 alone
  [0, 1, 4],       // 0010  corner 1 alone
  [1, 4, 2, 2, 4, 3], // 0011  edge 0-1 inside
  [1, 2, 5],       // 0100  corner 2 alone
  [0, 3, 5, 0, 5, 1], // 0101  corners 0,2
  [0, 2, 5, 0, 5, 4], // 0110  corners 1,2
  [5, 4, 3],       // 0111  corner 3 alone (outside)
  [3, 4, 5],       // 1000  corner 3 alone
  [0, 4, 5, 0, 5, 2], // 1001  corners 0,3
  [0, 1, 5, 0, 5, 3], // 1010  corners 1,3
  [1, 5, 2],       // 1011  corner 2 alone (outside)
  [2, 4, 1, 2, 3, 4], // 1100  corners 2,3
  [0, 4, 1],       // 1101  corner 1 alone (outside)
  [0, 2, 3],       // 1110  corner 0 alone (outside)
  [],              // 1111
];

interface Corner {
  value: number;
  position: Vec3;
  color: Vec3 | null;
}

/**
 * Extract an isosurface.
 *
 * Vertices are welded by grid edge, so the result is an indexed mesh with each
 * vertex shared by every triangle that touches it — which is what makes it
 * watertight in the topological sense, not merely gap-free visually.
 */
export function marchingTetrahedra(field: FieldSampler, options: MarchOptions): Mesh {
  const { min, max, voxelSize } = options;
  const isolevel = options.isolevel ?? 0;
  const offset = options.originOffset ?? voxelSize * 0.5;

  const positions: number[] = [];
  const colors: number[] = [];
  const indices: number[] = [];

  /**
   * Vertices are keyed by the *edge* they sit on, identified by its two grid
   * endpoints in a canonical order. Two adjacent tetrahedra crossing the same
   * edge must produce the same vertex, or the mesh is a soup of unshared
   * triangles that looks correct and is not watertight.
   */
  const vertexCache = new Map<string, number>();

  const worldOf = (x: number, y: number, z: number): Vec3 => [
    x * voxelSize + offset,
    y * voxelSize + offset,
    z * voxelSize + offset,
  ];

  const edgeVertex = (
    a: [number, number, number], av: number, ac: Vec3 | null,
    b: [number, number, number], bv: number, bc: Vec3 | null,
  ): number => {
    // Canonical ordering so the two tetrahedra sharing this edge agree on the key.
    const swap =
      a[0] > b[0] || (a[0] === b[0] && (a[1] > b[1] || (a[1] === b[1] && a[2] > b[2])));
    const [p, pv, pc, q, qv, qc] = swap
      ? [b, bv, bc, a, av, ac]
      : [a, av, ac, b, bv, bc];

    const key = `${p[0]},${p[1]},${p[2]}|${q[0]},${q[1]},${q[2]}`;
    const cached = vertexCache.get(key);
    if (cached !== undefined) return cached;

    // Linear interpolation to the crossing. Guard the degenerate case where
    // both endpoints sit exactly on the isolevel.
    const denominator = qv - pv;
    const t = Math.abs(denominator) < 1e-12 ? 0.5 : (isolevel - pv) / denominator;
    const clamped = t < 0 ? 0 : t > 1 ? 1 : t;

    const pw = worldOf(p[0], p[1], p[2]);
    const qw = worldOf(q[0], q[1], q[2]);
    positions.push(
      pw[0] + (qw[0] - pw[0]) * clamped,
      pw[1] + (qw[1] - pw[1]) * clamped,
      pw[2] + (qw[2] - pw[2]) * clamped,
    );

    if (pc && qc) {
      colors.push(
        pc[0] + (qc[0] - pc[0]) * clamped,
        pc[1] + (qc[1] - pc[1]) * clamped,
        pc[2] + (qc[2] - pc[2]) * clamped,
      );
    } else if (options.color) {
      // One endpoint had no colour; use whichever exists rather than blending
      // toward black, which would draw a dark seam along every such edge.
      const fallback = pc ?? qc ?? [1, 1, 1];
      colors.push(fallback[0], fallback[1], fallback[2]);
    }

    const index = positions.length / 3 - 1;
    vertexCache.set(key, index);
    return index;
  };

  const corners: Corner[] = new Array(8);
  const cornerGrid: [number, number, number][] = new Array(8);

  for (let z = min[2]; z < max[2]; z++) {
    for (let y = min[1]; y < max[1]; y++) {
      for (let x = min[0]; x < max[0]; x++) {
        // Gather the eight corners. A cube with any unobserved corner is
        // skipped entirely: interpolating into a region nobody measured would
        // fabricate surface, and fabricated surface in an as-built is worse
        // than a hole because it looks like a measurement.
        let complete = true;
        for (let c = 0; c < 8; c++) {
          const gx = x + CUBE_CORNERS[c][0];
          const gy = y + CUBE_CORNERS[c][1];
          const gz = z + CUBE_CORNERS[c][2];
          const sampled = field(gx, gy, gz);
          if (sampled === null) {
            complete = false;
            break;
          }
          // Nudge samples that sit exactly on the isolevel.
          //
          // A grid point with value exactly equal to the isolevel puts the
          // crossing exactly *on* that grid point, so every edge meeting it
          // produces the same vertex — collapsing triangles to zero area. Those
          // slivers are invisible in the geometry but poison vertex normals,
          // which are area-weighted: a fan of cancelling zero-area faces yields
          // a zero normal and a black shading artefact. Displacing by an
          // epsilon puts the crossing just off the grid point instead, which
          // moves the surface by far less than any measurement it represents.
          const value =
            Math.abs(sampled - isolevel) < ISOLEVEL_EPSILON ? isolevel + ISOLEVEL_EPSILON : sampled;
          cornerGrid[c] = [gx, gy, gz];
          corners[c] = {
            value,
            position: worldOf(gx, gy, gz),
            color: options.color ? options.color(gx, gy, gz) : null,
          };
        }
        if (!complete) continue;

        for (const tet of TETRAHEDRA) {
          let mask = 0;
          for (let i = 0; i < 4; i++) {
            if (corners[tet[i]].value < isolevel) mask |= 1 << i;
          }
          const triangles = TET_TRIANGLES[mask];
          if (triangles.length === 0) continue;

          for (let t = 0; t < triangles.length; t += 3) {
            // Emitted in reverse so the surface winds counter-clockwise when
            // viewed from *outside*. The table is built with the sign
            // convention "negative is inside", which orients its triangles the
            // other way; without this reversal the mesh is inside out — a
            // defect that renders as a plausible-looking solid under two-sided
            // lighting and is only obvious once it reaches a tool that
            // backface-culls. The signed-volume test pins it down.
            for (let k = 2; k >= 0; k--) {
              const edge = TET_EDGES[triangles[t + k]];
              const a = tet[edge[0]];
              const b = tet[edge[1]];
              indices.push(
                edgeVertex(
                  cornerGrid[a], corners[a].value, corners[a].color,
                  cornerGrid[b], corners[b].value, corners[b].color,
                ),
              );
            }
          }
        }
      }
    }
  }

  const mesh: Mesh = {
    positions: Float32Array.from(positions),
    indices: Uint32Array.from(indices),
  };
  if (options.color && colors.length === positions.length) {
    mesh.colors = Float32Array.from(colors);
  }
  return mesh;
}

/**
 * Area-weighted vertex normals.
 *
 * The cross product of two triangle edges has magnitude proportional to twice
 * the triangle's area, so *not* normalising before accumulating gives area
 * weighting for free — which is what you want, since a sliver triangle should
 * not steer a vertex normal as much as a large one.
 */
export function computeVertexNormals(mesh: Mesh): Float32Array {
  const normals = new Float32Array(mesh.positions.length);
  const p = mesh.positions;

  for (let i = 0; i < mesh.indices.length; i += 3) {
    const a = mesh.indices[i] * 3;
    const b = mesh.indices[i + 1] * 3;
    const c = mesh.indices[i + 2] * 3;

    const abx = p[b] - p[a], aby = p[b + 1] - p[a + 1], abz = p[b + 2] - p[a + 2];
    const acx = p[c] - p[a], acy = p[c + 1] - p[a + 1], acz = p[c + 2] - p[a + 2];

    const nx = aby * acz - abz * acy;
    const ny = abz * acx - abx * acz;
    const nz = abx * acy - aby * acx;

    for (const base of [a, b, c]) {
      normals[base] += nx;
      normals[base + 1] += ny;
      normals[base + 2] += nz;
    }
  }

  for (let i = 0; i < normals.length; i += 3) {
    const length = Math.hypot(normals[i], normals[i + 1], normals[i + 2]);
    if (length > 1e-20) {
      normals[i] /= length;
      normals[i + 1] /= length;
      normals[i + 2] /= length;
    }
  }
  return normals;
}

/**
 * Drop connected components below a triangle count.
 *
 * Fusion leaves specks: a hand that passed through frame, a reflection off
 * glazing, a few voxels of noise floating in the middle of a room. They are
 * always small and always disconnected from the real surface, so component size
 * separates them cleanly.
 */
export function removeSmallComponents(mesh: Mesh, minTriangles = 32): Mesh {
  const triangleCount = mesh.indices.length / 3;
  if (triangleCount === 0) return mesh;

  // Union-find over vertices; triangles connect their three corners.
  const parent = new Int32Array(mesh.positions.length / 3);
  for (let i = 0; i < parent.length; i++) parent[i] = i;

  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root];
    // Path compression, so repeated lookups stay near-constant.
    while (parent[i] !== root) {
      const next = parent[i];
      parent[i] = root;
      i = next;
    }
    return root;
  };
  const union = (a: number, b: number): void => {
    const ra = find(a), rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  for (let i = 0; i < mesh.indices.length; i += 3) {
    union(mesh.indices[i], mesh.indices[i + 1]);
    union(mesh.indices[i + 1], mesh.indices[i + 2]);
  }

  const componentSize = new Map<number, number>();
  for (let i = 0; i < mesh.indices.length; i += 3) {
    const root = find(mesh.indices[i]);
    componentSize.set(root, (componentSize.get(root) ?? 0) + 1);
  }

  const keptIndices: number[] = [];
  for (let i = 0; i < mesh.indices.length; i += 3) {
    const root = find(mesh.indices[i]);
    if ((componentSize.get(root) ?? 0) >= minTriangles) {
      keptIndices.push(mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]);
    }
  }

  // Re-index so unreferenced vertices are dropped rather than left orphaned.
  const remap = new Map<number, number>();
  const positions: number[] = [];
  const colors: number[] = [];
  const indices: number[] = [];

  for (const original of keptIndices) {
    let mapped = remap.get(original);
    if (mapped === undefined) {
      mapped = positions.length / 3;
      remap.set(original, mapped);
      positions.push(
        mesh.positions[original * 3],
        mesh.positions[original * 3 + 1],
        mesh.positions[original * 3 + 2],
      );
      if (mesh.colors) {
        colors.push(
          mesh.colors[original * 3],
          mesh.colors[original * 3 + 1],
          mesh.colors[original * 3 + 2],
        );
      }
    }
    indices.push(mapped);
  }

  const out: Mesh = {
    positions: Float32Array.from(positions),
    indices: Uint32Array.from(indices),
    name: mesh.name,
  };
  if (mesh.colors) out.colors = Float32Array.from(colors);
  return out;
}
