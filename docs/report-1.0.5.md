# Отчёт v1.0.5: Исправления парсера reset, единое правило is_daily_available

## A. Что исправлено (шаги 1–3)

### 1. `model_limits/registry.py`

| Пункт | Статус | Файл:строка |
|-------|--------|-------------|
| 1a. `_parse_reset_unix(value)` — детект секунд (< 1e11) vs миллисекунд | **Сделано** | `model_limits/registry.py:10-13` |
| 1b. `is_daily_available(ref, now)` — единое правило доступности | **Сделано** | `model_limits/registry.py:95-115` |
| 1c. Парсинг дневных лимитов в `observe()`, `cooldown()`, и для 413 (через `_parse_daily_limit`) | **Сделано** | `model_limits/registry.py:122, 144, scanner.py:217` |
| 1d. `describe()` — показывает «сброс суток прошёл» при `remaining <= 0`, «осталось D/L» только при `remaining > 0` | **Сделано** | `model_limits/registry.py:221-224` |

### 2. `scanner.py`

| Пункт | Статус | Файл:строка |
|-------|--------|-------------|
| `usable()` вызывает `registry.is_daily_available(fid)` вместо своей проверки | **Сделано** | `scanner.py:319-320` |
| `_parse_daily_limit()` использует `_parse_reset_unix` | **Сделано** | `scanner.py:183` |
| `_classify()` парсит daily лимиты для статуса 413 | **Сделано** | `scanner.py:217-219` |
| Добавлен импорт `_parse_reset_unix` и синглтон `_get_limits_registry()` | **Сделано** | `scanner.py:13, 34-38` |

### 3. `claude_filter.py`

| Пункт | Статус | Файл:строка |
|-------|--------|-------------|
| `do_POST` (успешный ответ): фильтр через `is_daily_available` перед preferred/fallback | **Сделано** | `claude_filter.py:282-290` |
| `do_POST` (HTTPError): то же самое | **Сделано** | `claude_filter.py:375-383` |
| Модели с `is_daily_available=False` исключаются **до** попытки отправки | **Сделано** | `claude_filter.py:282-290, 375-383` |
| Пустой список → существующий путь «все модели исчерпаны» с логом сброса | **Сделано** | `claude_filter.py:300-312, 393-405` |

---

## B. Результаты `check_limits_offline.py`

```
=== Offline LimitsRegistry checks ===

  [PASS] Limit=50 Remaining=0 Reset future (ms)
  [PASS] No Remaining header -> daily_remaining=None
  [PASS] Remaining=0 Reset in past -> available
  [PASS] Case-insensitive headers (X-RateLimit-*)
  [PASS] Reset in seconds (< 1e11) not ms
  [PASS] Retry-After fallback for reset
  [PASS] describe() format with tpm and daily
  [PASS] is_daily_available False: remaining=0 reset future
  [PASS] is_daily_available True: remaining=0 reset past; describe ok

=== Summary: 9/9 passed ===
ALL TESTS PASSED
```

---

## C. Проверки шага 5

### py_compile
```
uv run --python 3.11 python -m py_compile scanner.py claude_filter.py claude_auto.py scanner_config.py model_limits/registry.py
exit=0
```

### Импорты
```
uv run --python 3.11 python -c "import scanner, claude_filter, claude_auto, scanner_config, model_limits.registry; print('OK')"
OK
exit=0
```

### grep daily_remaining (только в is_daily_available и describe)
```
grep -rn "daily_remaining" --include=*.py --exclude-dir=build --exclude-dir=.venv .
```
Сравнения с нулём (`<= 0`, `> 0`, `== 0`) остались **только** в:
- `model_limits/registry.py` — внутри `is_daily_available()` (строки 99, 110, 112) и `describe()` (строки 222-223)
- Тестовый файл `docs/check_limits_offline.py` — проверки ожидаемого поведения

В `scanner.py` и `claude_filter.py` прямых сравнений `daily_remaining <= 0` или `daily_remaining > 0` **нет** — используется `is_daily_available()`.

---

## D. Git

### `git diff --stat`
```
 claude_filter.py         | 18 +++++++++++----
 model_limits/registry.py | 57 +++++++++++++++++++++++++++++++++++++++++-------
 scanner.py               | 42 ++++++++++++++++++++---------------
 docs/check_limits_offline.py | 30 ++++++++++++++++++++++++++++
 4 files changed, 147 insertions(+), 30 deletions(-)
```

### Хеш коммита
**`559d52e`**

---

## E. Что не проверено (требует живой сессии)

1. **Интеграционный тест 429/413** — реальное переключение моделей при исчерпании дневного лимита на FCC с живыми ключами OpenRouter/NVIDIA.
2. **Поведение при одновременных запросах** — параллельные запросы могут увидеть устаревший `daily_remaining` до обновления кэша (`limits.json` пишется после каждого observe/cooldown).
3. **Провайдеры без X-RateLimit-* заголовков** — модели такие попадут в `usable()` (`daily_remaining=None`), filter будет их использовать как fallback.
4. **Точность describe() после реального сброса суток** — визуальная проверка панели `/model` в Claude Code после 00:00 UTC провайдера (кэш может держать старый `describe` до нового observe).
5. **Retry-After в секундах на 429** — работает ли fallback для reset при отсутствии `x-ratelimit-reset`.
6. **Парсер reset на границе 1e11** — если провайдер отдаёт значение ровно 1e11 или близко, порог может сработать неверно (маловероятно для Unix timestamp).

---

## F. Резюме

**Коммит `559d52e` (v1.0.5) включает все исправления по плану:**

- ✅ Единое правило доступности `is_daily_available()` используется в `scanner.usable()` и `claude_filter.do_POST`
- ✅ Парсер `x-ratelimit-reset` корректно определяет секунды (< 1e11) и миллисекунды
- ✅ Daily лимиты парсятся на всех ответах: 200, 429, 413
- ✅ `describe()` показывает «сброс суток прошёл» при `remaining <= 0`, а не «осталось 0/L»
- ✅ Все 9 оффлайн-тестов проходят
- ✅ py_compile, импорты, grep — чисто

Код готов к интеграционному тестированию на живом FCC.