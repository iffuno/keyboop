# Third-party notices

## Языковые данные (триграммы и словари RU/EN)

Файлы `Sources/Keyboop/Resources/trigrams_ru.json`, `trigrams_en.json`,
`words_ru.json`, `words_en.json` взяты из проекта **keyswitcher**
(<https://github.com/graninilya/keyswitcher>), распространяемого под лицензией MIT.

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

## Ukrainian language resources

Files `Sources/Keyboop/Resources/words_uk.json` and
`Sources/Keyboop/Resources/trigrams_uk.json` were generated from linguistic
data provided by the **dict_uk** project:

<https://github.com/brown-uk/dict_uk>

The source project distributes its Ukrainian Hunspell resources under the
Mozilla Public License 1.1.

The generated JSON files are used as word-validation and trigram language
data for keyboard-layout detection.
