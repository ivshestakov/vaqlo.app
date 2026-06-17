import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Первый запуск: проводит через разрешения, чтобы системные диалоги не сыпались вразнобой.
struct OnboardingView: View {
    var onClose: () -> Void

    @ObservedObject private var loc = LocalizationManager.shared
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notifAuthorized = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axTrusted = AccessibilityHelper.isTrusted
    @State private var calAuthorized = CalendarService.isAuthorized
    @State private var refreshTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("onb.welcome")).font(.title2.bold())
                Text(L("onb.subtitle"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                row(
                    icon: "mic.fill",
                    title: L("onb.mic.title"),
                    subtitle: L("onb.mic.sub"),
                    done: micStatus == .authorized,
                    actionTitle: micStatus == .notDetermined ? L("onb.allow") : L("onb.openSettings")
                ) { requestMic() }

                Divider()

                row(
                    icon: "speaker.wave.2.fill",
                    title: L("onb.sys.title"),
                    subtitle: L("onb.sys.sub"),
                    done: false,
                    showCheck: false,
                    actionTitle: L("onb.openSettings")
                ) { openPrivacy("Microphone") }

                Divider()

                row(
                    icon: "bell.fill",
                    title: L("onb.notif.title"),
                    subtitle: L("onb.notif.sub"),
                    done: notifAuthorized,
                    actionTitle: L("onb.allow")
                ) { requestNotifications() }

                Divider()

                row(
                    icon: "person.wave.2.fill",
                    title: L("onb.ax.title"),
                    subtitle: L("onb.ax.sub"),
                    done: axTrusted,
                    actionTitle: L("onb.allow")
                ) { AccessibilityHelper.prompt() }

                Divider()

                row(
                    icon: "calendar",
                    title: L("onb.cal.title"),
                    subtitle: L("onb.cal.sub"),
                    done: calAuthorized,
                    actionTitle: L("onb.allow")
                ) { CalendarService.requestAccess() }

                Divider()

                row(
                    icon: "power",
                    title: L("onb.login.title"),
                    subtitle: L("onb.login.sub"),
                    done: launchAtLogin,
                    actionTitle: launchAtLogin ? L("onb.login.off") : L("onb.login.on")
                ) { toggleLogin() }
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Label(L("onb.hotkey", AppStore.shared.hotKeyDescription), systemImage: "keyboard")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("onb.done")) { onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .id(refreshTick)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
        .task { await checkNotifications() }
    }

    private func row(icon: String, title: String, subtitle: String, done: Bool,
                     showCheck: Bool = true, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showCheck, done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(12)
    }

    private func requestMic() {
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
            }
        } else {
            openPrivacy("Microphone")
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { await checkNotifications() }
        }
    }

    private func checkNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { notifAuthorized = settings.authorizationStatus == .authorized }
    }

    private func toggleLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login toggle: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func refreshStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        axTrusted = AccessibilityHelper.isTrusted
        calAuthorized = CalendarService.isAuthorized
        Task { await checkNotifications() }
        refreshTick += 1
    }

    private func openPrivacy(_ section: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(section)")!
        NSWorkspace.shared.open(url)
    }
}
