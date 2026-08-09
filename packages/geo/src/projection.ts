/**
 * Geodesy: ellipsoids, ECEF, ENU, and the two map projections that cover every
 * US State Plane zone.
 *
 * This is what turns a GNSS fix into a project coordinate. Without it an RTK
 * receiver reporting centimetre latitude and longitude is useless — the model,
 * the control sheet and the deliverable are all in State Plane, and something
 * has to do the conversion.
 *
 * Every State Plane zone is either Lambert Conformal Conic (zones wider
 * east-west) or Transverse Mercator (zones taller north-south). Both are
 * implemented here in their standard form, following Snyder's *Map Projections:
 * A Working Manual* (USGS Professional Paper 1395), which is also what PROJ and
 * GeographicLib implement.
 *
 * Angles are radians internally and degrees at the boundary, because degrees
 * are what a receiver reports and what a person types.
 */

import type { Vec3 } from '@pixmyd/core/math';

// ---------------------------------------------------------------------------
// Ellipsoids
// ---------------------------------------------------------------------------

export interface Ellipsoid {
  name: string;
  /** Semi-major axis, metres. */
  a: number;
  /** Inverse flattening. */
  invF: number;
}

export const GRS80: Ellipsoid = { name: 'GRS 1980', a: 6378137.0, invF: 298.257222101 };
export const WGS84: Ellipsoid = { name: 'WGS 84', a: 6378137.0, invF: 298.257223563 };

/**
 * NAD83 is defined on GRS80, WGS84 on its own ellipsoid. The two differ by
 * about 0.1 mm in semi-minor axis — irrelevant — but the *datums* have drifted
 * over a metre apart, which is not. See `NAD83_WGS84_NOTE`.
 */
export const NAD83_WGS84_NOTE =
  'NAD83 and WGS84 are different datums. Their ellipsoids are all but identical, ' +
  'but the frames have diverged by roughly 1-2 m in the continental US and the gap ' +
  'grows with time. A GNSS receiver outputs WGS84 (or ITRF) unless it is applying ' +
  'an RTK correction from an NAD83 base, in which case it outputs NAD83. Using one ' +
  'as the other is a systematic metre-level shift that no amount of averaging removes.';

export function flattening(e: Ellipsoid): number {
  return 1 / e.invF;
}

/** First eccentricity squared. */
export function eccentricitySquared(e: Ellipsoid): number {
  const f = flattening(e);
  return f * (2 - f);
}

export function semiMinorAxis(e: Ellipsoid): number {
  return e.a * (1 - flattening(e));
}

const DEG = Math.PI / 180;

// ---------------------------------------------------------------------------
// Geodetic <-> ECEF
// ---------------------------------------------------------------------------

export interface Geodetic {
  /** Degrees, positive north. */
  lat: number;
  /** Degrees, positive east. */
  lon: number;
  /** Metres above the ellipsoid — not above sea level. */
  height: number;
}

/** Geodetic to earth-centred earth-fixed metres. */
export function geodeticToEcef(g: Geodetic, ellipsoid: Ellipsoid = WGS84): Vec3 {
  const e2 = eccentricitySquared(ellipsoid);
  const phi = g.lat * DEG;
  const lambda = g.lon * DEG;
  const sinPhi = Math.sin(phi);
  const cosPhi = Math.cos(phi);
  // Radius of curvature in the prime vertical.
  const N = ellipsoid.a / Math.sqrt(1 - e2 * sinPhi * sinPhi);
  return [
    (N + g.height) * cosPhi * Math.cos(lambda),
    (N + g.height) * cosPhi * Math.sin(lambda),
    (N * (1 - e2) + g.height) * sinPhi,
  ];
}

/**
 * ECEF to geodetic, by Bowring's method with one Newton refinement.
 *
 * Bowring's closed form is accurate to well under a millimetre for heights
 * within a few thousand kilometres of the surface, which is every case here.
 * The refinement costs one iteration and removes the residual entirely.
 */
