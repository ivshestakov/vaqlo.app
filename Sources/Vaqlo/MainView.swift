import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var selectedSessionID: String?
    @State private var viewMode: TimelineMode = .day
    @State private var anchorDate = Date()
    @State private var showTrash = false
    @State private var keyMonitor: Any?
    @State private var searchQuery = ""

    enum TimelineMode: String, CaseIterable {
        case day = "День"
        case week = "Неделя"

        var title: String {
            switch self {
            case .day: L("mode.day")
            case .week: L("mode.week")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                Group {
                    if searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                        SearchResultsPane(query: searchQuery, selectedSessionID: $selectedSessionID)
                    } else {
                        TimelinePane(
                            mode: $viewMode,
                            anchorDate: $anchorDate,
                            selectedSessionID: $selectedSessionID
                        )
                    }
                }
                .frame(minWidth: 420, idealWidth: 540)

                Group {
                    if let id = selectedSessionID,
                       let session = store.library.sessions.first(where: { $0.id == id }) {
                        SessionDetailView(session: session, onDeleted: { selectedSessionID = nil })
                    } else {
                        ContentUnavailableView(
                            L("select.title"),
                            systemImage: "waveform",
                            description: Text(L("select.desc"))
                        )
                    }
                }
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showTrash) {
            TrashView()
                .environmentObject(store)
                .frame(width: 640, height: 460)
        }
        .alert(L("err.title"), isPresented: Binding(
            get: { store.recordingError != nil },
            set: { if !$0 { store.recordingError = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(store.recordingError ?? "")
        }
        .onAppear {
            store.library.rescan()
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: - Стрелки: переключение между записями дня

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Только главное окно и не во время ввода текста.
            guard event.window?.title == "Vaqlo",
                  !(event.window?.firstResponder is NSTextView) else { return event }
            switch event.keyCode {
            case 125: // ↓
                moveSelection(1)
                return nil
            case 126: // ↑
                moveSelection(-1)
                return nil
            default:
                return event
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        let cal = Calendar.current
        let visible: [Session]
        if viewMode == .day {
            visible = store.library.sessions(onDay: anchorDate).sorted { $0.start < $1.start }
        } else {
            guard let week = cal.dateInterval(of: .weekOfYear, for: anchorDate) else { return }
            visible = store.library.sessions
                .filter { week.contains($0.start) }
                .sorted { $0.start < $1.start }
        }
        guard !visible.isEmpty else { return }
        guard let currentID = selectedSessionID,
              let index = visible.firstIndex(where: { $0.id == currentID }) else {
            selectedSessionID = (delta > 0 ? visible.first : visible.last)?.id
            return
        }
        let next = index + delta
        if visible.indices.contains(next) {
            selectedSessionID = visible[next].id
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                store.toggleRecording()
            } label: {
                Label(
                    store.isRecording ? L("top.stop") : L("top.record"),
                    systemImage: store.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .foregroundStyle(store.isRecording ? .red : .primary)
            }
            .help(L("hotkey.help", store.hotKeyDescription))

            if store.isRecording {
                RecordingTimer(start: store.recorder.sessionStart ?? Date())
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(L("search.placeholder"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: Capsule())

            Spacer()

            if store.transcriber.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("top.transcribing")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    store.transcriber.transcribeAllPending()
                } label: {
                    Label(L("top.transcribeAll"), systemImage: "text.bubble")
                }
                .disabled(store.library.pending.isEmpty)
                .help(store.library.pending.isEmpty
                      ? L("top.noPending")
                      : L("top.pending", store.library.pending.count))
            }

            Button {
                showTrash = true
            } label: {
                Label(L("top.trash"), systemImage: "trash")
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
            } label: {
                Label(L("top.settings"), systemImage: "gearshape")
            }
        }
        .buttonStyle(.bordered)
        .padding(10)
    }
}

/// Левая панель в режиме поиска: результаты по всем транскриптам.
struct SearchResultsPane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var loc = LocalizationManager.shared
    let query: String
    @Binding var selectedSessionID: String?

    @State private var results: [TranscriptSearch.Result] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("search.results")).font(.headline)
                Spacer()
                Text("\(results.count)").foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(results, selection: $selectedSessionID) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(result.start, format: .dateTime.day().month().hour().minute())
                                .font(.callout.bold())
                            Spacer()
                            Text("\(result.matchCount)×").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(result.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(result.sessionID)
                }
            }
        }
        .onAppear(perform: run)
        .onChange(of: query) { run() }
    }

    private func run() {
        results = TranscriptSearch.search(query, in: store.library.sessions)
    }
}

/// Тикающий таймер записи в шапке.
struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(start))
            Text(String(format: "%d:%02d:%02d", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60))
                .font(.body.monospacedDigit())
                .foregroundStyle(.red)
        }
    }
}
