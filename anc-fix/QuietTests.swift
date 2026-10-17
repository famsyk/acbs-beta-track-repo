import Foundation

@MainActor
final class QuietMock {
    var mode = 3
    var level: UInt8 = 0
    var starts = 0
    var startedSlots: [UInt8] = []
    var refuse = false
    var omitStartResult = false
    var noSettings = false
    var isBadSettings = false
    func exchange(_ p: BMAPPacket, _ drain: Bool, _ timeout: Duration) async throws -> [BMAPPacket] {
        if p.functionBlock == 31 && p.function == 3 {
            if p.operation == BMAPOperator.start.rawValue {
                starts += 1
                startedSlots.append(p.payload.first ?? 255)
                if !refuse { mode = Int(p.payload.first ?? 255) }
                if omitStartResult { throw BMAPError.unsupported("missing RESULT") }
                return [BMAPPacket(31, 3, .result)]
            }
            return [BMAPPacket(31, 3, .status, payload: Data([UInt8(mode)]))]
        }
        if p.functionBlock == 31 && p.function == 6 {
            if noSettings { throw BMAPError.unsupported("unsupported") }
            var data = [UInt8](repeating: 0, count: 48)
            data[0] = 0
            data[42] = isBadSettings ? 5 : level
            return [BMAPPacket(31, 6, .status, payload: Data(data))]
        }
        throw BMAPError.unsupported("unexpected request")
    }
}

@main
struct QuietTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("TEST FAILED: " + message) }
    }
    @MainActor
    static func main() async throws {
        let m = QuietMock()
        let first = try await BMAPQuietControl.apply(force: true, exchange: m.exchange)
        check(m.startedSlots == [0] && first.slot == 0, "force must select factory Quiet without catalogue")
        check(first.config?.cncLevel == 0 && first.config?.autoCNC == false, "read-back confirms maximum")
        _ = try await BMAPQuietControl.apply(force: false, exchange: m.exchange)
        check(m.starts == 1, "stable Quiet must not be rewritten")
        m.mode = 4
        _ = try await BMAPQuietControl.apply(force: false, exchange: m.exchange)
        check(m.mode == 0 && m.starts == 2, "mode drift must be restored")
        m.omitStartResult = true
        _ = try await BMAPQuietControl.apply(force: true, exchange: m.exchange)
        check(m.mode == 0, "START timeout may still succeed by read-back")
        m.noSettings = true
        let modeOnly = try await BMAPQuietControl.apply(force: true, exchange: m.exchange)
        check(modeOnly.config == nil, "unsupported setting read must not fake CNC verification")
        m.noSettings = false
        m.isBadSettings = true
        do {
            _ = try await BMAPQuietControl.apply(force: true, exchange: m.exchange)
            fatalError("Bad ANC setting must not be claimed as maximum")
        } catch {}
        m.isBadSettings = false; m.refuse = true; m.mode = 4
        do {
            _ = try await BMAPQuietControl.apply(force: true, exchange: m.exchange)
            fatalError("Refused Quiet switch must not be claimed successful")
        } catch {}
        let window = BMAPDrainWindow()
        var fired = 0
        window.reset(after: .milliseconds(500)) { fired += 1 }
        window.reset(after: .milliseconds(500)) { fired += 1 }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(80))
        check(fired == 0, "cancelling previous timer must not prematurely finish mode dump")
        try await Task.sleep(for: .milliseconds(550))
        check(fired == 1, "only the newest complete quiet window may fire")
        window.reset(after: .milliseconds(50)) { fired += 1 }
        window.cancel()
        try await Task.sleep(for: .milliseconds(100))
        check(fired == 1, "explicit cancellation must not fire")
        print("PASS: Quiet without catalogue, verified ANC, drift restoration, no redundant writes, START timeout read-back, unsupported settings, rejection, bad ANC values, cancelled drain timers")
    }
}
