# Keyboop

> **неправильна розкладка? keyboop.**
> Безплатний open-source перемикач розкладки для macOS, який чинить кракозябри — і при цьому **не торкається твого буфера обміну**.

Набрав `ghbdtn` замість `привіт`? Keyboop мовчки все розколдує — прямо під час набору або по межі слова. Не вгадав — поправ гарячою клавішею: останнє слово, останні N слів або все, що натиснув за останні T секунд.

## Чим відрізняє��ься

- 🧼 **Не ламає буфер обміну.** Головна хвороба інших перемикачів — clipboard. Keyboop друкує виправлений текст безпосередньо, буфер не торкається вообще.
- ⏪ **Гнучке вікно відката.** Не тільки останнє слово, але й N слів / фраза / час — однією гарячою клавішею. Цього немає нікого.
- ✍️ **Фрагменти.** Набрав скорочення — отримав e-mail, підпис, будь-яку фразу. Розкладка і регістр не важливі.
- 🔒 **Локально і приватно.** З того, що ти друкуєш, назовні не йде нічого. Open source — можна перевірити кожне слово.
- 🍎 **Сучасно.** Apple Silicon, нотаризовано Apple, автооновлення.

## Установка

Скачай DMG на **[keyboop.com](https://keyboop.com)** — перетягни в Програми, дозволи доступ до клавіатури. Оновлюється саме.

Потрібно: Mac на Apple Silicon (M1 і новіше), macOS 14+.

## Збирання з вихідного коду

Потрібні Xcode Command Line Tools і три зовнішні залежності — їх код чужий, у цей репозиторій він не входить, поклади рядом у `vendor/`:

```bash
mkdir -p vendor && cd vendor

# 1. whisper.cpp — розпізнавання мови.
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build-macos14 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF
cmake --build build-macos14 -j
cd ..
```

⚠️ Прапор `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` обов'язковий. Без нього cmake бере версію тієї системи, на якій ти збираєш, і `ggml-metal` жорстко зв'язується з класом з macOS 15 — на macOS 14 програма молча вмре ще до `main()`. Перевірено на живих користувачах, чинилося екстреним релізом.

Ще дві:

- **Sparkle** (автооновлення) → `vendor/sparkle/Sparkle.framework` — [релізи](https://github.com/sparkle-project/Sparkle/releases)
- **FluidAudio** (Parakeet на Neural Engine) → `vendor/fluidaudio-prebuilt/` зі `libFluidAudio.a`, `Modules/` і `include/` — [вихідний код](https://github.com/FluidInference/FluidAudio)

Далі:

```bash
bash build-app.sh      # dev-збірка (self-signed) → Keyboop.app
bash install-local.sh  # те ж + установка в /Applications
```

Готові релізи підписані Developer ID і нотаризовані Apple — скрипт релізу завязаний на особисті ключі і у репозиторій не входить.

## Автори

**автор Сметанин** — ідея, продукт, руки і всі описки в цьому репозиторії.

**Claude (Anthropic)** — співавтор коду.

**Адаптація для української розкладки** — ssw112 (2026).

## Ліцензія

MIT. Безплатно — для всіх, хто живе на декількох розкладках.
