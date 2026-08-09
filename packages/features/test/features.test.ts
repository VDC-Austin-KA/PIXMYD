import assert from 'node:assert/strict';
import test from 'node:test';

import {
  blurGray,
  buildPyramid,
  createGray,
  grayFromRgba,
  resampleGray,
  sampleGrayBilinear,
  type GrayImage,
} from '../src/image.ts';
import {
  detectCorners,
  detectKeypoints,
  harrisResponse,
  intensityCentroidAngle,
} from '../src/detect.ts';
import {
  DESCRIPTOR_BITS,
  DESCRIPTOR_BYTES,
  describeKeypoints,
  hammingDistance,
  samplingPairs,
} from '../src/descriptor.ts';
import { filterByMotionConsistency, matchDescriptors } from '../src/match.ts';
import { extractFeatures, matchImagePair, normalizePixel, verifyMatches } from '../src/pipeline.ts';
import { decomposeEssential } from '@pixmyd/sfm/geometry';
import type { CameraModel } from '@pixmyd/core/bundle';

// ---------------------------------------------------------------------------
// Synthetic imagery
//
// Detection and matching are only testable against images whose content is
// known exactly. Random noise gives a texture the detector can find corners in
// without the corners being anywhere in particular, so the scenes below are
// built from shapes whose corner positions can be written down.
// ---------------------------------------------------------------------------

function fill(image: GrayImage, value: number): GrayImage {
  image.data.fill(value);
  return image;
}

function rect(image: GrayImage, x0: number, y0: number, w: number, h: number, value: number): void {
  for (let y = y0; y < y0 + h; y += 1) {
    if (y < 0 || y >= image.height) continue;
    for (let x = x0; x < x0 + w; x += 1) {
      if (x < 0 || x >= image.width) continue;
      image.data[y * image.width + x] = value;
    }
  }
}

/** A field of squares. Deterministic, and every corner position is known. */
function squaresImage(width: number, height: number, seed = 12345, count = 60): GrayImage {
  const image = fill(createGray(width, height), 40);
  let state = seed;
  const next = (): number => {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  };
  for (let i = 0; i < count; i += 1) {
    const x = Math.round(next() * (width - 30));
    const y = Math.round(next() * (height - 30));
    const size = 6 + Math.round(next() * 10);
    rect(image, x, y, size, size, 90 + Math.round(next() * 150));
  }
  return image;
}

