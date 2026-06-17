import AppIntents
import SwiftUI
import WidgetKit

@main
struct VaqloControlBundle: WidgetBundle {
    var body: some Widget {
        VaqloRecordControl()
    }
}

struct VaqloControlState {
    let isRecording: Bool
    let startedAt: Date?
    let pending: Int
}

/// Тоггл записи для Control Center: показывает статус записи (с какого времени)
/// и сколько сессий ждёт транскрибации.
struct VaqloRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VaqloShared.controlKind, provider: RecordingStateProvider()) { state in
            ControlWidgetToggle(
                title(for: state),
                isOn: state.isRecording,
                action: ToggleRecordingIntent()
            ) { isOn in
                Label(
                    isOn ? "Идёт запись" : "Начать запись",
                    systemImage: isOn ? "record.circle.fill" : "record.circle"
                )
            }
            .tint(.red)
        }
        .displayName("Vaqlo")
        .description("Запись микрофона и системного звука")
    }

    private func title(for state: VaqloControlState) -> String {
        if state.isRecording {
            if let startedAt = state.startedAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                return "Запись с \(formatter.string(from: startedAt))"
            }
            return "Идёт запись"
        }
        if state.pending > 0 {
            return "Vaqlo · \(state.pending) ждёт транскрибации"
        }
        return "Vaqlo"
    }
}

struct RecordingStateProvider: ControlValueProvider {
    var previewValue: VaqloControlState {
        VaqloControlState(isRecording: false, startedAt: nil, pending: 0)
    }

    func currentValue() async throws -> VaqloControlState {
        let defaults = VaqloShared.defaults
        let startedAt = defaults?.double(forKey: VaqloShared.startedAtKey) ?? 0
        return VaqloControlState(
            isRecording: defaults?.bool(forKey: VaqloShared.isRecordingKey) ?? false,
            startedAt: startedAt > 0 ? Date(timeIntervalSince1970: startedAt) : nil,
            pending: defaults?.integer(forKey: VaqloShared.pendingKey) ?? 0
        )
    }
}

struct ToggleRecordingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Переключить запись Vaqlo"

    @Parameter(title: "Запись")
    var value: Bool

    func perform() async throws -> some IntentResult {
        VaqloShared.defaults?.set(value, forKey: VaqloShared.requestedKey)
        DistributedNotificationCenter.default().postNotificationName(
            VaqloShared.toggleNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}
