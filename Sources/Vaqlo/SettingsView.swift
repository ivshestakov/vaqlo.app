import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L("tab.general"), systemImage: "gearshape") }
            ModelsSettings()
                .tabItem { Label(L("tab.models"), systemImage: "cpu") }
            VoicesSettings()
                .tabItem { Label(L("tab.voices"), systemImage: "person.wave.2") }
            StorageSettings()
                .tabItem { Label(L("tab.storage"), systemImage: "internaldrive") }
        }
        .frame(width: 540, height: 580)
    }
}

// MARK: - Приложения-триггеры

private struct TriggerAppsList: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var apps: [TriggerApp] = []

    var body: some View {
        Group {
            if apps.isEmpty {
                Text(L("set.meeting.noApps")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.policy },
                        set: { MeetingPolicies.set(bundleID: app.bundleID, name: app.name, policy: $0); reload() }
                    )) {
                        Text(L("policy.auto")).tag(AppPolicy.auto)
                        Text(L("policy.ask")).tag(AppPolicy.ask)
                        Text(L("policy.never")).tag(AppPolicy.never)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Button {
                        MeetingPolicies.remove(bundleID: app.bundleID); reload()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
            Button(L("set.meeting.addApp")) { addApp() }
        }
        .onAppear(perform: reload)
    }

    private func reload() { apps = MeetingPolicies.all() }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("set.export.choose")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        MeetingPolicies.set(bundleID: bundleID, name: name, policy: .never)
        reload()
    }
}

// MARK: - Голоса

