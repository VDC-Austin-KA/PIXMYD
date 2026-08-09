import test from 'node:test';
import assert from 'node:assert/strict';
import {
  readJpegSegments, parseExif, parseXmp, readImageMetadata, focalLengthInPixels,
} from '../src/exif.ts';
import {
  ingestDroneImages, ingestPanoramas, ingestColmap, exportColmap,
  gimbalToRotation, CUBE_FACE_ROTATIONS, type SourceImage,
} from '../src/sources.ts';
import { quat, v3, degToRad, type Vec3 } from '@pixmyd/core/math';
import { ByteWriter } from '@pixmyd/core/bytes';

const near = (a: number, b: number, tol: number, msg = '') =>
  assert.ok(Math.abs(a - b) < tol, `${msg}: ${a} !~= ${b} (tol ${tol})`);

// ===========================================================================
// Building a real JPEG with EXIF, so the parser is tested against bytes
// ===========================================================================

interface TagSpec {
  tag: number;
  type: number;
  values: number[] | string;
}

/**
 * Assemble a minimal but genuinely valid TIFF/EXIF block.
 *
 * Building the bytes rather than checking in a fixture means the test states
 * exactly what layout it expects, and the endianness can be flipped to prove
 * the parser reads the byte-order mark rather than assuming one.
 */
function buildExif(options: {
  littleEndian: boolean;
  ifd0: TagSpec[];
  exif?: TagSpec[];
  gps?: TagSpec[];
}): Uint8Array {
  const { littleEndian: le } = options;
  const TYPE_SIZE: Record<number, number> = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 10: 8 };

  // Lay out: header(8) | IFD0 | EXIF IFD | GPS IFD | heap
  const sizeOfIfd = (tags: TagSpec[]) => 2 + tags.length * 12 + 4;

  const ifd0Tags = [...options.ifd0];
  const exifOffsetPlaceholder = options.exif ? { tag: 0x8769, type: 4, values: [0] } : null;
  const gpsOffsetPlaceholder = options.gps ? { tag: 0x8825, type: 4, values: [0] } : null;
  if (exifOffsetPlaceholder) ifd0Tags.push(exifOffsetPlaceholder);
  if (gpsOffsetPlaceholder) ifd0Tags.push(gpsOffsetPlaceholder);
  // TIFF requires tags in ascending order.
  ifd0Tags.sort((a, b) => a.tag - b.tag);

  const ifd0Offset = 8;
  const exifOffset = ifd0Offset + sizeOfIfd(ifd0Tags);
  const gpsOffset = exifOffset + (options.exif ? sizeOfIfd(options.exif) : 0);
  let heapOffset = gpsOffset + (options.gps ? sizeOfIfd(options.gps) : 0);

  const heap: { offset: number; bytes: Uint8Array }[] = [];

  const encodeValues = (spec: TagSpec): { count: number; bytes: Uint8Array } => {
    if (typeof spec.values === 'string') {
      const text = new TextEncoder().encode(spec.values + '\0');
      return { count: text.length, bytes: text };
    }
    const size = TYPE_SIZE[spec.type];
    const isRational = spec.type === 5 || spec.type === 10;
    const count = isRational ? spec.values.length / 2 : spec.values.length;
    const bytes = new Uint8Array(count * size);
    const view = new DataView(bytes.buffer);
    if (isRational) {
      for (let i = 0; i < count; i++) {
        view.setUint32(i * 8, spec.values[i * 2], le);
        view.setUint32(i * 8 + 4, spec.values[i * 2 + 1], le);
      }
    } else {
      spec.values.forEach((value, i) => {
        if (spec.type === 1) view.setUint8(i, value);
        else if (spec.type === 3) view.setUint16(i * 2, value, le);
        else view.setUint32(i * 4, value, le);
      });
    }
    return { count, bytes };
  };

  // First pass: work out where heap data lands.
  const encoded = new Map<TagSpec, { count: number; bytes: Uint8Array; heapAt?: number }>();
  for (const tags of [ifd0Tags, options.exif ?? [], options.gps ?? []]) {
    for (const spec of tags) {
      const e = encodeValues(spec);
      if (e.bytes.length > 4) {
        encoded.set(spec, { ...e, heapAt: heapOffset });
        heap.push({ offset: heapOffset, bytes: e.bytes });
        // Keep the heap 2-aligned; TIFF requires even offsets.
        heapOffset += e.bytes.length + (e.bytes.length % 2);
      } else {
        encoded.set(spec, e);
      }
    }
  }

  if (exifOffsetPlaceholder) exifOffsetPlaceholder.values = [exifOffset];
  if (gpsOffsetPlaceholder) gpsOffsetPlaceholder.values = [gpsOffset];
  // Re-encode the two pointers now that their targets are known.
  for (const placeholder of [exifOffsetPlaceholder, gpsOffsetPlaceholder]) {
    if (placeholder) encoded.set(placeholder, encodeValues(placeholder));
  }

  const total = heapOffset;
  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);

  view.setUint16(0, le ? 0x4949 : 0x4d4d, false);
  view.setUint16(2, 42, le);
  view.setUint32(4, ifd0Offset, le);

  const writeIfd = (tags: TagSpec[], at: number, next: number): void => {
    view.setUint16(at, tags.length, le);
    let cursor = at + 2;
    for (const spec of tags) {
      const e = encoded.get(spec)!;
      view.setUint16(cursor, spec.tag, le);
      view.setUint16(cursor + 2, spec.type, le);
      view.setUint32(cursor + 4, e.count, le);
      if (e.heapAt !== undefined) {
        view.setUint32(cursor + 8, e.heapAt, le);
      } else {
        out.set(e.bytes, cursor + 8);
      }
      cursor += 12;
    }
    view.setUint32(cursor, next, le);
  };

  writeIfd(ifd0Tags, ifd0Offset, 0);
  if (options.exif) writeIfd(options.exif, exifOffset, 0);
  if (options.gps) writeIfd(options.gps, gpsOffset, 0);
  for (const chunk of heap) out.set(chunk.bytes, chunk.offset);

  return out;
}

