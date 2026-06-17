import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)

// pkill/SIGTERM: штатно закрываем запись (финализация m4a + session.json), иначе
// текущий чанк остаётся нечитаемым.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    MainActor.assumeIsolated {
        AppStore.shared.recorder.stop()
        NSApp.terminate(nil)
    }
}
sigtermSource.resume()

app.run()
