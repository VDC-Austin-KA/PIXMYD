import ARKit
import SwiftUI

/// The capture screen.
///
/// Layout follows the shape a field user already expects from this class of
/// app: signal quality top-left, tools top-right, the shutter bottom-centre
/// with the frame counter beside it, live preview toggle to one side.
///
/// The deliberate departure is that **the accuracy state is always on screen**,
/// not behind a tap. A scan georeferenced from a float RTK solution looks
/// identical to one from a fixed solution, and is decimetres out. The user has
/// to be able to see which one they are getting without looking for it.
struct CaptureView: View {
    @EnvironmentObject private var gnss: GnssManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var survey: SurveyStore
    @EnvironmentObject private var router: AppRouter

    @StateObject private var controller = ARSessionController()

    @State private var showLivePreview = false
    /// Live scene mesh, on by default.
    ///
    /// Coverage is the question someone is actually asking while they walk a
    /// site — "have I got that corner?" — and until now the only way to answer
    /// it was to finish, export, and look. Starting with it visible makes that
    /// the normal way to scan rather than a setting to discover.
    @State private var meshStyle: SceneMeshOverlay.Style? = .coverage
    @State private var showTools = false
    @State private var showSaveSheet = false
    @State private var showCancelConfirm = false
    @State private var pendingProject: CaptureProject?
    @State private var errorMessage: String?
    @State private var projectName = ""

