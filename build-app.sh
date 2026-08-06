#!/bin/bash
# Собирает Keyboop.app напрямую через swiftc (SwiftPM в этой CLT сломан),
# кладёт Info.plist (LSUIElement) и ad-hoc подписывает.
set -e
cd "$(dirname "$0")"

# Ежедневная резервная копия, привязанная к работе, а не к календарю. Сборка — самый честный
# признак того, что сегодня в проекте что-то менялось: в дни без сборок и терять нечего.
# Режим `daily` сам выходит за миллисекунды, если свежий снимок уже есть, поэтому цена этой
# строки — двадцать секунд раз в сутки. Сборку не роняем никогда: недоступное хранилище копий
# не повод не собрать приложение.
# ⚠️ Проверка на существование обязательна: этот скрипт публикуется на GitHub, а Tools/ — нет.
# Без неё у постороннего человека сборка начиналась бы с жалобы на отсутствующий файл.
# Именно `if`, а не `[ … ] && { … }`: при set -e неудачная проверка вернула бы 1 всем выражением
# и оборвала бы сборку ровно у того, у кого Tools/ нет — то есть у любого стороннего человека.
if [ -f Tools/backup.sh ]; then
  bash Tools/backup.sh daily || echo "  ⚠️ ежедневный бэкап не сделан"
fi

SWIFTDIR="/Library/Developer/CommandLineTools/usr/include/swift"
if [ -f "$SWIFTDIR/module.modulemap" ] && [ -f "$SWIFTDIR/bridging.modulemap" ]; then
  echo "⚠️  Сломанный toolchain: два modulemap определяют SwiftBridging."
  echo "    Почини один раз (нужен пароль):"
  echo "    sudo mv \"$SWIFTDIR/module.modulemap\" \"$SWIFTDIR/module.modulemap.bak-2023\""
  echo "    Затем запусти этот скрипт снова."
  echo
fi

APP="Keyboop.app"

# ⚠️ Пересборка бандла под РАБОТАЮЩИМ из него процессом запрещена: macOS перестаёт доверять
# клиенту, чей бандл изменился на диске, и coreaudiod МОЛЧА глушит ему микрофон — TCC отвечает
# authorized, буферы идут, но в них битовый ноль (инцидент 23.07.2026).
if pgrep -f "$(pwd)/$APP/Contents/MacOS/Keyboop" >/dev/null 2>&1; then
  echo "✗ Keyboop сейчас запущен из $(pwd)/$APP — собирать под ним нельзя."
  echo "  Сначала:  pkill -x Keyboop        затем собери и:  open \"$APP\""
  exit 1
fi
# ПРОВЕРКА ДУБЛЕЙ В L10n (25.07): Swift-словарь-литерал с повторяющимся ключом компилируется молча,
# но падает SIGTRAP при ПЕРВОМ обращении — то есть приложение не запускается вообще (Dictionary.init →
# one-time initialization function for strings). Ловим на сборке, а не по краш-репорту.
DUPES=$(python3 - <<'PYEOF'
import re, collections
src = open('Sources/Keyboop/L10n.swift', encoding='utf-8').read()
keys = re.findall(r'^\s*"([^"]+)":\s*\[', src, re.M)
print(",".join(k for k, c in collections.Counter(keys).items() if c > 1))
PYEOF
)
if [ -n "$DUPES" ]; then
  echo "✗ Дубликаты ключей в L10n.swift: $DUPES"
  echo "  Swift упадёт при запуске (SIGTRAP в Dictionary.init). Переименуй ключ и собери снова."
  exit 1
fi

