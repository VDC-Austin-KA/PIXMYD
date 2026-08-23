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
(`npm test`, 298 tests, no network access required — plus 240 Swift tests for
the iOS app's arithmetic, `swift test` in `apps/ios`).

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
  depth frames and poses, with confidence gating and colour.
- **Surface extraction**: marching tetrahedra — 16 unambiguous sign cases per
  tetrahedron rather than 256 cases with genuinely ambiguous configurations, so
  the surface is manifold by construction. Unobserved voxels return *null*
  rather than a large positive distance, so unseen regions stay open: an
  as-built with an honest hole is a note to go back to site, one with an
  invented lid is a measurement that was never taken.

### Features — `packages/features`

The front end SfM needs: given two photographs, which pixels are the same point?

- **FAST-9 corners** with the compass-point early rejection, Harris scoring to
  rank them, and grid-bucketed non-maximum suppression.
- **Scale pyramid** at 1.2 per level rather than an octave, because a
  photogrammetric pair is usually shot from a similar distance and an octave
  quantises that difference too coarsely to match well.
- **Steered 256-bit binary descriptors**, oriented by the intensity centroid so
  that two photos of the same wall taken with the phone at different angles
  still match — the normal case on a site, not an edge case.
- **Matching** with Lowe's ratio test, cross-check, and a robust
  motion-consistency pre-filter, then **RANSAC on the essential matrix**.
- **Intrinsics inversion** for all three camera models, including the iterative
  Brown-Conrady inverse and honest nulls for rays behind a fisheye or over the
  horizon of a panorama.

Verification is seeded and deterministic: reprocessing a capture has to give the
same answer, or there is no way to tell a real improvement from RANSAC's luck.

### iOS capture app — `apps/ios`

ARKit + LiDAR capture, RTK GNSS over MFi, Bluetooth LE or Wi-Fi — with a scan
mode that finds a receiver over the air and writes it into a profile — an NTRIP
client that reads a caster's source table, on-device fusion and export. Five
tabs — Capture, Projects, Site, Survey, Account.

**Partly compiled.** The arithmetic — bundle schema, TSDF fusion, meshing,
format writers, NMEA parsing — builds and tests on Linux via
[`apps/ios/Package.swift`](apps/ios/Package.swift), 240 tests, run in CI. The
SwiftUI, ARKit, CoreLocation and Metal half has only been parsed;
[Codemagic](codemagic.yaml) compiles it and produces an unsigned `.ipa` a free
Apple ID can sideload. See [`apps/ios/README.md`](apps/ios/README.md) for the
install route and an honest list of what would bite first.

This app exists because iPhone LiDAR is not reachable from a web page — not
through WebXR, not `getUserMedia`, not anything in flight. Everything else in
PIXMYD is deliberately a web toolchain.

### Navisworks round trip — `apps/ios/PIXMYD/Interop`

The other half lives in [PIXMYD-Nav](https://github.com/VDC-Austin-KA/PIXMYD-Nav),
a Navisworks add-in. Between them a scan goes onto a model and a model goes onto
a site, and the coordinates survive the journey both ways.

**Points can start at either end.** The workstation places control points on the
model and prints QR markers for them; or a crew walks the space first, places
points on the phone while scanning, and the workstation puts the same ids on the
model afterwards. The second is the case that used to stop people — it is the
normal one on a first visit, and the ids are what tie the two lists together.

**Two points are enough.** Both frames know which way down is: ARKit runs
gravity-aligned and a Navisworks model states its up axis. Holding the vertical
removes roll and pitch and leaves heading and translation, which two points
over-determine. `solveGravityConstrained` is a closed form, it agrees with
Horn's solve on clean control, and it *reports* a blunder that Horn's absorbs
into a tilt. Two points also leave no redundancy — the RMS is near zero whether
they were right or wrong — and both apps say so beside the number rather than
letting it reassure anybody.

**The mesh goes back as FBX.** A Navisworks add-in cannot author geometry into
an open document; it can append a file. Navisworks reads FBX and does not read
GLB, so `capture.fbx` is what travels, written by the same writer the monorepo
tests feed through three.js's own FBXLoader. When the phone knows the model
frame it bakes the alignment into the vertices and says so in
`geometry.frame`; when it does not, the workstation transforms the appended
model itself.

**Transfer is over the local network, and the bar moves.** One QR code on the
workstation screen, scanned on the phone, opens a session that offers a folder
and accepts a scan. Progress is reported in bytes rather than files completed,
because the return leg is a JSON of a few kilobytes and a mesh three orders of
magnitude larger.

### Studio web app — `apps/studio`

Open a `.pixmyd` capture folder or a zip of one, fuse it, and export. Runs
entirely in the browser — nothing is uploaded, and there is no server.

`npm run dev` to start it. An end-to-end test drives the whole path with a
synthetic capture: bundle reader, fusion, meshing, and every export format read
back by an independent parser.

### Capture bundle — `packages/core`

The data model everything normalizes into: iPhone LiDAR, Quest 3 passthrough, a
drone image folder and a 360 panorama all land in one schema, so nothing
downstream needs a per-device special case.

## What is not built yet

Stated plainly so nobody plans around vapour:

- **A WebGPU path for splat training.** The trainer is a correct CPU reference
  and is far too slow for a real capture — thousands of Gaussians, not millions.
  The GPU port is the single largest remaining piece of work.
- **A 3D viewer in the studio.** You can process and export, but not yet look
  at the result in the browser before you do.
- **Incremental reconstruction over a whole image set.** Pairs match and verify;
  choosing an initial pair, registering the rest by PnP, and growing one
  consistent track graph across a hundred images is not written yet.

The iOS app's framework layer **has never been compiled, and none of it has run
on a device** — a different kind of "not done", see its README. Nothing in this
repo has been validated against real hardware or a real survey network.

## Repository layout

```
packages/core      math, binary IO, the capture bundle schema
packages/formats   PLY, GLB, OBJ, FBX, E57, LAS readers and writers
packages/geo       ellipsoids, projections, State Plane, registration, NMEA
packages/recon     camera models, TSDF fusion, marching tetrahedra
packages/sfm       two-view geometry, PnP, bundle adjustment
packages/features  FAST/Harris detection, binary descriptors, matching
packages/splat     differentiable Gaussian splat rasterizer and trainer
packages/ingest    EXIF/XMP, drone, 360 and COLMAP import
apps/studio        the browser processing app
apps/ios           the Swift capture app (uncompiled)
```

### Structure-from-motion — `packages/sfm`

Two-view geometry (eight-point essential matrix with cheirality selection),
PnP with RANSAC and nonlinear refinement, and bundle adjustment by
Levenberg-Marquardt with the Schur complement.

### Gaussian splatting — `packages/splat`

A differentiable rasterizer and trainer: anisotropic 3D Gaussians, spherical
harmonics, Adam, and adaptive density control (clone, split, prune).

**Every gradient is checked against central finite differences** — colour,
opacity, position, log-scale and rotation. That matters more here than
elsewhere: a trainer with a subtly wrong gradient still converges to something
that looks like a scene, just blurrier, so the output does not reveal the bug.

## Ingest — `packages/ingest`

EXIF and XMP parsing written from the specification, so a folder of drone
photographs becomes a capture with initial poses: GPS position, gimbal
orientation, focal length and sensor width. Plus 360 panorama ingest with
cube-face splitting, and COLMAP import and export.

## Running it

Requires Node 22.6 or newer — the packages are TypeScript run directly via
native type stripping, so there is no build step for the library or its tests.

```sh
npm install
npm test
```

## Licence

Apache-2.0.
