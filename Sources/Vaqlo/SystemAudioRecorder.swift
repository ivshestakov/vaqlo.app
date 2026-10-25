import Accelerate
import AVFoundation
import CoreAudio
import AudioToolbox

/// Запись всего системного звука (микс всех процессов) через Core Audio process taps (macOS 14.4+).
/// Схема: системный tap → приватный агрегатный девайс → IOProc → чанки AAC.
///
/// Захват умеет умирать молча: после переоткрытия устройства вывода (переход из одного
/// звонка в другой в том же браузере, подключение/отключение AirPods, уход гарнитуры в HFP)
/// tap продолжает отдавать буферы, но из одних нулей — так 2026-10-22 пропал час голоса
/// собеседника. Поэтому захват — сменная «капсула» (tap + агрегат + IOProc), которую
/// recorder пересоздаёт по событиям устройств и по watchdog-у. Замена идёт без разрыва:
/// новая капсула поднимается рядом, старая пишет, пока новая не отдаст первый буфер.
final class SystemAudioRecorder {
    /// Один экземпляр tap + агрегата + IOProc.
    private final class Capture {
        let generation: Int
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var format: AVAudioFormat?
        var listeners: [AudioPropertyListener] = []
        init(generation: Int) { self.generation = generation }
    }

    /// Порог «тишины из нулей» при живом выводе чужого приложения, после которого
    /// захват считается мёртвым. Дальше — с нарастающей паузой: в звонке, где все молчат,
    /// браузер тоже может выводить чистые нули, а пересоздание там просто бесполезно.
    private static let silenceThresholds: [TimeInterval] = [6, 15, 30]
    /// Буферы не приходят вовсе — агрегат встал.
    private static let stallThreshold: TimeInterval = 3
    /// События устройств приходят пачками — пересоздаём один раз после затишья.
    private static let deviceDebounce: TimeInterval = 0.8

    /// Управление капсулами. IOProc-и живут на отдельной `ioQueue`: AudioDeviceStop ждёт
    /// завершения текущего IO-цикла, и вызов его с той же очереди, где крутится IOProc,
    /// мог бы взаимно заблокироваться.
    private let queue = DispatchQueue(label: "vaqlo.system-audio")
    private let ioQueue = DispatchQueue(label: "vaqlo.system-audio.io", qos: .userInteractive)
    private static let aggregateUIDPrefix = "com.vaqlo.aggregate."
    private var pendingSince = Date()
    /// Устройства, кроме наших агрегатов: создание собственной капсулы тоже меняет
    /// список устройств, и без фильтра каждое пересоздание вызывало бы следующее.
    private var knownDevices: Set<String> = []
    private var capture: Capture?
    private var pending: Capture?          // новая капсула, ждущая первого буфера
    private var nextGeneration = 1
    private var sink: ChunkedAudioFile?
    private var collected: [ChunkedAudioFile.ChunkInfo] = []
    private var directory: URL?
    private var running = false
    private var systemListeners: [AudioPropertyListener] = []
    private var watchdog: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var events: AudioEventLog?

    // Состояние, которое трогают IO-потоки капсул (под stateLock).
    private let stateLock = NSLock()
    private var activeGeneration = 0
    private var lastBufferAt = Date()
    private var lastSignalAt = Date()
    private var lastRebuildAt = Date.distantPast
    private var silentRebuilds = 0

    func start(directory: URL, events: AudioEventLog? = nil) throws {
        try queue.sync {
            self.directory = directory
            self.events = events
            collected = []
            running = true
            let now = Date()
            setState { $0.lastBufferAt = now; $0.lastSignalAt = now; $0.silentRebuilds = 0 }

            let first = try makeCapture()
            capture = first
            setState { $0.activeGeneration = first.generation }
            events?.add("sys", "start: output \(AudioHardware.name(of: AudioHardware.defaultOutput)), \(describe(first.format))")

            knownDevices = Self.externalDevices()
            installSystemListeners()
            startWatchdog()
        }
    }

