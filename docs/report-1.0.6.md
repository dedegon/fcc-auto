# Отчёт v1.0.6: describe по времени сброса, filter_available, исправлены тесты

## A. Что изменено

| Пункт | Статус | Файл:строка |
|-------|--------|-------------|
| 1. `_parse_reset_unix` — детект секунд (< 1e11) vs миллисекунд | **Сделано** | `model_limits/registry.py:26-34` |
| 2. `_daily_status(ref, now)` — общий приватный метод для describe и filter_available | **Сделано** | `model_limits/registry.py:96-115` |
| 3. `is_daily_available(ref, now)` использует `_daily_status` | **Сделано** | `model_limits/registry.py:118-130` |
| 4. `filter_available(refs, now)` — фильтрует список через `is_daily_available` | **Сделано** | `model_limits/registry.py:132-138` |
| 5. `describe(ref)` использует `_daily_status`: | **Сделано** | `model_limits/registry.py:221-270` |
|   - daily_remaining > 0: «осталось D/L в день» | | |
|   - daily_remaining <= 0, reset в будущем: «осталось 0/L в день, сброс HH:MM UTC» | | |
|   - daily_remaining <= 0, reset в прошлом или неизвестен: «сброс суток прошёл» | | |
|   - daily_remaining неизвестен: без дневной части | | |
| 6. `claude_filter.py` — оба места переключения (успешный ответ и HTTPError) вызывают `filter_available(filtered)` вместо ручного цикла | **Сделано** | `claude_filter.py:282-283, 371-372` |
| 7. Тесты: | **Сделано** | `docs/check_limits_offline.py` |
|   - test1: ожидает «осталось 0/50» + «сброс» + «UTC» при reset future | | |
|   - test9: проверяет «сброс суток прошёл» при reset past | | |
|   - test10: remaining=0, reset future — проверяет «осталось 0/50», «сброс», «UTC» | | |
|   - test11: filter_available исключает exhausted, оставляет no-data и available | | |
|   - test8: дополнена проверкой filter_available | | |

---

## B. Вывод check_limits_offline.py

```
=== Offline LimitsRegistry checks ===

  [PASS] Limit=50 Remaining=0 Reset future (ms)
  [PASS] No Remaining header -> daily_remaining=None
  [PASS] Remaining=0 Reset in past -> available
  [PASS] Case-insensitive headers (X-RateLimit-*)
  [PASS] Reset in seconds (< 1e11) not ms
  [PASS] Retry-After fallback for reset
  [PASS] describe() format with tpm and daily
  [PASS] is_daily_available False + filter_available
  [PASS] is_daily_available True: remaining=0 reset past; describe=сброс суток прошёл
  [PASS] describe: remaining=0 reset future -> 0/50 + сброс UTC
  [PASS] filter_available: excludes exhausted, keeps no-data and available

=== Summary: 11/11 passed ===
ALL TESTS PASSED
```

---

## C. Проверки шага 3

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

### grep filter_available / is_daily_available / describe
```
grep -rn "filter_available\|is_daily_available\|describe(" --include=*.py --exclude-dir=build --exclude-dir=.venv .
```

**Результат:** в `claude_filter.py` используется `filter_available` (строки 283, 372), ручной цикл с `is_daily_available` удалён. В `scanner.py` используется `is_daily_available` (строка 324). В `model_limits/registry.py` определены все три метода.

---

## D. Git

### `git diff --stat` (HEAD 4a8eba0 vs 69d25ff)
```
 claude_filter.py             | 14 ++-----
 docs/check_limits_offline.py | 81 +++++++++++++++++++++++++++++-------
 model_limits/registry.py     | 99 +++++++++++++++++++++++++++++++-------------
 3 files changed, 141 insertions(+), 53 deletions(-)
```

### Хеш коммита
**`4a8eba0`**

### `git log --oneline -4`
```
4a8eba0 1.0.6: describe по времени сброса, filter_available, фильтр переведён на единое правило, тесты 10-11
69d25ff 1.0.5: исходники, лимиты по моделям, is_daily_available, отчёты
c30d36d Лимит токенов как подпись в /model; инструменты проверяются коротким запросом
de558c3 gitignore: исправлена строка uv.lock
```

---

## E. Что не проверено

1. **Живой describe в /model** — визуальная проверка панели Claude Code при реальных ответах провайдеров.
2. **Реальный сброс суток** — поведение describe/usable/filter после 00:00 UTC провайдера (кэш может держать старый статус до нового observe).
3. **Интеграционный тест 429/413** — реальное переключение моделей при исчерпании дневного лимита на FCC с живыми ключами.
4. **Параллельные запросы** — race condition между observe() и filter_available() при одновременных запросах.
5. **Провайдеры без X-RateLimit-* заголовков** — модели такие попадают в usable/filter_available (daily_remaining=None).