import test from 'node:test';
import assert from 'node:assert/strict';
import {
  UNITS, float32Ulp, precisionReport, chooseOrigin, toLocalMetres,
  toProjectCoordinates, footDefinitionDivergence, fromMetres,
} from '../src/units.ts';
import {
  GRS80, WGS84, geodeticToEcef, ecefToGeodetic, geodeticToEnu, enuToGeodetic,
  project, unproject, gridScaleFactor, eccentricitySquared, semiMinorAxis,
  type Geodetic,
} from '../src/projection.ts';
import { STATE_PLANE_ZONES, lookupZone, zonesForState, checkZonePlausibility } from '../src/zones.ts';
import { solveRigidTransform, findOutliers, classifyAccuracy, applyTransform, type ControlPair } from '../src/registration.ts';
import { parseNmeaSentence, parseGga, parseGst, NmeaAssembler, describeFixQuality } from '../src/nmea.ts';
import { FixQuality } from '@pixmyd/core/bundle';
import { quat, v3, type Vec3 } from '@pixmyd/core/math';

const near = (a: number, b: number, tol: number, msg = '') =>
  assert.ok(Math.abs(a - b) < tol, `${msg} ${a} !~= ${b} (tol ${tol})`);

// ===========================================================================
// Units and precision
// ===========================================================================

test('the two feet are different, and it matters at survey magnitudes', () => {
  assert.notEqual(UNITS.usSurveyFoot, UNITS.internationalFoot);
  near(UNITS.usSurveyFoot, 1200 / 3937, 1e-15, 'usSurveyFoot is exactly 1200/3937');
  // Nothing on a 40 ft wall...
  assert.ok(footDefinitionDivergence(40) < 0.0001, '40 ft: negligible');
  // ...but 8+ metres on a Texas northing.
  assert.ok(footDefinitionDivergence(13_720_000) > 8, '13.7M ftUS: over 8 m apart');
});

test('float32 resolves exactly one unit between 2^23 and 2^24', () => {
  assert.equal(float32Ulp(2 ** 23), 1);
  assert.equal(float32Ulp(12_000_000), 1);
  assert.equal(float32Ulp(2 ** 24), 2);
  assert.equal(float32Ulp(100), 2 ** -17);
});

test('precisionReport demands a floating origin at Texas State Plane magnitudes', () => {
  const report = precisionReport([2_120_345.75, 13_720_000, 150], 'usSurveyFoot');
  assert.equal(report.requiresFloatingOrigin, true);
  assert.ok(report.ulpMillimetres > 100, 'step is over 100 mm');
  assert.match(report.reason, /Subtract a project origin/);

  const local = precisionReport([345.75, 1200, 150], 'usSurveyFoot');
  assert.equal(local.requiresFloatingOrigin, false);
});

test('chooseOrigin snaps to a readable grid and leaves elevation alone', () => {
  const origin = chooseOrigin({ min: [2_119_500, 13_719_000, 100], max: [2_121_000, 13_721_000, 200] });
  assert.equal(origin[0] % 1000, 0);
  assert.equal(origin[1] % 1000, 0);
  assert.equal(origin[2], 0, 'a 1000-unit snap on Z would lift the site off the ground');
});

test('project <-> local metres round trips exactly and flips handedness once', () => {
  const origin: Vec3 = [2_120_000, 13_720_000, 0];
  const point: Vec3 = [2_120_345.75, 13_720_500.25, 152.5];
  const local = toLocalMetres(point, origin, 'usSurveyFoot');

  // east -> +x, up -> +y, north -> -z
  near(local[0], 345.75 * UNITS.usSurveyFoot, 1e-9, 'east');
  near(local[1], 152.5 * UNITS.usSurveyFoot, 1e-9, 'up');
  near(local[2], -500.25 * UNITS.usSurveyFoot, 1e-9, 'north is negated');

  const back = toProjectCoordinates(local, origin, 'usSurveyFoot');
  for (let i = 0; i < 3; i++) near(back[i], point[i], 1e-6, `axis ${i}`);
});

// ===========================================================================
// Ellipsoid and ECEF
// ===========================================================================

