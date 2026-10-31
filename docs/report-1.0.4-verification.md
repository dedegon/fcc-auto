# Отчёт верификации v1.0.4 (коммит a54c5b1)

## A. Git (Шаг 1)

### `git show --stat a54c5b1`
```
commit a54c5b14522da16f55fda9d41922a49dd656495b
Author: dedegon <109426875+dedegon@users.noreply.github.com>
Date:   Sat Oct 31 05:31:06 2026 +0300

    1.0.4: per-model daily limits tracking and model switching
    
    - model_limits/registry.py: added _parse_daily_limit(), observe() and cooldown() track X-RateLimit-Limit/Remaining/Reset per model, get_daily_remaining() returns (daily_limit, daily_remaining, daily_reset_unix), describe() shows [Nk/мин, осталось D/день]
    - scanner.py: _classify() parses daily limits from all responses (200/429/413), stores in cache, usable() filters models with daily_remaining == 0 before reset
    - claude_filter.py: do_POST prefers models with daily_remaining > 0 when switching on 429/413, logs nearest reset time if all models exhausted
    
    Co-Authored-By: Claude Code <noreply@anthropic.com>

 claude_filter.py           |  95 +++++++++++++++++++++++++++++----------
 docs/report-1.0.3-fixes.md |  96 ++++++++++++++++++++++++++++++++++++++++
 model_limits/registry.py   | 108 ++++++++++++++++++++++++++++++++++++++-------
 scanner.py                 |  90 ++++++++++++++++++++++++++++++++++++-
 4 files changed, 349 insertions(+), 40 deletions(-)
```

### `git ls-files | grep -E "^(build|\.venv)/" | head -20`
```
(пусто — build/ и .venv/ НЕ в git)
```

### `git check-ignore -v build .venv`
```
.gitignore:4:build/	build
.gitignore:6:.venv/	.venv
```

### `git status --short`
```
?? docs/report-1.0.4-limits.md
```

**Вывод:** build/ и .venv/ в .gitignore, в коммит не попали. Рабочая директория чиста, только новый отчёт.

---

## B. Заявления отчёта 1.0.4 (Шаг 2)

| Проверка | Вердикт | Дословный вывод |
|----------|---------|-----------------|
| `grep -rni "stopped" --include=*.py --exclude-dir=build --exclude-dir=.venv .` | **Подтверждено** | (пусто) |
| `grep -rni "groq" --include=*.py --exclude-dir=build --exclude-dir=.venv .` | **Подтверждено** | `./claude_auto.py:80:# Groq исключён` |
| `grep -rn "FILLER" --include=*.py --exclude-dir=build --exclude-dir=.venv .` | **Подтверждено** | (пусто) |
| `uv run --python 3.11 python -m py_compile ...` | **Подтверждено** | `exit=0` |
| `uv run --python 3.11 python -c "import scanner, claude_filter, claude_auto, scanner_config, model_limits.registry; print('OK')"` | **Подтверждено** | `OK\nexit=0` |

Все заявления отчёта подтверждены.

---

## C. Результаты check_limits_offline.py (Шаг 3)

```
=== Offline LimitsRegistry checks ===

  [PASS] Limit=50 Remaining=0 Reset future (ms)
  [PASS] No Remaining header -> daily_remaining=None
  [PASS] Remaining=0 Reset in past -> available
  [PASS] Case-insensitive headers (X-RateLimit-*)
  [FAIL] Reset in seconds (< 1e11) not ms
  [PASS] Retry-After fallback for reset
  [PASS] describe() format with tpm and daily

=== Summary: 6/7 passed ===
SOME TESTS FAILED
```

### Детали FAIL:
**Test 5: Reset in seconds (< 1e11) not ms**
- `_parse_daily_limit()` в `model_limits/registry.py:67` **всегда** делит `x-ratelimit-reset` на 1000, предполагая миллисекунды.
- Если провайдер отдаёт секунды (Unix timestamp < 1e11), парсер ошибочно считает их миллисекундами и получает дату в 1970 году.
- **Риск:** модели с заголовком в секундах будут помечены как "лимит сброшен в 1970" → `daily_reset_unix < now` → модель считается доступной (что безопасно, но логирует неверное время сброса).

---

## D. Места исключения моделей по дневному лимиту (Шаг 4)

### 1. `scanner.py:313-318` — `usable()` (формирование списка для /model)
```python
daily_remaining = e.get("daily_remaining")
daily_reset_unix = e.get("daily_reset_unix")
if daily_remaining is not None and daily_remaining <= 0:
    if daily_reset_unix and daily_reset_unix > now_ts:
        continue  # Skip until reset
    # If reset time passed or unknown, allow (provider may have reset)
```
**Правило:** Модель исключается из `usable()` если `daily_remaining <= 0` **И** `daily_reset_unix > now`. Если reset в прошлом или неизвестен — модель допускается.

