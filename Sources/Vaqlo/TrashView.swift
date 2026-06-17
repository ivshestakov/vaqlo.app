import SwiftUI

/// Корзина: что лежит, когда удалится само, восстановить / удалить / очистить.
struct TrashView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [TrashEntry] = []
    @State private var selected: TrashEntry?
    @State private var confirmEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    L("trash.emptyTitle"),
                    systemImage: "trash",
                    description: Text(L("trash.emptyDesc"))
                )
            } else {
                HSplitView {
                    list.frame(minWidth: 300)
                    preview.frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(L("trash.confirmEmpty"), isPresented: $confirmEmpty) {
            Button(L("trash.emptyBtn"), role: .destructive) {
                TrashKeeper.emptyAll()
                reload()
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("trash.title")).font(.title3.bold())
            Text(L("trash.count", entries.count)).foregroundStyle(.secondary)
            Spacer()
            Button(L("trash.emptyBtn"), role: .destructive) { confirmEmpty = true }
                .disabled(entries.isEmpty)
            Button(L("common.close")) { dismiss() }
        }
        .padding(12)
    }

    private var list: some View {
        List(entries, selection: Binding(
            get: { selected?.id },
            set: { id in selected = entries.first { $0.id == id } }
        )) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: entry.kind == .session ? "waveform.circle" : "music.note")
                        .foregroundStyle(.secondary)
                    Text(entry.title).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(entry.kind == .session ? L("trash.kindSession") : L("trash.kindAudio"))
                    Text("·")
                    Text(timeLeftText(entry))
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button(L("trash.restore")) {
                        store.restoreFromTrash(entry)
                        reload()
                    }
                    .controlSize(.small)
                    Button(L("trash.deleteNow"), role: .destructive) {
                        TrashKeeper.deleteNow(entry)
                        reload()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 3)
            .tag(entry.id)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let selected, selected.kind == .session {
            ScrollView {
                Text(transcriptText(for: selected))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else if selected != nil {
            ContentUnavailableView(
                L("trash.audioTitle"),
                systemImage: "music.note",
                description: Text(L("trash.audioDesc"))
            )
        } else {
            ContentUnavailableView(L("trash.selectItem"), systemImage: "trash")
        }
    }

    private func transcriptText(for entry: TrashEntry) -> String {
        let md = URL(fileURLWithPath: entry.trashedPath).appendingPathComponent("transcript.md")
        if let text = try? String(contentsOf: md, encoding: .utf8) {
            return text
        }
        return L("trash.noTranscript")
    }

    private func timeLeftText(_ entry: TrashEntry) -> String {
        let seconds = entry.deleteAt.timeIntervalSinceNow
        if seconds <= 0 { return L("trash.leftSoon") }
        let days = Int(seconds / 86_400)
        if days > 0 { return L("trash.leftDays", days) }
        let hours = Int(seconds / 3600)
        return L("trash.leftHours", max(1, hours))
    }

    private func reload() {
        entries = TrashKeeper.all()
        if let selected, !entries.contains(selected) {
            self.selected = nil
        }
    }
}
