import SwiftUI

/// Правая панель: развёрнутая информация о сессии, транскрипт, действия.
struct SessionDetailView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var loc = LocalizationManager.shared
    let session: Session
    var onDeleted: () -> Void = {}

    @State private var lines: [TranscriptLine] = []
    @State private var metadata: SessionMetadata?
    @State private var exportResult: String?
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var renameTarget: RenameTarget?
    @StateObject private var player = SessionAudioPlayer()

    struct RenameTarget: Identifiable {
        let id = UUID()
        let from: String
        var to: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            infoCard
            playerBar
            Divider()
            content
        }
        .onAppear { load(); player.load(session) }
        .onChange(of: session) { load(); reloadPlayer() }
        .onChange(of: store.transcriber.isWorking) { load(); reloadPlayer() }
        .onChange(of: store.transcriptRevision) { load() }
        .onDisappear { player.teardown() }
        .sheet(item: $renameTarget) { target in
            RenameSpeakerSheet(target: target) { newName in
                store.renameSpeaker(in: session, from: target.from, to: newName)
            }
        }
        .confirmationDialog(
            L("delete.title"),
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(L("delete.btn"), role: .destructive) {
                store.deleteSession(session)
                onDeleted()
            }
        } message: {
            Text(L("delete.msg"))
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    if let meeting = metadata?.meeting {
                        Text(meetingTitle(meeting)).font(.title3.bold()).lineLimit(1)
                        Text(session.start, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(session.start, format: .dateTime.day().month().hour().minute())
                            .font(.title3.bold())
                    }
                }
                Spacer()
                stateBadge
            }

            HStack(spacing: 8) {
                if session.state == .pending {
                    Button(L("act.transcribe")) {
                        store.transcriber.transcribe(session)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if session.state == .transcribing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("act.inProgress")).font(.caption)
                    }
                }
                if session.state == .done {
                    Button {
                        export()
                    } label: {
                        if exporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("act.export"))
                        }
                    }
                    .disabled(exporting)
                    Button(L("act.showFiles")) {
                        NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                    }
                }
                Spacer()
                if session.state != .recording {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L("delete.title"))
                }
            }

            if let exportResult {
                Text(exportResult).font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.transcriber.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    private var stateBadge: some View {
        let (text, color): (String, Color) = switch session.state {
        case .recording: (L("state.recording"), .red)
        case .pending: (L("state.pending"), .orange)
        case .transcribing: (L("state.transcribing"), .purple)
        case .done: (L("state.done"), .green)
        }
        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Карточка с информацией

    private var infoCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            if let meeting = metadata?.meeting {
                GridRow {
                    Text(L("meeting.row")).foregroundStyle(.secondary)
                    Text(meetingTitle(meeting)).bold().lineLimit(1)
                }
                if !meeting.isLargeGroup, !meeting.attendees.isEmpty {
                    GridRow {
                        Text(L("meeting.participants")).foregroundStyle(.secondary)
                        Text(meeting.attendees.joined(separator: ", "))
                            .lineLimit(2)
                            .help(meeting.attendees.joined(separator: ", "))
                    }
                }
            }
            GridRow {
                Text(L("info.type")).foregroundStyle(.secondary)
                Text(classification).bold()
            }
            GridRow {
                Text(L("info.start")).foregroundStyle(.secondary)
                Text(session.start, format: .dateTime.hour().minute().second())
            }
            GridRow {
                Text(L("info.end")).foregroundStyle(.secondary)
                if let end = session.end {
                    Text("\(end, format: .dateTime.hour().minute().second()) · \(Int(session.duration / 60)) \(L("unit.min"))")
                } else {
                    Text(session.state == .recording ? L("info.recordingNow") : "—")
                }
            }
            GridRow {
                Text(L("info.apps")).foregroundStyle(.secondary)
                Text(appsLine)
                    .lineLimit(2)
                    .help(appsLine)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    // MARK: - Плеер

    @ViewBuilder
    private var playerBar: some View {
        if session.state != .recording {
            if player.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("player.loading")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else if player.available {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button { player.skip(by: -15) } label: {
                            Image(systemName: "gobackward.15")
                        }
                        .buttonStyle(.plain)

                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title)
                        }
                        .buttonStyle(.plain)

                        Button { player.skip(by: 15) } label: {
                            Image(systemName: "goforward.15")
                        }
                        .buttonStyle(.plain)

                        Text(timeLabel(player.currentTime))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...max(player.duration, 0.1)
                        )
                        Text(timeLabel(player.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        // Скорость
                        Menu("\(speedLabel)×") {
                            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                                Button("\(formatRate(r))×") { player.rate = Float(r) }
                            }
                        }
                        .frame(width: 64)

                        Spacer()

                        // Раздельный мьют дорожек
                        if player.hasMic {
                            Toggle(isOn: Binding(get: { !player.micMuted }, set: { player.micMuted = !$0 })) {
                                Label(TranscriptGrouper.selfLabel, systemImage: "mic.fill")
                            }
                            .toggleStyle(.button).controlSize(.small)
                        }
                        if player.hasSys {
                            Toggle(isOn: Binding(get: { !player.sysMuted }, set: { player.sysMuted = !$0 })) {
                                Label(L("speaker.computer"), systemImage: "speaker.wave.2.fill")
                            }
                            .toggleStyle(.button).controlSize(.small)
                        }
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else if session.state == .done {
                Text(L("player.deleted"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var speedLabel: String { formatRate(Double(player.rate)) }

    private func formatRate(_ r: Double) -> String {
        r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    }

    /// Индекс группы, играющей прямо сейчас (для подсветки и автоскролла).
    private func activeGroupID(_ groups: [TranscriptGroup]) -> String? {
        guard player.available, player.isPlaying || player.currentTime > 0 else { return nil }
        let now = player.currentTime
        return groups.last { $0.start.timeIntervalSince(session.start) <= now + 0.3 }?.id
    }

    private func reloadPlayer() {
        player.teardown()
        player.load(session)
    }

    private var classification: String {
        SessionClassifier.classify(metadata: metadata, lines: session.state == .done ? lines : nil)
    }

    private func meetingTitle(_ meeting: MeetingInfo) -> String {
        if meeting.isLargeGroup { return L("meeting.largeGroup", meeting.attendeeCount) }
        let title = (meeting.title ?? "").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? L("meeting.untitled") : title
    }

    private var appsLine: String {
        let names = (metadata?.frontmostApps ?? []).compactMap(\.name)
        guard !names.isEmpty else { return "—" }
        var unique: [String] = []
        for name in names where !unique.contains(name) {
            unique.append(name)
        }
        return unique.joined(separator: ", ")
    }

    // MARK: - Контент

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .recording:
            ContentUnavailableView(L("content.recording"), systemImage: "record.circle")
        case .pending:
            ContentUnavailableView(
                L("content.pending.title"),
                systemImage: "text.bubble",
                description: Text(L("content.pending.desc"))
            )
        case .transcribing:
            VStack(spacing: 10) {
                ProgressView()
                Text(L("content.transcribing"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            VStack(spacing: 0) {
                summaryCard
                transcriptList
            }
        }
    }

    // MARK: - Саммари

    @ViewBuilder
    private var summaryCard: some View {
        let working = store.summarizer.workingIDs.contains(session.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("summary.title"), systemImage: "sparkles")
                    .font(.callout.bold())
                Spacer()
                if working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("summary.thinking")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if summaryText == nil {
                    Button(L("summary.make")) { store.summarizer.summarize(session) }
                        .controlSize(.small)
                } else {
                    Button(L("summary.update")) { store.summarizer.summarize(session) }
                        .controlSize(.small)
                }
            }
            if let summaryText {
                ScrollView {
                    Text(LocalizedStringKey(summaryText))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            if let error = store.summarizer.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25))
        .overlay(Divider(), alignment: .bottom)
    }

    private var summaryText: String? {
        try? String(contentsOf: Summarizer.summaryURL(for: session), encoding: .utf8)
    }

    private var transcriptList: some View {
        let groups = TranscriptGrouper.group(lines)
        let activeID = activeGroupID(groups)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if lines.isEmpty {
                    Text(L("transcript.empty")).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button {
                                player.playFrom(seconds: group.start.timeIntervalSince(session.start))
                            } label: {
                                HStack(spacing: 3) {
                                    if player.available {
                                        Image(systemName: "play.fill").font(.system(size: 8))
                                    }
                                    Text(group.start, format: .dateTime.hour().minute().second())
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!player.available)
                            .help(player.available ? L("player.seek") : "")
                            if isRenamable(group.label) {
                                Button {
                                    renameTarget = RenameTarget(
                                        from: group.label,
                                        to: group.label.contains(where: { $0.isNumber }) ? "" : group.label.replacingOccurrences(of: "?", with: "")
                                    )
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(group.label).font(.caption.bold())
                                        Image(systemName: "pencil").font(.caption2)
                                    }
                                    .foregroundStyle(speakerColor(group))
                                }
                                .buttonStyle(.plain)
                                .help(L("rename.hint"))
                            } else {
                                Text(group.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(speakerColor(group))
                            }
                            if let app = group.app {
                                Text(L("focus.prefix", app))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                                    .help(L("focus.help"))
                            }
                        }
                        Text(group.lines.map(\.text).joined(separator: " "))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        group.id == activeID ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .id(group.id)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: activeID) { _, newID in
            guard player.isPlaying, let newID else { return }
            withAnimation { proxy.scrollTo(newID, anchor: .center) }
        }
        }
    }

    // MARK: - Спикеры

    private func isRenamable(_ label: String) -> Bool {
        label != L("speaker.computer") && label != TranscriptGrouper.selfLabel
    }

    private func speakerColor(_ group: TranscriptGroup) -> Color {
        if group.label == TranscriptGrouper.selfLabel { return .accentColor }
        if group.label == L("speaker.computer") { return .orange }
        let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint]
        let hash = group.label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    // MARK: - Данные

    private func load() {
        metadata = session.loadMetadata()
        guard session.state == .done,
              let data = try? Data(contentsOf: session.transcriptJSON) else {
            lines = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([TranscriptLine].self, from: data)) ?? []
        // Старые транскрипты чистим теми же фильтрами при показе.
        lines = TranscriptCleaner.clean(decoded)
    }

    private func export() {
        exporting = true
        defer { exporting = false }
        do {
            let url = try store.export(session)
            exportResult = L("msg.exported", url.path)
        } catch {
            exportResult = "\(L("err.exportFailed")): \(error.localizedDescription)"
        }
    }
}

/// Диалог переименования спикера.
struct RenameSpeakerSheet: View {
    @ObservedObject private var loc = LocalizationManager.shared
    let target: SessionDetailView.RenameTarget
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(target: SessionDetailView.RenameTarget, onSave: @escaping (String) -> Void) {
        self.target = target
        self.onSave = onSave
        _name = State(initialValue: target.to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("rename.title", target.from)).font(.headline)
            TextField(L("rename.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            Text(L("rename.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                Button(L("common.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