test('GRS80 and WGS84 differ only in the last digits of flattening', () => {
  assert.equal(GRS80.a, WGS84.a);
  assert.ok(Math.abs(semiMinorAxis(GRS80) - semiMinorAxis(WGS84)) < 0.001, 'under a millimetre');
  assert.notEqual(eccentricitySquared(GRS80), eccentricitySquared(WGS84));
});

test('geodetic <-> ECEF round trips to sub-millimetre worldwide', () => {
  const cases: Geodetic[] = [
    { lat: 0, lon: 0, height: 0 },
    { lat: 29.4241, lon: -98.4936, height: 198 }, // San Antonio
    { lat: 51.4778, lon: -0.0015, height: 45 }, // Greenwich
    { lat: -33.8688, lon: 151.2093, height: 58 }, // Sydney
    { lat: 78.2232, lon: 15.6469, height: 12 }, // Svalbard
    { lat: 89.999, lon: 0, height: 0 }, // near the pole
    { lat: -45, lon: 179.999, height: 8000 }, // near the antimeridian, high
  ];
  for (const g of cases) {
    const back = ecefToGeodetic(geodeticToEcef(g), WGS84);
    near(back.lat, g.lat, 1e-9, `lat at ${g.lat}`);
    near(back.height, g.height, 1e-4, `height at ${g.lat}`);
    if (Math.abs(g.lat) < 89.9) near(back.lon, g.lon, 1e-9, `lon at ${g.lat}`);
  }
});

test('ECEF at the equator/prime meridian is the semi-major axis on X', () => {
  const p = geodeticToEcef({ lat: 0, lon: 0, height: 0 }, WGS84);
  near(p[0], WGS84.a, 1e-6, 'x');
  near(p[1], 0, 1e-6, 'y');
  near(p[2], 0, 1e-6, 'z');
});

test('ENU is right-handed east-north-up and round trips', () => {
  const reference: Geodetic = { lat: 29.4241, lon: -98.4936, height: 198 };
  // 100 m east
  const east = enuToGeodetic([100, 0, 0], reference);
  assert.ok(east.lon > reference.lon, 'east increases longitude');
  near(east.lat, reference.lat, 1e-6, 'east does not change latitude much');

  const north = enuToGeodetic([0, 100, 0], reference);
  assert.ok(north.lat > reference.lat, 'north increases latitude');

  const up = enuToGeodetic([0, 0, 100], reference);
  near(up.height, reference.height + 100, 1e-4, 'up increases height');

  for (const enu of [[0, 0, 0], [123.4, -567.8, 9.1], [-1000, 2000, -50]] as Vec3[]) {
    const back = geodeticToEnu(enuToGeodetic(enu, reference), reference);
    for (let i = 0; i < 3; i++) near(back[i], enu[i], 1e-6, `enu axis ${i}`);
  }
});

// ===========================================================================
// Projections — structural checks that catch a mistyped zone constant
// ===========================================================================

test('every zone maps its own false origin to exactly (falseEasting, falseNorthing)', () => {
  // This is the definition of the false origin, so any zone whose constants
  // were transcribed wrong will fail here.
  for (const zone of Object.values(STATE_PLANE_ZONES)) {
    const p = zone.projection;
    const xy = project(
      { lat: p.latitudeOfOrigin, lon: p.centralMeridian, height: 0 },
      p,
    );
    near(xy.easting, p.falseEasting, 1e-6, `${zone.code} easting`);
    near(xy.northing, p.falseNorthing, 1e-6, `${zone.code} northing`);
  }
});

test('every zone round trips forward/inverse to sub-millimetre', () => {
  for (const zone of Object.values(STATE_PLANE_ZONES)) {
    const p = zone.projection;
    for (const dLat of [-1, 0, 1.5]) {
      for (const dLon of [-1.5, 0, 1]) {
        const g: Geodetic = {
          lat: p.latitudeOfOrigin + dLat,
          lon: p.centralMeridian + dLon,
          height: 0,
        };
        const back = unproject(project(g, p), p);
        // 1e-9 degrees is about 0.1 mm of latitude.
        near(back.lat, g.lat, 1e-9, `${zone.code} lat`);
        near(back.lon, g.lon, 1e-9, `${zone.code} lon`);
      }
    }
  }
});

