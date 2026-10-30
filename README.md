# fcc-auto

`claude-auto` запускает FCC, проверяет бесплатные модели (OpenRouter, Groq, NVIDIA NIM) и открывает Claude Code. В `/model` попадают только проверенные модели.

## Установка

Клонируйте репозиторий и запустите установщик:

    git clone https://github.com/dedegon/fcc-auto.git
    cd fcc-auto
    .\install.ps1

Установщик ставит uv, FCC (через официальный установщик) и `claude-auto`. Если шаг ломается, `claude-auto` откатывается.

Удалить `claude-auto`: `.\install.ps1 -Uninstall`.

## Использование

    cd D:\проект
    claude-auto            # сканирование и запуск
    claude-auto --offs     # без сканирования, из кэша
    claude-auto --help

Ключи API хранятся в `~/.fcc/.env` или в переменных окружения (`GROQ_API_KEY`, `NVIDIA_NIM_API_KEY`, `OPENROUTER_API_KEY`). В репозиторий они не попадают.