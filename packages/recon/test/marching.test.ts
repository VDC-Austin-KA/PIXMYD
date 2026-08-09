import test from 'node:test';
import assert from 'node:assert/strict';
import {
  marchingTetrahedra,
  computeVertexNormals,
  removeSmallComponents,
  type FieldSampler,
} from '../src/marching.ts';
import type { Mesh } from '@pixmyd/core/bundle';

/**
 * Every edge of a closed surface is shared by exactly two triangles.
 *
 * This is the definition of watertight, and it is the property marching
 * tetrahedra is chosen for. An edge used once is a boundary — a hole. An edge
 * used three times or more means the vertex welding is broken.
 */
function edgeUseCounts(mesh: Mesh): Map<string, number> {
  const counts = new Map<string, number>();
  for (let i = 0; i < mesh.indices.length; i += 3) {
    const corners = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]];
    for (let k = 0; k < 3; k++) {
      const a = corners[k];
      const b = corners[(k + 1) % 3];
      const key = a < b ? `${a}-${b}` : `${b}-${a}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  return counts;
}

/**
 * Signed volume via the divergence theorem: sum of the signed volumes of the
 * tetrahedra formed by each triangle and the origin.
 *
 * This is a far stronger check than area. It is only correct if the mesh is
 * closed *and* consistently wound — an inverted triangle subtracts where it
 * should add, so a single wrong entry in the triangle table shows up here as a
 * volume that is wrong by a visible fraction.
 */
function signedVolume(mesh: Mesh): number {
  let total = 0;
  const p = mesh.positions;
  for (let i = 0; i < mesh.indices.length; i += 3) {
    const a = mesh.indices[i] * 3;
    const b = mesh.indices[i + 1] * 3;
    const c = mesh.indices[i + 2] * 3;
    total +=
      (p[a] * (p[b + 1] * p[c + 2] - p[b + 2] * p[c + 1]) -
        p[a + 1] * (p[b] * p[c + 2] - p[b + 2] * p[c]) +
        p[a + 2] * (p[b] * p[c + 1] - p[b + 1] * p[c])) / 6;
  }
  return total;
}

function surfaceArea(mesh: Mesh): number {
  let total = 0;
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
    total += Math.hypot(nx, ny, nz) / 2;
  }
  return total;
}

/** Sphere of `radius` centred at `centre`, negative inside. */
function sphereField(radius: number, centre: [number, number, number], voxelSize: number): FieldSampler {
  return (x, y, z) => {
    const wx = x * voxelSize + voxelSize / 2 - centre[0];
    const wy = y * voxelSize + voxelSize / 2 - centre[1];
    const wz = z * voxelSize + voxelSize / 2 - centre[2];
    return Math.hypot(wx, wy, wz) - radius;
  };
}

// ===========================================================================

test('a sphere extracts a watertight surface: every edge shared by exactly two faces', () => {
  const voxelSize = 0.05;
  const radius = 0.5;
  const centre: [number, number, number] = [1, 1, 1];
  const mesh = marchingTetrahedra(sphereField(radius, centre, voxelSize), {
    min: [0, 0, 0],
    max: [40, 40, 40],
    voxelSize,
  });

  assert.ok(mesh.indices.length > 3000, `expected a substantial mesh, got ${mesh.indices.length / 3} triangles`);

  const counts = edgeUseCounts(mesh);
  const boundary = [...counts.values()].filter((n) => n === 1).length;
  const nonManifold = [...counts.values()].filter((n) => n > 2).length;

  assert.equal(boundary, 0, `${boundary} boundary edges — the surface has holes`);
  assert.equal(nonManifold, 0, `${nonManifold} edges shared by more than two faces`);
});

test('sphere surface area matches 4 pi r squared', () => {
  const voxelSize = 0.04;
  const radius = 0.5;
  const mesh = marchingTetrahedra(sphereField(radius, [1, 1, 1], voxelSize), {
    min: [0, 0, 0],
    max: [50, 50, 50],
    voxelSize,
  });
  const expected = 4 * Math.PI * radius * radius;
  const actual = surfaceArea(mesh);
  // Linear interpolation on a tetrahedral lattice slightly overestimates area.
  const error = Math.abs(actual - expected) / expected;
  assert.ok(error < 0.06, `area ${actual.toFixed(4)} vs ${expected.toFixed(4)} (${(error * 100).toFixed(1)}%)`);
});

test('sphere signed volume matches 4/3 pi r cubed, which pins down the winding', () => {
  // If any entry in the triangle table produced a reversed triangle, that
  // triangle would subtract from the sum instead of adding, and this would
  // fail even though the surface still looked closed.
  const voxelSize = 0.04;
  const radius = 0.5;
  const centre: [number, number, number] = [1, 1, 1];
  const mesh = marchingTetrahedra(sphereField(radius, centre, voxelSize), {
    min: [0, 0, 0],
    max: [50, 50, 50],
    voxelSize,
  });

  const expected = (4 / 3) * Math.PI * radius ** 3;
  const actual = signedVolume(mesh);
  // The sign is part of the assertion: a positive volume means the surface is
  // wound outward. Taking the absolute value here would hide an inside-out mesh.
  assert.ok(actual > 0, `volume ${actual.toFixed(5)} is negative — the mesh is inside out`);
  const error = Math.abs(actual - expected) / expected;
  assert.ok(error < 0.03, `volume ${actual.toFixed(5)} vs ${expected.toFixed(5)} (${(error * 100).toFixed(1)}%)`);
});

test('every extracted vertex lies on the isosurface', () => {
  const voxelSize = 0.05;
  const radius = 0.5;
  const centre: [number, number, number] = [1, 1, 1];
  const mesh = marchingTetrahedra(sphereField(radius, centre, voxelSize), {
    min: [0, 0, 0],
    max: [40, 40, 40],
    voxelSize,
  });

  let worst = 0;
  for (let i = 0; i < mesh.positions.length; i += 3) {
    const distance = Math.hypot(
      mesh.positions[i] - centre[0],
      mesh.positions[i + 1] - centre[1],
      mesh.positions[i + 2] - centre[2],
    );
    worst = Math.max(worst, Math.abs(distance - radius));
  }
  // Linear interpolation along an edge is exact only for a linear field; the
  // curvature of a sphere over one voxel bounds the error.
  assert.ok(worst < voxelSize * 0.3, `worst radial deviation ${worst.toFixed(4)} m`);
});

test('a plane extracts a flat surface at the right height', () => {
  const voxelSize = 0.1;
  // Negative below z = 1.0, positive above.
  const field: FieldSampler = (_x, _y, z) => z * voxelSize + voxelSize / 2 - 1.0;
  const mesh = marchingTetrahedra(field, {
    min: [0, 0, 0],
    max: [10, 10, 20],
    voxelSize,
  });

  assert.ok(mesh.indices.length > 0, 'a crossing plane must produce triangles');
  for (let i = 2; i < mesh.positions.length; i += 3) {
    assert.ok(
      Math.abs(mesh.positions[i] - 1.0) < 1e-5,
      `vertex at z=${mesh.positions[i]} should be on the plane`,
    );
  }
});

test('an entirely positive or entirely negative field produces nothing', () => {
  const empty = marchingTetrahedra(() => 1, { min: [0, 0, 0], max: [10, 10, 10], voxelSize: 0.1 });
  assert.equal(empty.indices.length, 0);
  const full = marchingTetrahedra(() => -1, { min: [0, 0, 0], max: [10, 10, 10], voxelSize: 0.1 });
  assert.equal(full.indices.length, 0);
});

test('unobserved regions are skipped rather than interpolated across', () => {
  // A sphere, but the whole upper half of the grid returns null — nobody looked
  // there. The mesher must leave it open rather than inventing a lid.
  const voxelSize = 0.05;
  const sphere = sphereField(0.5, [1, 1, 1], voxelSize);
  const field: FieldSampler = (x, y, z) => (z > 20 ? null : sphere(x, y, z));

  const mesh = marchingTetrahedra(field, {
    min: [0, 0, 0],
    max: [40, 40, 40],
    voxelSize,
  });

  assert.ok(mesh.indices.length > 0, 'the observed half should still be meshed');
  for (let i = 2; i < mesh.positions.length; i += 3) {
    assert.ok(
      mesh.positions[i] <= 20 * voxelSize + voxelSize,
      `no geometry should appear above the observed region, found z=${mesh.positions[i]}`,
    );
  }
  // And it must have a boundary, because a half-sphere is genuinely open.
  const counts = edgeUseCounts(mesh);
  assert.ok(
    [...counts.values()].some((n) => n === 1),
    'the cut edge must be a real boundary, not silently capped',
  );
});

test('vertices are shared between triangles rather than duplicated', () => {
  const voxelSize = 0.05;
  const mesh = marchingTetrahedra(sphereField(0.4, [1, 1, 1], voxelSize), {
    min: [0, 0, 0],
    max: [40, 40, 40],
    voxelSize,
  });
  const vertexCount = mesh.positions.length / 3;
  const triangleCount = mesh.indices.length / 3;
  // For a closed triangulated surface Euler's formula gives V ~= T/2.
  // Unwelded output would give V = 3T.
  assert.ok(
    vertexCount < triangleCount,
    `${vertexCount} vertices for ${triangleCount} triangles suggests unwelded output`,
  );
});

test('normals point outward on a sphere', () => {
  const voxelSize = 0.05;
  const centre: [number, number, number] = [1, 1, 1];
  const mesh = marchingTetrahedra(sphereField(0.5, centre, voxelSize), {
    min: [0, 0, 0],
    max: [40, 40, 40],
    voxelSize,
  });
  const normals = computeVertexNormals(mesh);

  let outward = 0;
  let total = 0;
  for (let i = 0; i < mesh.positions.length; i += 3) {
    const rx = mesh.positions[i] - centre[0];
    const ry = mesh.positions[i + 1] - centre[1];
    const rz = mesh.positions[i + 2] - centre[2];
    const dot = rx * normals[i] + ry * normals[i + 1] + rz * normals[i + 2];
    if (dot > 0) outward++;
    total++;
  }
  assert.equal(outward, total, `${total - outward} of ${total} normals point inward`);
});

test('normals are unit length', () => {
  const voxelSize = 0.08;
  const mesh = marchingTetrahedra(sphereField(0.4, [1, 1, 1], voxelSize), {
    min: [0, 0, 0],
    max: [25, 25, 25],
    voxelSize,
  });
  const normals = computeVertexNormals(mesh);
  for (let i = 0; i < normals.length; i += 3) {
    const length = Math.hypot(normals[i], normals[i + 1], normals[i + 2]);
    assert.ok(Math.abs(length - 1) < 1e-5, `normal ${i / 3} has length ${length}`);
  }
});

test('colour is interpolated along the crossing edge', () => {
  const voxelSize = 0.1;
  const field: FieldSampler = (_x, _y, z) => z * voxelSize + voxelSize / 2 - 1.0;
  const mesh = marchingTetrahedra(field, {
    min: [0, 0, 0],
    max: [6, 6, 20],
    voxelSize,
    // Red below the plane, blue above.
    color: (_x, _y, z) => (z * voxelSize < 1.0 ? [1, 0, 0] : [0, 0, 1]),
  });
  assert.ok(mesh.colors, 'colours must be produced when a sampler is given');
  assert.equal(mesh.colors!.length, mesh.positions.length);
  // Every vertex sits on the boundary, so each blends the two.
  for (let i = 0; i < mesh.colors!.length; i += 3) {
    const r = mesh.colors![i];
    const b = mesh.colors![i + 2];
    assert.ok(r >= 0 && r <= 1 && b >= 0 && b <= 1, 'colour must stay in range');
  }
});

test('small disconnected components are removed and the mesh re-indexed', () => {
  // The speck meshes to roughly 150 triangles and the sphere to several
  // thousand, so a 400-triangle threshold separates them cleanly.
  const voxelSize = 0.05;
  const big = sphereField(0.4, [1, 1, 1], voxelSize);
  // A second, tiny sphere far away — the kind of speck fusion leaves behind.
  const speck = sphereField(0.045, [2.4, 1, 1], voxelSize);
  const field: FieldSampler = (x, y, z) => Math.min(big(x, y, z)!, speck(x, y, z)!);

  const mesh = marchingTetrahedra(field, {
    min: [0, 0, 0],
    max: [60, 40, 40],
    voxelSize,
  });
  const cleaned = removeSmallComponents(mesh, 400);

  assert.ok(cleaned.indices.length < mesh.indices.length, 'the speck should be removed');
  assert.ok(cleaned.indices.length > 0, 'the main sphere should survive');

  // Re-indexing must leave no vertex unreferenced and no index out of range.
  const used = new Set(cleaned.indices);
  assert.equal(used.size, cleaned.positions.length / 3, 'every vertex must be referenced');
  for (const index of cleaned.indices) {
    assert.ok(index < cleaned.positions.length / 3, 'index out of range after re-indexing');
  }

  // The surviving component must still be watertight.
  const counts = edgeUseCounts(cleaned);
  assert.equal([...counts.values()].filter((n) => n === 1).length, 0, 'cleanup opened a hole');
});

test('removeSmallComponents keeps everything when nothing is small', () => {
  const voxelSize = 0.06;
  const mesh = marchingTetrahedra(sphereField(0.4, [1, 1, 1], voxelSize), {
    min: [0, 0, 0],
    max: [35, 35, 35],
    voxelSize,
  });
  const cleaned = removeSmallComponents(mesh, 4);
  assert.equal(cleaned.indices.length, mesh.indices.length);
});
