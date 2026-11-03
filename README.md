# claude-auto

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

Сборка установщика: **ISCC** (Inno Setup 6) из `claude-auto.iss`. Релиз в процессе — `.exe` будет на странице Releases.

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