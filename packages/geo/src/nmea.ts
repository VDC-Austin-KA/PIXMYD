/**
 * NMEA 0183 parsing, for RTK receivers.
 *
 * An Emlid Reach RX, a viDoc rover, a Bad Elf, a Trimble DA2 — all of them
 * speak NMEA over Bluetooth, and all of them speak the same four sentences that
 * matter here:
 *
 *   GGA  position, fix quality, satellite count, geoid separation
 *   GST  per-axis standard deviations — the only honest accuracy figure
 *   RMC  date and time, so a fix can be tied to a frame
 *   VTG  ground speed and course
 *
 * The single most important field is GGA's quality indicator. **4 means an
 * integer-ambiguity fixed solution and centimetre work. 5 is a float solution,
 * which looks identical on screen and is decimetres out.** A capture
 * georeferenced from float fixes will pass every internal check and be wrong.
 */

import { FixQuality, type GnssFix } from '@pixmyd/core/bundle';

export interface NmeaSentence {
  talker: string;
  type: string;
  fields: string[];
  valid: boolean;
}

/**
 * Split a sentence and verify its checksum.
 *
 * The checksum is an XOR of everything between `$` and `*`. Bluetooth serial
 * links drop bytes, and a corrupted latitude that parses as a number is far
 * worse than one that fails to parse, so unchecked sentences are marked invalid
 * rather than trusted.
 */
export function parseNmeaSentence(line: string): NmeaSentence | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith('$') && !trimmed.startsWith('!')) return null;

  const star = trimmed.lastIndexOf('*');
  const body = star >= 0 ? trimmed.slice(1, star) : trimmed.slice(1);

  let valid = false;
  if (star >= 0 && star + 3 <= trimmed.length) {
    let sum = 0;
    for (let i = 0; i < body.length; i++) sum ^= body.charCodeAt(i);
    const declared = parseInt(trimmed.slice(star + 1, star + 3), 16);
    valid = Number.isFinite(declared) && sum === declared;
  }

  const fields = body.split(',');
  const tag = fields[0] ?? '';
  // Talker is the first two characters (GP, GN, GL, GA...), type the rest.
  // Proprietary sentences start with P and have no fixed split.
  const talker = tag.startsWith('P') ? 'P' : tag.slice(0, 2);
  const type = tag.startsWith('P') ? tag.slice(1) : tag.slice(2);

  return { talker, type, fields: fields.slice(1), valid };
}

/** NMEA packs latitude as ddmm.mmmm and longitude as dddmm.mmmm. */
function parseCoordinate(value: string, hemisphere: string): number | null {
  if (!value) return null;
  const decimal = parseFloat(value);
  if (!Number.isFinite(decimal)) return null;
  const degrees = Math.floor(decimal / 100);
  const minutes = decimal - degrees * 100;
  const signed = degrees + minutes / 60;
  const negative = hemisphere === 'S' || hemisphere === 'W';
  return negative ? -signed : signed;
}

/** hhmmss.sss UTC into seconds since midnight. */
function parseUtcTime(value: string): number | null {
  if (!value || value.length < 6) return null;
  const hours = Number(value.slice(0, 2));
  const minutes = Number(value.slice(2, 4));
  const seconds = Number(value.slice(4));
  if (!Number.isFinite(hours) || !Number.isFinite(minutes) || !Number.isFinite(seconds)) {
    return null;
  }
  return hours * 3600 + minutes * 60 + seconds;
}

export interface GgaFix {
  utcSeconds: number | null;
  lat: number;
  lon: number;
  quality: FixQuality;
  satellites: number;
  hdop: number;
  /** Metres above the geoid — this is what GGA reports, not ellipsoidal height. */
  orthometricHeight: number;
  /** Metres. Ellipsoidal height = orthometric + separation. */
  geoidSeparation: number;
  /** Seconds since the last differential correction, when the receiver reports it. */
  correctionAge?: number;
  referenceStationId?: string;
}