test('Lambert scale factor is 1 on both standard parallels', () => {
  // The defining property of a 2SP Lambert: the cone cuts the ellipsoid there.
  for (const zone of Object.values(STATE_PLANE_ZONES)) {
    if (zone.projection.kind !== 'lcc') continue;
    const p = zone.projection;
    for (const parallel of [p.standardParallel1, p.standardParallel2]) {
      const k = gridScaleFactor({ lat: parallel, lon: p.centralMeridian, height: 0 }, p);
      near(k, 1, 5e-7, `${zone.code} at parallel ${parallel}`);
    }
  }
});

test('Transverse Mercator scale factor equals its declared k0 on the central meridian', () => {
  const zone = lookupZone('FL83-EF');
  assert.equal(zone.projection.kind, 'tm');
  const p = zone.projection;
  const k = gridScaleFactor({ lat: p.latitudeOfOrigin + 1, lon: p.centralMeridian, height: 0 }, p);
  near(k, (p as { scaleFactor: number }).scaleFactor, 5e-7, 'k0 on the central meridian');
});

test('State Plane scale factors stay inside the 1:10000 design limit within the zone', () => {
  // Every zone is designed so grid and ground agree to about 1 part in 10,000
  // *within its area of use*. For a Lambert that band lies between the standard
  // parallels — not at the latitude of origin, which is deliberately placed
  // south of the zone and where k is legitimately above 1.
  for (const zone of Object.values(STATE_PLANE_ZONES)) {
    const p = zone.projection;
    const lat =
      p.kind === 'lcc'
        ? (p.standardParallel1 + p.standardParallel2) / 2
        : p.latitudeOfOrigin + 1;
    const k = gridScaleFactor({ lat, lon: p.centralMeridian, height: 0 }, p);
    assert.ok(
      Math.abs(k - 1) < 1.5e-4,
      `${zone.code} scale factor ${k} at lat ${lat} is outside the zone design limit`,
    );
    if (p.kind === 'lcc') {
      assert.ok(k < 1, `${zone.code}: k must dip below 1 between the standard parallels`);
    }
  }
});

test('a San Antonio fix lands in Texas South Central at a plausible coordinate', () => {
  const zone = lookupZone('TX83-SCF');
  const xy = project({ lat: 29.4241, lon: -98.4936, height: 198 }, zone.projection);
  // The zone's false northing is 4,000,000 m and San Antonio is ~1.75 deg north
  // of the 27 deg 50' origin, so the northing should be roughly 4.19M m.
  assert.ok(xy.northing > 4_150_000 && xy.northing < 4_230_000, `northing ${xy.northing}`);
  assert.ok(xy.easting > 630_000 && xy.easting < 700_000, `easting ${xy.easting}`);

  // In US survey feet the northing is the 13.7 million that breaks float32.
  const northingFt = fromMetres(xy.northing, 'usSurveyFoot');
  assert.ok(northingFt > 13_600_000 && northingFt < 13_900_000, `northing ${northingFt} ftUS`);
  assert.equal(float32Ulp(northingFt), 1, 'float32 resolves exactly one foot here');
});

test('zone lookup is case-insensitive and resolves metric variants', () => {
  assert.equal(lookupZone('tx83-scf').name, 'Texas South Central');
  const metric = lookupZone('TX83-SC');
  assert.equal(metric.unit, 'metre', 'dropping the F means metres');
  assert.equal(metric.projection, lookupZone('TX83-SCF').projection, 'same projection');
  assert.throws(() => lookupZone('XX99-ZZ'), /unknown coordinate system/);
  assert.equal(zonesForState('tx').length, 5);
});

