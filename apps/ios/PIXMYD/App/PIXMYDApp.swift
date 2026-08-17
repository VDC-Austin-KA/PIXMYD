import SwiftUI

@main
struct PIXMYDApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var gnss = GnssManager()
    /// Owned by the app rather than by the scan screen.
    ///
    /// The scanner holds the one `CBCentralManager` in the app, and CoreBluetooth
    /// tears down every connection that manager opened when it goes away. If the
    /// scan screen owned it, connecting a receiver and then dismissing the sheet
    /// would drop the link — and the delegate callbacks that would have reported
    /// the drop would have gone with it.
    @StateObject private var receiverScanner = ReceiverScanner()
    @StateObject private var settings = AppSettings()
    @StateObject private var survey = SurveyStore()
    @StateObject private var router = AppRouter()
    @StateObject private var site = SiteStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(projectStore)
                .environmentObject(gnss)
                .environmentObject(receiverScanner)
                .environmentObject(settings)
                .environmentObject(survey)
                .environmentObject(router)
                .environmentObject(site)
                .preferredColorScheme(.dark)
                .tint(Theme.Palette.accent)
                // Nothing was starting the position manager, so CoreLocation
                // was never asked for authorisation and an MFi receiver already
                // attached was never picked up — every capture fell back to no
                // georeference at all. It starts with the app and runs for its
                // lifetime; it is deliberately not stopped when a screen goes
                // away, because a receiver connected on the capture screen has
                // to survive a trip to the Projects tab.
                .task { gnss.start() }
        }
    }
}

/// Cross-tab navigation: the Capture tab asks the Projects tab to open a
/// project, and the Projects tab's own navigation stack is the only thing
/// that can answer. Everything goes through here so the two never have to
/// know about each other.
@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: RootView.Tab = .capture
    /// The Projects stack. Owned here so Capture can push onto it.
    @Published var path = NavigationPath()
    /// A pending request from outside the Projects tab, e.g. "I just finished
    /// this capture, open it and start showing it to me."
    @Published private(set) var reviewRequest: ReviewRequest?

    struct ReviewRequest: Equatable {
        let project: CaptureProject
        /// When true the detail view should start processing immediately and
        /// open the review viewer when the result is ready.
        let autoReview: Bool
    }

    /// Switch to Projects and push a project's detail. `autoReview` starts
    /// the process-and-review flow without a second tap.
    func open(_ project: CaptureProject, autoReview: Bool = false) {
        selectedTab = .projects
        path.append(project)
        reviewRequest = ReviewRequest(project: project, autoReview: autoReview)
    }

    func clearReviewRequest(projectID: String) {
        guard reviewRequest?.project.id == projectID else { return }
        reviewRequest = nil
    }
}

/// Five tabs: Capture, Projects, Site, Survey, Account.
///
/// Capture is first and is the default, because the overwhelmingly common
/// reason to open this app is that the user is already standing in front of the
/// thing they intend to scan.
struct RootView: View {
    @State private var tab: Tab = .capture
    @EnvironmentObject private var router: AppRouter

    enum Tab: Hashable {
        case capture, projects, site, survey, account
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "viewfinder") }
                .tag(Tab.capture)

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
                .tag(Tab.projects)

            SiteView()
                .tabItem { Label("Site", systemImage: "building.2") }
                .tag(Tab.site)

            SurveyView()
                .tabItem { Label("Survey", systemImage: "mappin.and.ellipse") }
                .tag(Tab.survey)

            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(Tab.account)
        }
        .background(Theme.Palette.background)
    }
}
