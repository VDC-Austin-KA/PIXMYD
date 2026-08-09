/**
 * Reading a capture bundle in the browser.
 *
 * Two sources, because a field user will arrive with either:
 *
 *   - a **directory**, picked with `showDirectoryPicker` or a `webkitdirectory`
 *     input, which is what AirDropping a `.pixmyd` folder off the phone gives you
 *   - a **zip**, which is what everything else gives you
 *
 * Both are normalized to the same `BundleSource` interface so nothing
 * downstream cares which it got.
 *
 * The awkward constraint is size. A 20-minute LiDAR scan is a few gigabytes,
 * and reading it into memory would end the session. So files are read lazily by
 * path and the pipeline pulls one frame at a time.
 */

import type {
  CaptureBundle,
  CaptureManifest,
  Frame,
  GnssFix,
  ImuSample,
} from '@pixmyd/core/bundle';

export interface BundleSource {
  /** Human-readable, for the UI. */
  name: string;
  /** Read one file by its bundle-relative path. Rejects if absent. */
  read(path: string): Promise<Uint8Array>;
  /** Read a text file. */
  readText(path: string): Promise<string>;
  /** Whether a path exists, without reading it. */
  has(path: string): Promise<boolean>;
}

// ---------------------------------------------------------------------------
// Directory source
// ---------------------------------------------------------------------------

/**
 * A directory chosen through the File System Access API.
 *
 * Handles are cached because resolving a nested path walks the tree, and the
 * pipeline asks for thousands of files in a predictable pattern.
 */
export function directorySource(root: FileSystemDirectoryHandle): BundleSource {
  const cache = new Map<string, Promise<FileSystemFileHandle>>();

  const resolve = (path: string): Promise<FileSystemFileHandle> => {
    const cached = cache.get(path);
    if (cached) return cached;
    const promise = (async () => {
      const parts = path.split('/').filter(Boolean);
      let directory = root;
      for (let i = 0; i < parts.length - 1; i++) {
        directory = await directory.getDirectoryHandle(parts[i]);
      }
      return directory.getFileHandle(parts[parts.length - 1]);
    })();
    cache.set(path, promise);
    return promise;
  };

  return {
    name: root.name,
    async read(path) {
      const handle = await resolve(path);
      const file = await handle.getFile();
      return new Uint8Array(await file.arrayBuffer());
    },
    async readText(path) {
      const handle = await resolve(path);
      return (await handle.getFile()).text();
    },
    async has(path) {
      try {
        await resolve(path);
        return true;
      } catch {
        return false;
      }
    },
  };
}

/**
 * A directory chosen through a `<input webkitdirectory>`, which is the fallback
 * for browsers without the File System Access API — notably Safari and Firefox.
 *
 * The whole `FileList` is already in memory as `File` objects, but those are
 * lazy handles to disk rather than loaded bytes, so this is not as expensive as
 * it looks.
 */
export function fileListSource(files: FileList | File[], name = 'capture'): BundleSource {
  const byPath = new Map<string, File>();
  for (const file of Array.from(files)) {
    // webkitRelativePath includes the chosen directory as its first segment,
    // which is not part of the bundle-relative path.
    const relative = (file as File & { webkitRelativePath?: string }).webkitRelativePath;
    const path = relative ? relative.split('/').slice(1).join('/') : file.name;
    byPath.set(path, file);
  }

  const get = (path: string): File => {
    const file = byPath.get(path);
    if (!file) throw new Error(`bundle is missing ${path}`);
    return file;
  };

  return {
    name,
    async read(path) {
      return new Uint8Array(await get(path).arrayBuffer());
    },
    async readText(path) {
      return get(path).text();
    },
    async has(path) {
      return byPath.has(path);
    },
  };
}

// ---------------------------------------------------------------------------
// Zip source
// ---------------------------------------------------------------------------

interface ZipEntry {
  offset: number;
  compressedSize: number;
  uncompressedSize: number;
  method: number;
}

/**
 * A minimal zip reader.
 *
 * Only two compression methods exist in practice for this payload: stored (0),
 * because JPEG and PNG are already compressed and zip tools leave them alone,
 * and deflate (8) for the JSON. Deflate is handled by `DecompressionStream`,
 * which every target browser has, so there is no dependency here.
 */