echo "▸ swiftc compile…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ⚠️ КРИТИЧНО (24.07): arm64-сборка whisper.cpp ДОЛЖНА быть с CMAKE_OSX_DEPLOYMENT_TARGET=14.0.
# Без него cmake берёт таргет текущей системы (собирали на macOS 26) → ggml-metal делает STRONG-ссылку
# на MTLResidencySetDescriptor (класс есть только с macOS 15) → на Sonoma/14 dyld убивает процесс ДО
# main() с "Symbol not found", приложение молча не запускается (репорт M1/Sonoma, 0.2.66). С таргетом
# 14.0 ссылка становится weak (@available(macOS 15) в ggml отрабатывает как задумано).
WHISPER="vendor/whisper.cpp/build-macos14/.."
WHISPER_BUILD="vendor/whisper.cpp/build-macos14"
if [ ! -f "$WHISPER_BUILD/src/libwhisper.a" ]; then
  echo "⚠️  whisper.cpp не собран. Собери один раз:"
  echo "    cd $WHISPER && cmake -B build-macos14 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \\"
  echo "      -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF && cmake --build build-macos14 -j"
  exit 1
fi

# FluidAudio (Parakeet/CoreML/ANE) — предсобранная статика, предсобранная статика.
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
  -L "$WHISPER_BUILD/src" -L "$WHISPER_BUILD/ggml/src" \
  -L "$WHISPER_BUILD/ggml/src/ggml-metal" -L "$WHISPER_BUILD/ggml/src/ggml-blas" \
  -L "$FA" -lFluidAudio \
  -lwhisper -lggml -lggml-cpu -lggml-metal -lggml-blas -lggml-base -lc++ \
  -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Metal -framework MetalKit -framework Accelerate -framework CoreML \
  -framework SwiftUI -Xlinker -weak_framework -Xlinker Translation \
  -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# ── Universal (Intel): второй проход под x86_64 + lipo. Включается KEYBOOP_UNIVERSAL=1
