/**
 * Grayscale images and pyramids.
 *
 * Everything downstream works on a single 8-bit plane. Colour is dropped before
 * detection deliberately: corner response and the intensity comparisons a
 * binary descriptor is built from are luminance operations, and carrying three
 * channels through them triples the work to no benefit. Colour is still there
 * on the source image when a point needs one for the output cloud.
 */

/** A single-channel 8-bit image, row-major, no padding. */
export interface GrayImage {
  width: number;
  height: number;
  data: Uint8Array;
}

export function createGray(width: number, height: number): GrayImage {
  return { width, height, data: new Uint8Array(width * height) };
}

/**
 * ITU-R BT.601 luma, the coefficients every consumer camera's JPEG pipeline
 * uses. Rounded rather than truncated: truncation biases every pixel down by
 * half a level, which is invisible on screen and shifts the mean of a patch
 * enough to matter for a descriptor built on comparisons against that mean.
 */
export function grayFromRgba(
  rgba: Uint8Array | Uint8ClampedArray,
  width: number,
  height: number,
): GrayImage {
  if (rgba.length < width * height * 4) {
    throw new Error(
      `grayFromRgba: need ${width * height * 4} bytes for ${width}x${height}, got ${rgba.length}`,
    );
  }
  const out = createGray(width, height);
  for (let i = 0, p = 0; i < out.data.length; i += 1, p += 4) {
    out.data[i] = (0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2] + 0.5) | 0;
  }
  return out;
}

/** Clamped sample. Out-of-bounds reads replicate the edge pixel. */
export function sampleGray(image: GrayImage, x: number, y: number): number {
  const cx = x < 0 ? 0 : x >= image.width ? image.width - 1 : x;
  const cy = y < 0 ? 0 : y >= image.height ? image.height - 1 : y;
  return image.data[cy * image.width + cx];
}

/** Bilinear sample at a subpixel location, with the same clamped edges. */
export function sampleGrayBilinear(image: GrayImage, x: number, y: number): number {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const fx = x - x0;
  const fy = y - y0;
  const p00 = sampleGray(image, x0, y0);
  const p10 = sampleGray(image, x0 + 1, y0);
  const p01 = sampleGray(image, x0, y0 + 1);
  const p11 = sampleGray(image, x0 + 1, y0 + 1);
  const top = p00 + (p10 - p00) * fx;
  const bottom = p01 + (p11 - p01) * fx;
  return top + (bottom - top) * fy;
}

/**
 * Separable 5-tap Gaussian, sigma ~1.0, as integer weights [1, 4, 6, 4, 1] / 16.
 *
 * Integer weights and a shift rather than floats: the whole pipeline runs on
 * uint8 and this is the hottest loop in it. The kernel is applied before every
 * downsample, because decimating without it aliases high-frequency detail into
 * the smaller level, and aliased detail is *stable across a pyramid* — it looks
 * exactly like a corner to the detector, at a position that moves with the
 * sampling grid rather than with the scene.
 */
export function blurGray(image: GrayImage): GrayImage {
  const { width, height, data } = image;
  const horizontal = new Uint8Array(width * height);
  const out = createGray(width, height);

  for (let y = 0; y < height; y += 1) {
    const row = y * width;
    for (let x = 0; x < width; x += 1) {
      const x0 = x - 2 < 0 ? 0 : x - 2;
      const x1 = x - 1 < 0 ? 0 : x - 1;
      const x3 = x + 1 >= width ? width - 1 : x + 1;
      const x4 = x + 2 >= width ? width - 1 : x + 2;
      horizontal[row + x] =
        (data[row + x0] +
          4 * data[row + x1] +
          6 * data[row + x] +
          4 * data[row + x3] +
          data[row + x4] +
          8) >>
        4;
    }
  }

  for (let y = 0; y < height; y += 1) {
    const y0 = (y - 2 < 0 ? 0 : y - 2) * width;
    const y1 = (y - 1 < 0 ? 0 : y - 1) * width;
    const y2 = y * width;
    const y3 = (y + 1 >= height ? height - 1 : y + 1) * width;
    const y4 = (y + 2 >= height ? height - 1 : y + 2) * width;
    for (let x = 0; x < width; x += 1) {
      out.data[y2 + x] =
        (horizontal[y0 + x] +
          4 * horizontal[y1 + x] +
          6 * horizontal[y2 + x] +
          4 * horizontal[y3 + x] +
          horizontal[y4 + x] +
          8) >>
        4;
    }
  }

  return out;
}

/** One pyramid level and the factor mapping its coordinates back to level 0. */
export interface PyramidLevel {
  image: GrayImage;
  /** Multiply a coordinate at this level by this to reach level 0. */
  scale: number;
}

export interface PyramidOptions {
  /** Ratio between consecutive levels. 1.2 is ORB's default. */
  factor?: number;
  levels?: number;
  /** Stop early once a level would be smaller than this on either axis. */
  minSize?: number;
}

/**
 * A scale pyramid.
 *
 * The factor is deliberately not 2. A photogrammetric pair is usually taken
 * from a similar distance, so the scale change between them is small — an
 * octave-per-level pyramid quantises that change so coarsely that the matching
 * level is often a poor fit for both images. 1.2 costs more levels and finds
 * correspondences an octave pyramid misses.
 */
export function buildPyramid(base: GrayImage, options: PyramidOptions = {}): PyramidLevel[] {
  const factor = options.factor ?? 1.2;
  const levels = options.levels ?? 8;
  const minSize = options.minSize ?? 32;

  if (factor <= 1) throw new Error(`buildPyramid: factor must exceed 1, got ${factor}`);

  const pyramid: PyramidLevel[] = [{ image: base, scale: 1 }];
  let scale = 1;

  for (let level = 1; level < levels; level += 1) {
    scale *= factor;
    const width = Math.round(base.width / scale);
    const height = Math.round(base.height / scale);
    if (width < minSize || height < minSize) break;

    // Resample from the *original* every time rather than from the previous
    // level. Chained resampling compounds interpolation error, and by the top
    // of an eight-level pyramid that is a visibly softer image than one
    // resampled once — soft enough to cost corners.
    pyramid.push({ image: resampleGray(blurGray(base), width, height), scale });
  }

  return pyramid;
}

/** Bilinear resample to an arbitrary size. */
export function resampleGray(image: GrayImage, width: number, height: number): GrayImage {
  const out = createGray(width, height);
  const sx = image.width / width;
  const sy = image.height / height;
  for (let y = 0; y < height; y += 1) {
    // Sample pixel centres, not corners: the half-pixel offset is what keeps a
    // feature's position consistent between levels.
    const srcY = (y + 0.5) * sy - 0.5;
    for (let x = 0; x < width; x += 1) {
      const srcX = (x + 0.5) * sx - 0.5;
      out.data[y * width + x] = Math.round(sampleGrayBilinear(image, srcX, srcY));
    }
  }
  return out;
}