export function parseGga(sentence: NmeaSentence): GgaFix | null {
  const f = sentence.fields;
  if (f.length < 14) return null;
  const lat = parseCoordinate(f[1], f[2]);
  const lon = parseCoordinate(f[3], f[4]);
  if (lat === null || lon === null) return null;

  const quality = Number(f[5]);
  const separation = parseFloat(f[10]);

  return {
    utcSeconds: parseUtcTime(f[0]),
    lat,
    lon,
    quality: Number.isFinite(quality) ? (quality as FixQuality) : FixQuality.Invalid,
    satellites: Number(f[6]) || 0,
    hdop: parseFloat(f[7]) || 0,
    orthometricHeight: parseFloat(f[8]) || 0,
    geoidSeparation: Number.isFinite(separation) ? separation : 0,
    correctionAge: f[12] ? parseFloat(f[12]) : undefined,
    referenceStationId: f[13] || undefined,
  };
}

export interface GstAccuracy {
  utcSeconds: number | null;
  /** 1-sigma, metres. */
  latitudeSigma: number;
  longitudeSigma: number;
  heightSigma: number;
  /** Horizontal 1-sigma, combined. */
  horizontalSigma: number;
}

/**
 * GST is the sentence to trust for accuracy.
 *
 * HDOP from GGA is a geometry factor, not an accuracy — a receiver can report
 * an excellent HDOP while its solution is decimetres out. GST reports the
 * actual estimated standard deviations from the position solution.
 */
export function parseGst(sentence: NmeaSentence): GstAccuracy | null {
  const f = sentence.fields;
  if (f.length < 8) return null;
  const latSigma = parseFloat(f[5]);
  const lonSigma = parseFloat(f[6]);
  const heightSigma = parseFloat(f[7]);
  if (!Number.isFinite(latSigma) || !Number.isFinite(lonSigma)) return null;
  return {
    utcSeconds: parseUtcTime(f[0]),
    latitudeSigma: latSigma,
    longitudeSigma: lonSigma,
    heightSigma: Number.isFinite(heightSigma) ? heightSigma : 0,
    horizontalSigma: Math.hypot(latSigma, lonSigma),
  };
}

/**
 * Streaming assembler: feed it lines, get complete fixes.
 *
 * GGA and GST arrive as separate sentences at the same epoch, so a fix is only
 * complete once both have been seen for that timestamp. Emitting the GGA alone
 * would mean reporting a position with no accuracy attached, which is precisely
 * the thing this codebase refuses to do.
 */
export class NmeaAssembler {
  private pendingGga: GgaFix | null = null;
  private pendingGst: GstAccuracy | null = null;
  /** Session epoch in ms, for converting UTC-of-day into relative seconds. */
  private epochUtcSeconds: number | null = null;

  private readonly pairingToleranceSeconds: number;

  /**
   * @param pairingToleranceSeconds How far apart a GGA and GST timestamp may be
   * and still count as the same epoch. A receiver at 10 Hz leaves 100 ms between
   * epochs, so a quarter second is generous without risking a mis-pair.
   */
  constructor(pairingToleranceSeconds = 0.25) {
    this.pairingToleranceSeconds = pairingToleranceSeconds;
  }

  /**
   * Feed one line. Returns a fix when a GGA is complete.
   *
   * A GGA is emitted with whatever accuracy is available: if GST is present for
   * the same epoch its sigmas are attached, otherwise the fix carries no
   * accuracy fields and the caller can see that it does not.
   */
  push(line: string): GnssFix | null {
    const sentence = parseNmeaSentence(line);
    if (!sentence) return null;
    // A failed checksum means bytes were dropped. Parsing it anyway risks a
    // plausible-looking wrong position, which is the worst outcome available.
    if (!sentence.valid) return null;

    if (sentence.type === 'GST') {
      const gst = parseGst(sentence);
      if (gst) this.pendingGst = gst;
      // A GST may arrive after its GGA; flush the pair if so.
      if (this.pendingGga && gst && this.sameEpoch(this.pendingGga.utcSeconds, gst.utcSeconds)) {
        const fix = this.build(this.pendingGga, gst);
        this.pendingGga = null;
        return fix;
      }
      return null;
    }

    if (sentence.type === 'GGA') {
      const gga = parseGga(sentence);
      if (!gga) return null;
      // Emit any GGA still waiting — its GST never came.
      const stale = this.pendingGga ? this.build(this.pendingGga, null) : null;
      if (this.pendingGst && this.sameEpoch(gga.utcSeconds, this.pendingGst.utcSeconds)) {
        const fix = this.build(gga, this.pendingGst);
        this.pendingGst = null;
        return stale ?? fix;
      }
      this.pendingGga = gga;
      return stale;
    }

    return null;
  }

