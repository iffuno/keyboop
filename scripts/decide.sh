#!/bin/bash
# Проверка решения детектора на любом вводе — тем же кодом, что в приложении.
#
#   scripts/decide.sh --profile ru ghbdtn Email jr
#   printf 'Email\njr\n' | scripts/decide.sh --profile ru
#   scripts/decide.sh --pair --profile ru "z вижу"
#
# --profile ru|en|mixed — основной язык; по умолчанию берётся из настроек dev-приложения (ru.keyboop.app.dev).
# --clean — не брать настройки и исключения dev-приложения (основной язык mixed).
# --pair — проверка пары «предыдущее текущее» (decidePair), строка в кавычках через пробел.
# Без аргументов слова читаются из stdin построчно.
# Бинарник пересобирается, если поменялся любой .swift в Sources/Keyboop или scripts/decide.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/keyboop-decide"

stale=""
if [ -x "$BIN" ]; then
  stale="$(find "$ROOT/Sources/Keyboop" "$ROOT/scripts/decide" -name '*.swift' -newer "$BIN" -print -quit)"
fi
if [ ! -x "$BIN" ] || [ -n "$stale" ]; then
  "$ROOT/scripts/build-decide.sh"
fi

# Данные словарей и триграмм берутся из исходников, а не из бандла приложения.
export KEYBOOP_DATA_DIR="$ROOT/Sources/Keyboop/Resources"
exec "$BIN" "$@"
