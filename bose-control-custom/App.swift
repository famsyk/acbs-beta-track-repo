import SwiftUI
import UIKit

@main
struct BoseHeadphonesControlApp: App {
    @StateObject private var controller = BoseController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize disk logging before any Bluetooth or UI work.
        BoseDiagnostics.shared.event("APP", "BoseHeadphonesControlApp.init entered")
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onAppear {
                    BoseDiagnostics.shared.event("UI", "Root ContentView appeared")
                    updateIdleTimer()
                }
                .onChange(of: scenePhase) { _, nextPhase in
                    BoseDiagnostics.shared.setLifecycle(String(describing: nextPhase))
                    updateIdleTimer()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                    updateIdleTimer()
                }
        }
    }

    private func updateIdleTimer() {
        let batteryState = UIDevice.current.batteryState
        let isCharging = batteryState == .charging || batteryState == .full
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && isCharging
    }
}
