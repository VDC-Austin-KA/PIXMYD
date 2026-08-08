import test from 'node:test';
import assert from 'node:assert/strict';
import {
  writeE57,
  writePointCloudE57,
  readE57Header,
  readE57Xml,
  readE57Points,
  crc32c,
  paginate,
  depaginate,
  logicalToPhysical,
  physicalToLogical,
} from '../src/e57.ts';
import { writeLas, readLas, readLasHeader } from '../src/las.ts';
import type { PointCloud } from '@pixmyd/core/bundle';

function cloud(n: number, opts: { colors?: boolean; intensity?: boolean; base?: number } = {}): PointCloud {
  const base = opts.base ?? 0;
  const c: PointCloud = {
    count: n,
    positions: new Float64Array(n * 3),
    colors: opts.colors ? new Uint8Array(n * 3) : undefined,
    intensity: opts.intensity ? new Float32Array(n) : undefined,
  };
  for (let i = 0; i < n; i++) {
    c.positions[i * 3] = base + i * 0.001;
    c.positions[i * 3 + 1] = base + Math.sin(i) * 10;
    c.positions[i * 3 + 2] = base + (i % 17) * 0.5;
    if (c.colors) {
      c.colors[i * 3] = i % 256;
      c.colors[i * 3 + 1] = (i * 3) % 256;
      c.colors[i * 3 + 2] = 255 - (i % 256);
    }
    if (c.intensity) c.intensity[i] = (i % 100) / 100;
  }
  return c;
}

// ===========================================================================
// E57 paging and checksums
// ===========================================================================

test('CRC-32C matches the published check value', () => {
  // The standard CRC-32C check: "123456789" -> 0xE3069283.
  assert.equal(crc32c(new TextEncoder().encode('123456789')), 0xe3069283);
});

test('CRC-32C is not CRC-32, which is the whole point', () => {
  // If this ever equals the zip/PNG CRC-32 of the same input, the table is wrong.
  assert.notEqual(crc32c(new TextEncoder().encode('123456789')), 0xcbf43926);
});

test('logical and physical offsets round trip across page boundaries', () => {
  for (const logical of [0, 1, 1019, 1020, 1021, 2039, 2040, 100000]) {
    assert.equal(physicalToLogical(logicalToPhysical(logical)), logical, `logical ${logical}`);
  }
  // The first CRC sits at physical 1020, so logical 1020 is physical 1024.
  assert.equal(logicalToPhysical(1019), 1019);
  assert.equal(logicalToPhysical(1020), 1024);
  assert.equal(logicalToPhysical(1021), 1025);
});

test('paginate/depaginate round trips and validates every page checksum', () => {
  const logical = new Uint8Array(1020 * 3 + 17);
  for (let i = 0; i < logical.length; i++) logical[i] = (i * 31) % 256;
  const physical = paginate(logical);
  assert.equal(physical.length % 1024, 0);
  assert.equal(physical.length, 4 * 1024);
  const back = depaginate(physical);
  assert.deepEqual([...back.subarray(0, logical.length)], [...logical]);
});

test('depaginate reports a corrupted page rather than returning bad data', () => {
  const physical = paginate(new Uint8Array(2000).fill(7));
  physical[500] ^= 0xff;
  assert.throws(() => depaginate(physical), /checksum mismatch on page 0/);
});

// ===========================================================================
// E57 files
// ===========================================================================

test('E57 header fields are correct and self-consistent', () => {
  const bytes = writePointCloudE57(cloud(1000, { colors: true }));
  const header = readE57Header(bytes);
  assert.equal(header.majorVersion, 1);
  assert.equal(header.minorVersion, 0);
  assert.equal(header.pageSize, 1024);
  assert.equal(header.filePhysicalLength, bytes.length, 'declared length must match actual');
  assert.ok(header.xmlPhysicalOffset < bytes.length);
  assert.ok(header.xmlLogicalLength > 0);
});

test('E57 whole-file checksums verify', () => {
  // depaginate throws on any bad page, so this covers the file end to end.
  const bytes = writePointCloudE57(cloud(5000, { colors: true, intensity: true }));
  assert.doesNotThrow(() => depaginate(bytes));
});

test('E57 XML declares the prototype the binary section actually contains', () => {
  const xml = readE57Xml(writePointCloudE57(cloud(10, { colors: true, intensity: true })));
  assert.match(xml, /<e57Root type="Structure"/);
  assert.match(xml, /<cartesianX type="Float" precision="double"/);
  assert.match(xml, /<colorRed type="Integer" minimum="0" maximum="255"\/>/);
  assert.match(xml, /<intensity type="Float" precision="single"/);
  assert.match(xml, /recordCount="10"/);
});

test('E57 round trips coordinates exactly at double precision', () => {
  const original = cloud(3000, { colors: true, intensity: true });
  const back = readE57Points(writePointCloudE57(original));
  assert.equal(back.count, original.count);
  for (let i = 0; i < original.count * 3; i++) {
    assert.equal(back.positions[i], original.positions[i], `position[${i}]`);
  }
  for (let i = 0; i < original.count * 3; i++) {
    assert.equal(back.colors![i], original.colors![i], `color[${i}]`);
  }
});