    /// Пересоздать захват вручную (стенд, будущая кнопка «починить звук»).
    func requestRebuild(reason: String) {
        queue.async { self.rebuild(reason) }
    }

    var chunksSnapshot: [ChunkedAudioFile.ChunkInfo] {
        queue.sync { collected + (sink?.chunksSnapshot ?? []) }
    }

    func stop() -> [ChunkedAudioFile.ChunkInfo] {
        queue.sync {
            running = false
            watchdog?.cancel(); watchdog = nil
            debounce?.cancel(); debounce = nil
            systemListeners.forEach { $0.remove() }
            systemListeners = []
            // Сначала sink: даже если teardown Core Audio ниже частично провалится
            // и IOProc продолжит дёргаться, писать на диск он уже не сможет.
            sink?.close()
            let all = collected + (sink?.chunks ?? [])
            sink = nil
            collected = []
            if let pending { destroy(pending) }
            if let capture { destroy(capture) }
            pending = nil
            capture = nil
            return all
        }
    }

    // MARK: - Капсула захвата

    private func makeCapture() throws -> Capture {
        let capture = Capture(generation: nextGeneration)
        nextGeneration += 1

        // Tap на все процессы: пустой список + isExclusive = «все, кроме перечисленных».
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.uuid = UUID()
        description.name = "Vaqlo System Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = true

        var status = AudioHardwareCreateProcessTap(description, &capture.tapID)
        guard status == noErr, capture.tapID != kAudioObjectUnknown else {
            throw VaqloError(L("err.sysTap") + " (OSStatus \(status))")
        }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(capture.tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            destroy(capture)
            throw VaqloError("Couldn't read tap format (OSStatus \(status))")
        }
        capture.format = format

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vaqlo Aggregate",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [Any](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &capture.aggregateID)
        guard status == noErr, capture.aggregateID != kAudioObjectUnknown else {
            destroy(capture)
            throw VaqloError("Couldn't create aggregate device (OSStatus \(status))")
        }

        let sink = try sinkFor(format)
        let generation = capture.generation
        status = AudioDeviceCreateIOProcIDWithBlock(&capture.ioProcID, capture.aggregateID, ioQueue) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            let bufferList = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil) else { return }
            switch self.accept(buffer, generation: generation) {
            case .drop: return
            case .write: break
            case .writeNewChunk: sink.startNewChunk()
            }
            let time = inInputTime.pointee
            sink.write(buffer, hostTime: time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil)
        }
        guard status == noErr, let ioProcID = capture.ioProcID else {
            destroy(capture)
            throw VaqloError("Couldn't create IOProc (OSStatus \(status))")
        }

        status = AudioDeviceStart(capture.aggregateID, ioProcID)
        guard status == noErr else {
            destroy(capture)
            throw VaqloError("Couldn't start system audio recording (OSStatus \(status))")
        }

        // Формат tap меняется вместе с частотой устройства вывода (AirPods в HFP — 16/24 кГц):
        // буферы старого формата дальше читаются как мусор или тишина.
        if let listener = AudioPropertyListener(object: capture.tapID, selector: kAudioTapPropertyFormat,
                                                queue: queue, handler: { [weak self] in
            self?.scheduleRebuild("tap format changed")
        }) {
            capture.listeners.append(listener)
        }
        return capture
    }

    /// Писатель чанков под формат капсулы: тот же, если формат не изменился (нумерация
    /// и текущий чанк продолжаются), иначе — новый, со следующим номером.
    private func sinkFor(_ format: AVAudioFormat) throws -> ChunkedAudioFile {
        if let sink, sink.processingFormat == format { return sink }
        guard let directory else { throw VaqloError(L("err.sysTap")) }
        let startIndex = sink?.lastIndex ?? collected.count
        if let old = sink {
            old.close()
            collected += old.chunks
        }
        let fresh = ChunkedAudioFile(directory: directory, prefix: "sys", processingFormat: format, startIndex: startIndex)
        sink = fresh
        return fresh
    }

    private func destroy(_ capture: Capture) {
        capture.listeners.forEach { $0.remove() }
        capture.listeners = []
        var status: OSStatus
        if let ioProcID = capture.ioProcID, capture.aggregateID != kAudioObjectUnknown {
            status = AudioDeviceStop(capture.aggregateID, ioProcID)
            if status != noErr { NSLog("SystemAudioRecorder: AudioDeviceStop failed (OSStatus \(status))") }
            status = AudioDeviceDestroyIOProcID(capture.aggregateID, ioProcID)
            if status != noErr { NSLog("SystemAudioRecorder: AudioDeviceDestroyIOProcID failed (OSStatus \(status))") }
        }
        capture.ioProcID = nil
        if capture.aggregateID != kAudioObjectUnknown {
            status = AudioHardwareDestroyAggregateDevice(capture.aggregateID)
            if status != noErr { NSLog("SystemAudioRecorder: AudioHardwareDestroyAggregateDevice failed (OSStatus \(status))") }
            capture.aggregateID = kAudioObjectUnknown
        }
        if capture.tapID != kAudioObjectUnknown {
            status = AudioHardwareDestroyProcessTap(capture.tapID)
            if status != noErr { NSLog("SystemAudioRecorder: AudioHardwareDestroyProcessTap failed (OSStatus \(status))") }
            capture.tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Буферы (IO-поток капсулы, он же `queue`)

    /// Пишет ли буфер эта капсула. Новая капсула перехватывает запись на первом же
    /// буфере, старая с этого момента молчит — без дыр и без двойной записи.
    private enum Verdict { case drop, write, writeNewChunk }

    private func accept(_ buffer: AVAudioPCMBuffer, generation: Int) -> Verdict {
        let now = Date()
        let hasSignal = Self.hasSignal(buffer)
        stateLock.lock()
        defer { stateLock.unlock() }
        if generation < activeGeneration { return .drop }
        if generation > activeGeneration {
            activeGeneration = generation
            queue.async { [weak self] in self?.promote(generation) }
        }
        // Перерыв в потоке буферов (агрегат вставал) — новый чанк, чтобы его startTime
        // совпал с реальным временем, иначе sys-дорожка «съедет» относительно mic.
        let gap = now.timeIntervalSince(lastBufferAt) > 0.5
        lastBufferAt = now
        if hasSignal {
            lastSignalAt = now
            silentRebuilds = 0
        }
        return gap ? .writeNewChunk : .write
    }

    /// Хоть один ненулевой сэмпл. Мёртвый tap отдаёт ровно 0.0, живая тишина — почти всегда нет.
    private static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return true }
        let frames = vDSP_Length(buffer.frameLength) * vDSP_Length(buffer.stride)
        guard frames > 0 else { return false }
        for channel in 0..<Int(buffer.format.isInterleaved ? 1 : buffer.format.channelCount) {
            var peak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &peak, frames)
            if peak > 0 { return true }
        }
        return false
    }

    /// Новая капсула дала первый буфер — старую можно гасить.
    private func promote(_ generation: Int) {
        guard let pending, pending.generation == generation else { return }
        if let old = capture { destroy(old) }
        capture = pending
        self.pending = nil
        events?.add("sys", "switched to capture #\(generation)")
    }

    // MARK: - Пересоздание

    private func scheduleRebuild(_ reason: String) {
        guard running else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason) }
        debounce = work
        queue.asyncAfter(deadline: .now() + Self.deviceDebounce, execute: work)
    }

    private func rebuild(_ reason: String) {
        guard running else { return }
        // Предыдущая замена так и не дала буфера — выбрасываем её и пробуем снова.
        if let stale = pending {
            destroy(stale)
            pending = nil
        }
        setState { $0.lastRebuildAt = Date() }
        do {
            let fresh = try makeCapture()
            pending = fresh
            pendingSince = Date()
            events?.add("sys", "rebuild (\(reason)): output \(AudioHardware.name(of: AudioHardware.defaultOutput)), \(describe(fresh.format))")
        } catch {
            events?.add("sys", "rebuild (\(reason)) failed: \(error.localizedDescription)")
        }
    }

    /// Смена устройства вывода (AirPods подключили/сняли) и изменение списка устройств.
    private func installSystemListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [(AudioObjectPropertySelector, String)] = [
            (kAudioHardwarePropertyDefaultOutputDevice, "default output changed"),
            (kAudioHardwarePropertyDefaultSystemOutputDevice, "system output changed"),
            (kAudioHardwarePropertyDevices, "device list changed"),
        ]
        systemListeners = selectors.compactMap { selector, reason in
            AudioPropertyListener(object: system, selector: selector, queue: queue) { [weak self] in
                guard let self else { return }
                if selector == kAudioHardwarePropertyDevices {
                    let devices = Self.externalDevices()
                    guard devices != self.knownDevices else { return }  // это были наши агрегаты
                    self.knownDevices = devices
                }
                self.scheduleRebuild(reason)
            }
        }
    }

    /// UID всех аудиоустройств, кроме агрегатов самого Vaqlo.
    private static func externalDevices() -> Set<String> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        var result: Set<String> = []
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &uid) {
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, $0)
            }
            let value = uid as String
            if status == noErr, !value.hasPrefix(aggregateUIDPrefix) { result.insert(value) }
        }
        return result
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        watchdog = timer
    }

    private func checkHealth() {
        guard running else { return }
        let now = Date()
        if pending != nil {
            // Замена не дала ни одного буфера — пробуем ещё раз (rebuild выбросит её).
            if now.timeIntervalSince(pendingSince) > Self.stallThreshold { rebuild("replacement capture gave no buffers") }
            return
        }
        stateLock.lock()
        let sinceBuffer = now.timeIntervalSince(lastBufferAt)
        let sinceSignal = now.timeIntervalSince(lastSignalAt)
        let sinceRebuild = now.timeIntervalSince(lastRebuildAt)
        let attempt = silentRebuilds
        stateLock.unlock()

        if sinceBuffer > Self.stallThreshold, sinceRebuild > Self.stallThreshold {
            rebuild("no buffers for \(Int(sinceBuffer)) s")
            return
        }
        let threshold = Self.silenceThresholds[min(attempt, Self.silenceThresholds.count - 1)]
        guard sinceSignal > threshold, sinceRebuild > threshold else { return }
        // Нули при молчащей системе — норма; при играющем чужом приложении — мёртвый захват.
        guard MeetingDetector.isAnotherAppPlayingAudio() else { return }
        setState { $0.silentRebuilds += 1 }
        rebuild("digital silence for \(Int(sinceSignal)) s while another app plays audio")
    }

    // MARK: - Утилиты

    private struct State {
        var lastBufferAt: Date
        var lastSignalAt: Date
        var lastRebuildAt: Date
        var silentRebuilds: Int
        var activeGeneration: Int
    }

    private func setState(_ change: (inout State) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = State(lastBufferAt: lastBufferAt, lastSignalAt: lastSignalAt, lastRebuildAt: lastRebuildAt,
                          silentRebuilds: silentRebuilds, activeGeneration: activeGeneration)
        change(&state)
        lastBufferAt = state.lastBufferAt
        lastSignalAt = state.lastSignalAt
        lastRebuildAt = state.lastRebuildAt
        silentRebuilds = state.silentRebuilds
        activeGeneration = state.activeGeneration
    }

    private func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "no format" }
        return "\(Int(format.sampleRate)) Hz × \(format.channelCount)"
    }
}
