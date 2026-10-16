import SwiftUI

private let amber = Color(red: 0.96, green: 0.66, blue: 0.19)
private let ink = Color(red: 0.035, green: 0.042, blue: 0.055)
private let card = Color(red: 0.095, green: 0.108, blue: 0.135)

struct ContentView: View {
    @ObservedObject var controller: BoseController
    @State private var selection = 0

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                ControlView(controller: controller)
                    .tabItem { Label("Control", systemImage: "headphones") }
                    .tag(0)
                ProfilesView(controller: controller)
                    .tabItem { Label("Modes", systemImage: "slider.horizontal.3") }
                    .tag(1)
                DeviceView(controller: controller)
                    .tabItem { Label("Device", systemImage: "gearshape") }
                    .tag(2)
            }
            .disabled(controller.isBusy)

            if controller.isBusy {
                busyOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(10)
            }
        }
        .tint(amber)
        .preferredColorScheme(.dark)
        .task { controller.start() }
        .animation(.easeInOut(duration: 0.18), value: controller.isBusy)
    }

    private var busyOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(amber.opacity(0.13)).frame(width: 88, height: 88)
                    Circle().stroke(amber.opacity(0.24), lineWidth: 1).frame(width: 88, height: 88)
                    Image(systemName: "headphones")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(amber)
                    ProgressView().tint(.white).offset(y: 54)
                }
                Text("TALKING TO HEADPHONES")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(amber)
                Text(controller.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(28)
            .background(ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(amber.opacity(0.22)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working. \(controller.message)")
    }
}

private struct ControlView: View {
    @ObservedObject var controller: BoseController
    @AppStorage("announceModeIOS") private var announceMode = false
    @AppStorage("boseCustomEQPreset") private var customEQPreset = "0,0,0"
    @State private var eq = [0.0, 0.0, 0.0]
    @State private var cnc = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    modeDeck
                    if controller.state.supports("audio_settings") || controller.state.activeProfile?.editable == true { noiseCard }
                    if controller.state.supports("eq") { equalizerCard }
                    messageCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(background)
            .navigationTitle("Bose Control")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(controller.isBusy)
                }
            }
        }
        .onAppear { syncControls() }
        .onChange(of: controller.state.eq) { _, _ in syncControls() }
        .onChange(of: controller.state.cncLevel) { _, _ in syncControls() }
    }

    private var background: some View {
        ZStack {
            ink.ignoresSafeArea()
            RadialGradient(colors: [amber.opacity(0.13), .clear], center: .topTrailing, startRadius: 20, endRadius: 390)
                .ignoresSafeArea()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DIRECT BLE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(amber)
                    Text(controller.state.name)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Label(controller.state.connected ? "Connected" : "Finding headphones", systemImage: controller.state.connected ? "checkmark.circle.fill" : "wave.3.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(controller.state.connected ? .green : amber)
                }
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(controller.state.battery ?? 0) / 100)
                        .stroke(amber, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(controller.state.battery.map { "\($0)" } ?? "—")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 82, height: 82)
            }
            HStack {
                Label(controller.state.mode, systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text(controller.state.firmware == "—" ? "QC45" : "FW \(controller.state.firmware)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(
            LinearGradient(colors: [card, card.opacity(0.76)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26)
        )
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.06)))
    }

    private var modeDeck: some View {
        section("LISTENING MODE", icon: "ear") {
            if controller.state.playableProfiles.isEmpty {
                loadingRow("Reading modes…")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(controller.state.playableProfiles) { profile in
                            Button { controller.setMode(profile.name, announce: announceMode) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    Image(systemName: modeIcon(profile.name))
                                        .font(.title2)
                                    Text(profile.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                }
                                .frame(width: 112, alignment: .leading)
                                .padding(16)
                                .foregroundStyle(profile.id == controller.state.modeIndex ? ink : .primary)
                                .background(profile.id == controller.state.modeIndex ? amber : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
                            }
                            .disabled(controller.isBusy)
                        }
                    }
                }
                if controller.state.profiles.contains(where: { $0.name.caseInsensitiveCompare("Quiet") == .orderedSame })
                    || controller.state.supports("audio_settings")
                    || controller.state.activeProfile?.editable == true {
                    Button { controller.activateMaxQuiet() } label: {
                        Label("最大ANC（Quiet）に切り替える", systemImage: "speaker.slash.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy)
                }
                Toggle("モード切替を音声で通知", isOn: $announceMode)
                    .font(.subheadline)
            }
        }
    }

    private var noiseCard: some View {
        section("NOISE CONTROL", icon: "waveform.path.ecg") {
            HStack(alignment: .firstTextBaseline) {
                Text("Cancellation")
                    .font(.headline)
                Spacer()
                Text("\(Int(cnc))")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber)
            }
            Slider(value: $cnc, in: 0...Double(controller.state.cncMax), step: 1) { editing in
                if !editing { controller.setCNC(Int(cnc)) }
            }
            HStack {
                Text("QUIET")
                Spacer()
                Text("AWARE")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            Text("0 = 最大ノイズキャンセリング。10に近いほど外音を取り込みます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if controller.state.supports("auto_cnc") {
                Toggle("自動ANC調整 / ActiveSense", isOn: Binding(
                    get: { controller.state.autoCNC }, set: controller.setAutoCNC
                ))
                .font(.subheadline)
            }
            if controller.state.supports("spatial") {
                Picker("イマーシブオーディオ", selection: Binding(
                    get: { controller.state.spatial }, set: controller.setSpatial
                )) {
                    Text("オフ").tag(0)
                    Text("静止").tag(1)
                    Text("動きに追従").tag(2)
                }
                .font(.subheadline)
            }
            if controller.state.supports("wind_block") {
                Toggle("風切り音低減", isOn: Binding(
                    get: { controller.state.windBlock }, set: controller.setWind
                ))
                .font(.subheadline)
            }
            if controller.state.supports("anc_toggle") {
                Toggle("ANC設定", isOn: Binding(
                    get: { controller.state.ancEnabled }, set: controller.setANC
                ))
                .font(.subheadline)
            }
            Text("対応しない機能は表示しません。iOSの制限によりアプリ終了後の常時ANC固定はできません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var equalizerCard: some View {
        section("EQUALIZER", icon: "dial.medium") {
            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 5) {
                    HStack {
                        Text(["Bass", "Mid", "Treble"][index]).fontWeight(.semibold)
                        Spacer()
                        Text(eq[index], format: .number.sign(strategy: .always()))
                            .font(.body.monospaced().weight(.bold))
                            .foregroundStyle(amber)
                    }
                    Slider(value: $eq[index], in: -10...10, step: 1)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    preset("Flat", [0, 0, 0])
                    preset("Bass", [4, 0, 2])
                    preset("Voice", [-4, 2, 3])
                    preset("Podcast", [-3, 3, 2])
                    preset("Warm", [3, 1, -2])
                    preset("Clear", [-2, 2, 4])
                }
            }
            HStack(spacing: 10) {
                Button("自作EQを保存") {
                    customEQPreset = eq.map { String(Int($0)) }.joined(separator: ",")
                }
                .buttonStyle(.bordered)
                Button("呼び出す") {
                    let saved = customEQPreset.split(separator: ",").compactMap { Double($0) }
                    if saved.count == 3 { eq = saved }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("反映") { controller.setEqualizer(eq) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(ink)
            }
            Text("プリセットは選択後に「反映」を押します。自作EQはiPhone内だけに保存します。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var messageCard: some View {
        HStack(spacing: 12) {
            if controller.isBusy { ProgressView().tint(amber) }
            else { Image(systemName: controller.state.connected ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(controller.state.connected ? .green : amber) }
            Text(controller.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(amber)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.05)))
    }

    private func preset(_ title: String, _ values: [Double]) -> some View {
        Button(title) { eq = values }.buttonStyle(.bordered)
    }

    private func loadingRow(_ text: String) -> some View {
        HStack { ProgressView().tint(amber); Text(text).foregroundStyle(.secondary) }
    }

    private func syncControls() {
        eq = Array(controller.state.eq.prefix(3)) + Array(repeating: 0, count: max(0, 3 - controller.state.eq.count))
        cnc = Double(controller.state.cncLevel)
    }

    private func modeIcon(_ name: String) -> String {
        let value = name.lowercased()
        if value.contains("quiet") { return "speaker.slash.fill" }
        if value.contains("aware") { return "ear.badge.waveform" }
        if value.contains("work") || value.contains("focus") { return "scope" }
        if value.contains("music") { return "music.note" }
        return "waveform.circle.fill"
    }
}

private struct ProfilesView: View {
    @ObservedObject var controller: BoseController
    @State private var editing: NativeProfile?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(controller.state.profiles.filter { !($0.editable && $0.name.isEmpty) }) { profile in
                        Button { profile.editable ? (editing = profile) : controller.setMode(profile.name, announce: false) } label: {
                            HStack(spacing: 14) {
                                Text(String(format: "%02d", profile.id))
                                    .font(.headline.monospaced())
                                    .foregroundStyle(amber)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                        .font(.headline)
                                    Text(profile.editable ? "CNC \(profile.cncLevel) · Editable" : "Built-in mode")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == controller.state.modeIndex {
                                    Text("ACTIVE").font(.caption2.bold()).foregroundStyle(ink).padding(.horizontal, 9).padding(.vertical, 5).background(amber, in: Capsule())
                                } else {
                                    Image(systemName: profile.editable ? "pencil" : "play.fill").foregroundStyle(.secondary)
                                }
                            }
                            .padding(18)
                            .background(card, in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                    }
                    if let free = controller.state.profiles.first(where: { $0.editable && $0.name.isEmpty }) {
                        Button { editing = free } label: {
                            Label("Add mode", systemImage: "plus")
                                .font(.headline)
                                .foregroundStyle(amber)
                                .frame(maxWidth: .infinity)
                                .padding(18)
                                .background(card, in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                    }
                    if controller.state.profiles.isEmpty {
                        ProgressView("Reading Bose modes…").tint(amber).padding(.top, 80)
                    }
                }
                .padding(18)
            }
            .background(ink)
            .navigationTitle("Listening Modes")
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, controller: controller)
                .presentationDetents([.medium, .large])
        }
    }
}

private struct ProfileEditor: View {
    let profile: NativeProfile
    @ObservedObject var controller: BoseController
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var cnc: Double
    @State private var wind: Bool
    @State private var anc: Bool
    @State private var autoCNC: Bool
    @State private var spatial: Int

    init(profile: NativeProfile, controller: BoseController) {
        self.profile = profile
        self.controller = controller
        _name = State(initialValue: profile.name)
        _cnc = State(initialValue: Double(profile.cncLevel))
        _wind = State(initialValue: profile.windBlock)
        _anc = State(initialValue: profile.ancToggle)
        _autoCNC = State(initialValue: profile.autoCNC)
        _spatial = State(initialValue: profile.spatial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    LabeledContent("Noise level", value: "\(Int(cnc))")
                    Slider(value: $cnc, in: 0...Double(controller.state.cncMax), step: 1)
                    if profile.mutableMask & 0x02 != 0 {
                        Toggle("ActiveSense / 自動ANC", isOn: $autoCNC)
                    }
                    if profile.mutableMask & 0x04 != 0 {
                        Picker("イマーシブオーディオ", selection: $spatial) {
                            Text("オフ").tag(0)
                            Text("静止").tag(1)
                            Text("動きに追従").tag(2)
                        }
                    }
                    if profile.mutableMask & 0x08 != 0 {
                        Toggle("Wind block", isOn: $wind)
                    }
                    if profile.mutableMask & 0x10 != 0 {
                        Toggle("ANC", isOn: $anc)
                    }
                } header: {
                    Text("MODE")
                } footer: {
                    Text("Noise level 0 blocks the most outside sound. Higher lets more in. Wind block reduces wind noise.")
                }
                if !profile.name.isEmpty {
                    Section { Button("Clear this mode", role: .destructive) { controller.deleteProfile(slot: profile.id); dismiss() } }
                }
            }
            .navigationTitle(profile.name.isEmpty ? "New mode" : "Mode \(profile.id)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        controller.saveProfile(slot: profile.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), cnc: Int(cnc), wind: wind, anc: anc, spatial: spatial, autoCNC: autoCNC)
                        dismiss()
                    }
                }
            }
        }
        .tint(amber)
    }
}