/** Wrap EXIF and XMP into a real JPEG the segment walker can traverse. */
function buildJpeg(exif?: Uint8Array, xmp?: string): Uint8Array {
  const w = new ByteWriter();
  w.u8(0xff).u8(0xd8); // SOI

  if (exif) {
    const payload = new Uint8Array(6 + exif.length);
    payload.set(new TextEncoder().encode('Exif\0\0'), 0);
    payload.set(exif, 6);
    w.u8(0xff).u8(0xe1);
    w.u8((payload.length + 2) >> 8).u8((payload.length + 2) & 0xff);
    w.bytes(payload);
  }

  if (xmp) {
    const header = new TextEncoder().encode('http://ns.adobe.com/xap/1.0/\0');
    const body = new TextEncoder().encode(xmp);
    const payload = new Uint8Array(header.length + body.length);
    payload.set(header, 0);
    payload.set(body, header.length);
    w.u8(0xff).u8(0xe1);
    w.u8((payload.length + 2) >> 8).u8((payload.length + 2) & 0xff);
    w.bytes(payload);
  }

  w.u8(0xff).u8(0xda); // SOS — nothing parseable after this
  w.u8(0x00).u8(0x02);
  w.u8(0xff).u8(0xd9); // EOI
  return w.finish();
}

/** A DJI-shaped image: GPS, gimbal, focal length. */
function droneJpeg(options: {
  lat: number; latRef: string; lon: number; lonRef: string;
  altitude?: number; belowSeaLevel?: boolean;
  yaw?: number; pitch?: number; roll?: number;
  littleEndian?: boolean;
  model?: string;
  rtk?: boolean;
}): Uint8Array {
  const toDms = (value: number): number[] => {
    const degrees = Math.floor(value);
    const minutesFloat = (value - degrees) * 60;
    const minutes = Math.floor(minutesFloat);
    const seconds = (minutesFloat - minutes) * 60;
    // Rationals as numerator/denominator pairs; seconds at 1/10000.
    return [degrees, 1, minutes, 1, Math.round(seconds * 10000), 10000];
  };

  const exif = buildExif({
    littleEndian: options.littleEndian ?? true,
    ifd0: [
      { tag: 0x010f, type: 2, values: 'DJI' },
      { tag: 0x0110, type: 2, values: options.model ?? 'FC6310' },
    ],
    exif: [
      { tag: 0x829a, type: 5, values: [1, 500] },          // exposure 1/500
      { tag: 0x8827, type: 3, values: [100] },              // ISO
      { tag: 0x9003, type: 2, values: '2026:03:14 09:26:53' },
      { tag: 0x920a, type: 5, values: [880, 100] },         // focal 8.8 mm
      { tag: 0xa002, type: 4, values: [5472] },             // pixel width
      { tag: 0xa003, type: 4, values: [3648] },             // pixel height
      { tag: 0xa405, type: 3, values: [24] },               // 35mm equivalent
    ],
    gps: [
      { tag: 0x0001, type: 2, values: options.latRef },
      { tag: 0x0002, type: 5, values: toDms(Math.abs(options.lat)) },
      { tag: 0x0003, type: 2, values: options.lonRef },
      { tag: 0x0004, type: 5, values: toDms(Math.abs(options.lon)) },
      { tag: 0x0005, type: 1, values: [options.belowSeaLevel ? 1 : 0] },
      { tag: 0x0006, type: 5, values: [Math.round((options.altitude ?? 100) * 100), 100] },
    ],
  });

  const xmp = options.yaw !== undefined
    ? `<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/"
   drone-dji:GimbalYawDegree="${options.yaw >= 0 ? '+' : ''}${options.yaw.toFixed(2)}"
   drone-dji:GimbalPitchDegree="${(options.pitch ?? -90).toFixed(2)}"
   drone-dji:GimbalRollDegree="${(options.roll ?? 0).toFixed(2)}"
   drone-dji:RelativeAltitude="+${(options.altitude ?? 100).toFixed(2)}"
   drone-dji:AbsoluteAltitude="+${((options.altitude ?? 100) + 200).toFixed(2)}"
   drone-dji:RtkFlag="${options.rtk ? '50' : '0'}"/>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>`
    : undefined;

  return buildJpeg(exif, xmp);
}

