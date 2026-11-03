# claude-auto

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Platform](https://img.shields.io/badge/Platform-Windows%20x64-blue.svg)]() [![Inno Setup](https://img.shields.io/badge/Installer-Inno%20Setup%206-9b59b6.svg)]()

Автоматический установщик и запускатель для Free Claude Code (FCC). Ставит uv, затем FCC (если есть Python 3.14.10), затем claude-auto. Проверяет `claude-auto --help` после установки.

---

## Как работает установка

1. **uv** — фиксированная версия 0.11.33, скачивается с GitHub Releases, SHA256 проверяется по `uv.sha256`.
2. **FCC (free-claude-code) 6.18.5** — ставится через `uv tool install` только если найден **Python 3.14.10**:
   - Сначала проверяется переменная `CLAUDE_AUTO_PYTHON` (путь к python.exe).
   - Если не задана — выполняется `uv python find 3.14.10`.
   - Если Python 3.14.10 не найден — FCC **пропускается**, устанавливается только `claude-auto`.
3. **claude-auto** — ставится через `uv tool install` из локальных исходников.
4. Проверка: `claude-auto --help` (код возврата 0 = успех).
5. Манифест записывается в `%LOCALAPPDATA%\claude-auto\install.json`.

FCC слушает на порту **8082** (см. `scanner_config.py:PORT`).

Сборка установщика: **ISCC** (Inno Setup 6) из `claude-auto.iss`. Готовый установщик: [Releases](https://github.com/dedegon/fcc-auto/releases/latest).

---

## Установка в произвольную папку

По умолчанию программа ставится в `%LOCALAPPDATA%\claude-auto\app`, данные — 
в `%LOCALAPPDATA%\claude-auto`. Установщик поддерживает параметр `/DIR` 
(Inno Setup), чтобы поставить программу в другое место:

    install-claude-auto-V2.0.0.exe /DIR="C:\MyApps\claude-auto"

При этом:
- **Программа** (исходники, лаунчер) — в указанной папке (`C:\MyApps\claude-auto`).
- **Данные и окружение** (install.json, uv-tools, кэш) — всегда в 
  `%LOCALAPPDATA%\claude-auto`, независимо от `/DIR`. Это сделано, чтобы 
  удаление через «Приложения» не задевало пользовательские данные, 
  а обновления находили манифест в одном и том же месте.

---

## Удаление

- Параметры Windows → Приложения → claude-auto → Удалить
- Ярлык «Uninstall claude-auto» в меню Пуск

Удаляются: команда `claude-auto`, данные и кэш в `%LOCALAPPDATA%\claude-auto`, папка проекта. **FCC и `~\.fcc` не трогаются**.

---

## Ограничения

- Только Windows x64 (Inno Setup: `ArchitecturesAllowed=x64`).
- FCC ставится только при наличии Python 3.14.10. Без него работает только `claude-auto`.
- Версия uv зафиксирована: 0.11.33.

---

## Файлы проекта

- `claude-auto.iss` — скрипт Inno Setup
- `claude-auto-install.ps1` — логика установки (вызывается из установщика)
- `claude-auto-uninstall.ps1` — логика удаления
- `claude_auto.py`, `claude_filter.py`, `scanner.py`, `scanner_config.py` — исходный код
- `model_limits/` — лимиты моделей
- `uv.version`, `uv.sha256` — закреплённая версия uv и её хеш
- `fcc.version` — версия FCC (6.18.5)
- `assets/icon.ico`, `assets/wizard.bmp`, `assets/wizard_small.bmp` — иконки и баннеры установщика