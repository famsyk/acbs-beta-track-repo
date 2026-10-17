from pathlib import Path
import sys
root = Path(sys.argv[1])
extras = Path(__file__).parent
app = root / 'native-ios/BoseHeadphonesControl'

def load(name): return (app / name).read_text()
def save(name, text): (app / name).write_text(text)
def replace(text, old, new, count=1):
    actual = text.count(old)
    if actual != count:
        raise RuntimeError(f'Expected {count} occurrences, got {actual}: {old[:100]!r}')
    return text.replace(old, new)

# Transport: cancelled timers must stop, and packet bytes must be captured at
# delegate entry rather than after a hop to MainActor.
s = load('BoseBLETransport.swift')
s = s.replace('var quietTask: Task<Void, Never>?', 'var quietWindow: BMAPDrainWindow?')
s = s.replace('request.quietTask?.cancel()', 'request.quietWindow?.cancel()')
s = replace(s, '        request.packets.append(packet)\n        request.quietWindow?.cancel()', '        request.packets.append(packet)')
s = replace(s, 'try? await Task.sleep(for: .seconds(18))', 'do { try await Task.sleep(for: .seconds(18)) } catch { return }')
s = replace(s, 'try? await Task.sleep(for: timeout)', 'do { try await Task.sleep(for: timeout) } catch { return }')
start = s.index('        let id = request.id\n        request.quietTask = Task')
end = s.index('        pending = request', start)
s = s[:start] + '''        // PROCESSING alone is not a completed catalogue. Wait for payloads.
        if packet.operation == BMAPOperator.processing.rawValue {
            pending = request
            return
        }
        let id = request.id
        if request.quietWindow == nil { request.quietWindow = BMAPDrainWindow() }
        request.quietWindow?.reset(after: .milliseconds(750)) { [weak self] in
            guard let self, let current = self.pending, current.id == id else { return }
            self.finishPending(id: id, result: .success(current.packets))
        }
''' + s[end:]
s = replace(s, '        request.packets.append(packet)', '''        guard request.packets.count < 256 else {
            finishPending(id: request.id, result: .failure(BMAPError.unsupported("BMAP response exceeded packet limit")))
            return
        }
        request.packets.append(packet)''')
s = replace(s, '''    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in''', '''    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // CoreBluetooth changes characteristic.value for every notification.
        // Capture NOW: deferring this read can duplicate the newest packet and
        // lose earlier mode slots while the main actor is occupied.
        let capturedValue = characteristic.value.map { Data($0) }
        let capturedUUID = characteristic.uuid
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }''')
s = replace(s, 'guard characteristic.uuid == Self.secureUUID, let value = characteristic.value else { return }',
            'guard capturedUUID == Self.secureUUID, let value = capturedValue else { return }')
s = replace(s, '''    private func closeLink() {
        BoseDiagnostics.shared.event''', '''    private func closeLink() {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            continuation.resume(throwing: BoseBLEError.notConnected)
        }
        BoseDiagnostics.shared.event''')
s = replace(s, '''        Task { @MainActor in
            guard let continuation = writeContinuation else { return }''', '''        Task { @MainActor in
            guard self.peripheral === peripheral, self.characteristic === characteristic,
                  let continuation = writeContinuation else { return }''')
s = replace(s, '''        try await withCheckedThrowingContinuation { continuation in
            writeContinuation = continuation''', '''        guard writeContinuation == nil else { throw BoseBLEError.busy }
        try await withCheckedThrowingContinuation { continuation in
            writeContinuation = continuation''')
s = replace(s, '    private var pending: PendingExchange?', '''    private var pending: PendingExchange?
    var onModeUpdate: ((Int) -> Void)?''')
s = replace(s, '''    private func accept(_ packet: BMAPPacket) {
        guard var request''', '''    private func accept(_ packet: BMAPPacket) {
        if packet.functionBlock == 31, packet.function == 3,
           packet.operation == BMAPOperator.status.rawValue, let slot = packet.payload.first {
            onModeUpdate?(Int(slot))
        }
        guard var request''')
s = replace(s, '''            characteristic = nil
            incoming.reset()
            if let request = pending''', '''            guard self.peripheral === peripheral else { return }
            if let continuation = writeContinuation {
                writeContinuation = nil
                continuation.resume(throwing: BoseBLEError.notConnected)
            }
            characteristic = nil
            incoming.reset()
            if let request = pending''')
save('BoseBLETransport.swift', s)

# Reusable, actually-tested timer and Quiet command/read-back engine.
s = load('BoseBMAP.swift') + (extras / 'QuietSupport.swift').read_text()
save('BoseBMAP.swift', s)

s = load('BoseController.swift')
s = replace(s, 'import Foundation\n', 'import Foundation\nimport Combine\n')
s = replace(s, '    private let bluetooth: any BoseTransport', '''    @Published private(set) var maxANCLockEnabled: Bool
    @Published private(set) var maxANCStatus = "最大ANCを確認しています…"
    @Published private(set) var quietRequestPending = false
    private let preferences: UserDefaults
    private var quietTask: Task<Void, Never>?
    private var lockMonitor: Task<Void, Never>?
    private var isForeground = true
    private var controllerStarted = false
    private var lastQuietVerified: Date?

    private let bluetooth: any BoseTransport''')
