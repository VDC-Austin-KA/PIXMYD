// swift-tools-version:5.9

// A SwiftPM view of the parts of the iOS app that are pure arithmetic, so they
// can be compiled and tested on Linux CI rather than only by running the app on
// a phone.
//
// This is NOT how the app is built. Xcode builds from project.yml via XcodeGen
// and compiles every file under PIXMYD/. This manifest deliberately compiles a
// subset — the files whose only imports are Foundation and simd — and points
// the test target at the same PIXMYDTests directory the Xcode unit-test bundle
// uses, so one set of tests serves both.
//
// The library target is named PIXMYD so that `@testable import PIXMYD` resolves
// identically here and in Xcode.

import PackageDescription

// The files below have no UIKit, SwiftUI, ARKit, Combine or CoreLocation in
// them, by construction rather than by accident: everything that touches a
// framework lives behind a boundary, and these are what is left. Adding an
// import of a Darwin-only framework to one of these files will break the Linux
// build, which is the point.
let portableSources = [
    "Model/CaptureBundle.swift",
    "Model/ScanMode.swift",
    "Model/CaptureSettings.swift",
    "Model/ProcessingPresets.swift",
    "Geo/Registration.swift",
    "Interop/NavContracts.swift",
    "Interop/QrPayload.swift",
    "Interop/NavBundleStore.swift",
    "Interop/CaptureExport.swift",
    "Interop/NavTransfer.swift",
    "Export/Exporters.swift",
    "Export/TsdfVolume.swift",
    "Export/MeshSimplify.swift",
    "Export/MeshEditing.swift",
    "Export/MeshArchive.swift",
    "Export/ProcessedArtifact.swift",
    "Export/WebPageExport.swift",
    "RTK/NmeaAssembler.swift",
]

// The rest of the app: SwiftUI screens, the ARKit session, the CoreLocation and
// Network clients, and the pipeline that drives them. Xcode compiles these;
// SwiftPM cannot, because the frameworks do not exist off Apple platforms.
let unportableFiles = [
    "Info.plist",
    "Account/AccountView.swift",
    "App/PIXMYDApp.swift",
    "Capture/ARSessionController.swift",
    "Capture/CaptureSheets.swift",
    "Capture/CaptureView.swift",
    "Capture/CaptureWriter.swift",
    "Capture/LivePointCloudView.swift",
    "Capture/SceneMeshOverlay.swift",
    "Design/Theme.swift",
    "Export/ExportSheet.swift",
    "Interop/NavTransferClient.swift",
    "Interop/QrScannerView.swift",
    "Interop/SiteStore.swift",
    "Interop/CaptureUpload.swift",
    "Interop/MarkerAlignView.swift",
    "Interop/SiteView.swift",
    "Interop/SiteBundleView.swift",
    "Interop/NavPointDetailView.swift",
    "Interop/TransferView.swift",
    "Export/ModelViewer.swift",
    "Export/ProcessingPipeline.swift",
    "Export/SceneMeshView.swift",
    "Projects/ProjectStore.swift",
    "Projects/ProjectsView.swift",
    "RTK/GnssManager.swift",
    "RTK/NtripClient.swift",
    "Survey/SurveyView.swift",
]

#if os(Linux)
let simdCompat: [Target] = [.target(name: "simd", path: "Compat/simd")]
let simdDependency: [Target.Dependency] = ["simd"]
#else
// Apple platforms have the real simd; shadowing it with a target of the same
// name would be a genuine hazard, so the shim is not even declared.
let simdCompat: [Target] = []
let simdDependency: [Target.Dependency] = []
#endif

let package = Package(
    name: "PIXMYD",
    products: [
        .library(name: "PIXMYD", targets: ["PIXMYD"]),
    ],
    targets: simdCompat + [
        .target(
            name: "PIXMYD",
            dependencies: simdDependency,
            path: "PIXMYD",
            // Everything not in `sources` still has to be excluded, or SwiftPM
            // warns about 17 unhandled files on every build.
            exclude: unportableFiles,
            sources: portableSources
        ),
        .testTarget(
            name: "PIXMYDTests",
            dependencies: ["PIXMYD"] + simdDependency,
            path: "PIXMYDTests"
        ),
    ]
)
