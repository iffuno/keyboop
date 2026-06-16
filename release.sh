#!/bin/bash
# Полный релизный пайплайн Keyboop: Developer ID подпись + hardened runtime → нотаризация Apple →
# stapling → нотаризованный DMG для сайта. Конечный артефакт — Keyboop.dmg, который у пользователя
# открывается без предупреждений («Apple проверила на вредоносное ПО»). Обновления — заливкой на сайт.
#
# Один раз перед первым запуском (интерактивно, твой Apple ID + app-specific password):
#   xcrun notarytool store-credentials keyboop \
#     --apple-id "YOUR_APPLE_ID@example.com" --team-id "Q9244KA2SS"
#   (на запрос пароля — вставить app-specific password из appleid.apple.com → Sign-In and Security)
#
# Дальше каждый релиз — просто: bash release.sh
set -e
cd "$(dirname "$0")"

SIGN_ID="Developer ID Application: IVAN SMETANIN (Q9244KA2SS)"
NOTARY_PROFILE="keyboop"
APP="Keyboop.app"
DMG="Keyboop.dmg"
VOL="Keyboop"
STAGING="dmg-staging"
ZIP="Keyboop-notarize.zip"

# 0. Сертификат на месте?
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: IVAN SMETANIN"; then
  echo "✗ Нет сертификата «$SIGN_ID» в связке ключей. Создай его в Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
  exit 1
fi

# 1. Релизная сборка (Developer ID + hardened runtime + timestamp).
# KEYBOOP_SKIP_BUILD=1 — нотаризовать УЖЕ собранный Keyboop.app без пересборки (чтобы нотаризованный
# артефакт побайтно совпал с интерим-DMG, уже выложенным на сайт; апдейт интерим→нотаризованный без re-grant).
if [ "${KEYBOOP_SKIP_BUILD:-}" = "1" ]; then
  echo "▸ [1/6] Пропуск сборки (нотаризую существующий $APP)…"
  [ -d "$APP" ] || { echo "✗ Нет $APP — нечего нотаризовать."; exit 1; }
else
  echo "▸ [1/6] Релизная сборка (Developer ID + hardened runtime)…"
  KEYBOOP_RELEASE=1 KEYBOOP_SIGN_ID="$SIGN_ID" bash build-app.sh >/tmp/keyboop-release-build.log 2>&1 \
    || { echo "✗ Сборка упала:"; tail -20 /tmp/keyboop-release-build.log; exit 1; }
fi
codesign -dvvv "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" \
  || { echo "✗ Hardened runtime не включён — нотаризация отклонит."; exit 1; }

# S6 (security review): hardened runtime + наш Developer ID на КАЖДОМ вложенном бинаре Sparkle —
# иначе нотаризация отклонит (или останется чужая подпись org.sparkle-project). Ловим ДО отправки.
FV="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nb in "$FV/Sparkle" "$FV/Autoupdate" "$FV/Updater.app" "$FV/XPCServices/Downloader.xpc" "$FV/XPCServices/Installer.xpc"; do
  info=$(codesign -dvvv "$nb" 2>&1)
  echo "$info" | grep -q "flags=0x10000(runtime)" || { echo "✗ нет hardened runtime: $nb"; exit 1; }
  echo "$info" | grep -q "Q9244KA2SS" || { echo "✗ не наш Team ID (Q9244KA2SS): $nb"; exit 1; }
done
echo "  Sparkle: все вложенные бинари — Developer ID + hardened runtime ✓"

# S7 (security review): disable-library-validation НЕ должен попасть в РЕЛИЗ (он только для dev). Если
# попал — это дыра в hardened runtime (можно подгрузить чужой код). Фейлим релиз до нотаризации.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "disable-library-validation"; then
  echo "✗ В релизных entitlements есть disable-library-validation — это дыра. Проверь ENT в build-app.sh."; exit 1
fi
echo "  entitlements: без disable-library-validation ✓"

# ГАРАНТИЯ СОХРАНЕНИЯ ДОСТУПОВ ПРИ ОБНОВЛЕНИИ. macOS привязывает Accessibility/микрофон к
# Team ID + bundle id (designated requirement). Если релиз подписать ДРУГИМ сертификатом или сменить
# bundle id — система увидит «другое приложение» и заставит ВСЕХ пользователей переразрешать доступы
# заново (микрофон, Универсальный доступ). Фейлим релиз, если идентичность не та.
codesign -dvv "$APP" 2>&1 | grep -q "TeamIdentifier=Q9244KA2SS" \
  || { echo "✗ Team ID ≠ Q9244KA2SS — обновление заставит ВСЕХ переразрешать доступы! Подпиши тем же Developer ID."; exit 1; }
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
[ "$BID" = "ru.keyboop.app" ] \
  || { echo "✗ bundle id «$BID» ≠ ru.keyboop.app — доступы слетят у всех. Не меняй bundle id релиза."; exit 1; }
echo "  идентичность: ru.keyboop.app + Team Q9244KA2SS — доступы при обновлении сохранятся ✓"

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "  версия $VER, подпись Developer ID + hardened runtime ✓"

