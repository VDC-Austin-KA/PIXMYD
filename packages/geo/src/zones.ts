/**
 * State Plane zone registry, keyed by the Autodesk coordinate-system code that
 * Civil 3D and Revit use.
 *
 * The code encodes state, datum, zone and unit: `TX83-SCF` reads as Texas,
 * NAD83, South Central, `F` for US survey feet. Dropping the trailing `F` gives
 * the metric variant of the same zone.
 *
 * Projection parameters are in metres and degrees regardless of the zone's
 * working unit, because that is how the projection is defined — the unit
 * applies to the *output*, after projecting. Mixing that up is a factor-of-3.28
 * error, which at least announces itself.
 *
 * Zone constants below are the published NGS/EPSG definitions. The projection
 * tests check them structurally: the false origin must map exactly to
 * (falseEasting, falseNorthing), and the scale factor must be 1 on the standard
 * parallels. Those catch a mistyped constant.
 */

import { GRS80, unproject, type Projection } from './projection.ts';
import type { LinearUnit } from './units.ts';

export interface StatePlaneZone {
  code: string;
  name: string;
  state: string;
  datum: 'NAD83';
  unit: LinearUnit;
  /** NAD83 (1986 realisation). */
  epsg: number;
  /** NAD83(2011) realisation, which modern survey control is usually on. */
  epsg2011?: number;
  /** Same zone, metric variant. */
  metricCode: string;
  projection: Projection;
  note?: string;
}

/** Degrees-minutes to decimal degrees, for transcribing published constants. */
const dm = (deg: number, min: number): number =>
  Math.sign(deg || 1) * (Math.abs(deg) + min / 60);

const ZONES: Record<string, Omit<StatePlaneZone, 'code'>> = {
  'TX83-NF': {
    name: 'Texas North',
    state: 'TX',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2275,
    epsg2011: 6582,
    metricCode: 'TX83-N',
    note: 'Panhandle. Amarillo.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(34, 0),
      centralMeridian: dm(-101, 30),
      standardParallel1: dm(34, 39),
      standardParallel2: dm(36, 11),
      falseEasting: 200000,
      falseNorthing: 1000000,
    },
  },
  'TX83-NCF': {
    name: 'Texas North Central',
    state: 'TX',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2276,
    epsg2011: 6584,
    metricCode: 'TX83-NC',
    note: 'Dallas, Fort Worth, Abilene.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(31, 40),
      centralMeridian: dm(-98, 30),
      standardParallel1: dm(32, 8),
      standardParallel2: dm(33, 58),
      falseEasting: 600000,
      falseNorthing: 2000000,
    },
  },
  'TX83-CF': {
    name: 'Texas Central',
    state: 'TX',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2277,
    epsg2011: 6586,
    metricCode: 'TX83-C',
    note: 'Austin, Waco, Midland.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(29, 40),
      centralMeridian: dm(-100, 20),
      standardParallel1: dm(30, 7),
      standardParallel2: dm(31, 53),
      falseEasting: 700000,
      falseNorthing: 3000000,
    },
  },
  'TX83-SCF': {
    name: 'Texas South Central',
    state: 'TX',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2278,
    epsg2011: 6588,
    metricCode: 'TX83-SC',
    note:
      'San Antonio, Houston, Corpus Christi. False northing 4,000,000 m = ' +
      '13,123,333.333 ftUS — the magnitude that destroys a float32 pipeline.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(27, 50),
      centralMeridian: dm(-99, 0),
      standardParallel1: dm(28, 23),
      standardParallel2: dm(30, 17),
      falseEasting: 600000,
      falseNorthing: 4000000,
    },
  },
  'TX83-SF': {
    name: 'Texas South',
    state: 'TX',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2279,
    epsg2011: 6590,
    metricCode: 'TX83-S',
    note: 'Rio Grande Valley. Brownsville, McAllen.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(25, 40),
      centralMeridian: dm(-98, 30),
      standardParallel1: dm(26, 10),
      standardParallel2: dm(27, 50),
      falseEasting: 300000,
      falseNorthing: 5000000,
    },
  },

  // Non-Texas zones, so the registry is obviously extensible rather than
  // Texas-shaped. Florida East is Transverse Mercator, which exercises the
  // other projection.
  'CA83-IIIF': {
    name: 'California zone 3',
    state: 'CA',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2227,
    epsg2011: 6418,
    metricCode: 'CA83-III',
    note: 'Bay Area.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(36, 30),
      centralMeridian: dm(-120, 30),
      standardParallel1: dm(37, 4),
      standardParallel2: dm(38, 26),
      falseEasting: 2000000,
      falseNorthing: 500000,
    },
  },
  'CO83-CF': {
    name: 'Colorado Central',
    state: 'CO',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2232,
    epsg2011: 6428,
    metricCode: 'CO83-C',
    note: 'Denver.',
    projection: {
      kind: 'lcc',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(37, 50),
      centralMeridian: dm(-105, 30),
      standardParallel1: dm(38, 27),
      standardParallel2: dm(39, 45),
      falseEasting: 914401.8289,
      falseNorthing: 304800.6096,
    },
  },
  'FL83-EF': {
    name: 'Florida East',
    state: 'FL',
    datum: 'NAD83',
    unit: 'usSurveyFoot',
    epsg: 2236,
    epsg2011: 6437,
    metricCode: 'FL83-E',
    note: 'Miami, Orlando. Transverse Mercator, not Lambert.',
    projection: {
      kind: 'tm',
      ellipsoid: GRS80,
      latitudeOfOrigin: dm(24, 20),
      centralMeridian: dm(-81, 0),
      scaleFactor: 0.9999411764705882, // 1 - 1/17000
      falseEasting: 200000,
      falseNorthing: 0,
    },
  },
};

