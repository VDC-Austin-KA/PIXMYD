# PIXMYD for iOS

The capture app. ARKit + LiDAR, RTK GNSS, on-device processing, and export —
with no account, no subscription, and nothing uploaded anywhere.

> **Partly compiled, never run on a device.** The arithmetic half — bundle
> schema, TSDF fusion, meshing, format writers, NMEA parsing — is compiled and
> tested on every push (35 tests, on Linux). The SwiftUI, ARKit, CoreLocation
> and Metal half has only been *parsed*; [Codemagic](../../codemagic.yaml)
> compiles it, and until that build has run green nothing here has been through
> a full `swiftc`. Nothing at all has run on hardware — see [Before trusting
> it](#before-trusting-it).

## Getting it onto an iPhone without a Mac

The build happens on Codemagic's macOS instances and produces an **unsigned**
`.ipa`; a free Apple ID signs it on Windows. No Mac and no $99 developer
account are involved at any point.

1. **Get the build.** Push to the repo; Codemagic picks up
   [`codemagic.yaml`](../../codemagic.yaml) automatically. Download
   `PIXMYD-unsigned.ipa` from the build's artifacts.
2. **Install Apple's USB drivers.** [Apple
   Devices](https://apps.microsoft.com/detail/9np83lwlpz9k) from the Microsoft
   Store, or iTunes downloaded from apple.com. The Microsoft Store build of
   iTunes does not expose the drivers a sideloader needs.
3. **Sign and install with [Sideloadly](https://sideloadly.io/).** Plug the
   phone in, drag the `.ipa` on, enter the Apple ID, hit Start. It registers
   the device, generates a free provisioning profile, signs, and installs.
4. **Trust the certificate.** Settings → General → VPN & Device Management →
   the Apple ID → Trust. The app will not launch until this is done, and the
   failure looks like a crash rather than a permissions problem.

### What a free Apple ID costs you

- **The app stops working after 7 days** and has to be re-signed. This is
  Apple's limit on free provisioning, not something the app can avoid.
  [AltStore](https://altstore.io/) solves it properly — its Windows companion
  re-signs installed apps over Wi-Fi in the background, so the expiry becomes
  invisible. Worth the extra setup if this is going to be used on site.
- **Three sideloaded apps at a time**, and ten new app IDs per week.
- **No entitlements that need a paid team.** The app had exactly one —
  `com.apple.developer.networking.wifi-info` — which no code used and which
  would have failed free signing, so it is gone.

Everything the app actually does — ARKit, LiDAR depth, camera, GPS, Bluetooth
to an RTK receiver, on-device export — works under free provisioning.

A **Pro iPhone is required for LiDAR**. On a non-Pro phone the app runs and
says depth is unavailable rather than degrading quietly, but the whole point of
it is the depth sensor.

## Building

```sh
brew install xcodegen
cd apps/ios
xcodegen generate
open PIXMYD.xcodeproj
```

The Xcode project is generated from [`project.yml`](project.yml) rather than
committed. A `.pbxproj` is unreviewable in a diff and merges badly; the spec is
the source of truth.

Requires iOS 17, and a device — ARKit world tracking does not run in the
simulator. LiDAR needs a Pro iPhone or an iPad Pro; the app runs without it and
says so rather than degrading quietly.

### Testing without a Mac

The files whose only imports are Foundation and `simd` build and test on Linux:

```sh
cd apps/ios
swift test
```

[`Package.swift`](Package.swift) compiles that subset against a small stand-in
for Apple's `simd` module ([`Compat/simd`](Compat/simd/Simd.swift)) and points
at the same `PIXMYDTests` directory the Xcode unit-test bundle uses, so one set
of tests serves both. It is deliberately a subset: adding a UIKit or ARKit
import to one of those files breaks the Linux build, which is the point.

This is not a substitute for building the app — it cannot see a single view or
the AR session. It is how the code that silently produces a wrong measurement,
rather than crashing, gets checked on every push. Writing these tests found one
such bug immediately: `NmeaAssembler.flush` paired a leftover GST with a GGA
from a *different* epoch, stamping one position's accuracy onto another.

## Why an app at all

The rest of PIXMYD is a web toolchain, deliberately. This is the one piece that
cannot be:

**iPhone LiDAR is not reachable from a web page.** Not through WebXR, which
Safari does not implement on iOS. Not through `getUserMedia`, which yields
colour frames and no depth track, no confidence map, no scene mesh. Not through
anything else, and there is no proposal in flight that would change it. On a Pro
iPhone the LiDAR scanner feeds ARKit, and ARKit has no browser API.

So the split is: **this app captures, and the studio processes.** The app also
processes on device, because a field crew should not need a laptop to hand over
a deliverable — but the heavy paths live in the shared TypeScript packages where
they are tested.

## Screens

Four tabs, following the shape a field user already expects.

**Capture.** Viewfinder with the position quality top-left, tools top-right, and
the shutter bottom-centre. While recording it shows frames captured, distance
walked, and point count. A Live Preview toggle overlays the raw LiDAR point
cloud so coverage is visible while there is still a chance to fix it.

**Projects.** Search and filter over captures, with per-project detail, the
registration residual, and export.

**Survey.** Point collections imported from PNEZD files, for georeferencing and
for grading the result.

**Account.** Capture settings, scan mode, RTK profiles with NTRIP credentials
and antenna offsets, AR display options, and a plain statement of what this
device can do.

**RTK.** One screen for the receiver and its corrections, reached from the
Account tab. Scanning is the first thing on it, not a preference buried among
the others; the capture screen carries the same action as a labelled button
under the position badge, and the tools sheet links to it too.

**Scan mode.** Three searches run at once — a Bluetooth LE scan, a Bonjour
browse of the network the phone is joined to, and the list of attached MFi
accessories — because a receiver announces itself on exactly one of them and the
user should not have to know which. A `host:port` can also be typed, which is
the normal case rather than a fallback: a rover in access-point mode with a raw
TCP output advertises nothing at all. Connecting writes the device into an RTK
profile on the spot.

## Design decisions worth knowing

**Frame selection is the interesting problem.** ARKit delivers 60 fps. A
20-minute walk is 72,000 frames, of which maybe 1,500 carry new information.
Frames are gated on baseline, rotation and tracking quality, and the baseline
threshold is *derived* from the requested overlap and subject distance rather
than being a constant that is wrong at both ends. The settings screen shows the
derived number, because a user who can see it can reason about the sliders.

**Append-only capture survives interruption.** The manifest is written last, so
its absence is exactly the signature of a crash or force-quit mid-scan.
`CaptureWriter.recover` rebuilds it from the frames that made it to disk. Losing
a site visit to a missing summary file would be absurd.

**Back-pressure drops frames rather than crashing.** ARKit hands over frames
faster than flash absorbs 3 MB JPEGs. The write queue is bounded; when it fills,
frames are dropped and counted, and the count goes in the manifest. A dropped
frame is visible. An out-of-memory crash 18 minutes into a scan is not
recoverable.

**Depth is stored as uint16 millimetres.** ARKit gives float32 metres at
256×192 — 196 KB per frame, 295 MB across a 1,500-frame scan. Millimetre
integers halve that and still resolve ten times finer than the sensor.

**The accuracy state is always on screen.** A scan georeferenced from an RTK
*float* solution looks identical to one from a *fixed* solution and is
decimetres out. The badge shows the fix type in words, not a bar count, because
every receiver shows four bars for both. HDOP is labelled HDOP, never
"accuracy" — it is a satellite-geometry factor, and presenting it as an accuracy
would be a lie the user cannot detect.

**A profile is filled in from both ends, and only one end is discoverable.**
The receiver half — device, link, address — is written by the scan, because
asking someone to transcribe what the phone has just found out is asking them to
make a typo. The caster half cannot be discovered at all: corrections come from
a subscription, and no amount of scanning reveals an account. What it *can* do
is read the caster's own source table, so the mount point is picked from a list
rather than typed from memory — along with whether that stream needs a position
report, which the table states and which is the difference between a VRS that
works and one that goes quiet after a minute. With a fix, the list is ordered
nearest first.

**Connecting is not the same as working.** A link that opens and then delivers
something unreadable presents to the user as "it connected and there is no
position", which is indistinguishable from a receiver with no sky view. The
first bytes off every link are classified — NMEA, RTCM, u-blox binary, or
nothing recognisable — and anything that is not NMEA is reported with the thing
to change on the receiver. The screen also shows how many bytes have arrived, so
"connected and silent" is visibly different from "connected and misconfigured".

**The scan hides most of what it finds, and says how much.** A Bluetooth scan
anywhere near people finds phones, watches, tyre sensors and headphones. Devices
are shown first when they advertise a serial service or name a maker the app
recognises; the rest are hidden behind a toggle that carries the count, so the
filter is never silent. Name matching is a heuristic that affects ordering and
labels only — an unrecognised device is still listed and still connectable.

**The antenna lever arm is a first-class setting.** A pole-mounted rover sits a
fixed offset above and behind the phone. Ignoring it shifts every point in the
capture by exactly that amount — it does not average out, and it is invisible in
the residuals because it moves everything identically.

**RCS is not written.** Autodesk's ReCap formats are proprietary with no
published specification. The export sheet says so and gives the exact E57 → ReCap
steps instead. A guessed binary that fails to open would be worse than an honest
absence.

## Layout

```
PIXMYD/
  App/        entry point and tab shell
  Capture/    ARKit session, frame selection, bundle writer, live preview
  Projects/   on-disk project store and detail
  Survey/     point collections, PNEZD import
  Account/    settings, RTK profiles
  RTK/        GNSS manager, NMEA parsing, NTRIP client, receiver scan and links
  Export/     TSDF fusion, marching tetrahedra, format writers
  Model/      the capture bundle schema
  Design/     theme and shared components
```

`Model/CaptureBundle.swift` must stay byte-compatible with
`packages/core/src/bundle.ts`, and `Export/TsdfVolume.swift` mirrors
`packages/recon`. Those two pairings are the reason a capture from the phone and
one from the studio are interchangeable — if they drift, that stops being true.

## Before trusting it

Nothing here has run on hardware. In rough order of what would bite first:

1. **The UI and framework layer has not been compiled.** The arithmetic is
   tested; everything that imports SwiftUI, ARKit, CoreLocation, Metal or
   Network has only been parsed. Expect real errors on the first Xcode build,
   particularly from `SWIFT_STRICT_CONCURRENCY: complete`.
2. **Frame-selection thresholds are derived, not measured.** The geometry is
   sound; whether 90% overlap at 2 m gives good reconstructions on a real
   jobsite is an empirical question nobody has answered yet.
3. **External Accessory support is unverified.** The protocol strings in
   `Info.plist` are the published ones for Emlid, Bad Elf and Trimble, but MFi
   receivers vary and none has been tested.
4. **No radio in the scan has met a real receiver.** The bookkeeping behind it
   is tested on Linux — merging repeated sightings, expiry, endpoint parsing,
   stream classification, line reassembly — but which BLE service a given
   receiver actually exposes, and whether it advertises any Bonjour type at
   all, is a question only hardware answers. The generic fallback (any
   characteristic that can notify) and the typed `host:port` exist because that
   answer varies by make.
5. **The NTRIP client speaks NTRIP v1 only.** Enough for most casters, not all.
6. **On-device fusion has no measured performance.** The time estimates in the
   export sheet are stated as rough and are currently guesses.
7. **No accuracy validation.** The registration bands come from construction
   practice, but no capture from this app has been checked against a control
   network.
