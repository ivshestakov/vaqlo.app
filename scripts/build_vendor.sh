#!/bin/bash
# Клонирует и собирает локальные движки (whisper.cpp + llama.cpp) в ./vendor.
# Нужно один раз перед первой сборкой приложения. Требует cmake (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor

if [[ ! -x vendor/whisper.cpp/build/bin/whisper-cli ]]; then
    echo "▸ whisper.cpp"
    [[ -d vendor/whisper.cpp ]] || git clone --depth 1 https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
    cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF
    cmake --build vendor/whisper.cpp/build -j8 --target whisper-cli
fi

if [[ ! -x vendor/llama.cpp/build/bin/llama-completion ]]; then
    echo "▸ llama.cpp"
    [[ -d vendor/llama.cpp ]] || git clone --depth 1 https://github.com/ggml-org/llama.cpp vendor/llama.cpp
    cmake -S vendor/llama.cpp -B vendor/llama.cpp/build -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF
    cmake --build vendor/llama.cpp/build -j8 --target llama-completion
fi

echo "OK: vendor готов"
