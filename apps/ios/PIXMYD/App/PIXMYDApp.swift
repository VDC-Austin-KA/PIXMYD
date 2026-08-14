import SwiftUI

@main
struct PIXMYDApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var gnss = GnssManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var survey = SurveyStore()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(projectStore)
                .environmentObject(gnss)
                .environmentObject(settings)
                .environmentObject(survey)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.Palette.accent)
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

/// Four tabs: Capture, Projects, Survey, Account.
///
/// Capture is first and is the default, because the overwhelmingly common
/// reason to open this app is that the user is already standing in front of the
/// thing they intend to scan.
struct RootView: View {
    @State private var tab: Tab = .capture
    @EnvironmentObject private var router: AppRouter

    enum Tab: Hashable {
        case capture, projects, survey, account
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "viewfinder") }
                .tag(Tab.capture)

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
                .tag(Tab.projects)

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
