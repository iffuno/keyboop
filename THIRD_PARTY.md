# Third-party notices

Keyboop сам распространяется под MIT. Ниже — всё чужое, что входит в приложение или
скачивается им по явному действию человека, с лицензией и тем, где оно лежит.

Порядок: сначала то, что лежит в бандле, потом то, что приложение скачивает.

---

## 1. Sparkle — автообновление

Фреймворк <https://sparkle-project.org>, лицензия MIT. Лежит в бандле:
`Keyboop.app/Contents/Frameworks/Sparkle.framework`, исходники — `vendor/sparkle`.

```
Copyright (c) 2006-2013 Andy Matuschak
Copyright (c) 2009-2013 Elgato Systems GmbH
Copyright (c) 2011-2014 Kornel Lesiński
… (полный текст: vendor/sparkle/LICENSE)
```

Sparkle включает компоненты сторонних авторов со своими лицензиями — их тексты
идут вместе с фреймворком.

## 2. whisper.cpp — распознавание речи (движок Whisper)

<https://github.com/ggml-org/whisper.cpp>, лицензия MIT, исходники — `vendor/whisper.cpp`.
Собирается в приложение статически.

```
MIT License
Copyright (c) 2023-2026 The ggml authors
… (полный текст: vendor/whisper.cpp/LICENSE)
```

Модель Whisper (`ggml-*.bin`) в приложение НЕ входит: её скачивает человек в
настройках. Веса Whisper — OpenAI, MIT, репозиторий
<https://huggingface.co/ggerganov/whisper.cpp>.

## 3. FluidAudio — распознавание речи (движок Parakeet)

<https://github.com/FluidInference/FluidAudio>, лицензия Apache-2.0, исходники —
`vendor/FluidAudio`, собранные артефакты — `vendor/fluidaudio-prebuilt`. Собственные
сторонние зависимости FluidAudio перечислены в `vendor/FluidAudio/ThirdPartyLicenses`.

```
Apache License, Version 2.0
… (полный текст: vendor/FluidAudio/LICENSE)
```

## 4. Модель Parakeet (NVIDIA) — скачивается по действию человека

Модель распознавания речи **NVIDIA Parakeet TDT** в CoreML-порте FluidInference.
В приложение не входит: скачивается из настроек по кнопке, с нашего зеркала
`keyboop.com/models` (файл `parakeet/parakeet-v3.tar.gz`).

- Базовая модель: **NVIDIA**, лицензия **CC-BY-4.0**.
- CoreML-порт: **FluidInference**, та же лицензия.

Атрибуция обязательна по условиям CC-BY-4.0 и указана также в окне «О программе».

> Если будет добавлена потоковая модель Nemotron (`nvidia/nemotron-3.5-asr-streaming-0.6b`
> и её CoreML-порт), лицензия у неё другая — **OpenMDW-1.1** (Linux Foundation), и
> сюда нужно положить её текст отдельным разделом плюс сохранить copyright/origin-нотисы.

## 5. Языковые данные (триграммы и словари RU/EN)

Файлы `Sources/Keyboop/Resources/trigrams_ru.json`, `trigrams_en.json`,
`words_ru.json`, `words_en.json` взяты из проекта **keyswitcher**
(<https://github.com/graninilya/keyswitcher>), лицензия MIT.

```
MIT License

Copyright (c) 2026 Ilya Granin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND...
```

> На будущее: можно сгенерировать собственную триграммную модель из открытого
> корпуса (wordfreq / FrequencyWords), чтобы не зависеть от внешних данных. Тогда
> этот раздел можно убрать. Пока используем keyswitcher-данные (MIT это разрешает).

## 6. Системные фреймворки Apple

AppKit, Carbon (Text Input Services), CoreGraphics, IOKit, AVFoundation, Speech,
Translation и прочие — часть macOS, отдельной атрибуции не требуют.