s = replace(s, '''    init(bluetooth: (any BoseTransport)? = nil) {
        BoseDiagnostics.shared.event("CONTROLLER", "initializing")
        self.bluetooth = bluetooth ?? BoseBLETransport()
    }''', '''    init(bluetooth: (any BoseTransport)? = nil, preferences: UserDefaults = .standard) {
        BoseDiagnostics.shared.event("CONTROLLER", "initializing 1.3.0 maximum ANC")
        self.preferences = preferences
        self.maxANCLockEnabled = preferences.object(forKey: "boseMaximumANCLock") as? Bool ?? true
        self.bluetooth = bluetooth ?? BoseBLETransport()
        if let ble = self.bluetooth as? BoseBLETransport {
            ble.onModeUpdate = { [weak self] slot in
                guard let self else { return }
                if self.maxANCLockEnabled, self.isForeground, slot != BMAPQuietControl.factorySlot,
                   !self.isBusy, !self.quietRequestPending {
                    self.enqueueQuiet(reason: "device mode change: \\(slot)")
                }
            }
        }
    }''')
s = replace(s, '''        guard startupTask == nil, !state.connected else { return }
        startupTask = Task {
            isBusy = true''', '''        guard startupTask == nil, !state.connected, !isBusy else { beginLockMonitor(); return }
        isBusy = true
        beginLockMonitor()
        startupTask = Task {''')
s = replace(s, '''        startupTask?.cancel()
        startupTask = nil''', '''        startupTask?.cancel()
        startupTask = nil
        lockMonitor?.cancel()
        lockMonitor = nil
        quietTask?.cancel()
        quietTask = nil
        quietRequestPending = false''')
s = replace(s, '    func start() {', '    func start() {\n        controllerStarted = true')
# Claim the command lock before launching each task, not one actor turn later.
s = replace(s, '''        guard !isBusy else { return }
        Task {
            isBusy = true''', '''        guard !isBusy else { return }
        isBusy = true
        Task {''', count=3) # refresh + setMode + old max (removed below)
s = replace(s, '''        needsBLEPairing = false
        Task {
            isBusy = true''', '''        guard !isBusy else { return }
        needsBLEPairing = false
        isBusy = true
        Task {''')
# Replace the old catalogue-dependent maximum button implementation.
start = s.index('    func activateMaxQuiet() {')
end = s.index('    func setAutoCNC(', start)
s = s[:start] + s[end:]
s = replace(s, '''    func setMode(_ mode: String, announce: Bool) {
        guard''', '''    func setMode(_ mode: String, announce: Bool) {
        if mode.caseInsensitiveCompare("Quiet") == .orderedSame { activateQuiet(); return }
        if maxANCLockEnabled {
            message = "最大ANC固定中です。他のモードを使う場合は固定をOFFにしてください。"
            return
        }
        guard''')
s = replace(s, '''    func setCNC(_ level: Int) {
        action''', '''    func setCNC(_ level: Int) {
        if maxANCLockEnabled && level != 0 {
            message = "最大ANC固定中のため、強度を弱める変更は停止しました。"
            return
        }
        action''')
s = replace(s, '''        BoseDiagnostics.shared.event("ACTION", "start: " + label)
        Task {
            isBusy = true''', '''        guard !isBusy, !quietRequestPending else { return }
        BoseDiagnostics.shared.event("ACTION", "start: " + label)
        isBusy = true
        Task {''', count=2)
s = replace(s, '''            try await bluetooth.connect()
            message = "Connected. Reading headphone settings…"''', '''            // Clear the session cache before switching to a new BLE connection.
            modesByIndex.removeAll()
            try await bluetooth.connect()
            if maxANCLockEnabled {
                do { try await applyVerifiedQuiet(force: false) }
                catch { reportQuietFailure(error) }
            }
            message = "Connected. Reading headphone settings…"''')
# Read-only mode dumps may omit modes. Never erase known Quiet just because one
# dump is incomplete; this cache is cleared on reconnection above.
s = replace(s, '''            modesByIndex.removeAll(keepingCapacity: true)
            for config in configs { modesByIndex[config.index] = config }
            next.profiles = configs.map { config in''', '''            for config in configs { modesByIndex[config.index] = config }
            let mergedConfigs = modesByIndex.values.sorted { $0.index < $1.index }
            next.profiles = mergedConfigs.map { config in''')
s = replace(s, '''            let modePackets = try await bluetooth.exchange(BMAPPacket(31, 1, .start), drain: true, timeout: .seconds(7))''', '''            let modePackets: [BMAPPacket]
            do { modePackets = try await bluetooth.exchange(BMAPPacket(31, 1, .start), drain: true, timeout: .seconds(7)) }
            catch {
                if case BoseBLEError.pairingRequired = error { throw error }
                BoseDiagnostics.shared.event("MODE CATALOG", "optional dump unavailable: " + error.localizedDescription)
                modePackets = []
            }''')
