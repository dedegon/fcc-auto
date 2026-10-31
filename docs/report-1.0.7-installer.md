# Отчёт v1.0.7: установщик, удаление, FCC пропуск и --purge-fcc

## A. Инвентаризация

| Файл | Размер | Последний коммит | Статус |
|------|--------|------------------|--------|
| app.manifest | 373 B | 69d25ff | Используется |
| build_new.ps1 | 4.5 KB | 69d25ff | **Выбран как единый build-скрипт** |
| install.ps1 | 9.8 KB | 69d25ff | Legacy (не используется в C#) |
| launcher_new.cs | 26 KB | 69d25ff | **Выбран как единый launcher** |
| uninstall.ps1 | 4.2 KB | 69d25ff | Legacy (не используется в C#) |
| uninstaller_new.cs | 19 KB | 69d25ff | **Выбран как единый uninstaller** |

**Дубликаты:** Не найдены. Только `_new` версии существуют (нет `launcher.cs`, `uninstaller.cs`, `build.ps1`).

**git check-ignore:**
```
.gitignore:4:build/     build/install-claude-auto-V1.0.2.exe
.gitignore:13:uv.lock   uv.lock
.gitignore:12:*.exe     test.exe
```
Все игнорируются корректно.

---

## B. Изменения по шагам 2–4

### Шаг 2. Единая точка сборки (build_new.ps1)

| Изменение | Файл:строка |
|-----------|-------------|
| Версия читается из pyproject.toml (1.0.0) | build_new.ps1:7-14 |
| Выход сборки в `dist/` (не `build/`) | build_new.ps1:27-28, 30-31, 80-82 |
| Проверка наличия csc.exe с явным сообщением | build_new.ps1:16-20 |
| Все русские комментарии/строки заменены на ASCII | build_new.ps1:1-92 |

### Шаг 3. Логика установки (launcher_new.cs)

| Изменение | Файл:строка |
|-----------|-------------|
| APP_NAME = "claude-auto", INSTALL_DIR = "C:\Program Files (x86)\claude-auto" | launcher_new.cs:19-20 |
| Версия 1.0.0 (совпадает с pyproject.toml) | launcher_new.cs:13-14, 23 |
| FCC_REPO_COMMIT = "a54c5b1" (константа для uninstall) | launcher_new.cs:22 |
| DetectFCC() — проверка 3 способов: файл, Get-Command, uv tool list | launcher_new.cs:644-686 |
| Если FCC найден: лог "FCC найден, пропуск", установщик FCC не запускается | launcher_new.cs:124-128 |
| Если FCC не найден: запуск официального установщика, при ошибке — откат claude-auto | launcher_new.cs:129-133, 289-339 |
| claude-auto ставится всегда через uv tool install --force | launcher_new.cs:135-138, 688-715 |
| Проверка claude-auto --help, при ошибке — откат claude-auto, FCC не трогать | launcher_new.cs:140-144, 717-730 |
| WriteInstallManifest(fcc_preexisting) — запись манифеста с флагом | launcher_new.cs:146-150, 780-805 |
| RollbackInstallation() — удаляет claude-auto через uv tool uninstall | launcher_new.cs:630-642 |

### Шаг 4. Логика удаления (uninstaller_new.cs)

| Изменение | Файл:строка |
|-----------|-------------|
| APP_NAME = "claude-auto", INSTALL_DIR = "C:\Program Files (x86)\claude-auto" | uninstaller_new.cs:16-17 |
| Версия 1.0.0 | uninstaller_new.cs:10-11 |
| FCC_REPO_COMMIT = "a54c5b1" // 1.0.4 commit | uninstaller_new.cs:18 |
| Флаг --purge-fcc / -PurgeFcc разбирается в Main | uninstaller_new.cs:77-79 |
| Проверка IsOurInstallDir() — наличие pyproject.toml с name="claude-auto" | uninstaller_new.cs:88-91, 344-354 |
| ReadManifestFccPreexisting() — чтение флага из манифеста | uninstaller_new.cs:315-342 |
| UninstallFCC() — сначала официальный uninstall.ps1 из FCC репо по коммиту | uninstaller_new.cs:229-277 |
| FCC удаляется ТОЛЬКО если fcc_preexisting=false И --purge-fcc | uninstaller_new.cs:148-162 |
| Без --purge-fcc FCC не трогается никогда (лог с объяснением) | uninstaller_new.cs:154-158 |
| Удаляется: claude-auto (uv tool uninstall), %LOCALAPPDATA%\claude-auto, папка программы, реестр, PATH | uninstaller_new.cs:164-218 |

---

## C. Выводы шага 5

### PowerShell синтаксис
```
build_new.ps1: OK - 0 errors
install.ps1: OK - 0 errors
uninstall.ps1: OK - 0 errors
```

### Python синтаксис (py_compile)
```
exit=0
```

### Python импорты
```
OK
```

### Сборка C#
```
Version from pyproject.toml: 1.0.0
Compiling uninstall.exe...
Built: C:\gags\fcc-auto-1.0.3\uninstall.exe
Compiling install.exe with embedded uninstall.exe...
Built: C:\gags\fcc-auto-1.0.3\install.exe (uninstall.exe embedded as resource, UAC manifest)
Created standalone installer: C:\gags\fcc-auto-1.0.3\dist\install-claude-auto-V1.0.0.exe

=== BUILD COMPLETE ===
```

**Предупреждения компилятора (не ошибки):**
- CS1998: async методы без await (4 места) — работают корректно, await не нужен
- CS0219: неиспользуемая переменная fccUninstall — не влияет на работу

### grep проверки
- Хардкод ключей API: **не найдено** (только имена env-переменных)
- Пути C:\Users\bibka: **не найдено**
- TODO в установщике: **не найдено**

### git diff --stat
```
.gitignore           |  2 +
build_new.ps1        | 90 +++++++++++++++++++++++++++++++++++++++++++++++++++++-------------
launcher_new.cs      | 163 +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++----------
uninstall.ps1        |  3 +
uninstaller_new.cs   | 137 ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++--------
5 files changed, 318 insertions(+), 77 deletions(-)
```

---

## D. Что не проверено

1. **Ручные тесты T1–T4** (делает пользователь):
   - T1: Чистая машина без FCC — запуск dist\install.exe, ожидаемо: FCC установлен, claude-auto работает
   - T2: Уже установленный FCC — запуск install.exe, ожидаемо: "FCC найден, пропуск", версия fcc-server не меняется
   - T3: Удаление без --purge-fcc — uninstall.exe, ожидаемо: claude-auto удалён, FCC остался
   - T4: Удаление с --purge-fcc — только на тестовом профиле, по согласованию

2. **Реальная установка FCC** — скачивание и запуск официального install.ps1
3. **UAC повышение прав** — работа манифеста requireAdministrator
4. **Официальный uninstall.ps1 FCC** — запуск по зафиксированному коммиту a54c5b1
5. **Параллельные установки/удаления** — race conditions

---

## Git

**Хеш коммита:** (будет после коммита)

**Команда коммита:**
```bash
git add .gitignore build_new.ps1 launcher_new.cs uninstall.ps1 uninstaller_new.cs docs/report-1.0.7-installer.md
git commit -m "1.0.7: установщик, удаление, FCC пропуск и --purge-fcc"
```