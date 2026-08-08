/**
 * Growable little-endian binary writer, and a matching reader.
 *
 * Every binary format in this repo (GLB, FBX, E57, LAS, PLY) is little-endian,
 * so LE is the default and big-endian variants are named explicitly.
 */

const TEXT_ENCODER = new TextEncoder();
const TEXT_DECODER = new TextDecoder();

export class ByteWriter {
  private buf: Uint8Array;
  private view: DataView;
  private len = 0;

  constructor(initialCapacity = 1024) {
    this.buf = new Uint8Array(initialCapacity);
    this.view = new DataView(this.buf.buffer);
  }

  /** Number of bytes written so far. Also the offset of the next write. */
  get length(): number {
    return this.len;
  }

  private ensure(extra: number): void {
    const need = this.len + extra;
    if (need <= this.buf.length) return;
    let cap = this.buf.length * 2;
    while (cap < need) cap *= 2;
    const next = new Uint8Array(cap);
    next.set(this.buf.subarray(0, this.len));
    this.buf = next;
    this.view = new DataView(next.buffer);
  }

  u8(v: number): this {
    this.ensure(1);
    this.view.setUint8(this.len, v);
    this.len += 1;
    return this;
  }

  i8(v: number): this {
    this.ensure(1);
    this.view.setInt8(this.len, v);
    this.len += 1;
    return this;
  }

  u16(v: number): this {
    this.ensure(2);
    this.view.setUint16(this.len, v, true);
    this.len += 2;
    return this;
  }

  i16(v: number): this {
    this.ensure(2);
    this.view.setInt16(this.len, v, true);
    this.len += 2;
    return this;
  }

  u32(v: number): this {
    this.ensure(4);
    this.view.setUint32(this.len, v, true);
    this.len += 4;
    return this;
  }

  i32(v: number): this {
    this.ensure(4);
    this.view.setInt32(this.len, v, true);
    this.len += 4;
    return this;
  }

  u64(v: bigint | number): this {
    this.ensure(8);
    this.view.setBigUint64(this.len, BigInt(v), true);
    this.len += 8;
    return this;
  }

  i64(v: bigint | number): this {
    this.ensure(8);
    this.view.setBigInt64(this.len, BigInt(v), true);
    this.len += 8;
    return this;
  }

  f32(v: number): this {
    this.ensure(4);
    this.view.setFloat32(this.len, v, true);
    this.len += 4;
    return this;
  }

  f64(v: number): this {
    this.ensure(8);
    this.view.setFloat64(this.len, v, true);
    this.len += 8;
    return this;
  }

  u32be(v: number): this {
    this.ensure(4);
    this.view.setUint32(this.len, v, false);
    this.len += 4;
    return this;
  }

  bytes(src: ArrayLike<number> | Uint8Array): this {
    this.ensure(src.length);
    this.buf.set(src as Uint8Array, this.len);
    this.len += src.length;
    return this;
  }

  /** Raw bytes of a typed array, respecting its byteOffset/byteLength. */
  typed(src: ArrayBufferView): this {
    return this.bytes(new Uint8Array(src.buffer, src.byteOffset, src.byteLength));
  }

  /** UTF-8 text with no length prefix and no terminator. */
  ascii(s: string): this {
    return this.bytes(TEXT_ENCODER.encode(s));
  }

  /** Repeat a single byte `count` times. */
  fill(byte: number, count: number): this {
    if (count <= 0) return this;
    this.ensure(count);
    this.buf.fill(byte, this.len, this.len + count);
    this.len += count;
    return this;
  }

  /** Pad with `byte` until length is a multiple of `alignment`. */
  align(alignment: number, byte = 0): this {
    const rem = this.len % alignment;
    if (rem !== 0) this.fill(byte, alignment - rem);
    return this;
  }

  /** Overwrite a u32 already written at `offset`. Used for back-patching sizes. */
  patchU32(offset: number, v: number): this {
    if (offset + 4 > this.len) throw new RangeError(`patchU32 past end: ${offset}`);
    this.view.setUint32(offset, v, true);
    return this;
  }

  patchU64(offset: number, v: bigint | number): this {
    if (offset + 8 > this.len) throw new RangeError(`patchU64 past end: ${offset}`);
    this.view.setBigUint64(offset, BigInt(v), true);
    return this;
  }

  /** A view over the written bytes. Shares memory — copy if you intend to keep it. */
  subarray(): Uint8Array {
    return this.buf.subarray(0, this.len);
  }

  /** A detached copy of the written bytes. */
  finish(): Uint8Array {
    return this.buf.slice(0, this.len);
  }
}

export class ByteReader {
  readonly view: DataView;
  readonly bytes: Uint8Array;
  offset = 0;

  constructor(source: Uint8Array | ArrayBuffer) {
    this.bytes = source instanceof Uint8Array ? source : new Uint8Array(source);
    this.view = new DataView(this.bytes.buffer, this.bytes.byteOffset, this.bytes.byteLength);
  }

  get remaining(): number {
    return this.bytes.byteLength - this.offset;
  }

  u8(): number {
    return this.view.getUint8(this.offset++);
  }

  i8(): number {
    return this.view.getInt8(this.offset++);
  }

  u16(): number {
    const v = this.view.getUint16(this.offset, true);
    this.offset += 2;
    return v;
  }

  i16(): number {
    const v = this.view.getInt16(this.offset, true);
    this.offset += 2;
    return v;
  }

  u32(): number {
    const v = this.view.getUint32(this.offset, true);
    this.offset += 4;
    return v;
  }

  i32(): number {
    const v = this.view.getInt32(this.offset, true);
    this.offset += 4;
    return v;
  }

  u64(): bigint {
    const v = this.view.getBigUint64(this.offset, true);
    this.offset += 8;
    return v;
  }

  f32(): number {
    const v = this.view.getFloat32(this.offset, true);
    this.offset += 4;
    return v;
  }

  f64(): number {
    const v = this.view.getFloat64(this.offset, true);
    this.offset += 8;
    return v;
  }

  take(n: number): Uint8Array {
    const v = this.bytes.subarray(this.offset, this.offset + n);
    this.offset += n;
    return v;
  }

  ascii(n: number): string {
    return TEXT_DECODER.decode(this.take(n));
  }

  /** Read up to and including the next \n, returning the line without its terminator. */
  line(): string {
    const start = this.offset;
    while (this.offset < this.bytes.length && this.bytes[this.offset] !== 0x0a) this.offset++;
    let end = this.offset;
    if (end > start && this.bytes[end - 1] === 0x0d) end--; // strip CR
    this.offset++; // consume the LF
    return TEXT_DECODER.decode(this.bytes.subarray(start, end));
  }
}

/** Concatenate chunks into one buffer. */
export function concatBytes(chunks: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}