export const STATE_PLANE_ZONES: Record<string, StatePlaneZone> = Object.fromEntries(
  Object.entries(ZONES).map(([code, zone]) => [code, { ...zone, code }]),
);

/**
 * Look up a zone by its Autodesk code, case-insensitively. Metric codes resolve
 * to the same projection with `unit` set to metre, since dropping the `F` is
 * exactly what that means.
 */
export function lookupZone(code: string): StatePlaneZone {
  if (typeof code !== 'string') throw new Error('coordinate system code must be a string');
  const key = code.trim().toUpperCase();

  const direct = STATE_PLANE_ZONES[key];
  if (direct) return direct;

  const metric = Object.values(STATE_PLANE_ZONES).find(
    (z) => z.metricCode.toUpperCase() === key,
  );
  if (metric) return { ...metric, code: metric.metricCode, unit: 'metre' };

  const known = Object.keys(STATE_PLANE_ZONES).join(', ');
  throw new Error(`unknown coordinate system "${code}". Known zones: ${known}`);
}

/** All zones for a state, for building a picker. */
export function zonesForState(state: string): StatePlaneZone[] {
  return Object.values(STATE_PLANE_ZONES).filter(
    (z) => z.state.toUpperCase() === state.trim().toUpperCase(),
  );
}

/**
 * Check that a coordinate is plausibly inside its declared zone.
 *
 * The single most common georeferencing mistake is the right numbers in the
 * wrong zone, and it is silent — the model loads, it just sits 40 km away.
 * Round-tripping through the projection and comparing catches it immediately.
 */
export function checkZonePlausibility(
  sample: { easting: number; northing: number },
  code: string,
): { plausible: boolean; reason: string; latitude?: number; longitude?: number } {
  const zone = lookupZone(code);
  const g = unproject(sample, zone.projection);

  if (!Number.isFinite(g.lat) || !Number.isFinite(g.lon)) {
    return { plausible: false, reason: 'Coordinate does not invert to a real position.' };
  }
  const inLatBand = Math.abs(g.lat - zone.projection.latitudeOfOrigin) < 5;
  const inLonBand = Math.abs(g.lon - zone.projection.centralMeridian) < 5;

  if (inLatBand && inLonBand) {
    return {
      plausible: true,
      reason: `Inverts to ${g.lat.toFixed(5)}, ${g.lon.toFixed(5)} — inside ${zone.name}.`,
      latitude: g.lat,
      longitude: g.lon,
    };
  }
  return {
    plausible: false,
    reason:
      `Inverts to ${g.lat.toFixed(5)}, ${g.lon.toFixed(5)}, which is outside ` +
      `${zone.name}. Either the zone is wrong or the coordinates are in a different unit.`,
    latitude: g.lat,
    longitude: g.lon,
  };
}