// ===========================================================================
// EXIF
// ===========================================================================

test('JPEG segment walker finds EXIF and XMP', () => {
  const jpeg = droneJpeg({ lat: 29.4241, latRef: 'N', lon: -98.4936, lonRef: 'W', yaw: 0 });
  const segments = readJpegSegments(jpeg);
  assert.ok(segments.exif, 'EXIF segment');
  assert.ok(segments.xmp?.includes('drone-dji:GimbalYawDegree'), 'XMP segment');
});

test('a non-JPEG is refused rather than parsed as garbage', () => {
  assert.throws(() => readJpegSegments(new Uint8Array([1, 2, 3, 4])), /not a JPEG/);
});

for (const littleEndian of [true, false]) {
  test(`EXIF parses correctly in ${littleEndian ? 'little' : 'big'}-endian`, () => {
    // Endianness is declared inside the TIFF header, not by the JPEG. Both
    // orders exist in the wild and a parser that assumes one reads garbage
    // from half the world's cameras.
    const jpeg = droneJpeg({
      lat: 29.4241, latRef: 'N', lon: -98.4936, lonRef: 'W',
      altitude: 123.45, littleEndian,
    });
    const metadata = readImageMetadata(jpeg);

    assert.equal(metadata.camera.make, 'DJI');
    assert.equal(metadata.camera.model, 'FC6310');
    assert.equal(metadata.camera.imageWidth, 5472);
    assert.equal(metadata.camera.imageHeight, 3648);
    near(metadata.camera.focalLength!, 8.8, 1e-6, 'focal length');
    assert.equal(metadata.camera.iso, 100);
    near(metadata.camera.exposureTime!, 1 / 500, 1e-9, 'exposure');
    assert.equal(metadata.camera.captureTime, '2026-03-14T09:26:53');

    near(metadata.gps!.lat, 29.4241, 1e-6, 'latitude');
    near(metadata.gps!.lon, -98.4936, 1e-6, 'longitude');
    near(metadata.gps!.altitude!, 123.45, 1e-6, 'altitude');
  });
}