test('E57 spans multiple data packets and reassembles them in order', () => {
  // 40k points at 30 bytes each is ~1.2 MB, far past the 64 KiB packet ceiling.
  const original = cloud(40000, { colors: true });
  const bytes = writePointCloudE57(original);
  const back = readE57Points(bytes);
  assert.equal(back.count, 40000);
  // Spot-check the ends and a point inside a later packet.
  for (const i of [0, 1, 2047, 2048, 30000, 39999]) {
    for (let a = 0; a < 3; a++) {
      assert.equal(back.positions[i * 3 + a], original.positions[i * 3 + a], `point ${i} axis ${a}`);
    }
    assert.equal(back.colors![i * 3], original.colors![i * 3], `colour of point ${i}`);
  }
});

test('E57 section offsets point at real packet headers', () => {
  const bytes = writePointCloudE57(cloud(5000, { colors: true }));
  const xml = readE57Xml(bytes);
  const fileOffset = Number(/fileOffset="(\d+)"/.exec(xml)![1]);
  const logical = depaginate(bytes);
  const at = physicalToLogical(fileOffset);
  assert.equal(logical[at], 1, 'section id must be 1 (CompressedVector)');
  for (let i = 1; i < 8; i++) {
    assert.equal(logical[at + i], 0, `reserved byte ${i} must be zero`);
  }
  const v = new DataView(logical.buffer, logical.byteOffset, logical.byteLength);
  const sectionLength = Number(v.getBigUint64(at + 8, true));
  assert.equal(sectionLength % 4, 0, 'sectionLogicalLength must be a multiple of 4');
  const dataPhysical = Number(v.getBigUint64(at + 16, true));
  assert.equal(
    physicalToLogical(dataPhysical), at + 32,
    'dataPhysicalOffset must land on the first packet',
  );
  assert.equal(logical[physicalToLogical(dataPhysical)], 1, 'first packet must be a DATA_PACKET');
});

test('E57 writes multiple scans, each with its own section and pose', () => {
  const bytes = writeE57([
    { cloud: cloud(500, { colors: true }), name: 'station-1' },
    {
      cloud: cloud(700, { colors: true, base: 100 }),
      name: 'station-2',
      pose: { translation: [10, 20, 30], rotation: [0, 0, 0, 1] },
    },
  ]);
  const xml = readE57Xml(bytes);
  assert.match(xml, /station-1/);
  assert.match(xml, /station-2/);
  assert.equal([...xml.matchAll(/<points type="CompressedVector"/g)].length, 2);
  assert.match(xml, /<translation type="Structure">/);

  const first = readE57Points(bytes, 0);
  const second = readE57Points(bytes, 1);
  assert.equal(first.count, 500);
  assert.equal(second.count, 700);
  assert.ok(Math.abs(second.positions[0] - 100) < 1e-9, 'second scan keeps its own coordinates');
});

test('E57 carries the CRS description into coordinateMetadata', () => {
  const c = cloud(10);
  c.origin = undefined;
  c.crs = {
    code: 'EPSG:6588',
    unit: 'usSurveyFoot',
    metresPerUnit: 0.304800609601219,
    verticalDatum: 'NAVD88',
  };
  const xml = readE57Xml(writePointCloudE57(c));
  assert.match(xml, /coordinateMetadata/);
  assert.match(xml, /EPSG:6588/);
  assert.match(xml, /usSurveyFoot/);
});

test('E57 carries a cloud origin as the scan pose, which readers apply', () => {
  const c = cloud(50);
  c.origin = [646000, 4181000, 150];
  const bytes = writePointCloudE57(c);
  const xml = readE57Xml(bytes);
  assert.match(xml, /<pose type="Structure">/);
  assert.match(xml, /<x type="Float" precision="double">646000<\/x>/);

  const back = readE57Points(bytes);
  assert.deepEqual(back.origin, [646000, 4181000, 150], 'origin survives the round trip');
  // Stored coordinates stay local, which is what keeps them small and exact.
  for (let i = 0; i < c.count * 3; i++) {
    assert.equal(back.positions[i], c.positions[i], `stored position[${i}] must stay local`);
  }
});

test('E57 handles an empty cloud without producing a malformed file', () => {
  const bytes = writePointCloudE57({ count: 0, positions: new Float64Array(0) });
  assert.doesNotThrow(() => depaginate(bytes));
  assert.equal(readE57Points(bytes).count, 0);
  assert.equal(readE57Header(bytes).filePhysicalLength, bytes.length);
});

// ===========================================================================
// LAS
// ===========================================================================

test('LAS 1.4 header is exactly 375 bytes and reads back', () => {
  const bytes = writeLas(cloud(100, { colors: true }));
  const header = readLasHeader(bytes);
  assert.equal(header.versionMajor, 1);
  assert.equal(header.versionMinor, 4);
  assert.equal(header.pointCount, 100);
  assert.equal(header.pointDataFormat, 2, 'colour but no time selects format 2');
  assert.equal(header.pointDataRecordLength, 26);
  assert.equal(header.offsetToPointData, 375, 'no VLRs, so data starts right after the header');
  assert.equal(header.generatingSoftware, 'PIXMYD');
});