test('plausibility check catches coordinates handed to the wrong zone', () => {
  const zone = lookupZone('TX83-SCF');
  const sanAntonio = project({ lat: 29.4241, lon: -98.4936, height: 0 }, zone.projection);

  assert.equal(checkZonePlausibility(sanAntonio, 'TX83-SCF').plausible, true);
  // The same numbers read as Texas North: silently 40 km away, in a different zone.
  const wrong = checkZonePlausibility(sanAntonio, 'TX83-NF');
  assert.equal(wrong.plausible, false);
  assert.match(wrong.reason, /outside Texas North/);
});

// ===========================================================================
// Registration
// ===========================================================================

/** Build control pairs from a known transform, so the answer is checkable. */
function syntheticControl(
  rotation = quat.fromAxisAngle([0.2, 1, 0.1], 0.4),
  translation: Vec3 = [12.5, -3.25, 7],
  noise = 0,
): ControlPair[] {
  const observed: Vec3[] = [
    [0, 0, 0], [10, 0, 0], [0, 12, 0], [0, 0, 4],
    [10, 12, 4], [5, 6, 2],
  ];
  let seed = 42;
  const rand = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed / 0x7fffffff - 0.5) * 2;
  };
  return observed.map((o, i) => ({
    id: `CP${i + 1}`,
    observed: o,
    project: v3.add(applyTransform(rotation, translation, 1, o), [
      rand() * noise, rand() * noise, rand() * noise,
    ]),
  }));
}

test('Horn solve recovers a known transform exactly from clean control', () => {
  const rotation = quat.fromAxisAngle([0.2, 1, 0.1], 0.4);
  const translation: Vec3 = [12.5, -3.25, 7];
  const solution = solveRigidTransform(syntheticControl(rotation, translation));

  assert.ok(solution.rmsError < 1e-9, `rms ${solution.rmsError} should be numerically zero`);
  for (const p of [[1, 2, 3], [-5, 0, 8]] as Vec3[]) {
    const expected = applyTransform(rotation, translation, 1, p);
    const actual = applyTransform(solution.rotation, solution.translation, solution.scale, p);
    for (let i = 0; i < 3; i++) near(actual[i], expected[i], 1e-8, `axis ${i}`);
  }
  assert.equal(solution.scale, 1, 'scale stays 1 unless asked for');
});

test('scale is not estimated unless explicitly requested', () => {
  const pairs = syntheticControl().map((p) => ({
    ...p,
    project: v3.scale(p.project, 1.05), // a genuine 5% scale error
  }));
  const fixed = solveRigidTransform(pairs);
  assert.equal(fixed.scale, 1);
  assert.ok(fixed.rmsError > 0.1, 'the scale error must show up as residual, not be absorbed');

  const scaled = solveRigidTransform(pairs, { estimateScale: true });
  near(scaled.scale, 1.05, 1e-6, 'estimated scale');
  assert.ok(scaled.rmsError < 1e-6, 'with scale free, the fit is exact');
});

test('collinear control is refused with an actionable message', () => {
  const pairs: ControlPair[] = [0, 1, 2, 3].map((i) => ({
    id: `L${i}`,
    observed: [i, 0, 0],
    project: [i + 100, 50, 20],
  }));
  assert.throws(() => solveRigidTransform(pairs), /collinear or coincident/);
});

test('fewer than three pairs is refused', () => {
  assert.throws(
    () => solveRigidTransform(syntheticControl().slice(0, 2)),
    /need at least 3 control pairs/,
  );
});

test('a knocked marker is found by the outlier test, and inflates RMS', () => {
  const clean = syntheticControl(undefined, undefined, 0.005);
  const cleanSolution = solveRigidTransform(clean);
  assert.ok(cleanSolution.rmsError < 0.02, `clean rms ${cleanSolution.rmsError}`);

  // Knock one marker 300 mm, as if it had been bumped since it was shot.
  const knocked = clean.map((p, i) =>
    i === 2 ? { ...p, project: v3.add(p.project, [0.3, 0, 0]) } : p,
  );
  const solution = solveRigidTransform(knocked);
  assert.ok(solution.rmsError > cleanSolution.rmsError * 5, 'RMS must react to the bad point');

  const outliers = findOutliers(solution);
  assert.ok(outliers.length >= 1, 'the bad point must be flagged');
  assert.equal(outliers[0].id, 'CP3', 'and it must be the right one');
  // Leave-one-out is what actually catches it: the MAD z-score is masked below
  // the threshold because the fit smears the blunder across every residual.
  assert.ok(outliers[0].influence > 3, `influence ${outliers[0].influence} should be decisive`);
  assert.ok(outliers[0].rmsWithout < solution.rmsError / 3, 'RMS must collapse without it');
  assert.match(outliers[0].reason, /Re-shoot or exclude/);
});