test('GPS hemisphere comes from the ref tag, not from the sign of the value', () => {
  // The magnitude in EXIF is unsigned. Forgetting the ref tag puts the southern
  // hemisphere in the northern one, which looks plausible on a map.
  const south = readImageMetadata(
    droneJpeg({ lat: -33.8688, latRef: 'S', lon: 151.2093, lonRef: 'E' }),
  );
  near(south.gps!.lat, -33.8688, 1e-6, 'S must be negative');
  near(south.gps!.lon, 151.2093, 1e-6, 'E must be positive');

  const north = readImageMetadata(
    droneJpeg({ lat: 29.4241, latRef: 'N', lon: -98.4936, lonRef: 'W' }),
  );
  assert.ok(north.gps!.lat > 0 && north.gps!.lon < 0);
});

test('altitude below sea level is signed by its ref tag', () => {
  const metadata = readImageMetadata(
    droneJpeg({
      lat: 31.5, latRef: 'N', lon: 35.5, lonRef: 'E',
      altitude: 420, belowSeaLevel: true,
    }),
  );
  near(metadata.gps!.altitude!, -420, 1e-6, 'below sea level must be negative');
  assert.equal(metadata.gps!.belowSeaLevel, true);
});

test('sensor width is derived from the 35 mm equivalent', () => {
  const metadata = readImageMetadata(
    droneJpeg({ lat: 29, latRef: 'N', lon: -98, lonRef: 'W' }),
  );
  // 8.8 mm actual, 24 mm equivalent -> crop factor 2.727 -> 36/2.727 = 13.2 mm,
  // which is the Phantom 4 Pro's 1-inch sensor.
  near(metadata.camera.sensorWidth!, 13.2, 0.05, 'sensor width');

  const focalPixels = focalLengthInPixels(metadata.camera)!;
  near(focalPixels, (8.8 / 13.2) * 5472, 20, 'focal length in pixels');
});

test('focal length in pixels is undefined rather than guessed when unknown', () => {
  // A fabricated focal length yields a self-consistent reconstruction at the
  // wrong scale, which is worse than refusing.
  assert.equal(focalLengthInPixels({ imageWidth: 4000 }), undefined);
  assert.equal(focalLengthInPixels({ focalLength: 10, sensorWidth: 20 }), undefined);
});

test('XMP is read from both attribute and element forms', () => {
  const attributes = parseXmp('<rdf:Description drone-dji:GimbalYawDegree="+45.50"/>');
  near(attributes.gimbalYaw!, 45.5, 1e-9, 'attribute form');

  const elements = parseXmp('<drone-dji:GimbalYawDegree>-12.25</drone-dji:GimbalYawDegree>');
  near(elements.gimbalYaw!, -12.25, 1e-9, 'element form');
});

test('the RTK flag distinguishes a corrected image from an uncorrected one', () => {
  assert.equal(parseXmp('<x drone-dji:RtkFlag="50"/>').rtkFlag, true);
  assert.equal(parseXmp('<x drone-dji:RtkFlag="0"/>').rtkFlag, false);
  assert.equal(parseXmp('<x/>').rtkFlag, undefined);
});

// ===========================================================================
// Gimbal orientation
// ===========================================================================

test('a nadir gimbal looks straight down in ENU', () => {
  // Yaw 0, pitch -90 is the standard mapping attitude.
  const rotation = gimbalToRotation(0, -90, 0);
  // The camera's forward axis is +Z in vision convention.
  const forward = quat.rotate(rotation, [0, 0, 1]);
  near(forward[2], -1, 1e-6, 'a nadir camera looks down (-Z in ENU)');
});

test('a level gimbal at yaw 0 looks north', () => {
  const forward = quat.rotate(gimbalToRotation(0, 0, 0), [0, 0, 1]);
  near(forward[1], 1, 1e-6, 'yaw 0 looks north (+Y in ENU)');
  near(forward[2], 0, 1e-6, 'and is level');
});

test('yaw 90 looks east, which pins down the sign convention', () => {
  // DJI yaw is clockwise from north. ENU is right-handed with +Z up, so
  // clockwise is a negative rotation about up. Getting this backwards mirrors
  // the whole flight about the north axis.
  const forward = quat.rotate(gimbalToRotation(90, 0, 0), [0, 0, 1]);
  near(forward[0], 1, 1e-6, 'yaw 90 looks east (+X in ENU)');
});

