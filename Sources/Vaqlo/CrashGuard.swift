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
    /// kickstart поднимает джоб, дожидаемся реального спавна и выходим.
    /// Если джоб сломан (типовой случай — бандл заменили по тому же пути,
    /// BTM-запись устарела и спавн падает с EX_CONFIG), перерегистрируем
    /// агента; совсем не заводится — работаем без супервизии, но и без дублей.
    static func redirectThroughLaunchdIfNeeded() {
        guard ProcessInfo.processInfo.environment["VAQLO_LAUNCHD"] == nil,
              service.status == .enabled else { return }
        if kickstartConfirmed() { exit(0) }
        NSLog("CrashGuard: джоб агента не спавнится — перерегистрирую")
        try? service.unregister()
        try? service.register()
        if kickstartConfirmed() { exit(0) }
        NSLog("CrashGuard: агент не заводится — снимаю регистрацию, работаем без автоперезапуска")
        try? service.unregister()
    }

    /// kickstart + подтверждение, что launchd реально запустил процесс джоба:
    /// код возврата kickstart успешен и тогда, когда последующий спавн падает.
    private static func kickstartConfirmed() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/com.vaqlo.agent"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return false }
        guard task.terminationStatus == 0 else { return false }
        for _ in 0..<15 {  // до ~3 с на спавн
            if let pid = jobPID(), pid != getpid() { return true }
            usleep(200_000)
        }
        return false
    }

    /// pid работающего процесса джоба из `launchctl print`, если он есть.
    private static func jobPID() -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/com.vaqlo.agent"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst(6)) {
                return pid
            }
        }
        return nil
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