test('LAS selects the point format from the channels present', () => {
  assert.equal(readLasHeader(writeLas(cloud(4))).pointDataFormat, 0);
  assert.equal(readLasHeader(writeLas(cloud(4, { colors: true }))).pointDataFormat, 2);
  const timed = cloud(4);
  timed.timestamps = new Float64Array([1, 2, 3, 4]);
  assert.equal(readLasHeader(writeLas(timed)).pointDataFormat, 1);
  timed.colors = new Uint8Array(12);
  assert.equal(readLasHeader(writeLas(timed)).pointDataFormat, 3);
});

test('LAS round trips within the quantisation step, not approximately', () => {
  const original = cloud(2000, { colors: true, intensity: true });
  const bytes = writeLas(original, { scale: 0.001 });
  const back = readLas(bytes);
  assert.equal(back.count, original.count);
  for (let i = 0; i < original.count * 3; i++) {
    const error = Math.abs(back.positions[i] - original.positions[i]);
    assert.ok(error <= 0.0005 + 1e-9, `position[${i}] off by ${error}, past half a step`);
  }
  // Colour is exact: 255*257 = 65535 round trips through the 16-bit channel.
  for (let i = 0; i < original.count * 3; i++) {
    assert.equal(back.colors![i], original.colors![i], `color[${i}]`);
  }
});

test('LAS bounds in the header match the data', () => {
  const c = cloud(500);
  const header = readLasHeader(writeLas(c));
  let minX = Infinity, maxX = -Infinity;
  for (let i = 0; i < c.count; i++) {
    minX = Math.min(minX, c.positions[i * 3]);
    maxX = Math.max(maxX, c.positions[i * 3]);
  }
  assert.ok(Math.abs(header.min[0] - minX) < 1e-9, 'minX');
  assert.ok(Math.abs(header.max[0] - maxX) < 1e-9, 'maxX');
});

test('LAS survives State Plane magnitudes that would destroy float32', () => {
  // A real Texas South Central site: easting ~2.12M ftUS, northing ~13.72M ftUS,
  // converted to metres. float32 cannot resolve a foot here; int32 with a
  // millimetre scale and an offset resolves a millimetre.
  const n = 200;
  const c: PointCloud = { count: n, positions: new Float64Array(n * 3) };
  for (let i = 0; i < n; i++) {
    c.positions[i * 3] = 646000.123 + i * 0.001;
    c.positions[i * 3 + 1] = 4181000.456 + i * 0.001;
    c.positions[i * 3 + 2] = 150.789;
  }
  const back = readLas(writeLas(c, { scale: 0.001 }));
  for (let i = 0; i < n; i++) {
    assert.ok(
      Math.abs(back.positions[i * 3] - c.positions[i * 3]) <= 0.0005 + 1e-9,
      `easting ${i} lost precision`,
    );
    assert.ok(
      Math.abs(back.positions[i * 3 + 1] - c.positions[i * 3 + 1]) <= 0.0005 + 1e-9,
      `northing ${i} lost precision`,
    );
  }
});

test('LAS refuses a scale/offset combination that would overflow int32', () => {
  const c: PointCloud = {
    count: 1,
    // 3000 km from the offset at a 0.1 mm step is past int32.
    positions: new Float64Array([3_000_000, 0, 0]),
  };
  assert.throws(
    () => writeLas(c, { scale: 0.0001, offset: [0, 0, 0] }),
    /does not fit int32/,
  );
});

test('LAS writes a WKT VLR and shifts the point data past it', () => {
  const wkt = 'PROJCS["NAD83(2011) / Texas South Central (ftUS)"]';
  const bytes = writeLas(cloud(10), { wkt });
  const header = readLasHeader(bytes);
  assert.ok(header.offsetToPointData > 375, 'point data must start after the VLR');
  assert.match(new TextDecoder().decode(bytes.subarray(375, header.offsetToPointData)), /NAD83/);
  // Global encoding bit 4 signals that the CRS is WKT rather than GeoTIFF keys.
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(v.getUint16(6, true) & 0x10, 0x10);
  assert.equal(readLas(bytes).count, 10, 'points still parse at the shifted offset');
});

test('LAS treats a cloud origin as additive and writes it as the LAS offset', () => {
  const c = cloud(10);
  c.origin = [646000, 4181000, 150];
  const bytes = writeLas(c);
  const header = readLasHeader(bytes);
  assert.deepEqual(header.offset, [646000, 4181000, 150], 'origin becomes the LAS offset');

  // readLas returns world coordinates, so they must equal local + origin —
  // not local, and emphatically not local - origin.
  const back = readLas(bytes);
  for (let i = 0; i < c.count; i++) {
    for (let a = 0; a < 3; a++) {
      const expected = c.positions[i * 3 + a] + c.origin![a];
      assert.ok(
        Math.abs(back.positions[i * 3 + a] - expected) <= 0.0005 + 1e-9,
        `point ${i} axis ${a}: expected ${expected}, got ${back.positions[i * 3 + a]}`,
      );
    }
  }
});
