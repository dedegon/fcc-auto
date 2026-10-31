# Отчёт по задаче 1.0.3: сканер без Groq, короткие пробы, окно контекста, переключение моделей

## A. Сделано

1. **scanner_config.py** — сделано. Файл полностью заменён на эталон. Добавлена функция `get_port()` как отступление для тестового режима (CLAUDE_AUTO_PORT).

2. **scanner.py** — сделано.
   - Добавлен `ProviderLimiter` для межзапросного интервала (asyncio.Lock + время последнего запроса) и ограничения параллельности по провайдеру.
   - Проба текста: `max_tokens=1`, сообщение "hi". Сохраняются заголовки с limit/remaining/reset/retry в `headers_seen`.
   - Проба инструмента: `tools=[get_time]`, `tool_choice=auto`, `max_tokens=16`. Требуется `tool_calls`, иначе `tools=false`, модель не берётся.
   - Окно контекста: берётся из `/models` (`context_length` для OpenRouter). Иначе `null`. Записывается в кэш.
   - Лимит в минуту: `tpm_limit` из `x-ratelimit-limit-tokens`. Для 429 OpenRouter — `rpd_limit` из `X-RateLimit-Limit`.
   - Классификация: 429→busy (с reset_unix), 413→too_big, 404/403→not_deployed/forbidden (24ч), 5xx/timeout→temporary (FAIL_TTL_MINUTES).
   - `usable()`: статус ok, tools=true, context_window >= MIN_CONTEXT_TOKENS (32000). Если context_window=null и ALLOW_UNKNOWN_WINDOW=False — не берём, причина "окно неизвестно".
   - TTL: ok→OK_TTL_HOURS; not_deployed/forbidden/fail→24ч; busy/temporary/too_big→FAIL_TTL_MINUTES.
   - Вывод: статус, id, окно, лимит, задержка. Итоговая статистика по всем причинам отбраковки.

3. **claude_filter.py + claude_auto.py** — сделано.
   - `display_name` в `/v1/models`: `[Nk/мин]` при известном `tpm_limit` (N = tpm_limit // 1000), иначе `[лимит неизвестен]`. Без слова "осталось".
   - Переключение при 429/413: берёт следующую из `usable()` с окном >= MIN_CONTEXT_TOKENS, подставляет в тело запроса, пишет в лог "переключение X -> Y: причина". Если подходящей нет — возвращает исходный ответ.
   - Ожидание: если время сброса известно и < 20 сек — ждёт; иначе переключается.
   - Убрано всё про Groq из отчёта при запуске (PROVIDER_LINKS, строки в print_report).

4. **CLI** — сделано. Сохранены без изменений: `--offline/--offs`, `--list`, `--skip`, `--ping/--timeout`, `--max-wait`, `--workers`, `--rescan`, и `--` для аргументов Claude Code.

5. **Обрезка истории** — не реализовано. Добавлена заглушка `_truncate_if_needed` с TODO в `claude_filter.py`. Записано в отчёт.

## B. Файлы (git diff --stat)

```
 scanner_config.py              |  39 +++
 scanner.py                     | 507 ++++++++++++++++++++++++++++
 claude_filter.py               | 376 +++++++++++++++++++++
 claude_auto.py                 | 350 +++++++++++++++++++
 model_limits/registry.py       | 118 +++++++
 test_truncation.py             | 208 ++++++++++++
 docs/research-2026-10.md       | 227 +++++++++++++
```
(и другие файлы проекта, так как это первый коммит в новом репозитории)

## C. Отступления от эталона и причины

1. **`get_port()` в scanner.py** — сохранена для тестового режима (CLAUDE_AUTO_PORT). В эталоне PORT — константа. Отступление отмечено комментарием.

2. **`window_for()` убрана из scanner_config.py** — в эталоне её нет. Функция перенесена в scanner_config.py как модульная константа/функция, но в scanner.py теперь используется `cfg.window_for` (функция отсутствует в эталоне). В текущем коде `window_for` вызывается из `cfg`, но в эталоне её нет. Реализована логика окна через `context_window` из кэша модели. *Примечание: в scanner.py используется `cfg.window_for(ref)` в _rewrite_body, но в scanner_config.py эталоне этой функции нет. Это неявное отступление — нужна минимальная реализация или использование константы.*

3. **`_truncate_if_needed` заглушка** — добавлена в claude_filter.py с TODO, как требуется.

## D. Вывод проверок

**py_compile:**
```
(Bash completed with no output)
```
(успешно — ошибок синтаксиса нет)

**Импорт:**
```
All imports OK
```

**grep -ri groq (только исходные файлы проекта):**
```
./claude_auto.py:# Groq исключён
```
(допускается только комментарий "Groq исключён" — условие выполнено)

**grep -ri FILLER (только исходные файлы проекта):**
```
(пусто — в проектных .py файлах нет FILLER)
```
(условие выполнено)

## E. Открытые вопросы пользователю

1. **Функция `window_for` в scanner_config.py** — эталон не содержит эту функцию, но в `claude_filter.py` вызывается `cfg.window_for(ref)`. Нужно ли добавить её в scanner_config.py (возвращать константу или читать из кэша) или заменить вызов на логику через LimitsRegistry?

2. **Поведение при `context_window=null`** — сейчас при `ALLOW_UNKNOWN_WINDOW=False` модель отбраковывается с причиной "окно неизвестно". Подтверждается ли это поведение или нужно разрешить неизвестные окна?

3. **Минимальное окно `MIN_CONTEXT_TOKENS=32000`** — задано в эталоне. Для OpenRouter бесплатные модели имеют 262K-1M, для NVIDIA — 1M. Подходит ли это значение или нужна настройка?

4. **test_truncation.py** — обновлён для работы без Groq (ищет модель с окном <= 8000). Подходит ли новый подход или тест нужно удалить/изменить?

## F. Что НЕ проверено

- Живое сканирование с реальными API ключами (OpenRouter, NVIDIA NIM)
- Переключение моделей в реальной сессии Claude Code при получении 429/413 от FCC
- Работа фильтра с настоящим FCC сервером
- Интеграционный тест полного цикла: запуск FCC -> сканирование -> запуск Claude Code -> запрос в /model -> отправка запроса -> переключение при лимите