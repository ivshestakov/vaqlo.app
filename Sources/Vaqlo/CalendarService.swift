import AppKit
import EventKit
import Foundation

/// Участник встречи из календаря.
struct MeetingAttendee: Codable, Hashable {
    enum Status: String, Codable {
        case accepted, declined, tentative, pending, unknown
    }

    let name: String?
    let email: String?
    let status: Status
    let isMe: Bool
    let isOrganizer: Bool

    /// Имя для показа: имя из календаря, иначе часть email до «@».
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, let local = email.split(separator: "@").first { return String(local) }
        return "?"
    }
}

/// Информация о встрече, привязанная к сессии записи.
/// Поля после `source` появились позже — в старых session.json их нет (nil).
struct MeetingInfo: Codable {
    let title: String?
    let attendees: [String]   // имена участников (может быть пусто)
    let attendeeCount: Int
    let source: String        // "calendar" | "slack"

    /// EKEvent.calendarItemIdentifier — чтобы открыть событие и подсветить его на шкале.
    var eventID: String?
    /// Время по календарю (может не совпадать с фактической записью).
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var organizer: String?
    var people: [MeetingAttendee]?
    var location: String?
    var conferenceURL: String?
    /// Описание события без служебного блока Google Meet, обрезанное.
    var notes: String?
    var calendarName: String?
    /// Привязку выбрал пользователь — автоподбор её не перезаписывает.
    var manual: Bool?

    /// Сколько участников считается «большой группой» — список имён тогда не показываем целиком.
    static let largeGroupThreshold = 20

    var isLargeGroup: Bool { attendeeCount > Self.largeGroupThreshold }

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? L("meeting.untitled") : trimmed
    }

    /// Участники, кроме самого пользователя; для старых записей — из списка имён.
    var others: [MeetingAttendee] {
        if let people { return people.filter { !$0.isMe } }
        return attendees.map {
            MeetingAttendee(name: $0, email: nil, status: .unknown, isMe: false, isOrganizer: false)
        }
    }

    /// Контекст встречи для LLM: название, время по календарю, участники, описание.
    func promptContext() -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        var lines = ["- \(displayTitle)"]
        if let start = scheduledStart, let end = scheduledEnd {
            lines.append("- \(time.string(from: start))–\(time.string(from: end))")
        }
        let names = others.filter { $0.status != .declined }.map(\.displayName)
        if !names.isEmpty {
            let shown = names.prefix(Self.largeGroupThreshold).joined(separator: ", ")
            lines.append("- \(L("meeting.participants")): \(shown)\(names.count > Self.largeGroupThreshold ? " (+\(names.count - Self.largeGroupThreshold))" : "")")
        }
        if let organizer { lines.append("- \(L("meeting.organizer")): \(organizer)") }
        if let notes, !notes.isEmpty { lines.append("- \(L("meeting.agenda")): \(notes.prefix(800))") }
        return lines.joined(separator: "\n")
    }
}

/// Событие календаря для отрисовки на шкале (без ссылок на EventKit-объекты).
struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
    let attendeeCount: Int
}

/// Читает события из системного календаря через EventKit. Google-календарь сюда попадает,
/// если аккаунт подключён в «Системные настройки → Учётные записи интернета» — отдельный
/// OAuth не нужен, всё локально и работает офлайн.
enum CalendarService {
    static let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    static var isAuthorized: Bool { status == .fullAccess }

    /// Пользователь уже отказал — системный диалог второй раз не появится, только Настройки.
    static var isDenied: Bool { status == .denied || status == .restricted || status == .writeOnly }

    static func requestAccess() {
        if isDenied {
            openPrivacySettings()
            return
        }
        store.requestFullAccessToEvents { granted, _ in
            guard granted else { return }
            Task { @MainActor in AppStore.shared.calendarAccessGranted() }
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Подбор встречи к сессии

    /// Встреча, лучше всего совпадающая по времени с сессией. nil — нет доступа или совпадения.
    static func meeting(start: Date, end: Date, in eventStore: EKEventStore = store) -> MeetingInfo? {
        candidates(start: start, end: end, in: eventStore).first.map { info(for: $0) }
    }

    /// События, пересекающиеся с сессией, лучшие первыми. Отклонённые и отменённые — не встречи.
    static func candidates(start: Date, end: Date, in eventStore: EKEventStore = store) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let pad: TimeInterval = 300  // ±5 минут — встречу часто начинают/заканчивают не ровно
        let from = start.addingTimeInterval(-pad)
        let to = end.addingTimeInterval(pad)
        // Событие должно реально накрывать запись: ≥30% записи или ≥50% самого события.
        // Иначе часовая запись «прилипает» к встрече, которая закончилась на её 2-й минуте.
        let sessionLength = max(end.timeIntervalSince(start), 1)
        let events = fetch(from: from, to: to, in: eventStore).filter { e in
            let overlap = min(e.endDate, end).timeIntervalSince(max(e.startDate, start))
            let eventLength = max(e.endDate.timeIntervalSince(e.startDate), 1)
            return overlap >= sessionLength * 0.3 || overlap >= eventLength * 0.5
        }

        // Главное — сколько записи накрыто событием (самое длинное пересечение);
        // при близких значениях — есть участники / ссылка на звонок / ближе по началу.
        func score(_ e: EKEvent) -> Double {
            let overlap = min(e.endDate, to).timeIntervalSince(max(e.startDate, from))
            var s = max(overlap, 0)
            if (e.attendees?.count ?? 0) > 0 { s += 120 }
            if conferenceURL(e) != nil { s += 60 }
            s -= abs(e.startDate.timeIntervalSince(start)) * 0.25
            return s
        }
        return events.sorted { score($0) > score($1) }
    }

    /// Неполнодневные, не отменённые и не отклонённые мной события в интервале.
    static func fetch(from: Date, to: Date, in eventStore: EKEventStore = store) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        return eventStore.events(matching: predicate).filter { e in
            guard !e.isAllDay, e.status != .canceled else { return false }
            let me = e.attendees?.first { $0.isCurrentUser }
            return me?.participantStatus != .declined
        }
    }

