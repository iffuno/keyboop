#!/bin/bash
# Собирает CLI-проверку детектора: scripts/decide/main.swift поверх реального кода Keyboop.
# Флаги и вендорные библиотеки те же, что в build-app.sh; main.swift приложения не берём
# (у CLI свой вход). Результат: .build/keyboop-decide (каталог .build в .gitignore).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WHISPER="vendor/whisper.cpp"
WHISPER_BUILD="vendor/whisper.cpp/build-macos14"
FA="vendor/fluidaudio-prebuilt"
SPARKLE="vendor/sparkle"
OUT=".build/keyboop-decide"

if [ ! -f "$WHISPER_BUILD/src/libwhisper.a" ]; then
  echo "✗ whisper.cpp не собран: см. build-app.sh (cmake build-macos14)."
  exit 1
fi

# Все исходники приложения, кроме его точки входа main.swift.
SRCS=()
for f in Sources/Keyboop/*.swift; do
  [ "$(basename "$f")" = "main.swift" ] || SRCS+=("$f")
done

mkdir -p .build
echo "▸ swiftc decide…"
swiftc -O "${SRCS[@]}" scripts/decide/main.swift \
  -o "$OUT" \
  -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Keyboop/whisper-bridging.h \
  -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
  -I "$FA/Modules" -I "$FA/include/FastClusterWrapper" -I "$FA/include/MachTaskSelfWrapper" \
  -L "$WHISPER_BUILD/src" -L "$WHISPER_BUILD/ggml/src" \
  -L "$WHISPER_BUILD/ggml/src/ggml-metal" -L "$WHISPER_BUILD/ggml/src/ggml-blas" \
  -L "$FA" -lFluidAudio \
  -lwhisper -lggml -lggml-cpu -lggml-metal -lggml-blas -lggml-base -lc++ \
  -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework IOKit \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Metal -framework MetalKit -framework Accelerate -framework CoreML \
  -framework SwiftUI -Xlinker -weak_framework -Xlinker Translation \
  -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$ROOT/$SPARKLE"

echo "✓ $ROOT/$OUT"