### 2. `claude_filter.py:283-292` — `do_POST` при переключении (429/413), первый проход
```python
for m in filtered:
    dlim, drem, _ = self.limits.get_daily_remaining(m)
    if drem is not None and drem > 0:
        preferred.append(m)
    else:
        fallback.append(m)
next_models = preferred + fallback
```
**Правило:** При переключении модели **предпочитаются** модели с `drem > 0`. Модели с `drem == 0` или `drem is None` идут в `fallback` и используются только если `preferred` пуст. Модели **не исключаются полностью** — просто деприоритизируются.

### 3. `claude_filter.py:366-379` — `do_POST` при переключении (429/413), второй проход (HTTPError)
**То же правило** — предпочтение `drem > 0`, fallback на остальные.

### 4. `claude_filter.py:305-317` — все модели исчерпаны
```python
for m in verified_set:
    _, _, dreset = self.limits.get_daily_remaining(m)
    if dreset and dreset > time.time():
        if nearest_reset is None or dreset < nearest_reset:
            nearest_reset = dreset
```
**Правило:** Если `preferred + fallback` пуст (нет моделей с окном >= MIN_CONTEXT_TOKENS), логируется время ближайшего сброса среди всех верифицированных моделей и возвращается ошибка FCC.

---

## E. Найденные риски и расхождения

| # | Риск | Файл:строка | Описание |
|---|------|-------------|----------|
| 1 | **Парсер reset не определяет секунды/миллисекунды** | `model_limits/registry.py:67` | Всегда делит на 1000. Провайдеры (например, некоторые OpenRouter endpoints) могут отдавать Unix-секунды. Результат: неверное время сброса в логах/describe. |
| 2 | **Расхождение логики: scanner исключает, filter — только деприоритизирует** | `scanner.py:316` vs `claude_filter.py:288` | `usable()` **пропускает** модель с `daily_remaining=0` (если reset > now). `do_POST` при переключении **пытается использовать** такую модель как fallback. Если сканер уже исключил модель, она не попадёт в `verified()` и filter её не увидит — согласовано. Но если кэш устарел (TTL) и модель прошла usable(), filter может переключиться на модель с 0 remaining. |
| 3 | **daily_remaining <= 0 vs > 0** | `scanner.py:316` использует `<= 0`, `claude_filter.py:288` использует `> 0` | Консистентно: 0 = исчерпан. Но если remaining < 0 (теоретически) — scanner исключит, filter считает fallback. |
| 4 | **Кэш лимитов не инвалидируется при сбросе суток** | `model_limits/registry.py` | `limits.json` хранит `daily_reset_unix`. После сброса суток данные остаются до следующего ответа от провайдера. `usable()` проверяет `daily_reset_unix > now`, так что модель снова станет доступна, но в `/model` будет висеть старый `describe()` до нового observe(). |
| 5 | **cooldown() парсит daily лимиты только на 429** | `model_limits/registry.py:121` | На 413 (context limit) daily лимиты не парсятся, если они есть в ответе. |
| 6 | **describe() показывает "осталось D/L в день" даже если reset прошёл** | `model_limits/registry.py:183-184` | Не проверяет `daily_reset_unix > now` перед выводом "осталось". После сброса может показывать "осталось 0/50" вместо "лимит сбросился". |

---

## F. Что не проверено в живой сессии

1. **Интеграционный тест 429/413** — реальное переключение моделей при исчерпании дневного лимита на FCC с живыми ключами OpenRouter/NVIDIA.
2. **Поведение при одновременных запросах** — параллельные запросы могут увидеть устаревший `daily_remaining` до обновления кэша.
3. **Провайдеры без X-RateLimit-* заголовков** — модели такие попадут в `usable()` (daily_remaining=None), filter будет их использовать как fallback.
4. **Точность describe() после сброса суток** — визуальная проверка панели /model в Claude Code после 00:00 UTC провайдера.
5. **Retry-After в секундах на 429** — работает ли fallback для reset при отсутствии x-ratelimit-reset.

---

## Итог

**Коммит a54c5b1 соответствует отчёту 1.0.4** по всем проверяемым статическим критериям (grep, py_compile, импорты).

**Один функциональный дефект:** парсер `x-ratelimit-reset` не детектирует секунды vs миллисекунды (Test 5 FAIL). Это не ломает логику исключения (модель с прошедшим reset считается доступной), но даёт неверное время в логах и `/model`.

**Рекомендация:** до согласования исправлений не менять код. Основные риски — расхождение логик scanner/filter (пункт 2) и парсер reset (пункт 1).