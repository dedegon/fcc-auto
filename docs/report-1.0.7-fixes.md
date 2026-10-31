# Отчёт v1.0.7: исправлен FCC_REPO_COMMIT, русский текст в UTF-8 BOM, версия из pyproject

## A. Что исправлено по пунктам 1–3

### 1. FCC_REPO_COMMIT — заменён на хеш репозитория Alishahryar1/free-claude-code

| Файл | Строка | Было | Стало |
|------|--------|------|-------|
| launcher_new.cs | 23-24 | `a54c5b1` (hash нашего проекта) | `4e92110a0a3232765c6fc7a8c9d34489fb0e65da` |
| uninstaller_new.cs | 19-20 | `a54c5b1` (hash нашего проекта) | `4e92110a0a3232765c6fc7a8c9d34489fb0e65da` |

**Проверка URL:** `https://raw.githubusercontent.com/Alishahryar1/free-claude-code/4e92110a0a3232765c6fc7a8c9d34489fb0e65da/scripts/uninstall.ps1` — **HTTP 200 OK**, скрипт существует.

### 2. Русский текст — восстановлен в .ps1 и .cs, файлы сохранены в UTF-8 с BOM

| Файл | Изменения |
|------|-----------|
| build_new.ps1 | Все комментарии и строки возвращены на русский. Добавлена строка `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` в начале. Файл перезаписан с UTF-8 BOM (`file` показывает "Unicode text, UTF-8 (with BOM) text"). |
| launcher_new.cs | Русские комментарии сохранены (файл уже был в UTF-8). |
| uninstaller_new.cs | Русские комментарии сохранены (файл уже был в UTF-8). |

### 3. Версия — прочитана из pyproject.toml (1.0.0), AssemblyVersion приведены в соответствие

| Файл | AssemblyVersion | AssemblyFileVersion | Версия из pyproject.toml |
|------|-----------------|---------------------|--------------------------|
| launcher_new.cs | 1.0.0.0 | 1.0.0.0 | 1.0.0 ✓ |
| uninstaller_new.cs | 1.0.0.0 | 1.0.0.0 | 1.0.0 ✓ |

---

## B. Выводы проверок (дословно)

### PowerShell парсер (build_new.ps1, install.ps1, uninstall.ps1)

```
build_new.ps1: OK - 0 errors
install.ps1: OK - 0 errors
uninstall.ps1: OK - 0 errors
```

### Python py_compile

```
uv run --python 3.11 python -m py_compile scanner.py claude_filter.py claude_auto.py scanner_config.py model_limits/registry.py
exit=0
```

### Python импорты

```
uv run --python 3.11 python -c "import scanner, claude_filter, claude_auto, scanner_config, model_limits.registry; print('OK')"
OK
```

### Сборка через csc (build_new.ps1)

```
Версия из pyproject.toml: 1.0.0
Компиляция uninstall.exe...
Собрано: C:\gags\fcc-auto-1.0.3\uninstall.exe
Компиляция install.exe с внедрённым uninstall.exe...
launcher_new.cs(202,23): warning CS1998: Асинхронный метод не имеет операторов await...
launcher_new.cs(477,23): warning CS1998: Асинхронный метод не имеет операторов await...
launcher_new.cs(481,16): warning CS0219: Переменная "fccUninstall" присвоена значение, но не используется
launcher_new.cs(568,28): warning CS1998: Асинхронный метод не имеет операторов await...
Собрано: C:\gags\fcc-auto-1.0.3\install.exe (uninstall.exe внедрён как ресурс, UAC манифест)
Создан standalone установщик: C:\gags\fcc-auto-1.0.3\dist\install-claude-auto-V1.0.0.exe

=== СБОРКА ЗАВЕРШЕНА ===
```

**Предупреждения (не ошибки):**
- CS1998 ×4: асинхронные методы без await (работают корректно, await не требуется для данных методов)
- CS0219 ×1: неиспользуемая переменная `fccUninstall`

**Проверка ресурса:**
```
Resources found:
  Uninstaller.exe
```
Ресурс `Uninstaller.exe` корректно внедрён в `install.exe`.

**Размеры файлов:**
- `install.exe`: 49 152 байта
- `dist/install-claude-auto-V1.0.0.exe`: 49 152 байта

### grep проверки

| Паттерн | Результат |
|---------|-----------|
| `a54c5b1` | Не найдено |
| `4e92110a0a3232765c6fc7a8c9d34489fb0e65da` | Найдено в launcher_new.cs:23-24, uninstaller_new.cs:19-20 |
| `C:\\Users\\` | Не найдено |
| `gsk_`, `nvapi-` | Не найдено |
| `TODO` | Не найдено |

---

## C. Хеш FCC коммита

**Хеш:** `4e92110a0a3232765c6fc7a8c9d34489fb0e65da`

**Проверка:** `https://raw.githubusercontent.com/Alishahryar1/free-claude-code/4e92110a0a3232765c6fc7a8c9d34489fb0e65da/scripts/uninstall.ps1` — **HTTP 200 OK**

Это последний коммит, затрагивающий файл `scripts/uninstall.ps1` в репозитории Alishahryar1/free-claude-code (от 25.10.2026).

---

## D. Git-хеш коммита

*Коммит будет создан после проверки пользователем. Текущее состояние: changes staged.*

```
git diff --stat:
 build_new.ps1      | 69 +++++++++++++++++++++++++++---------------------------
 launcher_new.cs    |  3 ++-
 uninstaller_new.cs |  3 ++-
 3 files changed, 39 insertions(+), 36 deletions(-)
```

**Файлы для коммита:**
- build_new.ps1
- launcher_new.cs
- uninstaller_new.cs
- docs/report-1.0.7-fixes.md

**Сообщение коммита:** "1.0.7: исправлен FCC_REPO_COMMIT, русский текст в UTF-8 BOM, версия из pyproject"

---

## E. Что не проверено

1. **Ручные тесты T1–T4** (делает пользователь):
   - T1: Чистая машина без FCC — запуск `dist\install.exe`, ожидаемо: FCC установлен, `claude-auto` работает
   - T2: Уже установленный FCC — запуск `install.exe`, ожидаемо: "FCC найден, пропуск", версия `fcc-server` не меняется
   - T3: Удаление без `--purge-fcc` — `uninstall.exe`, ожидаемо: `claude-auto` удалён, FCC остался
   - T4: Удаление с `--purge-fcc` — только на тестовом профиле, по согласованию

2. **Реальная установка FCC** — скачивание и запуск официального `install.ps1` из репозитория FCC

3. **UAC повышение прав** — работа манифеста `requireAdministrator`

4. **Официальный uninstall.ps1 FCC** — запуск по зафиксированному коммиту `4e92110a0a3232765c6fc7a8c9d34489fb0e65da`

5. **Параллельные установки/удаления** — race conditions

6. **Отображение кириллицы в консоли** — csc.exe предупреждения выводятся в CP1251, в UTF-8 терминале отображаются некорректно (но сборка проходит успешно)