# Reachy Mini — Telegram sticker pack

16 PNG, 512×512, прозрачный фон, каждый < 512 КБ — формат, который принимает @Stickers.
Источник иллюстраций: pollen-robotics.com/assets/reachies/ (Pollen Robotics / Hugging Face).
`update-box.png` собран из `reachy-update-box.svg` — SVG рендерится в четырёхкратном
разрешении и уменьшается, иначе тонкие штрихи антенн рассыпаются на краях.

## Эмодзи для загрузки

| Файл          | Эмодзи |
| ------------- | ------ |
| astronaut     | 🚀     |
| builder       | 👷     |
| captain       | ⚓     |
| cooking-chief | 👨‍🍳   |
| cowboy        | 🤠     |
| doctor        | 🩺     |
| explorer      | 🧭     |
| farmer        | 🌾     |
| fisherman     | 🎣     |
| hacker        | 💻     |
| jazzman       | 🎷     |
| magician      | 🪄     |
| plumber       | 🔧     |
| rich          | 🎩     |
| student       | 🎓     |
| update-box    | 📦     |

## Как собрать пак

1. В Telegram открыть @Stickers → `/newpack`
2. Ввести название пака (например `Reachy Mini`)
3. Отправлять PNG **файлом** (не фото — иначе Telegram сожмёт в JPEG и убьёт прозрачность), после каждого — эмодзи из таблицы
4. `/publish` → выбрать иконку → задать короткий адрес, например `reachymini`
5. Готово: t.me/addstickers/<адрес>

## Лицензия и происхождение

Иллюстрации — «Reachies» Pollen Robotics, и они распространяются под **Apache License 2.0**.
Источник: `pollen-robotics/reachy-mini-desktop-app`, каталог `src/assets/reachies/original/`
(проверено на `f520136ffe9b`).
Файл лицензии в том репозитории назван `LICENCE`, британским написанием,
поэтому GitHub его не классифицирует и в интерфейсе репозиторий выглядит как без лицензии;
копия лежит здесь рядом, в `LICENSE-Apache-2.0.txt`.

**Изменения, внесённые в работы Pollen** (этого требует §4 лицензии):

- исходники 1024×1024 уменьшены до 512×512 (`art/stickers/*.png`), Lanczos;
- `update-box.png` отрисован из `reachy-update-box.svg` в четырёхкратном разрешении
  и уменьшён, иначе тонкие штрихи антенн рассыпаются на краях;
- для iMessage они дополнительно уменьшены до 408×408 и, для анимированных,
  перекодированы в APNG с общей 256-цветной палитрой — см. `Scripts/build-stickers.py`
  и `Apps/ReachyStickers/AGENTS.md`.

Чего лицензия **не** даёт — §6: прав на товарные знаки.
«Reachy» и «Reachy Mini» — обозначения Pollen Robotics,
и это отдельный от авторского права вопрос.
или на huggingface.co/pollen-robotics.
