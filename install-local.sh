#!/bin/bash
# Локальный цикл тестирования: собрать DEV-сборку → положить в /Applications → перезапустить.
# НЕ трогает сайт. Для быстрой проверки правок автором.
#
# ⚠️ Это ставит DEV (ru.keyboop.app.dev): свой домен настроек, СВОЙ лог (Keyboop-dev.log),
# Sparkle ВЫКЛЮЧЕН — такая копия никогда не обновится. Прецедент 23.07.2026: этим скриптом
# дважды «ставили прод» — версия совпадала, подмена прошла незаметно.
# Настоящий прод (как у пользователей) ставится из нотаризованного DMG:
#   hdiutil attach Keyboop.dmg && rm -rf /Applications/Keyboop.app && \
#   cp -R /Volumes/Keyboop/Keyboop.app /Applications/ && hdiutil detach /Volumes/Keyboop
set -e
cd "$(dirname "$0")"

bash build-app.sh

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Keyboop.app/Contents/Info.plist 2>/dev/null)
echo "▸ Перезапуск и установка в /Applications (v$VER)…"

# Закрыть работающий экземпляр (мягко, потом жёстко).
osascript -e 'tell application "Keyboop" to quit' 2>/dev/null || true
pkill -f "Keyboop.app/Contents/MacOS/Keyboop" 2>/dev/null || true
sleep 0.6

# Заменить в /Applications. ВАЖНО: rm -rf ОБЯЗАТЕЛЕН перед cp -R — иначе при существующем
# приёмнике 'cp -R Keyboop.app /Applications/Keyboop.app' вложит бандл ВНУТРЬ
# (Keyboop.app/Keyboop.app) → unsealed contents → TCC слетает + запустится старая версия.
rm -rf /Applications/Keyboop.app
cp -R Keyboop.app /Applications/Keyboop.app

# Пост-проверка установленного бандла: версия совпадает, нет вложенности, подпись цела.
INST_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/Keyboop.app/Contents/Info.plist 2>/dev/null)
if [ -e /Applications/Keyboop.app/Keyboop.app ]; then
  echo "  ⚠️  ОШИБКА: вложенный /Applications/Keyboop.app/Keyboop.app — установка битая!"
elif [ "$INST_VER" != "$VER" ]; then
  echo "  ⚠️  ОШИБКА: установлена v$INST_VER, ожидалась v$VER — старая версия не заменилась!"
elif codesign --verify --deep --strict /Applications/Keyboop.app 2>/dev/null; then
  echo "  проверка установки: v$INST_VER, подпись --deep --strict OK (TCC стабилен)"
else
  echo "  ⚠️  ОШИБКА: установленный бандл не проходит codesign --deep --strict (TCC будет слетать)"
fi

# Запустить свежую версию.
open /Applications/Keyboop.app
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" /Applications/Keyboop.app/Contents/Info.plist)
echo "✓ Установлено и запущено: /Applications/Keyboop.app  (v$VER, $BID)"
echo "  ⚠️ Это DEV-сборка: без автообновлений, настройки/лог — свои. Прод — из Keyboop.dmg (см. шапку)."
