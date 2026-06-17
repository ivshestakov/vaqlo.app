import Foundation
import Sparkle

/// Обёртка над Sparkle: автопроверка обновлений + ручной «Проверить обновления».
/// Фид и публичный ключ берутся из Info.plist (SUFeedURL / SUPublicEDKey).
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true — сам поднимет планировщик автопроверок (раз в сутки).
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