test('leave-one-out finds a blunder that the MAD z-score alone masks', () => {
  // The exact case from the field notes: six points, one knocked 300 mm. The
  // culprit sits at a z-score under 3 — below any sensible MAD threshold —
  // while its neighbours are dragged up with it.
  const clean = syntheticControl(undefined, undefined, 0.005);
  const knocked = clean.map((p, i) =>
    i === 2 ? { ...p, project: v3.add(p.project, [0.3, 0, 0]) } : p,
  );
  const solution = solveRigidTransform(knocked);

  const madOnly = findOutliers(solution, { madThreshold: 3.5, influenceThreshold: Infinity });
  assert.equal(madOnly.length, 0, 'MAD alone is masked here — this is the point');

  const both = findOutliers(solution);
  assert.equal(both.length >= 1, true);
  assert.equal(both[0].id, 'CP3');
});

test('outlier detection does not flag anything when all residuals are equal', () => {
  const solution = solveRigidTransform(syntheticControl());
  assert.deepEqual(findOutliers(solution), [], 'a perfect fit has no outliers');
});

test('accuracy grading maps residuals onto construction tolerance bands', () => {
  assert.equal(classifyAccuracy(0.002).band, 'layout');
  assert.equal(classifyAccuracy(0.005).band, 'penetrations');
  assert.equal(classifyAccuracy(0.008).band, 'dimensional-control');
  assert.equal(classifyAccuracy(0.030).band, 'coordination');
  assert.equal(classifyAccuracy(0.200).band, 'context');
  assert.equal(classifyAccuracy(1.5).band, 'unusable');
  assert.equal(classifyAccuracy(NaN).band, 'unusable');

  // Every band must carry guidance a crew can act on, not just a label.
  for (const rms of [0.002, 0.008, 0.03, 0.2, 5]) {
    assert.ok(classifyAccuracy(rms).guidance.length > 20, `guidance for ${rms}`);
  }
  assert.match(classifyAccuracy(0.008).guidance, /Not a substitute for layout instruments/);
});

test('survey sigma weights the solve toward the better-known points', () => {
  const pairs = syntheticControl(undefined, undefined, 0);
  // Corrupt one point badly but declare it poorly known.
  const mixed = pairs.map((p, i) =>
    i === 4
      ? { ...p, project: v3.add(p.project, [0.5, 0.5, 0.5]), sigma: 1.0 }
      : { ...p, sigma: 0.002 },
  );
  const weighted = solveRigidTransform(mixed, { useWeights: true });
  const unweighted = solveRigidTransform(mixed, { useWeights: false });
  // The well-known points should fit better when their weight is respected.
  const wellKnownRms = (s: typeof weighted) =>
    Math.sqrt(
      s.residuals.filter((_, i) => i !== 4).reduce((a, r) => a + r.error ** 2, 0) / 5,
    );
  assert.ok(
    wellKnownRms(weighted) < wellKnownRms(unweighted),
    'weighting must pull the fit toward the tight control',
  );
});

// ===========================================================================
// NMEA
// ===========================================================================

const GGA_FIXED =
  '$GNGGA,143042.00,2925.44600,N,09829.61600,W,4,18,0.6,198.500,M,-25.300,M,1.0,0000*4E';
const GST_LINE = '$GNGST,143042.00,0.015,0.012,0.009,0.0,0.011,0.013,0.021*168';

function withChecksum(body: string): string {
  let sum = 0;
  for (let i = 1; i < body.length; i++) sum ^= body.charCodeAt(i);
  return `${body}*${sum.toString(16).toUpperCase().padStart(2, '0')}`;
}

