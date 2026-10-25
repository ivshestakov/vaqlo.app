import SwiftUI

/// Левая панель: переключатель день/неделя, навигация по датам, шкала с блоками сессий.
struct TimelinePane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var library = AppStore.shared.library
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

/// Вертикальная шкала 00–24 одного дня: слева — события календаря, справа — сессии записи.
struct DayColumn: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var library = AppStore.shared.library
    @ObservedObject private var feed = CalendarFeed.shared
    @AppStorage(SettingsKeys.calendarOnTimeline) private var showCalendar = true
    let day: Date
    @Binding var selectedSessionID: String?
    let showHourLabels: Bool

    private var hourHeight: CGFloat { showHourLabels ? 36 : 14 }
    private var labelWidth: CGFloat { showHourLabels ? 40 : 0 }

    var body: some View {
        let sessions = store.library.sessions(onDay: day)
        let events = showCalendar ? feed.events(on: day) : []
        let selectedEventID = sessions.first { $0.id == selectedSessionID }?.meetingEventID
        let recordedEventIDs = Set(sessions.compactMap(\.meetingEventID))
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

            GeometryReader { geo in
                let width = max(geo.size.width - labelWidth, 0)
                let eventLane = events.isEmpty ? 0 : (width * 0.42).rounded()
                let sessionX = labelWidth + (events.isEmpty ? 0 : eventLane + 3)
                let sessionWidth = max(width - (sessionX - labelWidth), 0)

                ForEach(EventLayout.place(events)) { placed in
                    let columnWidth = eventLane / CGFloat(placed.columns)
                    EventBlock(
                        event: placed.event,
                        isRecorded: recordedEventIDs.contains(placed.event.id),
                        isSelected: placed.event.id == selectedEventID,
                        showTitle: showHourLabels
                    )
                    .frame(width: max(columnWidth - 1, 1), height: height(placed.event.start, placed.event.end, min: 4))
                    .offset(x: labelWidth + columnWidth * CGFloat(placed.column), y: yOffset(placed.event.start))
                    .onTapGesture {
                        // Записанная встреча → открыть её запись.
                        if let session = sessions.first(where: { $0.meetingEventID == placed.event.id }) {
                            selectedSessionID = session.id
                        }
                    }
                }

                ForEach(sessions) { session in
                    SessionBlock(session: session, isSelected: session.id == selectedSessionID, showTitle: showHourLabels)
                        .frame(width: sessionWidth, height: blockHeight(session))
                        .offset(x: sessionX, y: yOffset(session.start))
                        .onTapGesture { selectedSessionID = session.id }
                }
            }
        }
        .frame(height: hourHeight * 24)
    }

    private func yOffset(_ date: Date) -> CGFloat {
        let cal = Calendar.current
        let minutes = CGFloat(cal.component(.hour, from: date)) * 60
            + CGFloat(cal.component(.minute, from: date))
        return minutes / 60 * hourHeight
    }

    private func height(_ start: Date, _ end: Date, min minHeight: CGFloat) -> CGFloat {
        max(minHeight, CGFloat(end.timeIntervalSince(start)) / 3600 * hourHeight)
    }

    private func blockHeight(_ session: Session) -> CGFloat {
        max(showHourLabels ? 14 : 5, CGFloat(session.duration) / 3600 * hourHeight)
    }
}

/// Раскладка пересекающихся событий по колонкам (как в Календаре): в группе
/// пересекающихся событий каждое получает свою колонку, ширина делится поровну.
enum EventLayout {
    struct Placed: Identifiable {
        let event: CalendarEvent
        let column: Int
        let columns: Int
        var id: String { "\(event.id)@\(event.start.timeIntervalSince1970)" }
    }

    static func place(_ events: [CalendarEvent]) -> [Placed] {
        var result: [Placed] = []
        var group: [(event: CalendarEvent, column: Int)] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast

        func flush() {
            result += group.map { Placed(event: $0.event, column: $0.column, columns: max(columnEnds.count, 1)) }
            group = []
            columnEnds = []
        }

        for event in events.sorted(by: { $0.start < $1.start }) {
            if event.start >= groupEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= event.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(event.end) } else { columnEnds[column] = event.end }
            group.append((event, column))
            groupEnd = max(groupEnd, event.end)
        }
        flush()
        return result
    }
}

/// Событие календаря на шкале. Записанные — насыщеннее, незаписанные — бледные.
struct EventBlock: View {
    let event: CalendarEvent
    let isRecorded: Bool
    let isSelected: Bool
    let showTitle: Bool

    var body: some View {
        let color = Color(nsColor: event.color)
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(isRecorded ? 0.3 : 0.12))
            .overlay(alignment: .leading) {
                Rectangle().fill(color.opacity(isRecorded ? 0.9 : 0.45)).frame(width: 2)
            }
            .overlay(alignment: .topLeading) {
                if showTitle {
                    Text(event.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.primary.opacity(isRecorded ? 0.9 : 0.55))
                        .padding(.leading, 5)
                        .padding(.trailing, 2)
                        .padding(.top, 1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSelected ? color : .clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(helpText)
    }

    private var helpText: String {
        let formatter = DateFormatter()
        formatter.locale = LocalizationManager.shared.locale
        formatter.dateFormat = "HH:mm"
        var parts = ["\(formatter.string(from: event.start))–\(formatter.string(from: event.end))",
                     event.title.isEmpty ? L("meeting.untitled") : event.title]
        if event.attendeeCount > 0 { parts.append(L("meeting.peopleCount", event.attendeeCount)) }
        if !isRecorded { parts.append(L("meeting.notRecorded")) }
        return parts.joined(separator: " · ")
    }
}

struct SessionBlock: View {
    let session: Session
    let isSelected: Bool
    var showTitle = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(isSelected ? 0.9 : 0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topLeading) {
                if showTitle, let title = session.meetingTitle {
                    Text(title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
        let tooltip = L("block.tooltip", formatter.string(from: session.start), Int(session.duration / 60), status)
        return session.meetingTitle.map { "\($0)\n\(tooltip)" } ?? tooltip
    }
}