private struct DeviceView: View {
    @ObservedObject var controller: BoseController
    @State private var name = ""
    @State private var showPowerConfirm = false
    @State private var showPairConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("CONNECTION") {
                    LabeledContent("Headphones", value: controller.state.name)
                    LabeledContent("Transport", value: "Encrypted BLE")
                    LabeledContent("Battery", value: controller.state.battery.map { "\($0)%" } ?? "—")
                    LabeledContent("Firmware", value: controller.state.firmware)
                    Button("Reconnect") { controller.reconnect() }.disabled(controller.isBusy)
                }
                if controller.state.batteries.count > 1 {
                    Section("バッテリー詳細") {
                        ForEach(controller.state.batteries) { part in
                            LabeledContent(part.label, value: "\(part.percent)%")
                        }
                    }
                }
                Section("DEVICE NAME") {
                    TextField("Headphone name", text: $name)
                    Button("Rename") { controller.rename(name) }.disabled(name.isEmpty || controller.isBusy)
                }
                if controller.state.supports("voice_prompts") || controller.state.supports("auto_pause") || controller.state.supports("auto_answer") {
                    Section("BEHAVIOUR") {
                        if controller.state.supports("voice_prompts") {
                            Toggle("Voice prompts", isOn: Binding(get: { controller.state.promptsEnabled }, set: controller.setPrompts))
                            LabeledContent("Prompt language", value: controller.state.promptsLanguage)
                        }
                        if controller.state.supports("auto_pause") {
                            Toggle("Pause when removed", isOn: Binding(get: { controller.state.autoPause }, set: controller.setAutoPause))
                        }
                        if controller.state.supports("auto_answer") {
                            Toggle("Auto-answer calls", isOn: Binding(get: { controller.state.autoAnswer }, set: controller.setAutoAnswer))
                        }
                    }
                }
                if controller.state.supports("favorites") {
                    Section {
                        ForEach(controller.state.playableProfiles) { profile in
                            Toggle(profile.name, isOn: Binding(
                                get: { profile.favorite },
                                set: { controller.setFavorite(slot: profile.id, enabled: $0) }
                            ))
                            .disabled(controller.isBusy || profile.id >= 16)
                        }
                    } header: {
                        Text("モードのお気に入り")
                    } footer: {
                        Text("イヤホンのジェスチャーで切り替えるモードを選びます。最低1モードを残してください。")
                    }
                }
                if controller.state.supports("auto_off") || controller.state.supports("remember_last_mode")
                    || controller.state.supports("multipoint") || controller.state.supports("auto_transparency") {
                    Section {
                        if controller.state.supports("remember_last_mode") {
                            Toggle("最後のモードを記憶", isOn: Binding(
                                get: { controller.state.rememberLastMode }, set: controller.setRememberLastMode
                            ))
                        }
                        if controller.state.supports("auto_off") {
                            Picker("自動電源オフ", selection: Binding(
                                get: { controller.state.autoOffMinutes ?? 0 }, set: controller.setAutoOff
                            )) {
                                ForEach([0, 5, 20, 40, 60, 180], id: \.self) { minutes in
                                    Text(minutes == 0 ? "しない" : "\(minutes) 分").tag(minutes)
                                }
                            }
                        }
                        if controller.state.supports("multipoint") {
                            Toggle("マルチポイント", isOn: Binding(
                                get: { (controller.state.multipointRaw ?? 0) & 1 != 0 }, set: controller.setMultipoint
                            ))
                            .disabled(!controller.state.multipointWritable)
                        }
                        if controller.state.supports("auto_transparency") {
                            Toggle("片耳装着時の外音取り込み", isOn: Binding(
                                get: { controller.state.autoTransparency }, set: controller.setAutoTransparency
                            ))
                        }
                    } header: {
                        Text("詳細設定")
                    } footer: {
                        Text("対応する機能だけを表示します。マルチポイントを切り替えると接続が一時的に切れることがあります。")
                    }
                }
                if controller.state.supports("sidetone") {
                    Section("CALLS") {
                        Picker("Sidetone", selection: Binding(get: { controller.state.sidetone }, set: controller.setSidetone)) {
                            ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                }
                if !controller.state.buttons.isEmpty {
                    Section("BUTTON") {
                        ForEach(controller.state.buttons) { mapping in
                            LabeledContent("\(mapping.button) · \(mapping.event)", value: mapping.action)
                        }
                    }
                }
                Section("HEADPHONES") {
                    Button("Enter pairing mode") { showPairConfirm = true }
                    Button("Power off headphones", role: .destructive) { showPowerConfirm = true }
                }
                Section("LOGS / クラッシュ診断") {
                    Text("LiveContainerのデータフォルダ直下に「Logs」を保存します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(BoseDiagnostics.shared.logsDirectory.path)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Button("ログ書き込みテスト") {
                        BoseDiagnostics.shared.diagnosticProbe()
                    }
                    ShareLink("app.logを共有", item: BoseDiagnostics.shared.appLogURL)
                    ShareLink("crash.logを共有", item: BoseDiagnostics.shared.crashLogURL)
                    Text("アプリを開けない場合はLiveContainerからData → Logsを直接確認してください。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("LAST CHANGES") {
                    if controller.writeLog.isEmpty { Text("Changes are verified by reading them back from the headphones.").foregroundStyle(.secondary) }
                    ForEach(controller.writeLog.prefix(8), id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ink)
            .navigationTitle("Device")
        }
        .tint(amber)
        .onAppear { name = controller.state.name }
        .onChange(of: controller.state.name) { _, value in name = value }
        .confirmationDialog("Put the headphones in pairing mode?", isPresented: $showPairConfirm) {
            Button("Enter pairing mode") { controller.pair() }
        } message: { Text("This makes the headphones discoverable. It does not erase existing devices.") }
        .confirmationDialog("Power off the headphones?", isPresented: $showPowerConfirm) {
            Button("Power off", role: .destructive) { controller.powerOff() }
        }
    }
}
