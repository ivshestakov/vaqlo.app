import CoreAudio
import Foundation

/// Событие аудио-конвейера записи: перезапуск захвата, смена устройства и т.п.
/// Пишется в session.json, чтобы потерю звука можно было разобрать постфактум —
/// системные логи Core Audio живут считаные часы.
struct AudioEvent: Codable {
    let time: Date
    let track: String   // "mic" | "sys"
    let event: String   // «rebuild: default output changed», «engine restart: config change»…
}

/// Потокобезопасный журнал событий одной сессии (пишут аудио-очереди, читает RecordingController).
final class AudioEventLog {
    private let lock = NSLock()
    private var events: [AudioEvent] = []
    /// Защита от разрастания session.json при «шторме» событий.
    private let limit = 500

    func add(_ track: String, _ event: String) {
        NSLog("AudioEvent[\(track)]: \(event)")
        lock.lock()
        defer { lock.unlock() }
        guard events.count < limit else { return }
        events.append(AudioEvent(time: Date(), track: track, event: event))
    }

    var snapshot: [AudioEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Слушатель свойства Core Audio с гарантированной отпиской (блок нужно снимать тем же экземпляром).
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          queue: DispatchQueue, handler: @escaping () -> Void) {
        guard object != kAudioObjectUnknown else { return nil }
        self.objectID = object
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr else { return nil }
        installed = true
    }

    func remove() {
        guard installed else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        installed = false
    }

    deinit { remove() }
}

enum AudioHardware {
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static var defaultOutput: AudioObjectID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultInput: AudioObjectID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    static func name(of device: AudioObjectID) -> String {
        guard device != kAudioObjectUnknown else { return "none" }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? name as String : "#\(device)"
    }
}