test('NMEA checksum is verified, and a corrupted sentence is rejected', () => {
  const good = withChecksum('$GNGGA,143042.00,2925.44600,N,09829.61600,W,4,18,0.6,198.5,M,-25.3,M,1.0,0000');
  assert.equal(parseNmeaSentence(good)!.valid, true);

  // Flip one digit of the latitude, keep the old checksum.
  const corrupted = good.replace('2925.44600', '2935.44600');
  assert.equal(parseNmeaSentence(corrupted)!.valid, false);
});

test('GGA parsing converts ddmm.mmmm and applies the hemisphere', () => {
  const gga = parseGga(parseNmeaSentence(withChecksum(
    '$GNGGA,143042.00,2925.44600,N,09829.61600,W,4,18,0.6,198.500,M,-25.300,M,1.0,0000',
  ))!)!;
  // 29 deg 25.446' = 29.4241
  near(gga.lat, 29 + 25.446 / 60, 1e-9, 'latitude');
  near(gga.lon, -(98 + 29.616 / 60), 1e-9, 'longitude is negative for West');
  assert.equal(gga.quality, FixQuality.RtkFixed);
  assert.equal(gga.satellites, 18);
  near(gga.orthometricHeight, 198.5, 1e-9);
  near(gga.geoidSeparation, -25.3, 1e-9);
});

test('GST reports the standard deviations that GGA cannot', () => {
  const gst = parseGst(parseNmeaSentence(withChecksum(
    '$GNGST,143042.00,0.015,0.012,0.009,0.0,0.011,0.013,0.021',
  ))!)!;
  near(gst.latitudeSigma, 0.011, 1e-9);
  near(gst.longitudeSigma, 0.013, 1e-9);
  near(gst.heightSigma, 0.021, 1e-9);
  near(gst.horizontalSigma, Math.hypot(0.011, 0.013), 1e-9);
});

test('assembler pairs GGA with GST and computes ellipsoidal height', () => {
  const a = new NmeaAssembler();
  assert.equal(a.push(withChecksum(
    '$GNGGA,143042.00,2925.44600,N,09829.61600,W,4,18,0.6,198.500,M,-25.300,M,1.0,0000',
  )), null, 'GGA alone waits for its GST');

  const fix = a.push(withChecksum('$GNGST,143042.00,0.015,0.012,0.009,0.0,0.011,0.013,0.021'))!;
  assert.ok(fix, 'the pair completes the fix');
  assert.equal(fix.quality, FixQuality.RtkFixed);
  // GGA gives orthometric height; ellipsoidal = orthometric + separation.
  near(fix.height, 198.5 + -25.3, 1e-9, 'ellipsoidal height');
  near(fix.orthometricHeight!, 198.5, 1e-9);
  near(fix.hAccuracy!, Math.hypot(0.011, 0.013), 1e-9);
});

test('assembler still emits a fix when GST never arrives, without faking accuracy', () => {
  const a = new NmeaAssembler();
  a.push(withChecksum('$GNGGA,143042.00,2925.44600,N,09829.61600,W,4,18,0.6,198.5,M,-25.3,M,1.0,0000'));
  const fix = a.flush()!;
  assert.ok(fix);
  assert.equal(fix.hAccuracy, undefined, 'no GST means no accuracy claim');
});

test('assembler drops sentences that fail their checksum', () => {
  const a = new NmeaAssembler();
  const bad = '$GNGGA,143042.00,2925.44600,N,09829.61600,W,4,18,0.6,198.5,M,-25.3,M,1.0,0000*00';
  assert.equal(a.push(bad), null);
  assert.equal(a.flush(), null, 'nothing was accepted');
});

test('fix quality distinguishes RTK fixed from the float solution that looks like it', () => {
  assert.equal(describeFixQuality(FixQuality.RtkFixed).usable, true);
  assert.equal(describeFixQuality(FixQuality.RtkFloat).usable, false);
  assert.match(describeFixQuality(FixQuality.RtkFloat).label, /decimetre/);
  assert.equal(describeFixQuality(FixQuality.SinglePoint).usable, false);
});
