#!/bin/bash
# Клонирует и собирает локальные движки (whisper.cpp + llama.cpp) в ./vendor.
# Нужно один раз перед первой сборкой приложения. Требует cmake (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor

# Закреплённые коммиты: код движков подписывается нашим Developer ID и нотаризуется —
# собирать «что сейчас в main» нельзя (непроверенное изменение уехало бы пользователям).
# Обновление движка = осознанная смена SHA здесь + проверка транскрибации/саммари.
WHISPER_SHA="df7638d8229a243af8a4b5a8ae557e0d74e0a0ae"
LLAMA_SHA="f7ca93d12c523491e9123ee7ce6a881447c20e52"

fetch_pinned() {  # <repo url> <dir> <sha>
    if [[ ! -d "$2/.git" ]]; then
        git init -q "$2"
        git -C "$2" remote add origin "$1"
    fi
    if [[ "$(git -C "$2" rev-parse HEAD 2>/dev/null)" != "$3" ]]; then
        git -C "$2" fetch -q --depth 1 origin "$3"
        git -C "$2" checkout -q --detach FETCH_HEAD
    fi
}

if [[ ! -x vendor/whisper.cpp/build/bin/whisper-cli ]]; then
    echo "▸ whisper.cpp"
    fetch_pinned https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp "$WHISPER_SHA"
    cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF
    cmake --build vendor/whisper.cpp/build -j8 --target whisper-cli
fi

if [[ ! -x vendor/llama.cpp/build/bin/llama-completion ]]; then
    echo "▸ llama.cpp"
    fetch_pinned https://github.com/ggml-org/llama.cpp vendor/llama.cpp "$LLAMA_SHA"
    # LLAMA_OPENSSL=OFF обязателен: иначе бинарь линкуется с Homebrew-овским
    # libssl, который hardened runtime не загрузит (чужой Team ID) — саммари
    # молча падает с dyld-ошибкой в подписанных сборках.
    cmake -S vendor/llama.cpp -B vendor/llama.cpp/build -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
        -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF
    cmake --build vendor/llama.cpp/build -j8 --target llama-completion
fi

echo "OK: vendor готов"