export function ecefToGeodetic(p: Vec3, ellipsoid: Ellipsoid = WGS84): Geodetic {
  const [x, y, z] = p;
  const a = ellipsoid.a;
  const b = semiMinorAxis(ellipsoid);
  const e2 = eccentricitySquared(ellipsoid);
  // Second eccentricity squared.
  const ep2 = (a * a - b * b) / (b * b);

  const r = Math.hypot(x, y);
  const lon = Math.atan2(y, x);

  if (r < 1e-12) {
    // On the polar axis: longitude is undefined, latitude is +/-90.
    return { lat: z >= 0 ? 90 : -90, lon: 0, height: Math.abs(z) - b };
  }

  const theta = Math.atan2(z * a, r * b);
  const sinTheta = Math.sin(theta);
  const cosTheta = Math.cos(theta);
  let phi = Math.atan2(
    z + ep2 * b * sinTheta * sinTheta * sinTheta,
    r - e2 * a * cosTheta * cosTheta * cosTheta,
  );

  // One Newton step on the exact relation.
  for (let i = 0; i < 2; i++) {
    const sinPhi = Math.sin(phi);
    const N = a / Math.sqrt(1 - e2 * sinPhi * sinPhi);
    phi = Math.atan2(z + e2 * N * sinPhi, r);
  }

  const sinPhi = Math.sin(phi);
  const N = a / Math.sqrt(1 - e2 * sinPhi * sinPhi);
  const cosPhi = Math.cos(phi);
  // Near the poles r/cosPhi is unstable; use the z form instead.
  const height =
    Math.abs(cosPhi) > 0.1 ? r / cosPhi - N : z / sinPhi - N * (1 - e2);

  return { lat: phi / DEG, lon: lon / DEG, height };
}

// ---------------------------------------------------------------------------
// Local tangent plane (ENU)
// ---------------------------------------------------------------------------

/**
 * East-north-up metres relative to a reference point.
 *
 * This is the frame a capture session lives in before it is georeferenced:
 * flat, metric, and small enough for float32. Curvature error is under a
 * millimetre within a kilometre of the origin, so it is exact for a site and
 * wrong for a county.
 */
export function ecefToEnu(p: Vec3, reference: Geodetic, ellipsoid: Ellipsoid = WGS84): Vec3 {
  const origin = geodeticToEcef(reference, ellipsoid);
  const dx = p[0] - origin[0];
  const dy = p[1] - origin[1];
  const dz = p[2] - origin[2];
  const phi = reference.lat * DEG;
  const lambda = reference.lon * DEG;
  const sp = Math.sin(phi), cp = Math.cos(phi);
  const sl = Math.sin(lambda), cl = Math.cos(lambda);
  return [
    -sl * dx + cl * dy,
    -sp * cl * dx - sp * sl * dy + cp * dz,
    cp * cl * dx + cp * sl * dy + sp * dz,
  ];
}

export function enuToEcef(enu: Vec3, reference: Geodetic, ellipsoid: Ellipsoid = WGS84): Vec3 {
  const origin = geodeticToEcef(reference, ellipsoid);
  const phi = reference.lat * DEG;
  const lambda = reference.lon * DEG;
  const sp = Math.sin(phi), cp = Math.cos(phi);
  const sl = Math.sin(lambda), cl = Math.cos(lambda);
  const [e, n, u] = enu;
  return [
    origin[0] - sl * e - sp * cl * n + cp * cl * u,
    origin[1] + cl * e - sp * sl * n + cp * sl * u,
    origin[2] + cp * n + sp * u,
  ];
}

export function geodeticToEnu(g: Geodetic, reference: Geodetic, ellipsoid: Ellipsoid = WGS84): Vec3 {
  return ecefToEnu(geodeticToEcef(g, ellipsoid), reference, ellipsoid);
}

export function enuToGeodetic(enu: Vec3, reference: Geodetic, ellipsoid: Ellipsoid = WGS84): Geodetic {
  return ecefToGeodetic(enuToEcef(enu, reference, ellipsoid), ellipsoid);
}

// ---------------------------------------------------------------------------
// Map projections
// ---------------------------------------------------------------------------

export interface Projected {
  /** Easting in the projection's own linear unit (metres here). */
  easting: number;
  northing: number;
}

export interface LambertConformalConic2SP {
  kind: 'lcc';
  ellipsoid: Ellipsoid;
  /** Degrees. */
  latitudeOfOrigin: number;
  centralMeridian: number;
  standardParallel1: number;
  standardParallel2: number;
  /** Metres. */
  falseEasting: number;
  falseNorthing: number;
}

export interface TransverseMercator {
  kind: 'tm';
  ellipsoid: Ellipsoid;
  latitudeOfOrigin: number;
  centralMeridian: number;
  scaleFactor: number;
  falseEasting: number;
  falseNorthing: number;
}

export type Projection = LambertConformalConic2SP | TransverseMercator;

/** Isometric latitude helper, Snyder eq. 15-9. */
function tIso(phi: number, e: number): number {
  const sinPhi = Math.sin(phi);
  return (
    Math.tan(Math.PI / 4 - phi / 2) /
    ((1 - e * sinPhi) / (1 + e * sinPhi)) ** (e / 2)
  );
}

/** Snyder eq. 14-15. */
function mFn(phi: number, e: number): number {
  const sinPhi = Math.sin(phi);
  return Math.cos(phi) / Math.sqrt(1 - e * e * sinPhi * sinPhi);
}

interface LccConstants {
  n: number;
  F: number;
  rho0: number;
  e: number;
}