test('the camera right axis stays horizontal at any yaw when level', () => {
  for (const yaw of [0, 45, 90, 180, 270]) {
    const right = quat.rotate(gimbalToRotation(yaw, 0, 0), [1, 0, 0]);
    near(right[2], 0, 1e-6, `right axis at yaw ${yaw} must be horizontal`);
  }
});

// ===========================================================================
// Drone ingest
// ===========================================================================

test('a drone folder becomes a bundle with ENU poses', async () => {
  const images: SourceImage[] = [
    { name: 'DJI_0001.JPG', bytes: droneJpeg({ lat: 29.4241, latRef: 'N', lon: -98.4936, lonRef: 'W', altitude: 100, yaw: 0 }) },
    // 0.001 degrees north is about 111 m.
    { name: 'DJI_0002.JPG', bytes: droneJpeg({ lat: 29.4251, latRef: 'N', lon: -98.4936, lonRef: 'W', altitude: 100, yaw: 0 }) },
    { name: 'DJI_0003.JPG', bytes: droneJpeg({ lat: 29.4241, latRef: 'N', lon: -98.4926, lonRef: 'W', altitude: 100, yaw: 90 }) },
  ];

  const { bundle, warnings } = await ingestDroneImages(images, { name: 'Test flight' });

  assert.equal(bundle.frames.length, 3);
  assert.equal(bundle.manifest.device.kind, 'drone');
  // All three share one camera model.
  assert.equal(bundle.manifest.cameras.length, 1);
  assert.equal(warnings.length, 0, `unexpected warnings: ${warnings.join('; ')}`);

  // The first image defines the origin, so it sits at zero.
  const first = bundle.frames[0].pose!;
  near(v3.length(first.t), 0, 0.01, 'the first frame is the origin');

  // The second is ~111 m north.
  const second = bundle.frames[1].pose!;
  near(second.t[0], 0, 1, 'no easting change');
  near(second.t[1], 111, 3, 'about 111 m north');

  // The third is east.
  const third = bundle.frames[2].pose!;
  assert.ok(third.t[0] > 50, `expected an easterly offset, got ${third.t[0]}`);

  // Metadata poses must be marked as such, and weighted low.
  assert.equal(bundle.frames[0].poseSource, 'metadata');
  assert.ok(bundle.frames[0].poseWeight! < 0.5, 'a non-RTK metadata pose is weak evidence');
});

test('an RTK-flagged drone image is trusted more than an uncorrected one', async () => {
  const plain = await ingestDroneImages([
    { name: 'a.jpg', bytes: droneJpeg({ lat: 29, latRef: 'N', lon: -98, lonRef: 'W', yaw: 0, rtk: false }) },
  ]);
  const rtk = await ingestDroneImages([
    { name: 'b.jpg', bytes: droneJpeg({ lat: 29, latRef: 'N', lon: -98, lonRef: 'W', yaw: 0, rtk: true }) },
  ]);
  assert.ok(
    rtk.bundle.frames[0].poseWeight! > plain.bundle.frames[0].poseWeight!,
    'an RTK image should carry more weight',
  );
  assert.equal(rtk.bundle.gnss![0].quality, 4, 'RTK fixed');
  assert.equal(plain.bundle.gnss![0].quality, 1, 'single point');
});

test('images with no GPS produce a bundle with a stated warning, not a silent failure', async () => {
  const noGps = buildJpeg(
    buildExif({
      littleEndian: true,
      ifd0: [{ tag: 0x0110, type: 2, values: 'ILCE-7M3' }],
      exif: [
        { tag: 0xa002, type: 4, values: [6000] },
        { tag: 0xa003, type: 4, values: [4000] },
        { tag: 0x920a, type: 5, values: [3500, 100] },
        { tag: 0xa405, type: 3, values: [35] },
      ],
    }),
  );

  const { bundle, warnings } = await ingestDroneImages([{ name: 'x.jpg', bytes: noGps }]);
  assert.equal(bundle.frames.length, 1);
  assert.equal(bundle.frames[0].pose, undefined);
  assert.equal(bundle.frames[0].poseSource, 'none');
  assert.ok(
    warnings.some((w) => w.includes('No image carried a GPS position')),
    `expected a georeference warning, got: ${warnings.join('; ')}`,
  );
});

