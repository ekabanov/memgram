import SwiftUI
import OSLog

private let log = Logger.make("App")

@main
struct MemgramMobileApp: App {
    init() {
        log.info("Memgram Mobile launched — v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public)")
        CloudSyncEngine.shared.start()
        log.info("CloudSync started")
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                MobileMeetingListView()
                    .tabItem {
                        Label("Meetings", systemImage: "rectangle.stack")
                    }
                MobileSettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
        }
    }
}