function lccConstants(p: LambertConformalConic2SP): LccConstants {
  const e = Math.sqrt(eccentricitySquared(p.ellipsoid));
  const phi0 = p.latitudeOfOrigin * DEG;
  const phi1 = p.standardParallel1 * DEG;
  const phi2 = p.standardParallel2 * DEG;

  const m1 = mFn(phi1, e);
  const m2 = mFn(phi2, e);
  const t0 = tIso(phi0, e);
  const t1 = tIso(phi1, e);
  const t2 = tIso(phi2, e);

  // With coincident standard parallels the 2SP formula is 0/0; the 1SP limit is
  // n = sin(phi1). Guarding this keeps a tangent-case zone from returning NaN.
  const n =
    Math.abs(phi1 - phi2) < 1e-10
      ? Math.sin(phi1)
      : Math.log(m1 / m2) / Math.log(t1 / t2);

  const F = m1 / (n * t1 ** n);
  const rho0 = p.ellipsoid.a * F * t0 ** n;
  return { n, F, rho0, e };
}

function lccForward(g: Geodetic, p: LambertConformalConic2SP): Projected {
  const { n, F, rho0, e } = lccConstants(p);
  const phi = g.lat * DEG;
  const lambda = g.lon * DEG;
  const lambda0 = p.centralMeridian * DEG;

  const t = tIso(phi, e);
  const rho = p.ellipsoid.a * F * t ** n;
  // Normalise the meridian difference into (-pi, pi] so a zone spanning the
  // antimeridian does not wrap to the far side of the cone.
  let dLambda = lambda - lambda0;
  while (dLambda > Math.PI) dLambda -= 2 * Math.PI;
  while (dLambda < -Math.PI) dLambda += 2 * Math.PI;
  const theta = n * dLambda;

  return {
    easting: p.falseEasting + rho * Math.sin(theta),
    northing: p.falseNorthing + rho0 - rho * Math.cos(theta),
  };
}

function lccInverse(xy: Projected, p: LambertConformalConic2SP, height = 0): Geodetic {
  const { n, F, rho0, e } = lccConstants(p);
  const x = xy.easting - p.falseEasting;
  const y = rho0 - (xy.northing - p.falseNorthing);

  // rho carries the sign of n so southern-hemisphere cones invert correctly.
  const rho = Math.sign(n) * Math.hypot(x, y);
  const theta = Math.atan2(Math.sign(n) * x, Math.sign(n) * y);

  const t = (rho / (p.ellipsoid.a * F)) ** (1 / n);
  // Snyder eq. 3-4: iterate phi from t. Converges in 4-5 passes; 15 is ample.
  let phi = Math.PI / 2 - 2 * Math.atan(t);
  for (let i = 0; i < 15; i++) {
    const sinPhi = Math.sin(phi);
    const next =
      Math.PI / 2 -
      2 * Math.atan(t * ((1 - e * sinPhi) / (1 + e * sinPhi)) ** (e / 2));
    if (Math.abs(next - phi) < 1e-14) {
      phi = next;
      break;
    }
    phi = next;
  }

  return {
    lat: phi / DEG,
    lon: (theta / n + p.centralMeridian * DEG) / DEG,
    height,
  };
}

/** Meridional arc distance from the equator, Snyder eq. 3-21. */
function meridionalArc(phi: number, a: number, e2: number): number {
  const e4 = e2 * e2;
  const e6 = e4 * e2;
  return (
    a *
    ((1 - e2 / 4 - (3 * e4) / 64 - (5 * e6) / 256) * phi -
      ((3 * e2) / 8 + (3 * e4) / 32 + (45 * e6) / 1024) * Math.sin(2 * phi) +
      ((15 * e4) / 256 + (45 * e6) / 1024) * Math.sin(4 * phi) -
      ((35 * e6) / 3072) * Math.sin(6 * phi))
  );
}

function tmForward(g: Geodetic, p: TransverseMercator): Projected {
  const a = p.ellipsoid.a;
  const e2 = eccentricitySquared(p.ellipsoid);
  const ep2 = e2 / (1 - e2);
  const k0 = p.scaleFactor;

  const phi = g.lat * DEG;
  const lambda0 = p.centralMeridian * DEG;
  let dLambda = g.lon * DEG - lambda0;
  while (dLambda > Math.PI) dLambda -= 2 * Math.PI;
  while (dLambda < -Math.PI) dLambda += 2 * Math.PI;

  const sinPhi = Math.sin(phi);
  const cosPhi = Math.cos(phi);
  const tanPhi = Math.tan(phi);

  const N = a / Math.sqrt(1 - e2 * sinPhi * sinPhi);
  const T = tanPhi * tanPhi;
  const C = ep2 * cosPhi * cosPhi;
  const A = dLambda * cosPhi;
  const M = meridionalArc(phi, a, e2);
  const M0 = meridionalArc(p.latitudeOfOrigin * DEG, a, e2);

  const A2 = A * A;
  const easting =
    p.falseEasting +
    k0 * N * (A + ((1 - T + C) * A2 * A) / 6 +
      ((5 - 18 * T + T * T + 72 * C - 58 * ep2) * A2 * A2 * A) / 120);

  const northing =
    p.falseNorthing +
    k0 *
      (M - M0 +
        N * tanPhi *
          (A2 / 2 + ((5 - T + 9 * C + 4 * C * C) * A2 * A2) / 24 +
            ((61 - 58 * T + T * T + 600 * C - 330 * ep2) * A2 * A2 * A2) / 720));

  return { easting, northing };
}

