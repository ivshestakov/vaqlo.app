import AVFoundation
import CoreAudio
import AudioToolbox

/// Запись всего системного звука (микс всех процессов) через Core Audio process taps (macOS 14.4+).
/// Схема: системный tap → приватный агрегатный девайс → IOProc → чанки AAC.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sink: ChunkedAudioFile?
    private var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "vaqlo.system-audio")

    func start(directory: URL) throws {
        // Tap на все процессы: пустой список + mixdown всего системного вывода.
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.uuid = UUID()
        description.name = "Vaqlo System Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw VaqloError(L("err.sysTap") + " (OSStatus \(status))")
        }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw VaqloError("Couldn't read tap format (OSStatus \(status))")
        }
        tapFormat = format

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vaqlo Aggregate",
            kAudioAggregateDeviceUIDKey: "com.vaqlo.aggregate.\(UUID().uuidString)",
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
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            cleanup()
            throw VaqloError("Couldn't create aggregate device (OSStatus \(status))")
        }

        let sink = ChunkedAudioFile(directory: directory, prefix: "sys", processingFormat: format)
        self.sink = sink

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inInputData, _, _, _ in
            let bufferList = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil) else { return }
            sink.write(buffer)
        }
        guard status == noErr, let ioProcID else {
            cleanup()
            throw VaqloError("Couldn't create IOProc (OSStatus \(status))")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            throw VaqloError("Couldn't start system audio recording (OSStatus \(status))")
        }
    }

    var chunksSnapshot: [ChunkedAudioFile.ChunkInfo] { sink?.chunksSnapshot ?? [] }

    func stop() -> [ChunkedAudioFile.ChunkInfo] {
        cleanup()
        let chunks = sink?.chunks ?? []
        sink = nil
        return chunks
    }

    private func cleanup() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        sink?.close()
    }
}
