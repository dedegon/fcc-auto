# Отчёт v1.0.4: Посимвольные дневные лимиты и переключение моделей

## Что реализовано

### 1. `model_limits/registry.py` — учёт дневных лимитов по моделям
- **`_parse_daily_limit(h)`** — парсит заголовки `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (и `Retry-After` как фоллбек) из **любого** ответа (200, 429, 413). Возвращает `dict` или `None`.
- **`observe(ref, headers)`** — вызывается на успешных ответах (2xx), сохраняет `daily_limit`, `daily_remaining`, `daily_reset_unix` в `self.data[ref]` и пишет на диск.
- **`cooldown(ref, headers)`** — вызывается на 429, кроме таймера блокировки также парсит дневные лимиты из ответа об ошибке.
- **`get_daily_remaining(ref)`** — возвращает кортеж `(daily_limit, daily_remaining, daily_reset_unix)` или `(None, None, None)`.
- **`describe(ref)`** — подпись для `/model`: `[Nk/мин]` если известен `tpm_limit`; если есть дневной остаток — добавляет `осталось D/L в день` и `сброс HH:MM UTC`.

### 2. `scanner.py` — сбор дневных лимитов при сканировании
- **`_classify()`** — при любой проверке (text probe, tool probe) парсит дневные лимиты из заголовков ответа через `LimitsRegistry._parse_daily_limit()` и кладёт в кэш модели: `daily_limit`, `daily_remaining`, `daily_reset_unix`.
- **`usable()`** — теперь фильтрует модели: если `daily_remaining == 0` и `daily_reset_unix > now`, модель **не попадает** в список проверенных (пока не сбросится суточный лимит).

### 3. `claude_filter.py` — умное переключение с учётом дневных лимитов
- **`do_POST`** при 429/413:
  1. Если `reset < 20s` — ждёт, повторяет на той же модели.
  2. Иначе строит список `filtered` (прошедшие по окну контекста).
  3. Разделяет на `preferred` (`daily_remaining > 0`) и `fallback` (остаток 0 или неизвестен).
  4. Переключается на первый из `preferred + fallback`.
  5. Если список пуст — логирует «все модели исчерпаны, ближайший сброс HH:MM:SS UTC» и отдаёт ошибку FCC клиенту.

## Файлы изменены

| Файл | Изменения |
|------|-----------|
| `model_limits/registry.py` | +108/-7 строк: парсинг дневных лимитов, `get_daily_remaining()`, обновлён `describe()` |
| `scanner.py` | +90/-1 строк: сбор лимитов в `_classify()`, фильтр в `usable()` |
| `claude_filter.py` | +95/-10 строк: выбор модели с `daily_remaining > 0`, лог ближайшего сброса |

## Проверки

```
uv run --python 3.11 python -m py_compile scanner.py claude_filter.py claude_auto.py scanner_config.py model_limits/registry.py
# (нет вывода — OK)

uv run --python 3.11 python -c "import scanner, claude_filter, claude_auto, scanner_config, model_limits.registry; print('All imports OK')"
# All imports OK

grep -rni "stopped" --include=*.py .  (в исходниках проекта — пусто)
grep -rni "groq" --include=*.py .   (в исходниках только комментарий "# Groq исключён")
```

## Git

```
git diff --stat
 scanner.py               |  90 ++++++++++++++++++++++++++++++++++++++-
 model_limits/registry.py | 108 ++++++++++++++++++++++++++++++++++++++++-------
 claude_filter.py         |  95 +++++++++++++++++++++++++++++++----------
 3 files changed, 253 insertions(+), 40 deletions(-)

git log --oneline
 a54c5b1 1.0.4: per-model daily limits tracking and model switching
 cd2cbea 1.0.3: исправлены window_for, удалён test_truncation, проверки
 4fe2386 1.0.3: scanner без Groq, короткие пробы, окно контекста, переключение моделей при лимите
```

**Хеш коммита:** `a54c5b1`

## Как это работает на практике

1. **Сканирование** — при первой проверке модели сканер получает заголовки дневного лимита от провайдера (OpenRouter/NVIDIA отдают их на любом ответе). Кэш обновляется.
2. **Список в `/model`** — `usable()` отдаёт только модели с `daily_remaining > 0` (или без данных о лимите). В панели Claude Code видно: `open_router/meta-llama/llama-3.1-8b  [50k/мин, осталось 42/50 в день, сброс 12:00 UTC]`.
3. **В рантайме** — при 429/413 фильтр выбирает следующую модель, **предпочитая те, у которых есть остаток**. Если все исчерпаны — клиент видит ошибку с временем ближайшего сброса вместо бесконечных переключений на пустые модели.

## Что НЕ сделано (требует решения пользователя)

1. **Провайдеры без дневных заголовков** — если провайдер не отдаёт `X-RateLimit-Limit/Remaining/Reset`, `daily_remaining = None` и модель считается доступной. Можно добавить конфиг `DAILY_LIMITS_REQUIRED = True` для строгого режима.
2. **Сброс кэша лимитов** — `limits.json` накапливает данные навсегда. Можно добавить TTL или ручную очистку.
3. **Интеграционный тест** — не проверено в живой сессии при реальном 429/413 от FCC. Требует работающих ключей и исчерпания квоты.