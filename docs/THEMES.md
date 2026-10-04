# Цвета vysh из системы и дотов

В **Настройки → Внешний вид → Цвета** три варианта:

| Режим | Откуда цвет | Обновление |
|---|---|---|
| **Свои** | Один из встроенных акцентов | - |
| **Акцент системы** | Windows: «Параметры → Персонализация → Цвета». Linux: xdg-desktop-portal (`org.freedesktop.appearance accent-color`, GNOME 47+, KDE Plasma 6) | На лету |
| **Из дотов** (Linux) | Файл цветов: свой, caelestia, pywal | На лету, при каждой записи файла |

Из одного цвета vysh строит всю схему Material You - тем же алгоритмом, что matugen и Android. Если в файле есть готовые роли M3 или 16 цветов терминала, они используются как есть.

Если доты задают режим (`"mode": "dark"`) и в настройках выбрана тема «Системная», vysh переключится в этот режим.

## Где vysh ищет файл

По порядку, берётся первый найденный:

1. Путь из настроек («Свой путь к файлу цветов»)
2. `~/.config/vysh/colors.json` - сюда удобно писать шаблонами matugen / wallust
3. `~/.local/state/caelestia/scheme.json` - caelestia-shell, подхватывается сам
4. `~/.cache/wal/colors.json` - pywal / pywal16, подхватывается сам

## caelestia

Ничего настраивать не нужно: выберите «Из дотов». vysh читает текущую схему caelestia - все роли M3 и `term0…term15` для терминала. Сменили обои или схему - цвета обновятся сразу.

## pywal

Тоже работает сразу. Акцентом становится самый насыщенный из `color1…color6`, терминал получает все 16 цветов, фон и текст.

## matugen

Шаблон: [`themes/templates/matugen-vysh.json`](../themes/templates/matugen-vysh.json). Скопируйте его в `~/.config/matugen/templates/vysh.json` и добавьте в `~/.config/matugen/config.toml`:

```toml
[templates.vysh]
input_path = '~/.config/matugen/templates/vysh.json'
output_path = '~/.config/vysh/colors.json'
```

После `matugen image обои.jpg` vysh получит полные схемы для тёмной и светлой темы - те же цвета, что у остального рабочего стола.

## wallust

Шаблон: [`themes/templates/wallust-vysh.json`](../themes/templates/wallust-vysh.json). В `~/.config/wallust/wallust.toml`:

```toml
[templates]
vysh = { template = 'vysh.json', target = '~/.config/vysh/colors.json' }
```

и положите шаблон в `~/.config/wallust/templates/vysh.json`.

## Свой формат

Любой генератор может писать в `~/.config/vysh/colors.json`. Все поля необязательны, кроме цвета (`seed` или `primary`):

```json
{
  "mode": "dark",
  "seed": "#7aa2f7",
  "dark":  { "surface": "#1a1b26", "on_surface": "#c0caf5" },
  "light": { "primary": "#34548a" },
  "terminal": {
    "background": "#16161e",
    "foreground": "#c0caf5",
    "colors": ["#15161e", "#f7768e", "…ещё 14 цветов"]
  }
}
```

- `seed` - основной цвет, из него строится схема.
- `dark` / `light` - готовые роли M3 (`primary`, `on_primary`, `surface_container`, …; можно и `camelCase`), перекрывают сгенерированные.
- `colors` (без `dark`/`light`) - роли для режима из `mode`.
- `terminal.colors` - 16 цветов ANSI.

Цвета: `#rrggbb`, `rrggbb` или `#aarrggbb`. Пример: [`themes/templates/example-colors.json`](../themes/templates/example-colors.json).