#    (release.sh включает всегда; dev-сборки по умолчанию arm64-only — вдвое быстрее).
#    x86-срез: whisper из build-x86 (GGML_NATIVE=OFF + AVX2-бейзлайн, БЕЗ Metal — CPU/Accelerate),
#    БЕЗ FluidAudio (arm64-only статика; Swift-код компилирует Intel-заглушки по #if arch).
if [ "${KEYBOOP_UNIVERSAL:-}" = "1" ]; then
  WX="$WHISPER/build-x86"
  if [ ! -f "$WX/src/libwhisper.a" ]; then
    echo "✗ Нет x86-сборки whisper. Один раз собери:"
    echo "  cd $WHISPER && cmake -B build-x86 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \\"
    echo "    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON \\"
    echo "    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF && cmake --build build-x86 -j"
    exit 1
  fi
  echo "▸ swiftc compile (x86_64 для universal)…"
  mv "$APP/Contents/MacOS/Keyboop" "$APP/Contents/MacOS/.Keyboop-arm64"
  swiftc -O Sources/Keyboop/*.swift \
    -o "$APP/Contents/MacOS/.Keyboop-x86" \
    -swift-version 5 -target x86_64-apple-macos13.0 \
    -import-objc-header Sources/Keyboop/whisper-bridging.h \
    -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
    -L "$WX/src" -L "$WX/ggml/src" -L "$WX/ggml/src/ggml-blas" \
    -lwhisper -lggml -lggml-cpu -lggml-blas -lggml-base -lc++ \
    -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices \
    -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework CoreML \
    -framework SwiftUI -Xlinker -weak_framework -Xlinker Translation \
    -F "$SPARKLE" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  lipo -create "$APP/Contents/MacOS/.Keyboop-arm64" "$APP/Contents/MacOS/.Keyboop-x86" \
       -output "$APP/Contents/MacOS/Keyboop"
  rm -f "$APP/Contents/MacOS/.Keyboop-arm64" "$APP/Contents/MacOS/.Keyboop-x86"
  echo "  universal: $(lipo -archs "$APP/Contents/MacOS/Keyboop")"
fi

# Языковые данные (триграммы/словари) в bundle Resources
cp Sources/Keyboop/Resources/*.json "$APP/Contents/Resources/" 2>/dev/null || echo "  (нет Resources/*.json — детектор будет без данных)"
# Знак Keyboop (template) для waveform в строке меню
cp Sources/Keyboop/Resources/menubar-mark.png "$APP/Contents/Resources/" 2>/dev/null || echo "  (нет menubar-mark.png — значок будет вектором-фолбэком)"

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
    <key>CFBundleVersion</key>         <string>0.3.15</string>
    <key>CFBundleShortVersionString</key> <string>0.3.15</string>
    <!-- Штамп сборки: подставляется ниже (sed по __BUILD_STAMP__). Логируется при запуске, чтобы по
         логу было ВИДНО, какую именно сборку гоняем. Прецедент 21.07: диагностировали баг по логу
         процесса, стартовавшего на 11 минут РАНЬШЕ пересборки, — то есть по коду без свежих правок. -->
    <key>KeyboopBuildStamp</key>       <string>__BUILD_STAMP__</string>
    <key>CFBundleExecutable</key>      <string>Keyboop</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <!-- Sparkle по-русски (баг-репорт: «You're up to date» в русском интерфейсе).
         У приложения НЕТ .lproj-папок (своя L10n) → macOS фиксирует язык процесса = en, и строки
         Sparkle.framework резолвятся в английский, хотя ru.lproj внутри фреймворка ЕСТЬ. Этот ключ —
         штатное решение Apple ровно для такого случая: каждый бандл (фреймворк) локализуется
         независимо от главного. Явный выбор языка в настройках синхронизируется через AppleLanguages
         (AppDelegate), так что диалоги Sparkle слушаются переключателя в приложении. -->
    <key>CFBundleAllowMixedLocalizations</key> <true/>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Пер-архитектурные минимумы (задача «старые системы», 23.07.2026): arm64 требует 14
         (FluidAudio/ANE статически влинкован), x86_64 живёт с 13 — в этом срезе FluidAudio нет,
         а интелы 2017 года выше Ventura не обновляются. Ключ подтверждён в актуальной
         документации Apple (bundleresources → LSMinimumSystemVersionByArchitecture). -->
    <key>LSMinimumSystemVersionByArchitecture</key>
    <dict>
        <key>arm64</key>  <string>14.0</string>
        <key>x86_64</key> <string>13.0</string>
    </dict>
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
    <!-- Раз в 2 часа. Было раз в сутки, 29.07 стало 6 часов, 30.07 — 2 часа (решение автора).
         При суточном интервале момент проверки у каждого свой и сдвигается вслед за пробуждением
         Мака: релиз, выложенный днём, доезжал до части людей только на следующие сутки, и это
         выглядело как «автообновление не работает».
         Чем НЕ платим за учащение, по порядку:
         • Трафик — 12 запросов по 15 КБ в сутки на человека вместо одного. Это меньше, чем одна
           открытая вкладка делает за минуту.
         • Батарея — короткий GET, Мак от него не просыпается: Sparkle планирует проверку на время
           бодрствования, а не будильником.
         • Назойливость — и это главное, чего можно было бы бояться, но её нет. Найдя апдейт, Sparkle
           СКАЧИВАЕТ его и зовёт `willInstallUpdateOnQuit`; мы там возвращаем true и паркуем цикл
           (UpdaterController.swift:189), показав СВОЁ уведомление один раз. Пока человек не решил,
           дальнейшие проверки ничего не показывают, сколько бы их ни было. То есть интервал влияет
           только на скорость ПЕРВОГО обнаружения.
         Ниже часа опускать нельзя: Sparkle поднимет значение до своего минимума. 2 часа с запасом.
         Персонального значения в user defaults ни у кого нет (проверено: `defaults read ru.keyboop.app
         SUScheduledCheckInterval` → does not exist), поэтому новая цифра из Info.plist доедет до всех
         на ближайшем обновлении, а не только до новых установок. -->
    <key>SUScheduledCheckInterval</key>        <integer>7200</integer>
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

# Штамп сборки — реальные дата+время сборки в Info.plist (heredoc single-quoted, переменные там не
# раскрываются, поэтому подставляем sed'ом после). Логируется при запуске: по логу сразу видно,
# какую сборку гоняем (прецедент 21.07 — диагностика шла по процессу старше пересборки на 11 минут).
BUILD_STAMP="$(date '+%Y-%m-%d %H:%M')"
sed -i '' "s/__BUILD_STAMP__/$BUILD_STAMP/" "$APP/Contents/Info.plist"

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
