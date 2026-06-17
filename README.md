# Vaqlo

Local meeting recorder for macOS. Records your microphone **and** system audio
(Zoom, Meet, anything playing through the speakers), transcribes everything
**on-device** with Whisper, separates and names speakers, and writes searchable
markdown notes with local LLM summaries. No cloud, no subscription — everything
stays on your Mac.

- **Capture** — microphone + system audio via Core Audio process taps (macOS 14.4+).
  Start/stop by hotkey, menu-bar icon, or Control Center. Auto-detects meetings
  (Zoom/Meet/Teams grabbing the mic) with per-app policies.
- **Transcribe** — bundled `whisper.cpp` (Metal) with VAD; auto language detection.
- **Speakers** — local diarization (FluidAudio / CoreML) + a voice library that
  learns names once and recognizes them across meetings. Meeting titles and
  participants pulled from the system Calendar (incl. a connected Google account).
- **Work with it** — day/week timeline, audio player (per-track mute, follow-along),
  full-text search, local LLM summaries (TL;DR / decisions / action items).
- **Privacy** — recordings live in Application Support; audio auto-deletes after
  transcription, transcripts are kept until you remove them.
- **Languages** — UK / EN / FR / ES / PT / DE / IT, switchable in settings.

## Build

Requires macOS 15+, Xcode 26+, `cmake` and `xcodegen` (`brew install cmake xcodegen`).

```sh
scripts/build_vendor.sh   # one-time: clone + build whisper.cpp and llama.cpp into ./vendor
scripts/build_app.sh      # → dist/Vaqlo.app (ad-hoc signed, for local use)
```

## Release

```sh
scripts/release.sh        # Developer ID sign + notarize + styled DMG; prints the appcast item
```

Auto-updates via [Sparkle](https://sparkle-project.org); the appcast lives at
`https://panic-kit.com/vaqlo/appcast.xml`.

## License

MIT — see [LICENSE](LICENSE). Part of [panic-kit](https://panic-kit.com).

Bundled engines: [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT),
[FluidAudio](https://github.com/FluidInference/FluidAudio),
[Sparkle](https://github.com/sparkle-project/Sparkle). Whisper / LLM model weights
are downloaded by the user from Hugging Face and carry their own licenses.
