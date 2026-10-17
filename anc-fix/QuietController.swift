
// MARK: - Foreground maximum-ANC lock and priority Quiet action
extension BoseController {
    func activateQuiet() { enqueueQuiet(reason: "Quiet button") }
    func activateMaxQuiet() { enqueueQuiet(reason: "force maximum ANC") }

    func setMaxANCLock(_ enabled: Bool) {
        maxANCLockEnabled = enabled
        preferences.set(enabled, forKey: "boseMaximumANCLock")
        BoseDiagnostics.shared.event("ANC LOCK", "enabled=\(enabled)")
        if enabled { enqueueQuiet(reason: "lock enabled") }
        else { maxANCStatus = "固定OFF（Quietへの手動切替は可能）" }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        lockMonitor?.cancel()
        lockMonitor = nil
        if active {
            beginLockMonitor()
        } else {
            BoseDiagnostics.shared.event("ANC LOCK", "foreground monitoring paused; existing device setting retained")
        }
    }

    private func beginLockMonitor() {
        guard controllerStarted, isForeground, lockMonitor == nil else { return }
        lockMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.maxANCLockEnabled, self.isForeground, !self.isBusy,
                   !self.quietRequestPending, !self.needsBLEPairing {
                    await self.checkMaximumANC()
                }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
    }

    /// Accepted even while a catalogue or settings request is still running.
    /// Only one command sequence runs at a time; repeated taps coalesce.
    private func enqueueQuiet(reason: String) {
        guard quietTask == nil else { return }
        quietRequestPending = true
        maxANCStatus = isBusy ? "Quietを優先予約しました…" : "Quietを適用中…"
        BoseDiagnostics.shared.event("ANC PRIORITY", "queued reason=\(reason), busy=\(isBusy)")
        quietTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.quietRequestPending = false
                self.quietTask = nil
            }
            do {
                while self.isBusy {
                    try await Task.sleep(for: .milliseconds(80))
                }
                try Task.checkCancellation()
                self.isBusy = true
                defer { self.isBusy = false }
                try await self.ensureQuietConnection()
                try await self.applyVerifiedQuiet(force: true)
            } catch {
                self.reportQuietFailure(error)
            }
        }
    }

    private func ensureQuietConnection() async throws {
        if !bluetooth.isReady {
            modesByIndex.removeAll()
            state = NativeHeadphoneState()
            audioSettings = nil
            try await bluetooth.connect()
        }
        state.connected = true
        if let name = bluetooth.connectedName { state.name = name }
    }

    private func checkMaximumANC() async {
        guard maxANCLockEnabled, isForeground, !isBusy, !quietRequestPending else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureQuietConnection()
            // Stable Quiet is read back, not rewritten every 8 seconds.
            try await applyVerifiedQuiet(force: false)
        } catch { reportQuietFailure(error) }
    }

    private func applyVerifiedQuiet(force: Bool) async throws {
        let result = try await BMAPQuietControl.apply(force: force, exchange: { [self] packet, drain, timeout in
            try await bluetooth.exchange(packet, drain: drain, timeout: timeout)
        }, log: { text in BoseDiagnostics.shared.event("ANC VERIFY", text) })
        state.connected = true
        state.modeIndex = result.slot
        state.mode = "Quiet"
        needsBLEPairing = false
        if let config = result.config {
            modesByIndex[config.index] = config
            state.cncLevel = config.cncLevel
            state.autoCNC = config.autoCNC
            state.spatial = config.spatial
            state.windBlock = config.windBlock
            let profile = NativeProfile(id: config.index, name: "Quiet", editable: config.editable,
                configured: config.configured, cncLevel: config.cncLevel, autoCNC: config.autoCNC,
                mutableMask: config.mutableMask, favorite: config.favorite, windBlock: config.windBlock,
                ancToggle: config.ancToggle, spatial: config.spatial)
            state.profiles.removeAll { $0.id == config.index }
            state.profiles.append(profile)
            state.profiles.sort { $0.id < $1.id }
            maxANCStatus = "Quiet・最大ANC確認済み（CNC 0 / 自動調整OFF）"
        } else {
            maxANCStatus = "Quiet切替確認済み（強度値の読戻しは未対応）"
        }
        if result.commandSent { message = maxANCStatus }
        lastQuietVerified = Date()
    }

    private func reportQuietFailure(_ error: Error) {
        maxANCStatus = "未確認: " + error.localizedDescription
        message = maxANCStatus
        BoseDiagnostics.shared.event("ANC ERROR", error.localizedDescription)
        if case BoseBLEError.pairingRequired = error { needsBLEPairing = true }
        if !bluetooth.isReady { state.connected = false }
    }
}
