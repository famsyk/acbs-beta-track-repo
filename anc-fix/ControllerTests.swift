import Foundation

// This harness compiles the actual BoseController + BoseBMAP files on macOS.
// Only CoreBluetooth, UIKit/AccessorySetupKit and file logging are mocked.
enum BoseBLEError: Error { case notConnected, pairingRequired, busy }
@MainActor protocol BoseTransport: AnyObject {
    var connectedName: String? { get }
    var isReady: Bool { get }
    func connect() async throws
    func disconnect()
    func exchange(_ p: BMAPPacket, drain: Bool, timeout: Duration) async throws -> [BMAPPacket]
}
@MainActor final class BoseDiagnostics {
    static let shared = BoseDiagnostics()
    func event(_ a: String, _ b: String) {}
    func checkpoint(_ a: String, detail: String = "") {}
}
@MainActor final class BoseAccessorySetupManager {
    static let shared = BoseAccessorySetupManager()
    func prepareAndShowPairing() async -> Result<Void, Error> { .failure(BoseBLEError.notConnected) }
}
@MainActor final class BoseBLETransport: BoseTransport {
    var onModeUpdate: ((Int) -> Void)?
    var connectedName: String? { "Synthetic Bose" }
    var isReady = false
    var mode = 3
    var starts = 0
    var active = 0
    var maxConcurrent = 0
    func connect() async throws { isReady = true }
    func disconnect() { isReady = false }
    func prepareForAccessorySetup() { disconnect() }
    func restoreAfterAccessorySetup() {}
    func record(_ slot: UInt8) -> BMAPPacket {
        var b = [UInt8](repeating: 0, count: 48)
        b[0] = slot
        if slot != 0 { b[3] = 1; b[4] = 1 }
        let name = Array((slot == 0 ? "Quiet" : "Custom").utf8)
        b.replaceSubrange(6..<(6+name.count), with: name)
        return BMAPPacket(31, 6, .status, payload: Data(b))
    }
    func exchange(_ p: BMAPPacket, drain: Bool, timeout: Duration) async throws -> [BMAPPacket] {
        guard isReady else { throw BoseBLEError.notConnected }
        active += 1; maxConcurrent = max(active, maxConcurrent)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        if p.functionBlock == 31, p.function == 3 {
            if p.operation == BMAPOperator.start.rawValue {
                starts += 1; mode = Int(p.payload.first ?? 255)
                return [BMAPPacket(31, 3, .result)]
            }
            return [BMAPPacket(31, 3, .status, payload: Data([UInt8(mode)]))]
        }
        if p.functionBlock == 31, p.function == 6 { return [record(p.payload.first ?? 0)] }
        if p.functionBlock == 31, p.function == 1 { return [record(3), record(3)] }
        throw BMAPError.unsupported("synthetic optional feature unsupported")
    }
}

@main struct ControllerTests {
    @MainActor static func waitFor(_ done: () -> Bool) async throws {
        for _ in 0..<500 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Controller did not complete within five seconds")
    }
    @MainActor static func main() async throws {
        let suite = "BoseTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ble = BoseBLETransport()
        let c = BoseController(bluetooth: ble, preferences: defaults)
        precondition(c.maxANCLockEnabled, "Maximum lock defaults ON for this build")
        c.setForeground(true)
        c.start()
        try await waitFor { !c.isBusy }
        precondition(ble.mode == 0 && c.state.modeIndex == 0, "Startup restores Quiet")
        precondition(c.state.profiles.contains { $0.id == 0 }, "Partial dump must retain confirmed Quiet")
        precondition(c.state.profiles.filter { $0.id == 3 }.count == 1, "No duplicate IDs")
        c.setMode("Custom", announce: false)
        c.setCNC(10)
        precondition(ble.mode == 0 && !c.isBusy, "Lock blocks contradictory changes")
        c.setForeground(false)
        ble.mode = 4
        c.setForeground(true)
        try await waitFor { ble.mode == 0 && !c.isBusy }
        c.setMaxANCLock(false)
        precondition(defaults.object(forKey: "boseMaximumANCLock") as? Bool == false)
        c.stop()
        try await Task.sleep(for: .milliseconds(50))

        let ble2 = BoseBLETransport()
        let c2 = BoseController(bluetooth: ble2, preferences: defaults)
        precondition(!c2.maxANCLockEnabled, "Lock preference persists")
        c2.start()
        precondition(c2.isBusy)
        c2.activateMaxQuiet()
        c2.activateMaxQuiet()
        precondition(c2.quietRequestPending, "Busy requests must be queued, not dropped")
        try await waitFor { !c2.quietRequestPending && !c2.isBusy }
        precondition(ble2.mode == 0 && ble2.starts == 1, "Repeated priority taps coalesce")
        precondition(ble2.maxConcurrent == 1, "Only one GATT exchange at a time")
        c2.stop()
        print("PASS: actual controller startup lock, retained Quiet, unique modes, lock guardrails, foreground restore, persistence, priority busy queue, coalescing, serialized GATT")
    }
}