test('two different cameras in one folder produce two camera models', async () => {
  const { bundle } = await ingestDroneImages([
    { name: 'a.jpg', bytes: droneJpeg({ lat: 29, latRef: 'N', lon: -98, lonRef: 'W', model: 'FC6310' }) },
    { name: 'b.jpg', bytes: droneJpeg({ lat: 29, latRef: 'N', lon: -98, lonRef: 'W', model: 'ZENMUSE P1' }) },
  ]);
  assert.equal(bundle.manifest.cameras.length, 2);
  assert.notEqual(bundle.frames[0].camera, bundle.frames[1].camera);
});

// ===========================================================================
// Panoramas
// ===========================================================================

test('a 360 capture produces an equirectangular camera and no poses', () => {
  const { bundle, warnings } = ingestPanoramas(
    [{ name: 'VID_0001.jpg', bytes: new Uint8Array() }],
    { width: 5760, height: 2880 },
  );
  assert.equal(bundle.manifest.cameras[0].model, 'equirect');
  assert.equal(bundle.frames.length, 1);
  assert.equal(bundle.frames[0].poseSource, 'none');
  assert.equal(warnings.length, 0, '2:1 is the correct aspect');
  assert.match(bundle.manifest.notes!, /arbitrary scale/);
});

test('a panorama with the wrong aspect ratio is flagged', () => {
  const { warnings } = ingestPanoramas(
    [{ name: 'a.jpg', bytes: new Uint8Array() }],
    { width: 4000, height: 3000 },
  );
  assert.ok(warnings.some((w) => w.includes('not the 2:1 aspect')));
});

test('cube-face splitting yields six perspective frames per panorama', () => {
  const { bundle } = ingestPanoramas(
    [
      { name: 'a.jpg', bytes: new Uint8Array() },
      { name: 'b.jpg', bytes: new Uint8Array() },
    ],
    { width: 5760, height: 2880, cubeFaces: true },
  );

  assert.equal(bundle.frames.length, 12, 'two panoramas, six faces each');
  assert.equal(bundle.manifest.cameras.length, 2, 'the panorama and the face camera');

  const face = bundle.manifest.cameras[1];
  assert.equal(face.model, 'pinhole');
  if (face.model === 'pinhole') {
    // A cube face spans exactly 90 degrees, so fx is half the face size.
    near(face.fx, face.width / 2, 1e-9, 'a 90-degree face has fx = width/2');
  }

  const names = bundle.frames.slice(0, 6).map((f) => f.meta!.face);
  assert.deepEqual(names, ['right', 'left', 'up', 'down', 'front', 'back']);
});

test('the six cube faces point along the six axes and are mutually perpendicular', () => {
  const forwards = CUBE_FACE_ROTATIONS.map((f) => quat.rotate(f.rotation, [0, 0, 1] as Vec3));
  const expected: Vec3[] = [
    [1, 0, 0], [-1, 0, 0], [0, -1, 0], [0, 1, 0], [0, 0, 1], [0, 0, -1],
  ];
  forwards.forEach((forward, i) => {
    for (let a = 0; a < 3; a++) {
      near(forward[a], expected[i][a], 1e-6, `${CUBE_FACE_ROTATIONS[i].name} axis ${a}`);
    }
  });
});

// ===========================================================================
// COLMAP
// ===========================================================================

const COLMAP_CAMERAS = `# Camera list
1 PINHOLE 1920 1080 1500.0 1500.0 960.0 540.0
2 OPENCV 4000 3000 3200 3200 2000 1500 -0.02 0.001 0.0001 -0.0002
`;

test('COLMAP cameras parse, including the distortion models', () => {
  const { bundle, warnings } = ingestColmap(COLMAP_CAMERAS, '');
  assert.equal(bundle.manifest.cameras.length, 2);
  const first = bundle.manifest.cameras[0];
  assert.equal(first.model, 'pinhole');
  if (first.model === 'pinhole') {
    assert.equal(first.fx, 1500);
    assert.equal(first.cx, 960);
  }
  const second = bundle.manifest.cameras[1];
  if (second.model === 'pinhole') {
    assert.equal(second.k1, -0.02);
    assert.equal(second.p2, -0.0002);
  }
  assert.ok(warnings.some((w) => w.includes('No images were read')));
});