# 2. Учётные данные нотаризации настроены?
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo
  echo "⚠️  Профиль нотаризации «$NOTARY_PROFILE» не настроен. Подписанный .app готов (Keyboop.app),"
  echo "    но отправить в Apple нельзя. Настрой ОДИН РАЗ (интерактивно, пароль введёшь сам):"
  echo
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "      --apple-id \"YOUR_APPLE_ID@example.com\" --team-id \"Q9244KA2SS\""
  echo
  echo "    Пароль — это app-specific password (НЕ пароль от Apple ID!):"
  echo "    appleid.apple.com → Вход и безопасность → Пароли приложений → + → создать «keyboop-notary»."
  echo "    Потом снова: bash release.sh"
  exit 2
fi

# 3. Упаковываем .app в zip и шлём на нотаризацию (Apple сканирует cdhash приложения).
echo "▸ [2/6] Нотаризация в Apple (обычно 1–5 мин)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SUBMIT_OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$SUBMIT_OUT" | sed 's/^/    /'
if ! echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
  echo "✗ Нотаризация НЕ прошла. Лог Apple:"
  SUBID=$(echo "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')
  [ -n "$SUBID" ] && xcrun notarytool log "$SUBID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /'
  rm -f "$ZIP"
  exit 1
fi
rm -f "$ZIP"

# 4. Пришиваем «билет» Apple прямо в .app — доверие работает даже офлайн.
echo "▸ [3/6] Stapling билета в бандл…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" >/dev/null && echo "  staple OK ✓"

# 5. Финальная проверка Gatekeeper — должно быть «accepted / Notarized Developer ID».
echo "▸ [4/6] Проверка Gatekeeper…"
SPCTL=$(spctl -a -vvv "$APP" 2>&1)
echo "$SPCTL" | sed 's/^/    /'
echo "$SPCTL" | grep -q "source=Notarized Developer ID" \
  || { echo "✗ Gatekeeper не принял как нотаризованное."; exit 1; }

# 6. Собираем DMG из нотаризованного+stapled приложения (drag-to-install).
echo "▸ [5/6] Сборка DMG для сайта…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Как установить.txt" <<'TXT'
Keyboop — установка

1. Перетащи Keyboop в папку Applications (ярлык рядом). ВАЖНО: запускай именно
   из «Программ», а не из этого окна-образа — иначе macOS изолирует копию и
   может ругнуться «повреждён».
2. Запусти Keyboop из «Программ». Приложение нотаризовано Apple — откроется без
   предупреждений.
3. Разреши «Универсальный доступ» (Accessibility), когда попросит — без него не
   работает переключение раскладки и голос. Как включишь — заработает сразу,
   перезапускать не нужно.
4. Голосовой набор: Настройки → Голосовой набор → скачай модель. Потом зажми
   правый ⌥ и говори (это хоткей по умолчанию; можно сменить в настройках).

Keyboop обновляется сам — тихо, когда ты отошёл от компьютера. Выключить можно
в Настройках → Обновления. Из того, что ты печатаешь и диктуешь, наружу не уходит ничего.
TXT
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# Стапл и сам DMG-контейнер (чтобы и файл образа имел билет; .app внутри уже stapled).
echo "▸ [6/7] Stapling DMG…"
xcrun stapler staple "$DMG" >/dev/null 2>&1 && echo "  DMG stapled ✓" || echo "  (DMG-билет не пришит — не критично, .app внутри нотаризован)"

# Sparkle appcast для автообновлений: generate_appcast подписывает DMG ключом EdDSA из login-keychain
# (приватный ключ НЕ на сервере) и пишет appcast.xml. enclosure-URL = prefix + имя файла → версионный
# DMG на keyboop.com. Кладём версионную копию в sparkle-updates/ и генерируем оттуда.
echo "▸ [7/7] Sparkle appcast (EdDSA-подпись + appcast.xml)…"
GENAPP="vendor/sparkle/bin/generate_appcast"
UPDIR="sparkle-updates"
if [ -x "$GENAPP" ]; then
  mkdir -p "$UPDIR"
  cp -f "$DMG" "$UPDIR/Keyboop-$VER.dmg"
  if "$GENAPP" --download-url-prefix "https://keyboop.com/" "$UPDIR" 2>&1 | sed 's/^/    /'; then
    if grep -q "sparkle:edSignature" "$UPDIR/appcast.xml" 2>/dev/null; then
      echo "  appcast.xml готов и подписан → залить на keyboop.com рядом с DMG"
    else
      echo "  ⚠️  appcast.xml без EdDSA-подписи — проверь ключ в keychain"
    fi
  else
    echo "  ⚠️  generate_appcast упал"
  fi
else
  echo "  ⚠️  нет $GENAPP — пропускаю appcast"
fi

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ Релиз готов: $DMG ($SIZE), версия $VER — нотаризован."
echo "  Выложить на keyboop.com: $DMG (+ версионная копия) и $UPDIR/appcast.xml"