  /** Emit any fix still held. Call at end of stream. */
  flush(): GnssFix | null {
    if (!this.pendingGga) return null;
    const fix = this.build(this.pendingGga, this.pendingGst);
    this.pendingGga = null;
    this.pendingGst = null;
    return fix;
  }

  private sameEpoch(a: number | null, b: number | null): boolean {
    if (a === null || b === null) return false;
    return Math.abs(a - b) <= this.pairingToleranceSeconds;
  }

  private build(gga: GgaFix, gst: GstAccuracy | null): GnssFix {
    if (this.epochUtcSeconds === null && gga.utcSeconds !== null) {
      this.epochUtcSeconds = gga.utcSeconds;
    }
    const t =
      gga.utcSeconds !== null && this.epochUtcSeconds !== null
        ? gga.utcSeconds - this.epochUtcSeconds
        : 0;

    const fix: GnssFix = {
      t,
      lat: gga.lat,
      lon: gga.lon,
      // GGA reports orthometric height; ellipsoidal is what geodesy needs.
      height: gga.orthometricHeight + gga.geoidSeparation,
      orthometricHeight: gga.orthometricHeight,
      geoidSeparation: gga.geoidSeparation,
      quality: gga.quality,
      satellites: gga.satellites,
      hdop: gga.hdop,
    };
    if (gst) {
      fix.hAccuracy = gst.horizontalSigma;
      fix.vAccuracy = gst.heightSigma;
    }
    return fix;
  }
}

/** Human label for a fix quality, for the status line. */
export function describeFixQuality(quality: FixQuality): { label: string; usable: boolean } {
  switch (quality) {
    case FixQuality.RtkFixed:
      return { label: 'RTK fixed', usable: true };
    case FixQuality.RtkFloat:
      return { label: 'RTK float — decimetre, not centimetre', usable: false };
    case FixQuality.DGPS:
      return { label: 'DGPS — sub-metre', usable: false };
    case FixQuality.SinglePoint:
      return { label: 'Single point — metres', usable: false };
    case FixQuality.PPS:
      return { label: 'PPS', usable: false };
    case FixQuality.DeadReckoning:
      return { label: 'Dead reckoning — no satellites', usable: false };
    case FixQuality.Manual:
      return { label: 'Manual input', usable: false };
    case FixQuality.Simulation:
      return { label: 'Simulated — not a real fix', usable: false };
    default:
      return { label: 'No fix', usable: false };
  }
}

/**
 * Correct a fix for the lever arm between the GNSS antenna phase centre and the
 * camera centre.
 *
 * A pole-mounted rover sits a fixed offset above and behind the phone. Ignoring
 * it is a systematic error of exactly that size in every frame of the capture —
 * it does not average out, and it is invisible in the residuals because it
 * shifts every point identically.
 *
 * `bodyToWorld` rotates device body axes into the local ENU frame.
 */
export function applyLeverArm(
  fix: GnssFix,
  leverArmBody: [number, number, number],
  bodyToWorld: (v: [number, number, number]) => [number, number, number],
): { east: number; north: number; up: number } {
  const [e, n, u] = bodyToWorld(leverArmBody);
  return { east: -e, north: -n, up: -u };
}