private struct VoicesSettings: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var voices: [VoiceLibrary.Entry] = []
    @State private var renaming: VoiceLibrary.Entry?
    @State private var newName = ""

    var body: some View {
        Form {
            Section(L("voices.section")) {
                if voices.isEmpty {
                    Text(L("voices.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(voices, id: \.name) { voice in
                    HStack {
                        Image(systemName: voice.isSelf == true ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .foregroundStyle(voice.isSelf == true ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(voice.name).bold()
                            Text(voice.isSelf == true ? L("voices.you", voice.samples) : L("voices.samples", voice.samples))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("voices.rename")) { renaming = voice; newName = voice.name }
                            .controlSize(.small)
                        Button(L("common.delete"), role: .destructive) {
                            VoiceLibrary.remove(name: voice.name); reload()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text(L("voices.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .sheet(item: $renaming) { voice in
            VStack(alignment: .leading, spacing: 12) {
                Text(L("voices.renameTitle", voice.name)).font(.headline)
                TextField(L("rename.placeholder"), text: $newName).textFieldStyle(.roundedBorder).frame(width: 240)
                HStack {
                    Spacer()
                    Button(L("common.cancel")) { renaming = nil }
                    Button(L("common.save")) {
                        VoiceLibrary.rename(from: voice.name, to: newName)
                        renaming = nil; reload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16).frame(width: 280)
        }
    }

    private func reload() {
        voices = VoiceLibrary.load().sorted {
            ($0.isSelf == true ? 1 : 0, $0.samples) > ($1.isSelf == true ? 1 : 0, $1.samples)
        }
    }
}

extension VoiceLibrary.Entry: Identifiable {
    public var id: String { name }
}

// MARK: - Хранилище и статистика

private struct StorageSettings: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @EnvironmentObject var store: AppStore
    @State private var stats = VaqloStats()

    var body: some View {
        Form {
            Section(L("storage.records")) {
                statRow(L("storage.total"), "\(stats.sessionCount)")
                statRow(L("storage.done"), "\(stats.doneCount)")
                statRow(L("storage.pending"), "\(stats.pendingCount)")
                statRow(L("storage.recorded"), hoursLabel(stats.totalRecordedSeconds / 3600))
                statRow(L("storage.week"), hoursLabel(stats.hoursThisWeek))
            }
            Section(L("storage.disk")) {
                statRow(L("storage.audio"), stats.audioBytes.humanSize)
                statRow(L("storage.trash"), stats.trashBytes.humanSize)
                statRow(L("storage.transcripts"), stats.transcriptBytes.humanSize)
                statRow(L("storage.models"), stats.modelBytes.humanSize)
                statRow(L("storage.diar"), stats.diarizationBytes.humanSize)
                Divider()
                statRow(L("storage.totalSize"), stats.totalBytes.humanSize, bold: true)
            }
            Section {
                Button(L("storage.openFolder")) {
                    NSWorkspace.shared.open(Storage.root)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { stats = VaqloStats.compute(library: store.library) }
    }

    private func statRow(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(bold ? .bold : .regular).monospacedDigit()
        }
    }

    private func hoursLabel(_ hours: Double) -> String {
        if hours < 1 { return L("unit.minLong", Int(hours * 60)) }
        return L("unit.hours", hours)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @EnvironmentObject var store: AppStore
    @AppStorage(SettingsKeys.scheduleMode) private var scheduleMode = 0
    @AppStorage(SettingsKeys.scheduleIntervalHours) private var intervalHours = 4
    @AppStorage(SettingsKeys.scheduleDailyMinutes) private var dailyMinutes = 21 * 60
    @AppStorage(SettingsKeys.retentionDays) private var retentionDays = 7
    @AppStorage(SettingsKeys.exportFolder) private var exportFolder = ""
    @AppStorage(SettingsKeys.idleEmoji) private var idleEmoji = "😶"
    @AppStorage(SettingsKeys.recordingEmoji) private var recordingEmoji = "🙂"
    @AppStorage(SettingsKeys.language) private var language = "auto"
    @AppStorage(SettingsKeys.selfLabel) private var selfLabel = ""
    @AppStorage(SettingsKeys.meetingDetection) private var meetingDetection = 1
    @AppStorage(SettingsKeys.meetingAutoStop) private var meetingAutoStop = true
    @AppStorage(SettingsKeys.detectSpeakerNames) private var detectSpeakerNames = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityTrusted = AccessibilityHelper.isTrusted
    @State private var calendarAuthorized = CalendarService.isAuthorized

    var body: some View {
        Form {
            Section(L("set.lang.section")) {
                Picker(L("set.lang.label"), selection: Binding(
                    get: { LocalizationManager.shared.language },
                    set: { LocalizationManager.shared.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
                Text(L("set.lang.hint")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("set.hotkey.section")) {
                HotkeyRecorderRow()
            }

            Section(L("set.icon.section")) {
                EmojiPickerRow(title: L("set.icon.idle"), selection: $idleEmoji)
                EmojiPickerRow(title: L("set.icon.recording"), selection: $recordingEmoji)
                Text(L("set.icon.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("set.meeting.section")) {
                Toggle(L("set.meeting.enable"), isOn: Binding(
                    get: { meetingDetection != 0 },
                    set: { meetingDetection = $0 ? 1 : 0 }
                ))
                if meetingDetection != 0 {
                    Toggle(L("set.meeting.autostop"), isOn: $meetingAutoStop)
                }
                Text(L("set.meeting.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if meetingDetection != 0 {
                Section(L("set.meeting.apps")) {
                    TriggerAppsList()
                    Text(L("set.meeting.appsHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("set.names.section")) {
                Toggle(L("set.names.label"), isOn: $detectSpeakerNames)
                if detectSpeakerNames {
                    HStack {
                        Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(accessibilityTrusted ? Color.green : Color.orange)
                        Text(accessibilityTrusted ? L("set.names.granted") : L("set.names.grant"))
                        Spacer()
                        if !accessibilityTrusted {
                            Button(L("set.names.grant")) {
                                AccessibilityHelper.prompt()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text(L("set.names.hint")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("set.cal.section")) {
                HStack {
                    Image(systemName: calendarAuthorized ? "checkmark.circle.fill" : "calendar.badge.plus")
                        .foregroundStyle(calendarAuthorized ? Color.green : Color.orange)
                    Text(calendarAuthorized ? L("common.granted") : L("set.cal.label"))
                    Spacer()
                    if !calendarAuthorized {
                        Button(L("onb.allow")) { CalendarService.requestAccess() }
                            .controlSize(.small)
                    }
                }
                Text(L("set.cal.hint")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("set.transcript.section")) {
                HStack {
                    Text(L("set.selflabel.label"))
                    Spacer()
                    TextField(L("self.default"), text: $selfLabel)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                }
                Text(L("set.selflabel.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("set.translang.section")) {
                Picker(L("set.translang.label"), selection: $language) {
                    Text(L("set.translang.auto")).tag("auto")
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang.rawValue)
                    }
                }
                Text(L("set.translang.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("set.schedule.section")) {
                Picker(L("set.schedule.mode"), selection: $scheduleMode) {
                    Text(L("set.schedule.manual")).tag(0)
                    Text(L("set.schedule.everyN")).tag(1)
                    Text(L("set.schedule.daily")).tag(2)
                }
                if scheduleMode == 1 {
                    Stepper(L("set.schedule.everyHours", intervalHours), value: $intervalHours, in: 1...24)
                }
                if scheduleMode == 2 {
                    DatePicker(
                        L("set.schedule.time"),
                        selection: Binding(
                            get: {
                                Calendar.current.date(
                                    bySettingHour: dailyMinutes / 60,
                                    minute: dailyMinutes % 60,
                                    second: 0, of: Date()
                                ) ?? Date()
                            },
                            set: {
                                let cal = Calendar.current
                                dailyMinutes = cal.component(.hour, from: $0) * 60 + cal.component(.minute, from: $0)
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                }
            }

            Section(L("set.audio.section")) {
                Stepper(L("set.audio.retention", retentionDays), value: $retentionDays, in: 1...90)
                Text(L("set.audio.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("set.export.section")) {
                HStack {
                    Text(exportFolder.isEmpty ? L("set.export.none") : exportFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(exportFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(L("set.export.choose")) { pickFolder() }
                }
            }

            Section {
                Toggle(L("set.login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AccessibilityHelper.isTrusted
            calendarAuthorized = CalendarService.isAuthorized
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("set.export.choose")
        if panel.runModal() == .OK, let url = panel.url {
            exportFolder = url.path
        }
    }
}

// MARK: - Хоткей

private struct HotkeyRecorderRow: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @EnvironmentObject var store: AppStore
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var display = ""

    var body: some View {
        HStack {
            Text(L("set.hotkey.label"))
            Spacer()
            Text(display.isEmpty ? AppStore.shared.hotKeyDescription : display)
                .font(.body.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(capturing ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6))
            Button(capturing ? L("set.hotkey.capturing") : L("set.hotkey.change")) {
                capturing ? stopCapture() : startCapture()
            }
        }
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = HotKeyFormat.carbonModifiers(from: event.modifierFlags)
            // Требуем хотя бы один модификатор, иначе хоткей перехватит обычный ввод.
            guard modifiers != 0 else { return nil }
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: SettingsKeys.hotKeyCode)
            defaults.set(Int(modifiers), forKey: SettingsKeys.hotKeyModifiers)
            display = HotKeyFormat.description(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            store.registerHotKey()
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        capturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - Эмодзи

private struct EmojiPickerRow: View {
    @ObservedObject private var loc = LocalizationManager.shared
    let title: String
    @Binding var selection: String

    private static let options = ["😶", "🙂", "😊", "🎧", "🎙", "📝", "🤖", "🦄", "🌚", "👀", "🍩", "🫥"]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(Self.options.prefix(8), id: \.self) { emoji in
                Button(emoji) { selection = emoji }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .padding(3)
                    .background(
                        selection == emoji ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            TextField("", text: $selection)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .help(L("set.icon.emojiHelp"))
        }
    }
}

// MARK: - Модели

private struct ModelsSettings: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @EnvironmentObject var store: AppStore
    @AppStorage(SettingsKeys.activeModel) private var activeModel = "large-v3-turbo-q5_0"
    @AppStorage(SettingsKeys.activeSummaryModel) private var activeSummaryModel = "qwen3-4b-instruct-q4"
    @AppStorage(SettingsKeys.autoSummarize) private var autoSummarize = false

    var body: some View {
        Form {
            Section(L("set.models.whisper")) {
                ForEach(WhisperModel.presets) { model in
                    ModelRow(model: model, active: $activeModel)
                }
            }
            Section(L("set.models.llm")) {
                Toggle(L("set.models.autosum"), isOn: $autoSummarize)
                ForEach(SummaryModel.presets) { model in
                    ModelRow(model: model, active: $activeSummaryModel)
                }
            }
            Section(L("set.models.voice")) {
                VoiceModelsRow()
            }
            Section {
                Text(L("set.models.activehint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @EnvironmentObject var store: AppStore
    let model: any DownloadableModel
    @Binding var active: String

    var body: some View {
        let downloaded = store.models.downloadedIDs.contains(model.id)
        let progress = store.models.progress[model.id]

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if downloaded {
                    Toggle(isOn: Binding(
                        get: { active == model.id },
                        set: { if $0 { active = model.id } }
                    )) {
                        Text(model.title).bold()
                    }
                    .toggleStyle(.checkbox)
                } else {
                    Text(model.title).bold()
                }
                Spacer()
                Text(model.sizeMB >= 1000
                     ? L("unit.gb", Double(model.sizeMB) / 1000)
                     : L("unit.mb", model.sizeMB))
                    .foregroundStyle(.secondary).font(.caption)

                if let progress {
                    if progress < 0.001 {
                        // Мгновенный фидбек: соединение ещё устанавливается.
                        ProgressView().controlSize(.small).frame(width: 80)
                    } else {
                        ProgressView(value: progress).frame(width: 80)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button(L("model.cancel")) { store.models.cancelDownload(model) }
                        .controlSize(.small)
                } else if downloaded {
                    Button(L("common.delete")) { store.models.delete(model) }
                        .controlSize(.small)
                } else {
                    Button(L("model.download")) { store.models.download(model) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(model.details).font(.caption).foregroundStyle(.secondary)
            if let error = store.models.errors[model.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// CoreML-модели диаризации скачиваются автоматически — здесь только статус и очистка.
private struct VoiceModelsRow: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var sizeMB: Int?

    private var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("voice.coreml.title")).bold()
                Text(sizeMB == nil
                     ? L("voice.coreml.notyet")
                     : L("voice.coreml.downloaded", sizeMB!))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if sizeMB != nil {
                Button(L("common.delete")) {
                    try? FileManager.default.removeItem(at: modelsDir)
                    refresh()
                }
                .controlSize(.small)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: modelsDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            sizeMB = nil
            return
        }
        var total = 0
        for case let url as URL in files {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        sizeMB = total > 0 ? total / 1_048_576 : nil
    }
}