function tmInverse(xy: Projected, p: TransverseMercator, height = 0): Geodetic {
  const a = p.ellipsoid.a;
  const e2 = eccentricitySquared(p.ellipsoid);
  const ep2 = e2 / (1 - e2);
  const k0 = p.scaleFactor;
  const e1 = (1 - Math.sqrt(1 - e2)) / (1 + Math.sqrt(1 - e2));

  const M0 = meridionalArc(p.latitudeOfOrigin * DEG, a, e2);
  const M = M0 + (xy.northing - p.falseNorthing) / k0;
  const mu = M / (a * (1 - e2 / 4 - (3 * e2 * e2) / 64 - (5 * e2 ** 3) / 256));

  const e1_2 = e1 * e1;
  const e1_3 = e1_2 * e1;
  const e1_4 = e1_3 * e1;
  // Footprint latitude, Snyder eq. 3-26.
  const phi1 =
    mu +
    ((3 * e1) / 2 - (27 * e1_3) / 32) * Math.sin(2 * mu) +
    ((21 * e1_2) / 16 - (55 * e1_4) / 32) * Math.sin(4 * mu) +
    ((151 * e1_3) / 96) * Math.sin(6 * mu) +
    ((1097 * e1_4) / 512) * Math.sin(8 * mu);

  const sinPhi1 = Math.sin(phi1);
  const cosPhi1 = Math.cos(phi1);
  const tanPhi1 = Math.tan(phi1);
  const C1 = ep2 * cosPhi1 * cosPhi1;
  const T1 = tanPhi1 * tanPhi1;
  const N1 = a / Math.sqrt(1 - e2 * sinPhi1 * sinPhi1);
  const R1 = (a * (1 - e2)) / (1 - e2 * sinPhi1 * sinPhi1) ** 1.5;
  const D = (xy.easting - p.falseEasting) / (N1 * k0);

  const D2 = D * D;
  const phi =
    phi1 -
    ((N1 * tanPhi1) / R1) *
      (D2 / 2 -
        ((5 + 3 * T1 + 10 * C1 - 4 * C1 * C1 - 9 * ep2) * D2 * D2) / 24 +
        ((61 + 90 * T1 + 298 * C1 + 45 * T1 * T1 - 252 * ep2 - 3 * C1 * C1) * D2 * D2 * D2) / 720);

  const lambda =
    p.centralMeridian * DEG +
    (D - ((1 + 2 * T1 + C1) * D2 * D) / 6 +
      ((5 - 2 * C1 + 28 * T1 - 3 * C1 * C1 + 8 * ep2 + 24 * T1 * T1) * D2 * D2 * D) / 120) /
      cosPhi1;

  return { lat: phi / DEG, lon: lambda / DEG, height };
}

/** Geodetic to projected metres. */
export function project(g: Geodetic, projection: Projection): Projected {
  return projection.kind === 'lcc' ? lccForward(g, projection) : tmForward(g, projection);
}

/** Projected metres back to geodetic. Height passes through unchanged. */
export function unproject(xy: Projected, projection: Projection, height = 0): Geodetic {
  return projection.kind === 'lcc'
    ? lccInverse(xy, projection, height)
    : tmInverse(xy, projection, height);
}

/**
 * Grid scale factor at a point: the ratio of grid distance to ground distance.
 *
 * This is the number that decides whether a survey can be laid out from grid
 * coordinates directly. State Plane zones are designed to keep it within about
 * 1 part in 10,000, which is 100 mm per kilometre — well past a layout
 * tolerance, so a combined factor is applied on real jobs. Computed
 * numerically, which is exact enough and avoids a second set of series.
 */
export function gridScaleFactor(g: Geodetic, projection: Projection): number {
  const delta = 1e-6; // degrees, roughly 0.1 m
  const north: Geodetic = { ...g, lat: g.lat + delta };
  const a = project(g, projection);
  const b = project(north, projection);
  const gridDistance = Math.hypot(b.easting - a.easting, b.northing - a.northing);
  const groundDistance = Math.hypot(
    ...(geodeticToEnu(north, g, projection.ellipsoid).slice(0, 2) as [number, number]),
  );
  return groundDistance === 0 ? 1 : gridDistance / groundDistance;
}
