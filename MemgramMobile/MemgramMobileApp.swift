import SwiftUI
import OSLog

private let log = Logger.make("App")

@main
struct MemgramMobileApp: App {
    init() {
        log.info("Memgram Mobile launched — v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public)")
        CloudSyncEngine.shared.start()
        log.info("CloudSync started")

        if CalendarManager.shared.isEnabled {
            Task {
                _ = await CalendarManager.shared.requestAccess()
                CalendarManager.shared.startMonitoring()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                MobileMeetingListView()
                    .tabItem {
                        Label("Meetings", systemImage: "rectangle.stack")
                    }
                MobileRecordingView()
                    .tabItem {
                        Label("Record", systemImage: "mic.fill")
                    }
                MobileSettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
        }
    }
}
