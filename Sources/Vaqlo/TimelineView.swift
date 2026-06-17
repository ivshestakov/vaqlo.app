import SwiftUI

/// Левая панель: переключатель день/неделя, навигация по датам, шкала с блоками сессий.
struct TimelinePane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var loc = LocalizationManager.shared
    @Binding var mode: MainView.TimelineMode
    @Binding var anchorDate: Date
    @Binding var selectedSessionID: String?

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if mode == .day {
                    DayColumn(day: anchorDate, selectedSessionID: $selectedSessionID, showHourLabels: true)
                        .padding(.horizontal, 12)
                } else {
                    weekGrid
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $mode) {
                ForEach(MainView.TimelineMode.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button(L("today")) { anchorDate = Date() }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }

            Text(rangeTitle)
                .font(.headline)
                .frame(minWidth: 130, alignment: .trailing)
        }
        .padding(10)
    }

    private var weekGrid: some View {
        let days = weekDays
        return HStack(alignment: .top, spacing: 4) {
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : .secondary)
                    DayColumn(day: day, selectedSessionID: $selectedSessionID, showHourLabels: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.locale, LocalizationManager.shared.locale)
        .padding(.horizontal, 12)
    }

    private var weekDays: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var rangeTitle: String {
        let formatter = DateFormatter()
        formatter.locale = LocalizationManager.shared.locale
        if mode == .day {
            formatter.dateFormat = "E, d MMM"
            return formatter.string(from: anchorDate)
        }
        formatter.dateFormat = "d MMM"
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        return "\(formatter.string(from: first)) – \(formatter.string(from: last))"
    }

    private func shift(_ direction: Int) {
        let component: Calendar.Component = mode == .day ? .day : .weekOfYear
        anchorDate = calendar.date(byAdding: component, value: direction, to: anchorDate) ?? anchorDate
    }
}

/// Вертикальная шкала 00–24 одного дня с блоками сессий.
struct DayColumn: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var loc = LocalizationManager.shared
    let day: Date
    @Binding var selectedSessionID: String?
    let showHourLabels: Bool

    private var hourHeight: CGFloat { showHourLabels ? 36 : 14 }
    private var labelWidth: CGFloat { showHourLabels ? 40 : 0 }

    var body: some View {
        let sessions = store.library.sessions(onDay: day)
        ZStack(alignment: .topLeading) {
            // Часовая сетка
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    HStack(spacing: 4) {
                        if showHourLabels {
                            Text(String(format: "%02d", hour))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: labelWidth - 8, alignment: .trailing)
                        }
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 1)
                    }
                    .frame(height: hourHeight, alignment: .top)
                }
            }

            ForEach(sessions) { session in
                SessionBlock(session: session, isSelected: session.id == selectedSessionID)
                    .frame(height: blockHeight(session))
                    .padding(.leading, labelWidth)
                    .offset(y: yOffset(session))
                    .onTapGesture { selectedSessionID = session.id }
            }
        }
        .frame(height: hourHeight * 24)
    }

    private func yOffset(_ session: Session) -> CGFloat {
        let cal = Calendar.current
        let minutes = CGFloat(cal.component(.hour, from: session.start)) * 60
            + CGFloat(cal.component(.minute, from: session.start))
        return minutes / 60 * hourHeight
    }

    private func blockHeight(_ session: Session) -> CGFloat {
        max(showHourLabels ? 14 : 5, CGFloat(session.duration) / 3600 * hourHeight)
    }
}

struct SessionBlock: View {
    let session: Session
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(isSelected ? 0.9 : 0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .help(helpText)
    }

    private var color: Color {
        switch session.state {
        case .recording: .red
        case .pending: .orange
        case .transcribing: .purple
        case .done: .green
        }
    }

    private var helpText: String {
        let formatter = DateFormatter()
        formatter.locale = LocalizationManager.shared.locale
        formatter.dateFormat = "HH:mm"
        let status = switch session.state {
        case .recording: L("block.recording")
        case .pending: L("block.pending")
        case .transcribing: L("block.transcribing")
        case .done: L("block.done")
        }
        return L("block.tooltip", formatter.string(from: session.start), Int(session.duration / 60), status)
    }
}
