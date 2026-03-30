import SwiftUI
import UIKit
import OSLog

private let log = Logger.make("App")

/// UIApplicationDelegate adaptor for push notification registration.
/// CKSyncEngine relies on silent pushes to trigger fetches when
/// another device writes records to the shared CloudKit zone.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        log.info("Registered for remote notifications")
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.info("Push token received (\(deviceToken.count) bytes)")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("Push registration failed: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        log.info("Remote notification received — triggering CloudKit fetch")
        // CKSyncEngine with automaticallySync=true handles this internally,
        // but we ensure a fetch happens by calling fetchNow as well.
        Task {
            await CloudSyncEngine.shared.fetchNow()
            completionHandler(.newData)
        }
    }
}

@main
struct MemgramMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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

        // Start WatchConnectivity to receive Watch recordings
        _ = PhoneSessionManager.shared
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