export async function zipSource(data: Uint8Array, name = 'capture'): Promise<BundleSource> {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

  // Find the end-of-central-directory record. It is at the end, but a zip
  // comment can follow it, so scan backwards over the maximum comment length.
  let eocd = -1;
  const scanFrom = Math.max(0, data.length - 0xffff - 22);
  for (let i = data.length - 22; i >= scanFrom; i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip file: no end-of-central-directory record');

  const entryCount = view.getUint16(eocd + 10, true);
  let cursor = view.getUint32(eocd + 16, true);

  const entries = new Map<string, ZipEntry>();
  const decoder = new TextDecoder();

  for (let i = 0; i < entryCount; i++) {
    if (view.getUint32(cursor, true) !== 0x02014b50) break;
    const method = view.getUint16(cursor + 10, true);
    const compressedSize = view.getUint32(cursor + 20, true);
    const uncompressedSize = view.getUint32(cursor + 24, true);
    const nameLength = view.getUint16(cursor + 28, true);
    const extraLength = view.getUint16(cursor + 30, true);
    const commentLength = view.getUint16(cursor + 32, true);
    const localOffset = view.getUint32(cursor + 42, true);
    const entryName = decoder.decode(data.subarray(cursor + 46, cursor + 46 + nameLength));

    // Strip a single leading directory, so a zip of the folder and a zip of its
    // contents both work — users produce both and neither is wrong.
    const normalized = entryName.includes('/')
      ? entryName.slice(entryName.indexOf('/') + 1)
      : entryName;
    if (normalized) {
      entries.set(normalized, { offset: localOffset, compressedSize, uncompressedSize, method });
    }
    cursor += 46 + nameLength + extraLength + commentLength;
  }

  const readEntry = async (path: string): Promise<Uint8Array> => {
    const entry = entries.get(path);
    if (!entry) throw new Error(`bundle is missing ${path}`);

    // The local header repeats the name and extra length, and they can differ
    // from the central directory's, so the data offset must be read from here.
    const localNameLength = view.getUint16(entry.offset + 26, true);
    const localExtraLength = view.getUint16(entry.offset + 28, true);
    const start = entry.offset + 30 + localNameLength + localExtraLength;
    const raw = data.subarray(start, start + entry.compressedSize);

    if (entry.method === 0) return raw;
    if (entry.method === 8) {
      // Copy into a plain ArrayBuffer-backed view: a subarray of a SharedArrayBuffer
      // is not a valid BlobPart, and TypeScript tracks that distinction.
      const stream = new Blob([new Uint8Array(raw)]).stream().pipeThrough(
        new DecompressionStream('deflate-raw'),
      );
      return new Uint8Array(await new Response(stream).arrayBuffer());
    }
    throw new Error(`unsupported zip compression method ${entry.method} for ${path}`);
  };

  return {
    name,
    read: readEntry,
    async readText(path) {
      return new TextDecoder().decode(await readEntry(path));
    },
    async has(path) {
      return entries.has(path);
    },
  };
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/** Parse JSONL, skipping malformed lines rather than failing the whole file. */
function parseJsonl<T>(text: string): T[] {
  const out: T[] = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      out.push(JSON.parse(trimmed) as T);
    } catch {
      // A capture interrupted mid-write leaves a truncated final line. That is
      // the reason the format is line-delimited, so losing it is the design
      // working rather than a corruption to report.
    }
  }
  return out;
}

/**
 * Read a bundle's metadata. Imagery and depth stay on disk — this returns the
 * index, and the pipeline streams the heavy payload frame by frame.
 */
export async function readBundle(source: BundleSource): Promise<CaptureBundle> {
  if (!(await source.has('manifest.json'))) {
    throw new Error(
      'This does not look like a PIXMYD capture — there is no manifest.json at the top level. ' +
      'If you zipped the folder, make sure the zip contains the capture directory or its contents.',
    );
  }

  const manifest = JSON.parse(await source.readText('manifest.json')) as CaptureManifest;
  const frames = parseJsonl<Frame>(await source.readText('frames.jsonl'));

  const bundle: CaptureBundle = { manifest, frames };

  if (await source.has('imu.jsonl')) {
    bundle.imu = parseJsonl<ImuSample>(await source.readText('imu.jsonl'));
  }
  if (await source.has('gnss.jsonl')) {
    bundle.gnss = parseJsonl<GnssFix>(await source.readText('gnss.jsonl'));
  }
  if (await source.has('control.json')) {
    bundle.control = JSON.parse(await source.readText('control.json'));
  }

  // The manifest's frame count is written before the last frames flush, so it
  // can disagree with what actually landed. Trust the file, not the summary.
  if (frames.length !== manifest.frameCount) {
    bundle.manifest = { ...manifest, frameCount: frames.length };
  }

  return bundle;
}

/** Decode a depth map into metres. */
export function decodeDepth(
  bytes: Uint8Array,
  encoding: 'uint16-mm' | 'float32-m',
  width: number,
  height: number,
): Float32Array {
  const count = width * height;
  const out = new Float32Array(count);

  if (encoding === 'float32-m') {
    // The byte offset is not guaranteed 4-aligned, so copy rather than alias.
    const source = new Float32Array(bytes.slice(0, count * 4).buffer);
    out.set(source.subarray(0, count));
    return out;
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let i = 0; i < count; i++) {
    // Zero means "no measurement", not "zero metres".
    const mm = view.getUint16(i * 2, true);
    out[i] = mm === 0 ? 0 : mm / 1000;
  }
  return out;
}
