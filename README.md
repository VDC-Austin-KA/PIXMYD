# PIXMYD

A free, open reality-capture toolchain: capture on whatever hardware you have,
process on-device, and export to the formats engineering actually uses.

The goal is a dependable alternative to the subscription scanning apps — one an
engineering team can read, fix, and rely on without a per-seat licence or a
cloud round trip.

**Status: foundations built and tested. Not yet an end-to-end product.**
See [What works today](#what-works-today) before planning around it.

---

## Why

Reality capture on a phone is a solved problem technically and an unsolved one
commercially. The tools that do it well are subscriptions, they process in
someone else's cloud, and they hold your deliverable behind an export tier. For
a VDC team that needs an as-built in a format Navisworks will attach, that is a
recurring cost and a recurring dependency.

The parts that are genuinely hard — the file formats, the geodesy, the honest
accuracy reporting — are hard once. This repo does them once, in the open.

## Design commitments

These are the rules the code is held to, not aspirations.

**Every number carries its tolerance.** A registration RMS is displayed with the
construction band it falls in and guidance in the terms a crew uses. A
measurement shown without its accuracy is an unfinished measurement, because
somebody will build to it.

**Say what the hardware actually cannot do.** iPhone LiDAR is not reachable from
a web page — not through WebXR, not through `getUserMedia`, not through anything
in flight. That is stated plainly wherever it matters rather than discovered by
a user staring at a black screen.

**A missing format beats a broken one.** RCS/RCP are proprietary with no
published specification. Rather than guess at the layout and emit files that
fail to open, the exporter produces E57 and returns the exact conversion steps.

**Validate against somebody else's parser.** A writer checked only by its own
reader proves the pair agrees, not that the file is correct. FBX and GLB output
is parsed back by three.js's loaders in the test suite.

## What works today

Everything listed here is implemented and covered by the test suite
(`npm test`, 153 tests, no network access required).

### Export formats — `packages/formats`

| Format | Write | Read | Notes |
|---|---|---|---|
| **PLY** | yes | yes | ascii, binary LE and BE; point clouds, meshes, and 3DGS splats |
| **GLB / glTF 2.0** | yes | parse | textured meshes; splats via `KHR_gaussian_splatting` |
| **OBJ + MTL** | yes | yes | with the vertex-colour extension |
| **FBX** | yes | parse | binary 7400 |
| **E57** | yes | yes | full ASTM E2807: CRC-32C paging, XML, CompressedVector |
| **LAS 1.4** | yes | yes | int32 + scale/offset, WKT VLR |
| **RCS / RCP** | — | — | proprietary; E57 bridge with exact steps instead |

Three details in here were the difference between "loads" and "correct":

- Splat GLB **activates** opacity and scale on the way out.
  `KHR_gaussian_splatting` stores linear alpha and world-unit scale, while
  training and the PLY convention store logit and log values. Skip the
  conversion and the file loads cleanly and renders as an opaque blob.
- Splat PLY writes `f_rest` **channel-major**, matching the reference
  implementation. Transposed, it looks right head-on and wrong at grazing angles.
- FBX writes **centimetres** by default. Most importers ignore
  `UnitScaleFactor` and assume centimetres, so writing metres makes a 3 m wall
  arrive 3 cm tall.

### Geodesy — `packages/geo`

Ellipsoids, geodetic/ECEF/ENU, and Lambert Conformal Conic + Transverse
Mercator, which between them cover every US State Plane zone. Plus the
State Plane registry, rigid registration, and NMEA parsing for RTK receivers.

Zone constants are checked structurally rather than trusted: every zone must map
its own false origin to exactly its false easting and northing, round trip to
sub-millimetre, and hold scale factor 1 on its standard parallels.

Two things this package exists to prevent:

- **float32 cannot hold survey coordinates.** Texas South Central has a false
  northing of 4,000,000 m — 13,123,333 ftUS — and between 2²³ and 2²⁴ a float32
  step is exactly 1.0. At that magnitude float32 resolves one *foot*. Every GPU
  vertex buffer is float32, so a floating origin is not optional.
- **"Feet" is not a unit.** The US survey foot and the international foot differ
  by 2 ppm. On a 40-foot wall that is nothing; multiplied by a 13.7-million-foot
  northing, the same number read two ways lands 27 feet apart. Nothing here
  records a unit as "feet".

Registration uses Horn's closed-form solve, with **leave-one-out outlier
detection** alongside the usual median/MAD z-score. MAD alone is masked on small
networks: least squares smears one blunder across every residual, so a 300 mm
knocked marker in a six-point network scores only 2.9 MADs and slips under any
sensible threshold. Refitting without each point measures influence directly.
There is a test for exactly that case.

### Reconstruction — `packages/recon`

- **Camera models**: pinhole with Brown-Conrady distortion, equidistant fisheye,
  and equirectangular — so a drone, an action camera and a stitched 360
  panorama share one reconstruction path.
- **TSDF fusion**: sparse-block Curless & Levoy volumetric integration from
  depth frames and poses, with confidence gating and colour, plus zero-crossing
  point extraction.

### Capture bundle — `packages/core`

The data model everything normalizes into: iPhone LiDAR, Quest 3 passthrough, a
drone image folder and a 360 panorama all land in one schema, so nothing
downstream needs a per-device special case.

## What is not built yet

Stated plainly so nobody plans around vapour:

- **Surface extraction to a mesh.** TSDF fusion produces the field and point
  extraction; marching-tetrahedra meshing is next.
- **Gaussian splat training.** The export path is complete and tested; the
  WebGPU trainer that produces the splats is not written.
- **Structure-from-motion.** Nothing yet solves poses from images alone, so
  photogrammetry-only capture (drone, 360) has no pose source without metadata.
- **The iOS capture app.** ARKit/LiDAR/RTK capture is designed against the
  bundle schema but not written.
- **The studio web app.** No UI yet.

None of the above has been run against real hardware or a real survey network.

## Repository layout

```
packages/core      math, binary IO, the capture bundle schema
packages/formats   PLY, GLB, OBJ, FBX, E57, LAS readers and writers
packages/geo       ellipsoids, projections, State Plane, registration, NMEA
packages/recon     camera models, TSDF fusion
```

## Running it

Requires Node 22.6 or newer — the packages are TypeScript run directly via
native type stripping, so there is no build step for the library or its tests.

```sh
npm install
npm test
```

## Licence

Apache-2.0.