test('COLMAP poses invert world-to-camera into a camera position', () => {
  // A camera at (10, 0, 0) looking down world -X. World-to-camera rotation is
  // the inverse of that, and COLMAP's translation is the world origin expressed
  // in camera coordinates — not the camera position.
  const cameraToWorld = quat.fromAxisAngle([0, 1, 0], -Math.PI / 2);
  const worldToCamera = quat.conjugate(cameraToWorld);
  const position: Vec3 = [10, 0, 0];
  const t = v3.negate(quat.rotate(worldToCamera, position));

  const imagesText =
    `1 ${worldToCamera[3]} ${worldToCamera[0]} ${worldToCamera[1]} ${worldToCamera[2]} ` +
    `${t[0]} ${t[1]} ${t[2]} 1 frame.jpg\n\n`;

  const { bundle } = ingestColmap(COLMAP_CAMERAS, imagesText);
  assert.equal(bundle.frames.length, 1);
  const pose = bundle.frames[0].pose!;
  for (let i = 0; i < 3; i++) {
    near(pose.t[i], position[i], 1e-6, `camera position axis ${i}`);
  }
  assert.equal(bundle.frames[0].poseSource, 'sfm');
});

test('COLMAP export and import round trip a pose exactly', () => {
  const original = {
    manifest: {
      formatVersion: 1, id: 'x', name: 'y', startedAt: new Date().toISOString(),
      device: { kind: 'colmap' as const },
      cameras: [{ model: 'pinhole' as const, width: 1920, height: 1080, fx: 1500, fy: 1500, cx: 960, cy: 540 }],
      frameCount: 2,
    },
    frames: [
      {
        id: '0', t: 0, imageUri: 'a.jpg', camera: 0, poseSource: 'sfm' as const,
        pose: { t: [1, 2, 3] as Vec3, q: quat.normalize([0.1, 0.2, 0.3, 0.9]) },
      },
      {
        id: '1', t: 1, imageUri: 'b.jpg', camera: 0, poseSource: 'sfm' as const,
        pose: { t: [-4, 5, 6] as Vec3, q: quat.fromAxisAngle([0, 1, 0], degToRad(37)) },
      },
    ],
  };

  const text = exportColmap(original);
  const { bundle } = ingestColmap(text.cameras, text.images);

  assert.equal(bundle.frames.length, 2);
  for (let f = 0; f < 2; f++) {
    const before = original.frames[f].pose;
    const after = bundle.frames[f].pose!;
    for (let i = 0; i < 3; i++) near(after.t[i], before.t[i], 1e-6, `frame ${f} position ${i}`);
    // Compare rotations by their action, since q and -q are the same rotation.
    for (const probe of [[1, 0, 0], [0, 1, 0], [0, 0, 1]] as Vec3[]) {
      const expected = quat.rotate(before.q, probe);
      const actual = quat.rotate(after.q, probe);
      for (let i = 0; i < 3; i++) near(actual[i], expected[i], 1e-6, `frame ${f} rotation`);
    }
  }
});

test('COLMAP export skips equirectangular frames it cannot represent', () => {
  const text = exportColmap({
    manifest: {
      formatVersion: 1, id: 'x', name: 'y', startedAt: new Date().toISOString(),
      device: { kind: 'panoramic-360' as const },
      cameras: [{ model: 'equirect' as const, width: 5760, height: 2880 }],
      frameCount: 1,
    },
    frames: [{
      id: '0', t: 0, imageUri: 'pano.jpg', camera: 0, poseSource: 'sfm' as const,
      pose: { t: [0, 0, 0] as Vec3, q: quat.identity() },
    }],
  });
  // The header lines remain; no image entry should be written.
  assert.ok(!text.images.includes('pano.jpg'), 'COLMAP has no equirectangular model');
});

test('an unsupported COLMAP camera model is reported rather than mis-parsed', () => {
  const { warnings } = ingestColmap('1 FOV 1920 1080 1500 960 540 0.9\n', '');
  assert.ok(warnings.some((w) => w.includes('FOV')));
});
