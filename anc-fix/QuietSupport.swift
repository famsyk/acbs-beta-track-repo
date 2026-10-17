
// MARK: - Quiet controls independent of the mode catalogue

/// Cancellation must not run an old quiet-period completion. An older build
/// swallowed CancellationError, truncating a dump as soon as its next packet arrived.
@MainActor
final class BMAPDrainWindow {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func reset(after delay: Duration, fire: @escaping @MainActor () -> Void) {
        cancel()
        let expected = generation
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.task = nil
            fire()
        }
    }
}

struct BMAPQuietConfirmation {
    let slot: Int
    let config: BMAPModeConfig?
    let commandSent: Bool
}

@MainActor
enum BMAPQuietControl {
    // Factory Quiet slot confirmed by the supplied device log. This is not an
    // editable mode or an invented catalogue entry; read-back is mandatory.
    static let factorySlot = 0

    static func apply(
        slot: Int = 0,
        force: Bool,
        exchange: (BMAPPacket, Bool, Duration) async throws -> [BMAPPacket],
        log: (String) -> Void = { _ in }
    ) async throws -> BMAPQuietConfirmation {
        guard (0...255).contains(slot) else { throw BMAPError.malformedPacket }
        func currentMode() async throws -> Int {
            let replies = try await exchange(BMAPPacket(31, 3, .get), false, .seconds(3))
            guard let first = replies.first else { throw BMAPError.malformedPacket }
            let reply = try checked(first)
            guard let value = reply.payload.first else { throw BMAPError.malformedPacket }
            return Int(value)
        }
        func config() async -> BMAPModeConfig? {
            do {
                let replies = try await exchange(BMAPPacket(31, 6, .get, payload: Data([UInt8(slot)])), false, .seconds(2))
                guard let reply = replies.first,
                      let result = BMAPModeConfig.parse(try checked(reply).payload),
                      result.index == slot, result.layout == .status47 || result.layout == .status48
                else { return nil }
                return result
            } catch {
                log("Quiet settings read-back unavailable: \(error.localizedDescription)")
                return nil
            }
        }
        let initial = force ? nil : try? await currentMode()
        var shouldSend = force || initial != slot
        var details: BMAPModeConfig?
        if !shouldSend {
            details = await config()
            if let details, details.cncLevel != 0 || details.autoCNC { shouldSend = true }
        }
        if shouldSend {
            try Task.checkCancellation()
            log("SEND Quiet slot=\(slot), force=\(force)")
            do {
                let replies = try await exchange(BMAPPacket(31, 3, .start, payload: Data([UInt8(slot), 0])), false, .seconds(2))
                for reply in replies { _ = try checked(reply) }
            } catch {
                // START may apply successfully without RESULT. Never call it a
                // success until a subsequent GET confirms the actual mode.
                log("START response: \(error.localizedDescription); checking actual mode")
            }
            var confirmed = false
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if attempt > 0 { try await Task.sleep(for: .milliseconds(200)) }
                do {
                    let actual = try await currentMode()
                    log("VERIFY attempt=\(attempt + 1) actual=\(actual) expected=\(slot)")
                    if actual == slot { confirmed = true; break }
                } catch { log("VERIFY failed: \(error.localizedDescription)") }
            }
            guard confirmed else {
                throw BMAPError.unsupported("Quietへの切替を端末から確認できませんでした。再接続して再適用してください。")
            }
            details = await config()
        }
        if let details, details.cncLevel != 0 || details.autoCNC {
            throw BMAPError.unsupported("Quietは選択されましたが、最大ANC設定（CNC=0・自動調整OFF）を確認できませんでした。")
        }
        log("CONFIRMED slot=\(slot) settingReadback=\(details != nil) commandSent=\(shouldSend)")
        return BMAPQuietConfirmation(slot: slot, config: details, commandSent: shouldSend)
    }
}
