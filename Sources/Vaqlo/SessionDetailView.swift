import SwiftUI

/// Правая панель: развёрнутая информация о сессии, транскрипт, действия.
struct SessionDetailView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var transcriber = AppStore.shared.transcriber
    @ObservedObject private var summarizer = AppStore.shared.summarizer
    let session: Session
    var onDeleted: () -> Void = {}

    @State private var lines: [TranscriptLine] = []
    @State private var metadata: SessionMetadata?
    @State private var exportResult: String?
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var renameTarget: RenameTarget?
    /// События календаря около сессии — для меню «сменить встречу». Считаются в load(),
    /// а не в body: деталка перерисовывается на каждый тик плеера.
    @State private var meetingCandidates: [CalendarEvent] = []
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
            RenameSpeakerSheet(target: target, suggestions: nameSuggestions) { newName in
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
                        Text(meeting.displayTitle).font(.title3.bold()).lineLimit(1)
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
            meetingRows
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

    // MARK: - Встреча из календаря

    @ViewBuilder
    private var meetingRows: some View {
        if let meeting = metadata?.meeting {
            GridRow {
                Text(L("meeting.row")).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(meeting.displayTitle).bold().lineLimit(1).help(meeting.displayTitle)
                    Spacer(minLength: 4)
                    meetingMenu
                }
            }
            if let start = meeting.scheduledStart, let end = meeting.scheduledEnd {
                GridRow {
                    Text(L("meeting.scheduled")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("\(start, format: .dateTime.hour().minute())–\(end, format: .dateTime.hour().minute())")
                        if let calendar = meeting.calendarName {
                            Text("· \(calendar)").foregroundStyle(.secondary).lineLimit(1)
                        }
                        if meeting.eventID != nil {
                            Button { CalendarService.openInCalendar(meeting) } label: {
                                Image(systemName: "calendar")
                            }
                            .buttonStyle(.borderless)
                            .help(L("meeting.openCal"))
                        }
                        // Старые session.json могли сохранить ссылку до проверки домена.
                        if let link = meeting.conferenceURL.flatMap(URL.init(string:)),
                           CalendarService.isTrustedConferenceLink(link) {
                            Link(destination: link) { Image(systemName: "video") }
                                .help(L("meeting.join"))
                        }
                    }
                }
            }
            if let organizer = meeting.organizer {
                GridRow {
                    Text(L("meeting.organizer")).foregroundStyle(.secondary)
                    Text(organizer).lineLimit(1)
                }
            }
            let others = meeting.others
            if !others.isEmpty {
                GridRow {
                    Text(L("meeting.participants")).foregroundStyle(.secondary)
                    Text(participantsText(others))
                        .lineLimit(3)
                        .help(L("meeting.statusHelp"))
                }
            }
            if let notes = meeting.notes {
                GridRow {
                    Text(L("meeting.agenda")).foregroundStyle(.secondary)
                    Text(notes).lineLimit(2).help(notes)
                }
            }
        } else if CalendarService.isAuthorized, session.state != .recording {
            GridRow {
                Text(L("meeting.row")).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(L("meeting.none")).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    meetingMenu
                }
            }
        }
    }

    /// Ручная привязка: события календаря около записи + «это не встреча».
    private var meetingMenu: some View {
        let linkedID = metadata?.meeting?.eventID
        return Menu {
            if meetingCandidates.isEmpty {
                Text(L("meeting.noCandidates"))
            }
            ForEach(meetingCandidates) { event in
                Button {
                    store.setMeeting(for: session, eventID: event.id)
                } label: {
                    let title = "\(event.start.formatted(date: .omitted, time: .shortened)) · \(event.title.isEmpty ? L("meeting.untitled") : event.title)"
                    if event.id == linkedID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
            if metadata?.meeting != nil {
                Divider()
                Button(L("meeting.unlink")) { store.setMeeting(for: session, eventID: nil) }
            }
        } label: {
            Text(metadata?.meeting == nil ? L("meeting.link") : L("meeting.change"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
    }

    /// Участники через запятую: отклонившие — зачёркнуты, «под вопросом» — с «?».
    private func participantsText(_ people: [MeetingAttendee]) -> AttributedString {
        let limit = MeetingInfo.largeGroupThreshold
        var result = AttributedString()
        if people.count > limit {
            result += AttributedString(L("meeting.peopleCount", people.count) + ": ")
        }
        for (index, person) in people.prefix(limit).enumerated() {
            if index > 0 { result += AttributedString(", ") }
            var name = AttributedString(person.displayName + (person.status == .tentative ? "?" : ""))
            if person.status == .declined {
                name.strikethroughStyle = .single
                name.foregroundColor = .secondary
            }
            result += name
        }
        if people.count > limit { result += AttributedString(" …") }
        return result
    }

    /// Подсказки для переименования спикера: участники встречи, ещё не названные в транскрипте.
    private var nameSuggestions: [String] {
        let used = Set(lines.compactMap(\.speaker))
        return (metadata?.meeting?.others ?? [])
            .filter { $0.status != .declined }
            .map(\.displayName)
            .filter { !used.contains($0) }
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
        // Старые саммари (до очистки ссылок) тоже показываем очищенными.
        (try? String(contentsOf: Summarizer.summaryURL(for: session), encoding: .utf8)).map(SummarySanitizer.clean)
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
        // Кандидаты — с запасом в полчаса: запись могла начаться раньше/позже встречи.
        let pad: TimeInterval = 1800
        meetingCandidates = CalendarService.fetch(
            from: session.start.addingTimeInterval(-pad),
            to: (session.end ?? Date()).addingTimeInterval(pad)
        ).map {
            CalendarEvent(
                id: $0.calendarItemIdentifier, title: ($0.title ?? "").trimmingCharacters(in: .whitespaces),
                start: $0.startDate, end: $0.endDate, color: $0.calendar?.color ?? .systemBlue,
                attendeeCount: $0.attendees?.count ?? 0
            )
        }
        .sorted { $0.start < $1.start }
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
    let target: SessionDetailView.RenameTarget
    var suggestions: [String] = []
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(target: SessionDetailView.RenameTarget, suggestions: [String] = [], onSave: @escaping (String) -> Void) {
        self.target = target
        self.suggestions = suggestions
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
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("rename.suggestions")).font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { name = suggestion }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(width: 260, alignment: .leading)
            }
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