    var body: some View {
        ZStack {
            if ARSessionController.isSupported {
                ARViewContainer(session: controller.session, meshStyle: meshStyle)
                    .ignoresSafeArea()

                if showLivePreview {
                    LivePointCloudView(points: controller.previewPoints)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                overlay
            } else {
                unsupported
            }
        }
        .background(Theme.Palette.background)
        .onAppear { controller.start(settings: settings.capture) }
        .onDisappear { controller.stop() }
        .sheet(isPresented: $showTools) {
            ToolsSheet(controller: controller)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveCaptureSheet(
                project: pendingProject,
                onKeep: { name in
                    if let pendingProject {
                        projects.add(pendingProject.renamed(to: name))
                    }
                    pendingProject = nil
                },
                onDiscard: {
                    if let pendingProject { projects.delete(pendingProject) }
                    pendingProject = nil
                },
                onKeepAndReview: { name in
                    guard let pendingProject else { return }
                    let kept = pendingProject.renamed(to: name)
                    projects.add(kept)
                    self.pendingProject = nil
                    router.open(kept, autoReview: true)
                }
            )
        }
        .alert("Capture problem", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Discard this capture?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard capture", role: .destructive) {
                Task { await controller.cancelRecording() }
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Everything captured so far will be deleted. This cannot be undone.")
        }
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if controller.isRecording { coverageBar }
            bottomBar
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.bottom, Theme.Metrics.gutterTight)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.gutterTight) {
            SignalQualityBadge(fix: gnss.currentFix, state: gnss.connectionState)

            Spacer()

            trackingBadge

            meshButton

            Button {
                showTools = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: Theme.Metrics.minimumTapTarget,
                           height: Theme.Metrics.minimumTapTarget)
                    .foregroundStyle(Theme.Palette.text)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("Tools")
        }
        .padding(.top, Theme.Metrics.gutterTight)
    }

    /// Cycles the live mesh: coverage wireframe, surface colours, off.
    ///
    /// A cycle rather than a menu because it is used mid-scan, one-handed,
    /// while holding a phone at arm's length — three states are faster to step
    /// through than to pick from.
    private var meshButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                meshStyle = switch meshStyle {
                case .coverage: .classification
                case .classification: nil
                case nil: .coverage
                }
            }
        } label: {
            Image(systemName: meshStyle == nil ? "grid" : "square.grid.3x3.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: Theme.Metrics.minimumTapTarget,
                       height: Theme.Metrics.minimumTapTarget)
                .foregroundStyle(meshStyle == nil ? Theme.Palette.textSecondary : Theme.Palette.text)
                .background(.black.opacity(0.55), in: Circle())
        }
        .disabled(!ARSessionController.hasLiDAR)
        .opacity(ARSessionController.hasLiDAR ? 1 : 0.35)
        .accessibilityLabel(meshAccessibilityLabel)
    }

    /// A `switch` expression is only allowed in a return, a throw, or the right
    /// side of an assignment — not inline as an argument.
    private var meshAccessibilityLabel: String {
        switch meshStyle {
        case .coverage: return "Scene mesh: coverage. Tap for surface colours."
        case .classification: return "Scene mesh: surfaces. Tap to hide."
        case nil: return "Scene mesh hidden. Tap to show coverage."
        }
    }

    private var trackingBadge: some View {
        let state = controller.trackingState
        let tone: Readout.Tone = switch state {
        case .normal: .good
        case .limited, .relocalizing: .caution
        case .initializing: .neutral
        case .unavailable: .bad
        }
        let icon = switch state {
        case .normal: "checkmark.circle.fill"
        case .limited: "exclamationmark.triangle.fill"
        case .relocalizing: "arrow.triangle.2.circlepath"
        case .initializing: "circle.dotted"
        case .unavailable: "xmark.octagon.fill"
        }
        return StatusChip(text: state.label, tone: tone, systemImage: icon)
            .padding(.top, 6)
    }

    /// Shown only while recording. Frame count, distance walked, and a live
    /// warning when tracking degrades — the things that tell a user whether to
    /// keep walking or go back over a stretch.
    private var coverageBar: some View {
        HStack(spacing: Theme.Metrics.gutter) {
            Readout(label: "Frames", value: "\(controller.capturedFrameCount)")
            Readout(label: "Walked", value: String(format: "%.1f", controller.pathLength), unit: "m")
            if ARSessionController.hasLiDAR {
                Readout(
                    label: "Points",
                    value: formatCount(controller.estimatedPointCount)
                )
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .padding(.bottom, Theme.Metrics.gutterTight)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            // Live preview toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLivePreview.toggle() }
            } label: {
                Image(systemName: showLivePreview ? "eye.fill" : "eye")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(showLivePreview ? Theme.Palette.accent : Theme.Palette.text)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel(showLivePreview ? "Hide live point cloud" : "Show live point cloud")
            .disabled(!ARSessionController.hasLiDAR)
            .opacity(ARSessionController.hasLiDAR ? 1 : 0.35)

            Spacer()

            shutter

            Spacer()

            if controller.isRecording {
                Button {
                    showCancelConfirm = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .foregroundStyle(Theme.Palette.bad)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel("Discard capture")
            } else {
                Color.clear.frame(width: 56, height: 56)
            }
        }
    }

    private var shutter: some View {
        VStack(spacing: 6) {
            if controller.isRecording {
                HStack(spacing: 12) {
                    // Pause / resume
                    Button {
                        controller.isPaused ? controller.resumeRecording() : controller.pauseRecording()
                    } label: {
                        Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 52, height: 52)
                            .foregroundStyle(Theme.Palette.text)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(controller.isPaused ? "Resume" : "Pause")

                    // Save
                    Button { finish() } label: {
                        ZStack {
                            Circle()
                                .fill(controller.isPaused ? Theme.Palette.surfaceRaised : Theme.Palette.recording)
                                .frame(width: Theme.Metrics.shutterDiameter,
                                       height: Theme.Metrics.shutterDiameter)
                            Image(systemName: "square.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3)
                                .frame(width: Theme.Metrics.shutterDiameter + 10,
                                       height: Theme.Metrics.shutterDiameter + 10)
                        )
                    }
                    .accessibilityLabel("Stop and save")
                }
            } else {
                Button { begin() } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white.opacity(0.9), lineWidth: 4)
                            .frame(width: Theme.Metrics.shutterDiameter + 10,
                                   height: Theme.Metrics.shutterDiameter + 10)
                        Circle()
                            .fill(Theme.Palette.recording)
                            .frame(width: Theme.Metrics.shutterDiameter,
                                   height: Theme.Metrics.shutterDiameter)
                    }
                }
                .accessibilityLabel("Start capture")
                .disabled(!controller.trackingState.isUsable)
                .opacity(controller.trackingState.isUsable ? 1 : 0.4)
            }

            if !controller.trackingState.isUsable && !controller.isRecording {
                Text("Move the phone slowly until tracking settles")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
    }

    private var unsupported: some View {
        UnavailableNotice(
            title: "This device cannot scan",
            detail: "PIXMYD needs ARKit world tracking, which this device does not "
                + "provide. Captures made on another device can still be opened and "
                + "exported here.",
            systemImage: "iphone.slash"
        )
        .padding(Theme.Metrics.gutter)
    }

    // MARK: - Actions

    private func begin() {
        do {
            let name = projects.suggestedName()
            try controller.beginRecording(projectName: name)
            projectName = name
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        Task {
            do {
                let project = try await controller.finishRecording()
                pendingProject = project
                showSaveSheet = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - AR view

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    /// Nil draws no scene mesh at all.
    var meshStyle: SceneMeshOverlay.Style?

    func makeCoordinator() -> SceneMeshOverlay { SceneMeshOverlay() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        // The only scene content is the live mesh, added by the coordinator as
        // ARKit reports anchors. Every other overlay is drawn in SwiftUI on
        // top, which keeps them legible and testable.
        view.scene = SCNScene()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.isEnabled = meshStyle != nil
        if let meshStyle { context.coordinator.style = meshStyle }
    }
}

// MARK: - Signal quality

/// GNSS state, always visible.
///
/// The label is the fix type in words, not a bar count. "RTK float" and
/// "RTK fixed" both show four bars on every receiver's own display, and they
/// differ by two orders of magnitude in accuracy.
struct SignalQualityBadge: View {
    let fix: GnssFix?
    let state: GnssManager.ConnectionState

    var body: some View {
        Button {} label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typeface.label(13, weight: .semibold))
                    if let accuracy {
                        Text(accuracy)
                            .font(Theme.Typeface.numeric(11))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .foregroundStyle(tone.color)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(tone.color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Position quality: \(title). \(accuracy ?? "no accuracy reported")")
    }

    private var title: String {
        switch state {
        case .disconnected: "No receiver"
        case .searching: "Searching"
        case .connected: fix?.quality.label ?? "No fix"
        }
    }

    private var accuracy: String? {
        guard let fix else { return nil }
        if let h = fix.hAccuracy {
            return String(format: "±%.3f m H", h)
        }
        // HDOP is a geometry factor, not an accuracy. Labelling it as one would
        // be a lie the user cannot detect, so it is labelled as what it is.
        if let hdop = fix.hdop { return String(format: "HDOP %.1f", hdop) }
        return nil
    }

    private var tone: Readout.Tone {
        guard case .connected = state, let fix else { return .bad }
        if fix.quality.isSurveyGrade { return .good }
        if fix.quality == .rtkFloat || fix.quality == .dgps { return .caution }
        return .bad
    }

    private var icon: String {
        switch state {
        case .disconnected: "antenna.radiowaves.left.and.right.slash"
        case .searching: "antenna.radiowaves.left.and.right"
        case .connected: fix?.quality.isSurveyGrade == true ? "location.fill" : "location"
        }
    }
}
