import AppKit
import Combine
import SwiftUI
import UserNotifications

/// Menu bar иконка (левый клик — окно, правый — меню), окна приложения, хоткей.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        AppStore.shared.registerHotKey()
        Notifier.configure(delegate: self)
        _ = Updater.shared  // запускает автопроверку обновлений

        AppStore.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // Эмодзи иконки могли поменять в настройках.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }

        updateIcon()

        if !UserDefaults.standard.bool(forKey: SettingsKeys.onboardingDone) {
            showOnboarding()
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView(onClose: { [weak self] in
                UserDefaults.standard.set(true, forKey: SettingsKeys.onboardingDone)
                self?.onboardingWindow?.close()
            }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Vaqlo"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.recorder.stop()
    }

    // Тап по уведомлению / кнопке.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let bundleID = info["bundleID"] as? String ?? ""
        let name = info["name"] as? String ?? ""

        switch response.actionIdentifier {
        case Notifier.actionAlways:
            AppStore.shared.applyFirstSeenChoice(bundleID: bundleID, name: name, policy: .auto)
        case Notifier.actionAsk:
            AppStore.shared.applyFirstSeenChoice(bundleID: bundleID, name: name, policy: .ask)
        case Notifier.actionNever:
            AppStore.shared.applyFirstSeenChoice(bundleID: bundleID, name: name, policy: .never)
        case Notifier.recordAction, UNNotificationDefaultActionIdentifier:
            AppStore.shared.startRecordingFromNotification()
        default:
            break
        }
    }

    // Показывать баннер, даже когда приложение активно.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func updateIcon() {
        let defaults = UserDefaults.standard
        let key = AppStore.shared.isRecording ? SettingsKeys.recordingEmoji : SettingsKeys.idleEmoji
        let emoji = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        if emoji.isEmpty {
            statusItem.button?.title = ""
            statusItem.button?.image = NSImage(
                systemSymbolName: AppStore.shared.isRecording ? "record.circle.fill" : "record.circle",
                accessibilityDescription: "Vaqlo"
            )
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = emoji
        }
    }

    // MARK: - Клики по иконке

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else {
            showMainWindow()
        }
    }

    private func showMenu() {
        let store = AppStore.shared
        let menu = NSMenu()

        let status = NSMenuItem(
            title: store.isRecording ? L("menu.recording") : L("menu.idle"),
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: store.isRecording ? "\(L("menu.stop")) (\(store.hotKeyDescription))" : "\(L("menu.start")) (\(store.hotKeyDescription))",
            action: #selector(toggleRecording), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let openItem = NSMenuItem(title: L("menu.open"), action: #selector(openMain), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let helpItem = NSMenuItem(title: L("menu.help"), action: #selector(openOnboarding), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let updateItem = NSMenuItem(title: L("menu.checkUpdates"), action: #selector(checkUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Трюк: временно вешаем меню и кликаем — иконка показывает меню, затем снимаем,
        // чтобы левый клик продолжил открывать окно.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRecording() { AppStore.shared.toggleRecording() }
    @objc private func openMain() { showMainWindow() }
    @objc private func openSettings() { showSettingsWindow() }
    @objc private func openOnboarding() { showOnboarding() }
    @objc private func checkUpdates() { Updater.shared.checkForUpdates() }
    @objc private func quit() {
        AppStore.shared.recorder.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Окна

    func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainView().environmentObject(AppStore.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Vaqlo"
            window.setContentSize(NSSize(width: 960, height: 660))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppStore.shared.library.rescan()
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(AppStore.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = L("set.title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