/** Rotate an image about its centre, sampling bilinearly. */
function rotateImage(image: GrayImage, radians: number): GrayImage {
  const out = createGray(image.width, image.height);
  const cx = (image.width - 1) / 2;
  const cy = (image.height - 1) / 2;
  const cos = Math.cos(-radians);
  const sin = Math.sin(-radians);
  for (let y = 0; y < image.height; y += 1) {
    for (let x = 0; x < image.width; x += 1) {
      const dx = x - cx;
      const dy = y - cy;
      out.data[y * image.width + x] = Math.round(
        sampleGrayBilinear(image, cx + dx * cos - dy * sin, cy + dx * sin + dy * cos),
      );
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Image basics
// ---------------------------------------------------------------------------

test('grayFromRgba uses BT.601 luma and rounds', () => {
  const rgba = new Uint8Array([255, 255, 255, 255, 0, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255]);
  const gray = grayFromRgba(rgba, 4, 1);
  assert.equal(gray.data[0], 255);
  assert.equal(gray.data[1], 0);
  assert.equal(gray.data[2], Math.round(0.299 * 255));
  assert.equal(gray.data[3], Math.round(0.587 * 255));
});

test('grayFromRgba rejects a buffer that is too small', () => {
  assert.throws(() => grayFromRgba(new Uint8Array(12), 4, 1), /need 16 bytes/);
});

test('blur preserves a constant image exactly', () => {
  // The kernel weights sum to 16 and the shift divides by 16, so a flat field
  // must come back bit-identical. If it does not, the rounding term is wrong
  // and every image is being darkened or brightened by a level.
  const flat = fill(createGray(20, 20), 137);
  const blurred = blurGray(flat);
  assert.ok(blurred.data.every((value) => value === 137));
});

test('blur is symmetric about an impulse', () => {
  const image = fill(createGray(21, 21), 0);
  image.data[10 * 21 + 10] = 255;
  const blurred = blurGray(image);
  const at = (x: number, y: number): number => blurred.data[y * 21 + x];
  assert.equal(at(9, 10), at(11, 10));
  assert.equal(at(10, 9), at(10, 11));
  assert.ok(at(10, 10) > at(9, 10));
});

test('resample preserves pixel centres at 1:1', () => {
  const image = squaresImage(64, 64);
  const same = resampleGray(image, 64, 64);
  assert.deepEqual([...same.data], [...image.data]);
});

test('pyramid levels shrink by the factor and stop at minSize', () => {
  const pyramid = buildPyramid(squaresImage(320, 240), { factor: 1.2, levels: 20, minSize: 32 });
  assert.ok(pyramid.length > 1);
  assert.equal(pyramid[0].scale, 1);
  for (let i = 1; i < pyramid.length; i += 1) {
    assert.ok(Math.abs(pyramid[i].scale / pyramid[i - 1].scale - 1.2) < 1e-9);
    assert.ok(pyramid[i].image.width >= 32 && pyramid[i].image.height >= 32);
    assert.equal(pyramid[i].image.width, Math.round(320 / pyramid[i].scale));
  }
});

test('pyramid rejects a factor that would never terminate', () => {
  assert.throws(() => buildPyramid(createGray(64, 64), { factor: 1 }), /must exceed 1/);
});

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

test('FAST finds the corners of a square and nothing along its edges', () => {
  const image = fill(createGray(60, 60), 30);
  rect(image, 20, 20, 20, 20, 200);

  const corners = detectCorners(image, { threshold: 20, suppressionRadius: 3 });
  assert.ok(corners.length >= 4, `expected at least 4 corners, got ${corners.length}`);

  const expected = [
    [20, 20],
    [39, 20],
    [20, 39],
    [39, 39],
  ];
  for (const [ex, ey] of expected) {
    const near = corners.some((c) => Math.abs(c.x - ex) <= 2 && Math.abs(c.y - ey) <= 2);
    assert.ok(near, `no corner near (${ex}, ${ey})`);
  }

  // Nothing in the middle of an edge. An edge point has a well-defined position
  // in one direction only, and matching it yields a correspondence that slides
  // along the edge — a wrong observation that looks like a good one.
  for (const corner of corners) {
    const onTopEdge = Math.abs(corner.y - 20) <= 1 && corner.x > 24 && corner.x < 35;
    assert.ok(!onTopEdge, `corner at (${corner.x}, ${corner.y}) is mid-edge`);
  }
});

test('non-maximum suppression leaves one detection per corner', () => {
  const image = fill(createGray(60, 60), 30);
  rect(image, 20, 20, 20, 20, 200);

  const raw = detectCorners(image, { threshold: 20, suppressionRadius: 0 });
  const suppressed = detectCorners(image, { threshold: 20, suppressionRadius: 5 });

  assert.ok(raw.length > suppressed.length);
  for (let i = 0; i < suppressed.length; i += 1) {
    for (let j = i + 1; j < suppressed.length; j += 1) {
      const distance = Math.hypot(suppressed[i].x - suppressed[j].x, suppressed[i].y - suppressed[j].y);
      assert.ok(distance >= 5, `two survivors ${distance.toFixed(2)} apart`);
    }
  }
});

test('a corner arc that wraps the end of the circle is still found', () => {
  // A corner whose bright arc straddles index 15/0 of the circle. Testing the
  // circle only once, without wrapping, misses one corner orientation in
  // sixteen — a bug that leaves the detector working well enough to look fine.
  const image = fill(createGray(40, 40), 20);
  for (let y = 0; y < 40; y += 1) {
    for (let x = 0; x < 40; x += 1) {
      // Wedge opening upward, centred on the -y axis, which is circle index 0.
      const dx = x - 20;
      const dy = y - 20;
      if (dy < 0 && Math.abs(dx) < -dy * 0.6) image.data[y * 40 + x] = 220;
    }
  }
  const corners = detectCorners(image, { threshold: 20, suppressionRadius: 3 });
  assert.ok(
    corners.some((c) => Math.abs(c.x - 20) <= 3 && Math.abs(c.y - 20) <= 3),
    'wedge apex not detected',
  );
});

test('Harris ranks a corner above an edge above flat ground', () => {
  const image = fill(createGray(60, 60), 30);
  rect(image, 20, 20, 20, 20, 200);

  const corner = harrisResponse(image, 20, 20);
  const edge = harrisResponse(image, 30, 20);
  const flat = harrisResponse(image, 50, 50);

  assert.ok(corner > 0, `corner response ${corner} should be positive`);
  assert.ok(corner > edge, 'a corner must score above an edge');
  assert.ok(edge <= 0 || edge < corner / 10, 'an edge must score far below a corner');
  assert.ok(Math.abs(flat) < 1e-9, 'flat ground must score zero');
});

test('detector skips the border where its window would read clamped pixels', () => {
  // Clamped reads at the edge form a perfect step, which is a textbook corner.
  // A detector that runs to the border reports a ring of them.
  const image = squaresImage(80, 80);
  const corners = detectCorners(image, { threshold: 20 });
  for (const corner of corners) {
    assert.ok(corner.x >= 4 && corner.x < 76, `x=${corner.x} inside the border`);
    assert.ok(corner.y >= 4 && corner.y < 76, `y=${corner.y} inside the border`);
  }
});

test('intensity centroid angle rotates with the patch', () => {
  const image = fill(createGray(61, 61), 20);
  // A bright lobe to the right of centre: the centroid points at it, angle 0.
  rect(image, 32, 26, 10, 10, 220);

  const base = intensityCentroidAngle(image, 30, 30);
  assert.ok(Math.abs(base) < 0.25, `expected ~0, got ${base}`);

  for (const degrees of [30, 90, 145, 220]) {
    const radians = (degrees * Math.PI) / 180;
    const measured = intensityCentroidAngle(rotateImage(image, radians), 30, 30);
    let delta = measured - base - radians;
    while (delta > Math.PI) delta -= 2 * Math.PI;
    while (delta < -Math.PI) delta += 2 * Math.PI;
    assert.ok(Math.abs(delta) < 0.12, `at ${degrees} deg the angle was off by ${delta}`);
  }
});

test('keypoint budget is spread across pyramid levels', () => {
  const pyramid = buildPyramid(squaresImage(320, 240));
  const keypoints = detectKeypoints(pyramid, { maxKeypoints: 300, threshold: 20 });

  assert.ok(keypoints.length > 0);
  assert.ok(keypoints.length <= 300);

  const levels = new Set(keypoints.map((k) => k.level));
  // Taking the globally strongest N instead would fill the budget entirely from
  // level 0, because Harris response falls with blur — and a feature set with
  // no coarse levels cannot match across a scale change.
  assert.ok(levels.size > 1, `all keypoints came from level(s) ${[...levels]}`);

  // Coordinates are reported at level 0 regardless of the level found on.
  for (const keypoint of keypoints) {
    assert.ok(keypoint.x >= 0 && keypoint.x <= 320);
    assert.ok(keypoint.y >= 0 && keypoint.y <= 240);
  }
});

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------

test('sampling pairs are in the patch, distinct, and deterministic', () => {
  const pairs = samplingPairs();
  assert.equal(pairs.length, DESCRIPTOR_BITS * 4);

  for (let i = 0; i < DESCRIPTOR_BITS; i += 1) {
    const [ax, ay, bx, by] = [pairs[i * 4], pairs[i * 4 + 1], pairs[i * 4 + 2], pairs[i * 4 + 3]];
    for (const value of [ax, ay, bx, by]) {
      assert.ok(value >= -15 && value <= 15, `offset ${value} outside the 31x31 patch`);
    }
    // A pair sampling the same pixel twice always yields the same bit and
    // carries no information.
    assert.ok(ax !== bx || ay !== by, `pair ${i} is degenerate`);
  }

  // Same array on every call: a capture reprocessed tomorrow has to produce the
  // same descriptors as one processed today, or nothing matches across sessions.
  assert.equal(samplingPairs(), pairs);
});

test('hamming distance counts differing bits', () => {
  const a = new Uint8Array(DESCRIPTOR_BYTES);
  const b = new Uint8Array(DESCRIPTOR_BYTES);
  assert.equal(hammingDistance(a, 0, b, 0), 0);

  b[0] = 0xff;
  assert.equal(hammingDistance(a, 0, b, 0), 8);

  b.fill(0xff);
  assert.equal(hammingDistance(a, 0, b, 0), DESCRIPTOR_BITS);
});

test('descriptors survive rotation', () => {
  // The whole point of steering. Two photos of the same wall with the phone
  // held at different angles is the normal case on site, not an edge case.
  const image = squaresImage(200, 200);
  const rotated = rotateImage(image, Math.PI / 4);

  const a = extractFeatures(image, { maxKeypoints: 200, threshold: 20 });
  const b = extractFeatures(rotated, { maxKeypoints: 200, threshold: 20 });

  const matches = matchDescriptors(a.descriptors, b.descriptors, { ratio: 0.8 });
  assert.ok(matches.length >= 10, `only ${matches.length} matches across a 45 degree rotation`);

  // Check the matches are geometrically right, not merely numerous: a matched
  // pair must sit where the rotation puts it.
  const cx = (image.width - 1) / 2;
  const cy = (image.height - 1) / 2;
  const cos = Math.cos(Math.PI / 4);
  const sin = Math.sin(Math.PI / 4);

  let correct = 0;
  for (const match of matches) {
    const ka = a.keypoints[match.a];
    const kb = b.keypoints[match.b];
    const dx = ka.x - cx;
    const dy = ka.y - cy;
    const expectedX = cx + dx * cos - dy * sin;
    const expectedY = cy + dx * sin + dy * cos;
    if (Math.hypot(kb.x - expectedX, kb.y - expectedY) < 4) correct += 1;
  }
  assert.ok(
    correct / matches.length > 0.6,
    `only ${correct}/${matches.length} matches were geometrically correct`,
  );
});

test('descriptors of an unrotated image match themselves exactly', () => {
  const image = squaresImage(160, 160);
  const features = extractFeatures(image, { maxKeypoints: 100, threshold: 20 });
  const again = describeKeypoints(buildPyramid(image), features.keypoints);
  assert.deepEqual([...again.data], [...features.descriptors.data]);
});

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

test('the ratio test rejects an ambiguous match', () => {
  const a = { count: 1, data: new Uint8Array(DESCRIPTOR_BYTES) };

  // Two candidates at distance 8 and 9: nearly tied, so the best one carries no
  // evidence that it is the right one. This is a facade of identical windows.
  const b = { count: 2, data: new Uint8Array(DESCRIPTOR_BYTES * 2) };
  b.data[0] = 0xff;
  b.data[DESCRIPTOR_BYTES] = 0xff;
  b.data[DESCRIPTOR_BYTES + 1] = 0x01;

  assert.equal(matchDescriptors(a, b, { ratio: 0.75, crossCheck: false }).length, 0);

  // Widen the gap — 8 versus 40 — and the best is unambiguous.
  b.data.fill(0, DESCRIPTOR_BYTES);
  for (let byte = 0; byte < 5; byte += 1) b.data[DESCRIPTOR_BYTES + byte] = 0xff;
  assert.equal(matchDescriptors(a, b, { ratio: 0.75, crossCheck: false }).length, 1);
});

test('a single candidate is rejected, because there is no ratio to test', () => {
  const a = { count: 1, data: new Uint8Array(DESCRIPTOR_BYTES) };
  const b = { count: 1, data: new Uint8Array(DESCRIPTOR_BYTES) };
  assert.equal(matchDescriptors(a, b, { crossCheck: false }).length, 0);
});

test('cross-check removes many-to-one matches', () => {
  // Two features in A both nearest to the same feature in B. At most one can be
  // right; without cross-check both survive.
  const a = { count: 2, data: new Uint8Array(DESCRIPTOR_BYTES * 2) };
  a.data[DESCRIPTOR_BYTES] = 0x03;

  const b = { count: 2, data: new Uint8Array(DESCRIPTOR_BYTES * 2) };
  b.data.fill(0xff, DESCRIPTOR_BYTES);

  const loose = matchDescriptors(a, b, { ratio: 0.99, crossCheck: false });
  const strict = matchDescriptors(a, b, { ratio: 0.99, crossCheck: true });

  assert.equal(loose.filter((m) => m.b === 0).length, 2);
  assert.ok(strict.filter((m) => m.b === 0).length <= 1);
});

test('motion consistency drops a match moving against the crowd', () => {
  const keypointsA = [];
  const keypointsB = [];
  const matches = [];
  for (let i = 0; i < 20; i += 1) {
    keypointsA.push({ x: i * 5, y: 10, score: 1, angle: 0, level: 0, scale: 1 });
    // Nineteen shift by (7, 0); one shifts by (7, 60).
    keypointsB.push({ x: i * 5 + 7, y: i === 13 ? 70 : 10, score: 1, angle: 0, level: 0, scale: 1 });
    matches.push({ a: i, b: i, distance: 10 });
  }

  const kept = filterByMotionConsistency(matches, keypointsA, keypointsB);
  assert.equal(kept.length, 19);
  assert.ok(!kept.some((m) => m.a === 13));
});

test('motion consistency keeps everything when the set is perfectly consistent', () => {
  // MAD is zero for a planar scene under pure translation. A filter that
  // divides by it, or treats zero as "reject everything", deletes a good pair.
  const keypointsA = [];
  const keypointsB = [];
  const matches = [];
  for (let i = 0; i < 12; i += 1) {
    keypointsA.push({ x: i * 5, y: 10, score: 1, angle: 0, level: 0, scale: 1 });
    keypointsB.push({ x: i * 5 + 3, y: 12, score: 1, angle: 0, level: 0, scale: 1 });
    matches.push({ a: i, b: i, distance: 10 });
  }
  assert.equal(filterByMotionConsistency(matches, keypointsA, keypointsB).length, 12);
});

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

const PINHOLE: CameraModel = {
  model: 'pinhole',
  width: 1920,
  height: 1440,
  fx: 1450,
  fy: 1450,
  cx: 960,
  cy: 720,
};

test('the principal point normalizes to the origin', () => {
  const point = normalizePixel(PINHOLE, { x: 960, y: 720 });
  assert.ok(point);
  assert.ok(Math.abs(point.x) < 1e-12 && Math.abs(point.y) < 1e-12);
});

test('distortion inversion round-trips against the forward model', () => {
  const distorted: CameraModel = { ...PINHOLE, k1: -0.28, k2: 0.09, p1: 0.001, p2: -0.0005 };

  for (const pixel of [
    { x: 100, y: 80 },
    { x: 1800, y: 1300 },
    { x: 960, y: 200 },
  ]) {
    const normalized = normalizePixel(distorted, pixel);
    assert.ok(normalized);

    // Push it back through the forward Brown-Conrady model and expect the
    // original pixel. This is the check the iterative inverse actually needs;
    // asserting it merely returns a number would pass with the loop deleted.
    const { x, y } = normalized;
    const r2 = x * x + y * y;
    const radial = 1 + r2 * (-0.28 + r2 * 0.09);
    const dx = x * radial + 2 * 0.001 * x * y + -0.0005 * (r2 + 2 * x * x);
    const dy = y * radial + 0.001 * (r2 + 2 * y * y) + 2 * -0.0005 * x * y;

    assert.ok(Math.abs(dx * 1450 + 960 - pixel.x) < 0.01);
    assert.ok(Math.abs(dy * 1450 + 720 - pixel.y) < 0.01);
  }
});

test('a fisheye ray past 90 degrees is dropped, not folded forward', () => {
  const fisheye: CameraModel = {
    model: 'fisheye',
    width: 1600,
    height: 1600,
    fx: 500,
    fy: 500,
    cx: 800,
    cy: 800,
  };
  // theta = r/f, so r = 500 * (pi/2) is exactly the horizon; beyond it the ray
  // points behind the camera and x/z is meaningless.
  assert.ok(normalizePixel(fisheye, { x: 800 + 400, y: 800 }));
  assert.equal(normalizePixel(fisheye, { x: 800 + 900, y: 800 }), null);
});

test('an equirectangular pixel behind the camera is dropped', () => {
  const equirect: CameraModel = { model: 'equirect', width: 4000, height: 2000 };
  const forward = normalizePixel(equirect, { x: 2000, y: 1000 });
  assert.ok(forward);
  assert.ok(Math.abs(forward.x) < 1e-3 && Math.abs(forward.y) < 1e-3);
  assert.equal(normalizePixel(equirect, { x: 10, y: 1000 }), null);
});

// ---------------------------------------------------------------------------
// End to end
// ---------------------------------------------------------------------------

/**
 * Render a textured wedge — two planes meeting in a vertical edge — seen from a
 * known camera position.
 *
 * It has to be two planes, not one. **A planar scene is the degenerate case for
 * the essential matrix**: correspondences on a single plane satisfy a
 * homography, the eight-point system loses rank, and the recovered pose is
 * whatever the noise happens to favour. A test built on one plane would grade
 * the matcher on a problem the geometry cannot solve in principle, and the
 * failure would look like a matching failure. Two planes at different
 * orientations give the depth variation the solve needs.
 *
 * Rendered by ray casting rather than by warping an image, so every pixel is
 * exact and the ground-truth pose is known rather than fitted.
 */
function renderWedge(
  textures: [GrayImage, GrayImage],
  cameraPosition: [number, number, number],
  camera: CameraModel & { model: 'pinhole' },
): GrayImage {
  const out = createGray(camera.width, camera.height);
  // Texels per world metre. This has to be high enough that the visible world —
  // about 5 m across at this focal length and depth — maps across the whole
  // texture. At 40 it mapped to a 190 px patch of it, so the only features in
  // frame were the handful of squares near the crease, every one of them at
  // essentially the same depth. The pose solve then had no depth variation to
  // work with and returned a translation along the optical axis, which reads
  // exactly like a matching failure and is not one.
  const texelsPerMetre = 110;
  // A convex wedge with its crease on the optical axis: z = 3 + 0.7|x|, so each
  // face fills half the frame and depth runs from 3 m at the centre to about
  // 4.4 m at the edges.
  //
  // Where the crease sits matters more than it looks. An earlier version put it
  // at x = 1.76, which left one plane covering five sixths of the image — still
  // effectively a single plane, still the degenerate case, and the recovered
  // translation came out along the optical axis instead of along the baseline.
  // Half and half is what actually breaks the degeneracy.
  const planes = [
    { slope: 0.7, offset: 3, texture: textures[0] },
    { slope: -0.7, offset: 3, texture: textures[1] },
  ];

  for (let py = 0; py < camera.height; py += 1) {
    for (let px = 0; px < camera.width; px += 1) {
      const dx = (px + 0.5 - camera.cx) / camera.fx;
      const dy = (py + 0.5 - camera.cy) / camera.fy;

      let bestT = Number.POSITIVE_INFINITY;
      let bestTexture = textures[0];
      for (const plane of planes) {
        // Ray p = c + t(dx, dy, 1); solve z = offset + slope*x for t.
        const denominator = 1 - plane.slope * dx;
        if (Math.abs(denominator) < 1e-9) continue;
        const t =
          (plane.offset + plane.slope * cameraPosition[0] - cameraPosition[2]) / denominator;
        if (t <= 0 || t >= bestT) continue;
        bestT = t;
        bestTexture = plane.texture;
      }
      if (!Number.isFinite(bestT)) continue;

      const worldX = cameraPosition[0] + bestT * dx;
      const worldY = cameraPosition[1] + bestT * dy;

      // Each face carries its own texture, so a feature on one cannot be
      // confused with the mirrored feature on the other.
      out.data[py * camera.width + px] = Math.round(
        sampleGrayBilinear(
          bestTexture,
          (worldX + 4) * texelsPerMetre,
          (worldY + 4) * texelsPerMetre,
        ),
      );
    }
  }
  return out;
}

test('two rendered views recover the known relative pose', () => {
  const view: CameraModel & { model: 'pinhole' } = {
    model: 'pinhole',
    width: 320,
    height: 240,
    fx: 300,
    fy: 300,
    cx: 160,
    cy: 120,
  };

  const textures: [GrayImage, GrayImage] = [squaresImage(760, 620, 4242, 220), squaresImage(760, 620, 90210, 220)];
  const left = renderWedge(textures, [0, 0, 0], view);
  const right = renderWedge(textures, [0.5, 0, 0], view);

  const a = extractFeatures(left, { maxKeypoints: 600, threshold: 15 });
  const b = extractFeatures(right, { maxKeypoints: 600, threshold: 15 });

  assert.ok(a.keypoints.length > 50, `only ${a.keypoints.length} keypoints in the left view`);

  const verified = matchImagePair(a, b, view, view, { ratio: 0.85, thresholdPx: 2 });
  assert.ok(verified, 'the pair failed to verify');
  assert.ok(verified.matches.length >= 20, `only ${verified.matches.length} inliers`);
  assert.ok(verified.inlierRatio > 0.5, `inlier ratio ${verified.inlierRatio}`);

  const pose = decomposeEssential(verified.essential, verified.correspondences);
  assert.ok(pose, 'the essential matrix did not decompose');

  // decomposeEssential returns world-to-camera for the second view, so with the
  // second camera at (0.5, 0, 0) and no rotation the translation is -x, up to
  // the scale a two-view solve cannot see. Vec3 and Quat are arrays here, not
  // objects — reading `.x` off one yields undefined, and `Math.hypot` of that
  // is NaN, which fails every comparison and reads as a reconstruction failure.
  const [tx, ty, tz] = pose.translation;
  const length = Math.hypot(tx, ty, tz);
  assert.ok(
    Math.abs(tx / length + 1) < 0.15,
    `translation should be along -x, got ${JSON.stringify(pose.translation)}`,
  );

  // Pure translation, so the rotation is near identity: |w| ~ 1.
  assert.ok(
    Math.abs(Math.abs(pose.rotation[3]) - 1) < 0.02,
    `unexpected rotation ${JSON.stringify(pose.rotation)}`,
  );
});

test('verification is deterministic for a given seed', () => {
  const view: CameraModel & { model: 'pinhole' } = {
    model: 'pinhole',
    width: 320,
    height: 240,
    fx: 300,
    fy: 300,
    cx: 160,
    cy: 120,
  };
  const textures: [GrayImage, GrayImage] = [squaresImage(760, 620, 4242, 220), squaresImage(760, 620, 90210, 220)];
  const a = extractFeatures(renderWedge(textures, [0, 0, 0], view), { maxKeypoints: 400, threshold: 15 });
  const b = extractFeatures(renderWedge(textures, [0.4, 0.1, 0], view), { maxKeypoints: 400, threshold: 15 });

  const first = matchImagePair(a, b, view, view, { seed: 7, ratio: 0.85 });
  const second = matchImagePair(a, b, view, view, { seed: 7, ratio: 0.85 });
  assert.ok(first && second);

  // Reprocessing a capture and getting a different answer would make it
  // impossible to tell a real improvement from RANSAC's luck.
  assert.deepEqual(first.essential, second.essential);
  assert.deepEqual(first.matches, second.matches);
});

test('two unrelated images do not verify', () => {
  const view: CameraModel & { model: 'pinhole' } = {
    model: 'pinhole',
    width: 200,
    height: 200,
    fx: 200,
    fy: 200,
    cx: 100,
    cy: 100,
  };

  const a = extractFeatures(squaresImage(200, 200), { maxKeypoints: 300, threshold: 20 });
  const b = extractFeatures(squaresImage(200, 200, 987654), { maxKeypoints: 300, threshold: 20 });

  const verified = matchImagePair(a, b, view, view, { ratio: 0.7 });
  // "No overlap" is the honest answer for most pairs in a real capture, and it
  // has to be reachable — a matcher that always returns a pose will happily
  // wire two different rooms together.
  if (verified) {
    assert.ok(verified.matches.length < 15, `${verified.matches.length} inliers between unrelated images`);
  }
});

test('verification needs eight usable correspondences', () => {
  const view: CameraModel & { model: 'pinhole' } = {
    model: 'pinhole',
    width: 100,
    height: 100,
    fx: 100,
    fy: 100,
    cx: 50,
    cy: 50,
  };
  const keypoints = Array.from({ length: 5 }, (_, i) => ({
    x: i * 10,
    y: i * 7,
    score: 1,
    angle: 0,
    level: 0,
    scale: 1,
  }));
  const matches = keypoints.map((_, i) => ({ a: i, b: i, distance: 5 }));
  assert.equal(verifyMatches(matches, keypoints, keypoints, view, view), null);
});