    static func event(withID id: String) -> EKEvent? {
        store.calendarItem(withIdentifier: id) as? EKEvent
    }

    static func info(for event: EKEvent, manual: Bool = false) -> MeetingInfo {
        let people = (event.attendees ?? []).map { attendee(from: $0, organizer: event.organizer) }
        let names = people.filter { !$0.isMe }.map(\.displayName)
        let organizer = event.organizer.flatMap { o -> String? in
            o.isCurrentUser ? nil : attendee(from: o, organizer: nil).displayName
        }
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingInfo(
            title: event.title,
            attendees: names,
            attendeeCount: max(event.attendees?.count ?? 0, names.count),
            source: "calendar",
            eventID: event.calendarItemIdentifier,
            scheduledStart: event.startDate,
            scheduledEnd: event.endDate,
            organizer: organizer,
            people: people.isEmpty ? nil : people,
            location: (location?.isEmpty ?? true) ? nil : location,
            conferenceURL: conferenceURL(event)?.absoluteString,
            notes: cleanNotes(event.notes),
            calendarName: event.calendar?.title,
            manual: manual ? true : nil
        )
    }

    private static func attendee(from p: EKParticipant, organizer: EKParticipant?) -> MeetingAttendee {
        let status: MeetingAttendee.Status = switch p.participantStatus {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
        // EKParticipant.url — "mailto:…"; для ресурсов (переговорок) там бывает что-то другое.
        let url = p.url.absoluteString
        let email = url.hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)).removingPercentEncoding : nil
        let isOrganizer = organizer.map { $0.url == p.url } ?? false
        return MeetingAttendee(
            name: p.name?.trimmingCharacters(in: .whitespaces),
            email: email,
            status: status,
            isMe: p.isCurrentUser,
            isOrganizer: isOrganizer
        )
    }

    /// Ссылка на звонок: url события, иначе первая meet/zoom/teams-ссылка в месте или описании.
    static func conferenceURL(_ event: EKEvent) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true { return url }
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "webex.com", "telemost.yandex"]
        for text in [event.location, event.notes].compactMap({ $0 }) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { break }
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, hosts.contains(where: { url.host?.contains($0) == true }) { return url }
            }
        }
        return nil
    }

    /// Описание без HTML и без служебного блока «Join with Google Meet» (между `-::~:~::~:` маркерами).
    static func cleanNotes(_ notes: String?) -> String? {
        guard var text = notes else { return nil }
        if let marker = text.range(of: "-::~:~::~") { text = String(text[..<marker.lowerBound]) }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 1500 ? String(text.prefix(1500)) + "…" : text
    }

    /// Открывает событие в Календаре; если событие не найти — Календарь на дате.
    static func openInCalendar(_ meeting: MeetingInfo) {
        if let id = meeting.eventID,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Кэш событий календаря по дням для шкалы. Сбрасывается, когда календарь меняется
/// (синхронизация Google, правка в Календаре) или выдан доступ.
@MainActor
final class CalendarFeed: ObservableObject {
    static let shared = CalendarFeed()

    @Published private(set) var revision = 0
    private var cache: [Date: [CalendarEvent]] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: CalendarService.store, queue: .main
        ) { _ in
            Task { @MainActor in CalendarFeed.shared.invalidate() }
        }
    }

    func invalidate() {
        cache = [:]
        revision += 1
    }

    func events(on day: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        if let cached = cache[dayStart] { return cached }
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let events = CalendarService.fetch(from: dayStart, to: dayEnd).map { e in
            CalendarEvent(
                id: e.calendarItemIdentifier,
                title: (e.title ?? "").trimmingCharacters(in: .whitespaces),
                start: max(e.startDate, dayStart),
                end: min(e.endDate, dayEnd),
                color: e.calendar?.color ?? .systemBlue,
                attendeeCount: e.attendees?.count ?? 0
            )
        }
        .sorted { $0.start < $1.start }
        cache[dayStart] = events
        return events
    }
}

/// Дозаполняет встречу в записях, сделанных до выдачи доступа к календарю (или когда
/// подбор не сработал). Идёт в фоне на своём EKEventStore; пишет session.json только при совпадении.
enum MeetingBackfill {
    private static let queue = DispatchQueue(label: "vaqlo.meeting-backfill", qos: .utility)
    private static let store = EKEventStore()

    static func run(sessions: [Session], completion: @escaping @MainActor (Int) -> Void) {
        guard CalendarService.isAuthorized else { return }
        queue.async {
            var updated = 0
            for session in sessions {
                guard session.state != .recording, let end = session.end,
                      var metadata = session.loadMetadata(),
                      metadata.meeting == nil, metadata.meetingUnlinked != true,
                      let meeting = CalendarService.meeting(start: session.start, end: end, in: store)
                else { continue }
                metadata.meeting = meeting
                metadata.write(to: session.metadataURL)
                updated += 1
            }
            let count = updated
            Task { @MainActor in completion(count) }
        }
    }
}
