/**
 * Units, precision, and the floating origin.
 *
 * The two facts this module exists to enforce:
 *
 * 1. **"Feet" is not a unit.** The US survey foot is 1200/3937 m; the
 *    international foot is 0.3048 m exactly. Two parts per million — nothing on
 *    a 40-foot wall, but multiplied by a 13.7-million-foot Texas northing the
 *    same number read two ways lands 27 feet apart. Nothing in this codebase
 *    records a unit as "feet".
 *
 * 2. **float32 cannot hold survey coordinates.** A float32 has a 24-bit
 *    significand, so between 2^23 and 2^24 its spacing is exactly 1.0. Texas
 *    South Central has a false northing of 13,123,333.333 ftUS, so real site
 *    northings sit near 13.7 million — where float32 resolves one *foot*. Every
 *    GPU vertex buffer is float32. The fix is a floating origin, and it is not
 *    optional.
 */

import type { Vec3 } from '@pixmyd/core/math';
import type { CrsBlock } from '@pixmyd/core/bundle';

export type LinearUnit = 'metre' | 'usSurveyFoot' | 'internationalFoot';

/** Metres per unit. Exact definitions. */
export const UNITS: Record<LinearUnit, number> = {
  usSurveyFoot: 1200 / 3937, // 0.30480060960121920...
  internationalFoot: 0.3048,
  metre: 1,
};

export const UNIT_LABELS: Record<LinearUnit, string> = {
  usSurveyFoot: 'US survey foot (ftUS)',
  internationalFoot: 'International foot (ft)',
  metre: 'Metre (m)',
};

export function toMetres(value: number, unit: LinearUnit): number {
  return value * UNITS[unit];
}

export function fromMetres(metres: number, unit: LinearUnit): number {
  return metres / UNITS[unit];
}

/**
 * Spacing of representable float32 values at a magnitude — the number that
 * decides whether a floating origin is required.
 */
export function float32Ulp(value: number): number {
  const magnitude = Math.abs(value);
  if (magnitude === 0) return 2 ** -149; // smallest subnormal
  if (!Number.isFinite(magnitude)) return Infinity;
  const exponent = Math.floor(Math.log2(magnitude));
  // 24-bit significand, so the step is 2^(exponent - 23).
  return 2 ** (exponent - 23);
}

export interface PrecisionReport {
  requiresFloatingOrigin: boolean;
  /** float32 step at this coordinate, in the coordinate's own unit. */
  ulp: number;
  /** The same step expressed in millimetres. */
  ulpMillimetres: number;
  tolerance: number;
  reason: string;
}

/**
 * Whether a coordinate can be shipped to a GPU as-is, with the reason in words
 * a person can act on.
 */
export function precisionReport(
  sampleCoordinate: Vec3,
  unit: LinearUnit,
  toleranceMetres = 0.001,
): PrecisionReport {
  const worst = Math.max(
    Math.abs(sampleCoordinate[0]),
    Math.abs(sampleCoordinate[1]),
    Math.abs(sampleCoordinate[2]),
  );
  const ulp = float32Ulp(worst);
  const ulpMetres = ulp * UNITS[unit];
  const requiresFloatingOrigin = ulpMetres > toleranceMetres;

  const mm = ulpMetres * 1000;
  const reason = requiresFloatingOrigin
    ? `At ${worst.toLocaleString()} ${unit}, float32 resolves no finer than ` +
      `${mm >= 1 ? `${mm.toFixed(0)} mm` : `${mm.toFixed(3)} mm`}. ` +
      `Geometry would snap to that lattice and visibly shake as the camera moves. ` +
      `Subtract a project origin before converting to float32.`
    : `At ${worst.toLocaleString()} ${unit}, float32 resolves ${mm.toExponential(2)} mm, ` +
      `inside the ${(toleranceMetres * 1000).toFixed(1)} mm tolerance.`;

  return {
    requiresFloatingOrigin,
    ulp,
    ulpMillimetres: mm,
    tolerance: toleranceMetres,
    reason,
  };
}

export interface OriginOptions {
  /** Snap grid in project units. 1000 by default. */
  grid?: number;
}

/**
 * Choose a project origin from the data bounds.
 *
 * The origin snaps to a round grid, and that is operational, not cosmetic. An
 * origin that tracked the centroid would move every time the model changed —
 * republishing after adding a wing would silently shift every cached tile and
 * every stored observation relative to the geometry. Snapped, it only moves if
 * the project moves to a different part of the state. It is also readable,
 * which counts when a surveyor checks it against a control sheet.
 */
export function chooseOrigin(
  bounds: { min: Vec3; max: Vec3 },
  options: OriginOptions = {},
): Vec3 {
  const grid = options.grid ?? 1000;
  const centre: Vec3 = [
    (bounds.min[0] + bounds.max[0]) / 2,
    (bounds.min[1] + bounds.max[1]) / 2,
    (bounds.min[2] + bounds.max[2]) / 2,
  ];
  return [
    Math.round(centre[0] / grid) * grid,
    Math.round(centre[1] / grid) * grid,
    // Elevation stays put: a 1000-unit snap on Z would put the site
    // hundreds of metres off the ground for no precision benefit.
    0,
  ];
}

/**
 * Axis conventions.
 *
 * Survey and BIM are X east, Y north, **Z up**. glTF, WebXR and every renderer
 * here are X right, **Y up**, Z toward the viewer. The negation on Z is not
 * cosmetic: without it the frame is left-handed and the floorplate mirrors —
 * which is worse than lying on its side, because a mirrored plan still looks
 * plausible until someone notices the stair turns the wrong way.
 */
export type AxisConvention = 'surveyToRender' | 'identity';

/** Project coordinates -> local Y-up metres. */
export function toLocalMetres(
  point: Vec3,
  origin: Vec3,
  unit: LinearUnit,
  convention: AxisConvention = 'surveyToRender',
): Vec3 {
  const scale = UNITS[unit];
  const east = (point[0] - origin[0]) * scale;
  const north = (point[1] - origin[1]) * scale;
  const up = (point[2] - origin[2]) * scale;
  return convention === 'surveyToRender' ? [east, up, -north] : [east, north, up];
}

/** Local Y-up metres -> project coordinates. The exact inverse. */
export function toProjectCoordinates(
  local: Vec3,
  origin: Vec3,
  unit: LinearUnit,
  convention: AxisConvention = 'surveyToRender',
): Vec3 {
  const scale = UNITS[unit];
  const [east, north, up] =
    convention === 'surveyToRender'
      ? [local[0], -local[2], local[1]]
      : [local[0], local[1], local[2]];
  return [
    east / scale + origin[0],
    north / scale + origin[1],
    up / scale + origin[2],
  ];
}

/**
 * Build a CRS block. Note that `unit` is always explicit and
 * `metresPerUnit` is written out, so no consumer downstream has to guess which
 * foot was meant.
 */
export function buildCrsBlock(spec: {
  code: string;
  name?: string;
  unit: LinearUnit;
  origin?: Vec3;
  verticalDatum?: string;
  geoidModel?: string;
}): CrsBlock {
  return {
    code: spec.code,
    name: spec.name,
    unit: spec.unit,
    metresPerUnit: UNITS[spec.unit],
    origin: spec.origin,
    verticalDatum: spec.verticalDatum,
    geoidModel: spec.geoidModel,
  };
}

/**
 * How far apart the two definitions of "foot" put the same number.
 * Returned in metres, so the answer is directly comparable to a tolerance.
 */
export function footDefinitionDivergence(valueInFeet: number): number {
  return Math.abs(valueInFeet * (UNITS.usSurveyFoot - UNITS.internationalFoot));
}