# Let a priority Quiet tap finish before optional expensive feature probes.
s = replace(s, '''        BoseDiagnostics.shared.checkpoint("state.extras.begin", detail: "favorites/multipoint/autoOff")''', '''        if quietRequestPending {
            state = next
            BoseDiagnostics.shared.event("ANC PRIORITY", "deferred optional feature probes for Quiet request")
            return
        }
        BoseDiagnostics.shared.checkpoint("state.extras.begin", detail: "favorites/multipoint/autoOff")''')
s = replace(s, '    func sendRaw(_ hex: String) {', '    func sendRaw(_ hex: String) {\n        guard !isBusy, !quietRequestPending else { return }')
s = replace(s, '        rawLog.insert("TX  \\(bytes.hex)", at: 0)\n        Task {\n            isBusy = true', '        rawLog.insert("TX  \\(bytes.hex)", at: 0)\n        isBusy = true\n        Task {')
s = replace(s, '        BoseDiagnostics.shared.event("ASK", "user requested BLE pairing / re-authentication")\n        Task {\n            isBusy = true', '        BoseDiagnostics.shared.event("ASK", "user requested BLE pairing / re-authentication")\n        isBusy = true\n        Task {')
for signature, condition in [
    ('func setAutoCNC(_ enabled: Bool)', 'enabled'),
    ('func setWind(_ enabled: Bool)', 'enabled'),
    ('func setANC(_ enabled: Bool)', '!enabled'),
    ('func setSpatial(_ mode: Int)', 'mode != 0')]:
    s = replace(s, '    ' + signature + ' {', '    ' + signature + ' {\n        if maxANCLockEnabled && ' + condition + ' {\n            message = "最大ANC固定中のため、この変更は停止しました。"\n            return\n        }')
s += (extras / 'QuietController.swift').read_text()
save('BoseController.swift', s)

s = load('ContentView.swift')
start = s.index('    var body: some View {')
end = s.index('    private var busyOverlay:', start)
s = s[:start] + '''    var body: some View {
        TabView(selection: $selection) {
            ControlView(controller: controller)
                .tabItem { Label("Control", systemImage: "headphones") }.tag(0)
            ProfilesView(controller: controller)
                .tabItem { Label("Modes", systemImage: "slider.horizontal.3") }.tag(1)
            DeviceView(controller: controller)
                .tabItem { Label("Device", systemImage: "gearshape") }.tag(2)
        }
        .safeAreaInset(edge: .top, spacing: 0) { maximumANCPanel }
        .tint(amber)
        .preferredColorScheme(.dark)
        .task { controller.start() }
    }

    // Outside every catalogue condition and busy overlay, on all three tabs.
    private var maximumANCPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button { controller.activateQuiet() } label: {
                    Label("Quiet", systemImage: "speaker.slash.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { controller.activateMaxQuiet() } label: {
                    Text("最大ANCを強制適用").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
            Toggle("最大ANC固定", isOn: Binding(
                get: { controller.maxANCLockEnabled }, set: controller.setMaxANCLock
            )).font(.subheadline.bold())
            HStack(spacing: 8) {
                if controller.isBusy || controller.quietRequestPending { ProgressView().controlSize(.small) }
                Text(controller.maxANCStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("固定ON: 接続・画面復帰時と表示中に確認。別モードならQuietへ戻します。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(ink)
    }

''' + s[end:]
# Remove old conditional maximum button, now replaced by the persistent panel.
start = s.index('                if controller.state.profiles.contains(where: { $0.name.caseInsensitiveCompare("Quiet")')
end = s.index('                Toggle("モード切替を音声で通知"', start)
s = s[:start]+s[end:]
s = s.replace('state.firmware == "—" ? "QC45"', 'state.firmware == "—" ? "Bose"')
save('ContentView.swift', s)
s = load('App.swift')
s = replace(s, '                    updateIdleTimer()\n                }\n                .onChange', '                    controller.setForeground(scenePhase == .active)\n                    updateIdleTimer()\n                }\n                .onChange')
s = replace(s, '                    BoseDiagnostics.shared.setLifecycle(String(describing: nextPhase))', '                    controller.setForeground(nextPhase == .active)\n                    BoseDiagnostics.shared.setLifecycle(String(describing: nextPhase))')
save('App.swift', s)

project = root / 'native-ios/BoseHeadphonesControl.xcodeproj/project.pbxproj'
s = project.read_text().replace('MARKETING_VERSION = 1.2.1;', 'MARKETING_VERSION = 1.3.0;').replace('CURRENT_PROJECT_VERSION = 5;', 'CURRENT_PROJECT_VERSION = 6;')
project.write_text(s)
# Keep fully patched mirrors in the source ZIP for the overlay-based workflow.
custom = root/'bose-control-custom'; custom.mkdir(exist_ok=True)
for p in app.iterdir():
    if p.suffix in ('.swift', '.plist', '.c', '.h'): (custom/p.name).write_bytes(p.read_bytes())
(custom/'project.pbxproj').write_bytes(project.read_bytes())
print('Applied Quiet/maximum ANC patch 1.3.0 (6)')
