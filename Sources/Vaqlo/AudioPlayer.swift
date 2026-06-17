import AVFoundation
import Foundation

/// Находит аудиочанки сессии — в её папке (до транскрибации) или в Корзине (после,
/// пока не истёк срок хранения).
enum AudioLocator {
    struct LocatedChunk {
        let url: URL
        let startOffset: Double  // секунды от начала сессии
        let source: String       // "mic" | "sys"
    }

    static func chunks(for session: Session) -> [LocatedChunk] {
        guard let metadata = session.loadMetadata() else {
            return chunksFromFiles(session)
        }
        let trash = TrashKeeper.all()
        var result: [LocatedChunk] = []

        func locate(_ infos: [ChunkedAudioFile.ChunkInfo], source: String) {
            for info in infos {
                let inSession = session.directory.appendingPathComponent(info.file)
                let url: URL?
                if FileManager.default.fileExists(atPath: inSession.path) {
                    url = inSession
                } else if let entry = trash.first(where: { $0.originalPath == inSession.path }) {
                    url = URL(fileURLWithPath: entry.trashedPath)
                } else {
                    url = nil
                }
                if let url {
                    result.append(LocatedChunk(
                        url: url,
                        startOffset: info.start.timeIntervalSince(session.start),
                        source: source
                    ))
                }
            }
        }

        locate(metadata.micChunks, source: "mic")
        locate(metadata.systemChunks, source: "sys")
        return result
    }

    /// Запасной путь, если session.json потерян: берём файлы по именам, offset — по номеру чанка.
    private static func chunksFromFiles(_ session: Session) -> [LocatedChunk] {
        session.audioFiles().compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent // mic_0001
            let parts = name.split(separator: "_")
            guard parts.count == 2, let index = Int(parts[1]) else { return nil }
            return LocatedChunk(
                url: url,
                startOffset: Double(index - 1) * ChunkedAudioFile.chunkDuration,
                source: name.hasPrefix("mic") ? "mic" : "sys"
            )
        }
    }

    static func hasAudio(for session: Session) -> Bool { !chunks(for: session).isEmpty }
}

/// Плеер одной сессии: микрофонная и системная дорожки сшиты в единый таймлайн.
/// Поддерживает скорость, перемотку, раздельный мьют дорожек.
@MainActor
final class SessionAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var available = false
    @Published private(set) var loading = false
    @Published var rate: Float = 1.0 { didSet { applyRate() } }
    @Published var micMuted = false { didSet { applyMix() } }
    @Published var sysMuted = false { didSet { applyMix() } }
    @Published private(set) var hasMic = false
    @Published private(set) var hasSys = false

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var composition: AVMutableComposition?
    private var micTrackID: CMPersistentTrackID?
    private var sysTrackID: CMPersistentTrackID?
    private var timeObserver: Any?
    private var endObserver: Any?
    private(set) var loadedSessionID: String?

    func load(_ session: Session) {
        guard session.id != loadedSessionID else { return }
        teardown()
        loadedSessionID = session.id
        let chunks = AudioLocator.chunks(for: session)
        guard !chunks.isEmpty else { available = false; return }
        loading = true
        Task {
            let built = await Self.buildItem(chunks: chunks)
            await MainActor.run {
                self.loading = false
                guard let built, session.id == self.loadedSessionID else { self.available = false; return }
                self.setup(built)
            }
        }
    }

    private struct Built {
        let item: AVPlayerItem
        let composition: AVMutableComposition
        let duration: Double
        let micTrackID: CMPersistentTrackID?
        let sysTrackID: CMPersistentTrackID?
    }

    private func setup(_ built: Built) {
        item = built.item
        composition = built.composition
        micTrackID = built.micTrackID
        sysTrackID = built.sysTrackID
        hasMic = built.micTrackID != nil
        hasSys = built.sysTrackID != nil
        built.item.audioTimePitchAlgorithm = .spectral

        let player = AVPlayer(playerItem: built.item)
        self.player = player
        duration = built.duration
        available = duration > 0
        applyMix()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: built.item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.1 { seek(to: 0) }
            player.rate = rate
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func skip(by delta: Double) { seek(to: currentTime + delta) }

    func playFrom(seconds: Double) {
        seek(to: seconds)
        if !isPlaying { togglePlay() }
    }

    private func applyRate() {
        if isPlaying { player?.rate = rate }
    }

    /// Раздельный мьют дорожек через audioMix.
    private func applyMix() {
        guard let composition else { return }
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        if let micID = micTrackID, let track = composition.track(withTrackID: micID) {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(micMuted ? 0 : 1, at: .zero)
            params.append(p)
        }
        if let sysID = sysTrackID, let track = composition.track(withTrackID: sysID) {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(sysMuted ? 0 : 1, at: .zero)
            params.append(p)
        }
        mix.inputParameters = params
        item?.audioMix = mix
    }

    func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        item = nil
        composition = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        available = false
        hasMic = false
        hasSys = false
        loadedSessionID = nil
    }

    /// Сшивает чанки обеих дорожек в одну композицию: mic и sys звучат одновременно.
    private static func buildItem(chunks: [AudioLocator.LocatedChunk]) async -> Built? {
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]

        for chunk in chunks {
            let asset = AVURLAsset(url: chunk.url)
            guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration) else { continue }
            let track = tracks[chunk.source] ?? composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            tracks[chunk.source] = track
            let at = CMTime(seconds: max(0, chunk.startOffset), preferredTimescale: 600)
            try? track?.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: at
            )
        }

        guard !tracks.isEmpty else { return nil }
        return Built(
            item: AVPlayerItem(asset: composition),
            composition: composition,
            duration: composition.duration.seconds,
            micTrackID: tracks["mic"]?.trackID,
            sysTrackID: tracks["sys"]?.trackID
        )
    }
}
