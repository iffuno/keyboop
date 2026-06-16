#!/bin/bash
# Собирает Keyboop.app напрямую через swiftc (SwiftPM в этой CLT сломан),
# кладёт Info.plist (LSUIElement) и ad-hoc подписывает.
set -e
cd "$(dirname "$0")"

SWIFTDIR="/Library/Developer/CommandLineTools/usr/include/swift"
if [ -f "$SWIFTDIR/module.modulemap" ] && [ -f "$SWIFTDIR/bridging.modulemap" ]; then
  echo "⚠️  Сломанный toolchain: два modulemap определяют SwiftBridging."
  echo "    Почини один раз (нужен пароль):"
  echo "    sudo mv \"$SWIFTDIR/module.modulemap\" \"$SWIFTDIR/module.modulemap.bak-2023\""
  echo "    Затем запусти этот скрипт снова."
  echo
fi

APP="Keyboop.app"
echo "▸ swiftc compile…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

WHISPER="vendor/whisper.cpp"
if [ ! -f "$WHISPER/build/src/libwhisper.a" ]; then
  echo "⚠️  whisper.cpp не собран. Собери один раз:"
  echo "    cd $WHISPER && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \\"
  echo "      -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF && cmake --build build -j"
  exit 1
fi

# FluidAudio (Parakeet/CoreML/ANE) — предсобранная статика, см. docs/PARAKEET_BUILD.md.
# Требует macOS 14 (поэтому таргет подняли 13→14).
FA="vendor/fluidaudio-prebuilt"
# Sparkle (автообновления): динамический фреймворк. Линкуем + rpath на Contents/Frameworks,
# куда сам фреймворк копируется ниже (с переподписью вложенных бинарей нашим Developer ID).
SPARKLE="vendor/sparkle"
swiftc -O Sources/Keyboop/*.swift \
  -o "$APP/Contents/MacOS/Keyboop" \
  -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Keyboop/whisper-bridging.h \
  -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
  -I "$FA/Modules" -I "$FA/include/FastClusterWrapper" -I "$FA/include/MachTaskSelfWrapper" \
  -L "$WHISPER/build/src" -L "$WHISPER/build/ggml/src" \
  -L "$WHISPER/build/ggml/src/ggml-metal" -L "$WHISPER/build/ggml/src/ggml-blas" \
  -L "$FA" -lFluidAudio \
  -lwhisper -lggml -lggml-cpu -lggml-metal -lggml-blas -lggml-base -lc++ \
  -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Metal -framework MetalKit -framework Accelerate -framework CoreML \
  -framework SwiftUI -Xlinker -weak_framework -Xlinker Translation \
  -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# Языковые данные (триграммы/словари) в bundle Resources
cp Sources/Keyboop/Resources/*.json "$APP/Contents/Resources/" 2>/dev/null || echo "  (нет Resources/*.json — детектор будет без данных)"

# Анимированный логотип (онбординг-герой). 59 КБ, без звука, h264.
cp Sources/Keyboop/Resources/keyboop-logo-anim.mp4 "$APP/Contents/Resources/" 2>/dev/null \
  && echo "  ресурс: keyboop-logo-anim.mp4 (онбординг)" \
  || echo "  (нет keyboop-logo-anim.mp4 — онбординг покажет статичную иконку)"

# Asset Catalog → coral как системный accent (чекбоксы/тумблеры/popup станут оранжевыми).
if [ -d Resources/Assets.xcassets ]; then
  actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 13.0 \
    --output-partial-info-plist /tmp/keyboop-assets-plist.plist >/dev/null 2>&1 \
    && echo "  ассеты: AccentColor (coral) скомпилирован" \
    || echo "  ассеты: actool не справился (accent останется системным)"
fi

# Иконка приложения (Finder/Dock/About/DMG).
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null \
  && echo "  иконка: AppIcon.icns" \
  || echo "  (нет Resources/AppIcon.icns — иконка дефолтная)"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Keyboop</string>
    <key>CFBundleDisplayName</key>     <string>Keyboop</string>
    <key>CFBundleIdentifier</key>      <string>ru.keyboop.app</string>
    <key>CFBundleVersion</key>         <string>0.2.12</string>
    <key>CFBundleShortVersionString</key> <string>0.2.12</string>
    <key>CFBundleExecutable</key>      <string>Keyboop</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSAccentColorName</key>       <string>AccentColor</string>
    <key>NSMicrophoneUsageDescription</key> <string>Keyboop распознаёт надиктованный текст локально, на вашем Mac. Аудио никуда не отправляется.</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Keyboop — free &amp; open source</string>
    <!-- Sparkle (автообновления). Проверка ВКЛ + фоновое скачивание. SUAutomaticallyUpdate=true
         включает «тихий» путь, но мы его ПЕРЕХВАТЫВАЕМ делегатом willInstallUpdateOnQuit
         (UpdaterController) и по умолчанию НЕ ставим молча, а показываем СВОЁ уведомление «Обновить
         сейчас / Обновлять автоматически». Тихо ставим только если пользователь сам выбрал «авто».
         Так выполняется требование ревизии (установка с согласия), а тихий режим — opt-in. Профайлинг off. -->
    <key>SUFeedURL</key>                       <string>https://keyboop.com/appcast.xml</string>
    <key>SUPublicEDKey</key>                   <string>JHgcY6qatoAU6Tdo02B7mHgfceMyfdPWXqwWQiMESmY=</string>
    <key>SUEnableAutomaticChecks</key>         <true/>
    <key>SUAutomaticallyUpdate</key>           <true/>
    <key>SUEnableSystemProfiling</key>         <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>  <true/>
    <key>SURequireSignedFeed</key>             <true/>
    <key>SUScheduledCheckInterval</key>        <integer>86400</integer>
    <!-- Spotlight-алиасы: приложение находится по «лунищщз» (keyboop вслепую на RU-раскладке) и по
         функциональным синонимам. Видимое имя (CFBundleName/DisplayName) НЕ меняется — это отдельное
         метаполе индекса. macOS-ключ MDItemKeywords (без k-префикса; kMDItemKeywords — iOS). Внутри
         подписанного Info.plist → переживает codesign + нотаризацию + Sparkle-апдейт.
         Ref: developer.apple.com/forums/thread/761535 -->
    <key>MDItemKeywords</key>
    <string>лунищщз, keyboop, раскладка, punto, switcher</string>
</dict>
</plist>
PLIST

# M4 (фикс инцидента 14.06): dev-сборкам — ОТДЕЛЬНЫЙ bundle id и имя, чтобы они физически НЕ могли
# перехватить TCC/Accessibility у боевой ru.keyboop.app (две сборки с одним id, но разной подписью →
# конфликт designated requirement → TCC-запись инвалидируется, доступ слетает). Меняем PlistBuddy'ем
# ПОСЛЕ heredoc (он single-quoted, переменные не раскрывает) и ДО codesign (иначе порвём seal подписи).
# Заодно у dev снимаем SUFeedURL — пусть dev-сборка вообще не ходит за боевым appcast.
if [ "${KEYBOOP_RELEASE:-}" != "1" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ru.keyboop.app.dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Keyboop Dev" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Keyboop Dev" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :MDItemKeywords" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "  dev: bundle id → ru.keyboop.app.dev (TCC изолирован от боевой), SUFeedURL + Spotlight-ключи сняты"
fi

# Подпись. Два режима:
#   • DEV (по умолчанию) — self-signed "Keyboop Dev", без timestamp/hardened runtime; entitlements
#     с disable-library-validation, чтобы загрузить встроенный Sparkle.framework. Для локалки.
#   • RELEASE (KEYBOOP_RELEASE=1) — Developer ID + hardened runtime + timestamp (нотаризация). Один
#     Developer ID на всё → Library Validation проходит сама, ослаблять её НЕ нужно.
SIGN_ID="${KEYBOOP_SIGN_ID:-Keyboop Dev}"
if [ "${KEYBOOP_RELEASE:-}" = "1" ]; then
  ENT="Keyboop.entitlements"
  CS_OPTS="--options runtime --timestamp"
else
  ENT="Keyboop-dev.entitlements"
  CS_OPTS="--timestamp=none"
fi

# Встраиваем Sparkle.framework в бандл (ditto сохраняет симлинки версий и права).
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Переподписываем вложенные бинари Sparkle нашим SIGN_ID ИЗНУТРИ НАРУЖУ, без --deep (Xcode делает это
# сам, swiftc — нет; --deep — частый источник ошибок нотаризации). XPC сохраняют свои entitlements.
FW="$APP/Contents/Frameworks/Sparkle.framework"; FV="$FW/Versions/B"
codesign -f -s "$SIGN_ID" $CS_OPTS --preserve-metadata=entitlements "$FV/XPCServices/Downloader.xpc"
codesign -f -s "$SIGN_ID" $CS_OPTS --preserve-metadata=entitlements "$FV/XPCServices/Installer.xpc"
codesign -f -s "$SIGN_ID" $CS_OPTS "$FV/Updater.app"
codesign -f -s "$SIGN_ID" $CS_OPTS "$FV/Autoupdate"
codesign -f -s "$SIGN_ID" $CS_OPTS "$FW" \
  && echo "  Sparkle.framework встроен и переподписан ($SIGN_ID)" \
  || { echo "  ⚠️  ОШИБКА переподписи Sparkle"; [ "${KEYBOOP_RELEASE:-}" = "1" ] && exit 1; }

# Подписываем само приложение (после вложенных — печатает бандл целиком).
if codesign --force --sign "$SIGN_ID" --entitlements "$ENT" $CS_OPTS "$APP" 2>/dev/null; then
  echo "  подпись: «$SIGN_ID» + entitlements + Sparkle"
elif [ "${KEYBOOP_RELEASE:-}" = "1" ]; then
  echo "  ⚠️  ОШИБКА: не удалось подписать релиз «$SIGN_ID» (есть ли Developer ID в связке?)"; exit 1
else
  codesign --force --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1 || true
  echo "  подпись: ⚠️  ad-hoc (нет '$SIGN_ID')"
fi

# Пост-проверка целостности подписи. Строгая верификация ловит «unsealed contents»
# (напр. случайно вложенный бандл от 'cp -R app существующая_папка') и битую подпись ДО установки.
# Битый бандл → trustd видит сломанную подпись → TCC переспрашивает Accessibility каждый раз.
# Прецедент (2026-06-09): ручной 'cp -R Keyboop.app /Applications/Keyboop.app' при существующем
# приёмнике вложил бандл внутрь (Keyboop.app/Keyboop.app) → unsealed contents → слетал TCC, и
# запускалась СТАРАЯ версия. Установку делать ТОЛЬКО через install-local.sh (rm -rf + cp -R).
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "  проверка: codesign --deep --strict OK (бандл запечатан, TCC стабилен)"
else
  echo "  ⚠️  ОШИБКА: codesign --deep --strict НЕ прошёл — бандл битый, TCC будет слетать:"
  codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/      /'
fi

echo "✓ Готово: $APP"
echo "  Запуск:  open \"$APP\"  (или bash install-local.sh — чистая установка в /Applications)"
