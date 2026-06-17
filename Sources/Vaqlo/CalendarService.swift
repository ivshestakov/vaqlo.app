import EventKit
import Foundation

/// Информация о встрече, привязанная к сессии записи.
struct MeetingInfo: Codable {
    let title: String?
    let attendees: [String]   // имена участников (может быть пусто)
    let attendeeCount: Int
    let source: String        // "calendar" | "slack"

    /// Сколько участников считается «большой группой».
    static let largeGroupThreshold = 20

    var isLargeGroup: Bool { attendeeCount > Self.largeGroupThreshold }
}

/// Читает события из системного календаря (включая подключённый Google-аккаунт) через EventKit.
enum CalendarService {
    static let store = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestAccess() {
        store.requestFullAccessToEvents { _, _ in }
    }

    /// Встреча, пересекающаяся по времени с сессией. nil — нет доступа или совпадения.
    static func meeting(start: Date, end: Date) -> MeetingInfo? {
        guard isAuthorized else { return nil }
        let pad: TimeInterval = 300  // ±5 минут — встречу часто начинают/заканчивают не ровно
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-pad),
            end: end.addingTimeInterval(pad),
            calendars: nil
        )
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        guard !events.isEmpty else { return nil }

        // Лучшее совпадение: событие, накрывающее середину сессии; при равенстве —
        // у которого есть участники / ссылка на конференцию / ближе по началу.
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        func score(_ e: EKEvent) -> Int {
            var s = 0
            if e.startDate <= mid, e.endDate >= mid { s += 100 }
            if (e.attendees?.count ?? 0) > 0 { s += 10 }
            if e.url != nil || (e.location?.contains("http") ?? false) { s += 5 }
            s -= Int(abs(e.startDate.timeIntervalSince(start)) / 60)  // штраф за расхождение начала
            return s
        }
        guard let event = events.max(by: { score($0) < score($1) }) else { return nil }

        let names = (event.attendees ?? [])
            .compactMap { $0.name }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return MeetingInfo(
            title: event.title,
            attendees: names,
            attendeeCount: max(event.attendees?.count ?? 0, names.count),
            source: "calendar"
        )
    }
}
