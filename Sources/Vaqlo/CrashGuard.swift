import AppKit
import ServiceManagement

/// Автозапуск и автоперезапуск: приложение живёт как launchd-агент с
/// KeepAlive(SuccessfulExit=false) — если процесс умер не своей смертью
/// (краш, kill), macOS поднимает его сам в течение ~10 секунд. Штатный
/// выход (Quit, обновление Sparkle) агент не перезапускает.
@MainActor
enum CrashGuard {
    static let service = SMAppService.agent(plistName: "com.vaqlo.agent.plist")

    static var isEnabled: Bool { service.status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            // Старый login item не нужен — агент сам стартует при входе.
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            try service.register()
        } else {
            try service.unregister()
        }
    }

    /// Одноразовая миграция со старого login item (до 0.1.4) на агента.
    static func migrateFromLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        try? service.register()
        NSLog("CrashGuard: login item мигрирован на launchd-агента")
    }

    /// Запущены не через launchd (Finder/Spotlight/релонч Sparkle), а агент
    /// включён — переезжаем под launchd, чтобы KeepAlive следил за процессом:
    /// kickstart поднимает джоб и выходим. Если job уже работает, kickstart
    /// ничего не делает — но до сюда мы в этом случае и не дойдём (Launch
    /// Services активирует существующий инстанс, а не запускает второй).
    static func redirectThroughLaunchdIfNeeded() {
        guard ProcessInfo.processInfo.environment["VAQLO_LAUNCHD"] == nil,
              service.status == .enabled else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/com.vaqlo.agent"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return  // launchctl не запустился — работаем обычным процессом
        }
        if task.terminationStatus == 0 { exit(0) }
    }

    // MARK: - Метка некорректного завершения

    private static let markerKey = "runningMarker"

    /// Ставит метку «работаем» и возвращает true, если прошлый запуск
    /// не завершился штатно (краш/kill) — метку тогда никто не снял.
    static func markLaunchDetectingCrash() -> Bool {
        let defaults = UserDefaults.standard
        let crashed = defaults.bool(forKey: markerKey)
        defaults.set(true, forKey: markerKey)
        return crashed
    }

    static func markCleanShutdown() {
        UserDefaults.standard.set(false, forKey: markerKey)
    }
}
