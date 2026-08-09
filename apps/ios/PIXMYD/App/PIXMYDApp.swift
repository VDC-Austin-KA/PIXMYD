import SwiftUI

@main
struct PIXMYDApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var gnss = GnssManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var survey = SurveyStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(projectStore)
                .environmentObject(gnss)
                .environmentObject(settings)
                .environmentObject(survey)
                .preferredColorScheme(.dark)
                .tint(Theme.Palette.accent)
        }
    }
}

/// Four tabs: Capture, Projects, Survey, Account.
///
/// Capture is first and is the default, because the overwhelmingly common
/// reason to open this app is that the user is already standing in front of the
/// thing they intend to scan.
struct RootView: View {
    @State private var tab: Tab = .capture

    enum Tab: Hashable {
        case capture, projects, survey, account
    }

    var body: some View {
        TabView(selection: $tab) {
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
