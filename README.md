# gpt2giga - Утилиты для GigaChat и gpt2giga прокси

## Описание

**gpt2giga** — набор bash-скриптов для работы с **GigaChat API** (Сбербанк) и **gpt2giga прокси**.

### Содержимое проекта:
- `gigachat_quota_check.sh` — мониторинг квот токенов GigaChat
- `gpt2giga_healthcheck.sh` — проверка работоспособности прокси
- `assets/chat_test.json` — пейлоад для теста chat completions
- `assets/tool_call.json` — пейлоад для проверки вызова инструментов (tool call)
- `assets/tool_result.json` — шаблон пейлоада второго раунда tool call (передача результата инструмента модели)
- `mcp_weather/` — MCP-сервер с инструментом `get_weather` (погоду запрашивает агент, а не скрипт)
- `.roo/mcp.json` — регистрация MCP-серверов проекта (`filesystem`, `weather`)
- `russian_trusted_root.cer` — SSL сертификат для API Сбербанка
- `secrets.txt` — ключи авторизации с https://developers.sber.ru/studio (создается пользователем самостоятельно)

## 🚀 Быстрый старт

### Требования
```bash
sudo apt install curl jq  # Ubuntu/Debian
# или
sudo dnf install curl jq  # Fedora
```

### Подготовка
```bash
cd gpt2giga/
chmod +x *.sh
```

### Настройка secrets.txt
```
T2=ваш_base64_ключ_T2
MTS=ваш_base64_ключ_MTS
SBR=ваш_base64_ключ_SBR
```
**Ключи берутся в [developers.sber.ru/studio](https://developers.sber.ru/studio) → Настройка API**

Количество аккаунтов не ограничено: скрипт читает все строки вида `ИМЯ=КЛЮЧ`
(пустые строки и строки, начинающиеся с `#`, игнорируются).
Порядок колонок задаётся массивом `ACCOUNT_ORDER=(T2 MTS SBR)` в начале скрипта,
остальные аккаунты добавляются в конец в порядке следования в `secrets.txt`.

### Настройка gpt2giga.cfg
Добавить URL gpt2giga и токен дотупа в файл `gpt2giga.cfg`:
```
# Configuration file for gpt2giga healthcheck script

# API URL
GIGACHAT_API_URL=https://gigachat.ydns.eu/v1

# Authentication Token
TOKEN=your_auth_token_here
```

## 📊 Скрипты

### 1. `gigachat_quota_check.sh`
**Функция:** Показывает баланс токенов GigaChat для всех аккаунтов из `secrets.txt` (T2, MTS, SBR и любых других)

**Использование:**
```bash
./gigachat_quota_check.sh
```

**Вывод:**
```
+--------------+---------+---------+---------+---------+
| Model        |      T2 |     MTS |     SBR |   TOTAL |
+--------------+---------+---------+---------+---------+
| GigaChat     | 1234567 | 2345678 | 3456789 | 7035034 |
| GigaChat_Pro |  987654 |  876543 |  765432 | 2629629 |
+--------------+---------+---------+---------+---------+
```

Ширина колонок рассчитывается автоматически.
Последний столбец `TOTAL` — сумма токенов одной модели по всем аккаунтам
(аккаунты, по которым не удалось получить токен, в сумму не входят).
Если по аккаунту произошла ошибка, в его колонке отображается `-`,
а предупреждение выводится в `stderr`.

**Коды возврата:**
| Код | Значение |
|-----|----------|
| `0` | Все аккаунты проверены успешно |
| `1` | Нет `secrets.txt` / не установлены `curl` или `jq` / нет ни одного ключа |
| `2` | Не удалось получить баланс ни по одному аккаунту |
| `3` | Часть аккаунтов не проверена (невалидные ключи) |

**Зависимости:** `jq`, `curl`, `secrets.txt`, `russian_trusted_root.cer`
(при отсутствии сертификата выводится предупреждение и запросы идут без `--cacert`)

---

### 2. `gpt2giga_healthcheck.sh`
**Функция:** Тестирование gpt2giga прокси, URL и токен берутся из `gpt2giga.cfg`
**Использование:**
```bash
./gpt2giga_healthcheck.sh -h  # Справка
./gpt2giga_healthcheck.sh -m  # Модели
./gpt2giga_healthcheck.sh -t  # Тест чата
./gpt2giga_healthcheck.sh -c  # Тест вызова инструментов (tool call)
./gpt2giga_healthcheck.sh -a  # Все тесты (модели + чат + tool call)
```

Скрипт проверяет наличие `gpt2giga.cfg`, обязательных параметров
(`GIGACHAT_API_URL`, `TOKEN`) и зависимостей `curl`/`jq`, а также
контролирует HTTP-код ответа API. Код возврата `0` — все проверки успешны,
`1` — ошибка конфигурации или хотя бы одна проверка завершилась неудачей.

**Пейлоады:** тело запроса для `-t` и `-c` хранится в JSON-файлах
(`assets/chat_test.json`, `assets/tool_call.json`, `assets/tool_result.json`)
и отправляется в `/v1/chat/completions`. Поля `model` в шаблонах **нет** —
модель подставляется из окружения при запуске, поэтому один и тот же пейлоад
работает с любой моделью. Второй раунд tool call
(`assets/tool_result.json`) собирается функцией `build_tool_result_payload`:
`id` вызова, аргументы и `tools_state_id` берутся из ответа модели,
содержимое сообщения `tool` — из реального ответа MCP-инструмента
`get_weather`.

**Модели (все — только через env):**
- `GIGACHAT_MODEL` — модель по умолчанию для всех проверок; если переменная
  не задана, скрипт использует `GigaChat-3-Pro`;
- `GIGACHAT_PROBE_MODEL` — переопределяет модель для `-t` и `-c` в текущем
  запуске: `GIGACHAT_PROBE_MODEL=GigaChat-2-Pro ./gpt2giga_healthcheck.sh -a`;
- `GIGACHAT_TOOLCALL_MODEL` — модель **только** для `-c`, приоритетнее
  `GIGACHAT_PROBE_MODEL`:
  ```bash
  GIGACHAT_TOOLCALL_MODEL=GigaChat-3-Pro ./gpt2giga_healthcheck.sh -c
  ```

**Проверка tool call (`-c`)** выполняется целиком и автономно, в два раунда:

1. **Раунд 1 — выбор инструмента.** Отправляется `assets/tool_call.json`;
   скрипт проверяет наличие `choices[0].message.tool_calls` в ответе.
   Если модель не вызвала функцию, проверка неуспешна и скрипт возвращает `1`
   (второй раунд в этом случае не выполняется).
2. **Раунд 2 — результат инструмента.** Скрипт **не содержит своей погодной
   логики**: он выступает MCP-клиентом и исполняет `get_weather` на стороне
   сервера `mcp_weather/server.py` по stdio JSON-RPC
   (`initialize` → `notifications/initialized` → `tools/call`, аргумент
   `city` берётся из ответа модели). Источники данных (`wttr.in` →
   Open-Meteo) описаны в разделе «MCP-инструмент `get_weather`».

   Полученный JSON подставляется в шаблон `assets/tool_result.json` вместе
   с `id` вызова и `tools_state_id` из ответа первого раунда, после чего
   пейлоад отправляется в `/v1/chat/completions`. Успех — непустой
   `choices[0].message.content`, то есть модель сформулировала ответ по
   фактическим данным (например, «Температура: 11°C, ощущается как 8°C,
   условия: смог»).

Для `-c` требуется `uv` (команда по умолчанию
`uv run --quiet --with "mcp<2" python mcp_weather/server.py`) либо `python3`
с установленным `pip install -r mcp_weather/requirements.txt`. Команду запуска
можно переопределить через `GIGACHAT_MCP_CMD`, таймаут ответа — через
`GIGACHAT_MCP_TIMEOUT` (по умолчанию 90 с).

Если MCP-сервер не ответил или инструмент вернул ошибку/`null`, скрипт
печатает ошибку и возвращает `1` — выдуманные значения вместо реальных
не подставляются.

После всех проверок (при `-c` или `-a`) выводится итоговый блок
`Итог проверки tool call`, в котором печатаются: промпт, ответ модели первого
раунда (блок `Вызовы инструментов:` с именами функций и аргументами либо
`Текст ассистента:`), фактический JSON-результат инструмента и финальный
текст модели второго раунда. Если какой-то из блоков недоступен, вместо него
печатается соответствующее пояснение.

**Пример:**
```bash
$ ./gpt2giga_healthcheck.sh -a
==================================================
1. Список доступных моделей
==================================================
["GigaChat", "GigaChat-Pro"]
==================================================
API /chat/completions test
==================================================
{"id":"...","object":"chat.completion",...}
==================================================
API tool call test (assets/tool_call.json)
==================================================
{"id":"...","object":"chat.completion","choices":[...]}
OK: вызваны инструменты: get_weather
==================================================
API tool call result test (assets/tool_result.json)
==================================================
{"id":"...","object":"chat.completion","choices":[...]}
OK: модель учла результат инструмента и вернула финальный ответ
==================================================
Итог проверки tool call
==================================================
Промпт:
Пользователь: Вызови get_weather для Москвы и ничего не выдумывай.

Ответ модели (раунд 1, вызов инструмента):
Вызовы инструментов:
  — вызвана функция get_weather с аргументами {"city": "Москва"}

Результат инструмента get_weather:
{"city":"Москва","location":"Москва","temperature_c":11,"feels_like_c":8,"condition":"смог","humidity":"49%","wind":"↑12km/h","source":"wttr.in"}

Финальный ответ модели (раунд 2):
Москва сейчас:

- Температура: 11°C
- Ощущается как: 8°C
- Влажность: 49%
- Ветер: ↑12 км/ч
- Условия: смог

Данные предоставлены wttr.in.
```

### 3. MCP-инструмент `get_weather` (`mcp_weather/`)

Инструмент вынесен в MCP-сервер — это **единственная реализация** погодной
логики. В интерактивном сценарии цикл tool call выполняет агент (Roo Code):
модель возвращает вызов `get_weather`, Roo Code исполняет его через MCP и
отправляет результат обратно модели. В автономном сценарии тот же сервер
вызывает сам скрипт (`-c`) — как MCP-клиент по stdio JSON-RPC.

**Состав:**
- `mcp_weather/server.py` — stdio MCP-сервер (FastMCP) с инструментом
  `get_weather(city)`; источники те же, что у скрипта: `wttr.in` → Open-Meteo,
  описание погоды на русском, результат — JSON-строка.
- `mcp_weather/requirements.txt` — зависимость `mcp>=1.2,<2`
  (в `mcp` 2.x `FastMCP` переименован в `MCPServer`, поэтому версия закреплена).
- `.roo/mcp.json` — регистрация серверов проекта:
  ```json
  "weather": {
    "command": "uv",
    "args": ["run", "--quiet", "--with", "mcp<2", "python",
             "/home/filebrowser/workspace/shell/gpt2giga/mcp_weather/server.py"]
  }
  ```

**Проверка сервера вручную (stdio JSON-RPC):**
```bash
cd gpt2giga/mcp_weather
printf '%s\\n' \\
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \\
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \\
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Москва"}}}' \\
  | uv run --quiet --with "mcp<2" python server.py
```
Ожидаемый фрагмент ответа:
```json
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\\"city\\": \\"Москва\\", \\"temperature_c\\": 11, \\"condition\\": \\"смог\\", \\"source\\": \\"wttr.in\\"}"}],"isError":false}}
```

Без `uv`: `pip install -r mcp_weather/requirements.txt && python3 mcp_weather/server.py`.

**Использование в Roo Code:**
1. Включите MCP-серверы в панели Roo Code — сервер `weather` должен быть
   `Connected` (при первом старте подтвердите запуск).
2. Провайдер модели — gpt2giga (OpenAI-совместимый): API URL
   `https://gigachat.ydns.eu/v1`, ключ — `TOKEN` из `gpt2giga.cfg`,
   модель с поддержкой tools (например `GigaChat-3-Pro`).
3. Запрос: «Какая сейчас погода в Москве? Используй `get_weather`».
   Агент сам сформирует `tool_calls`, выполнит MCP-инструмент, получит
   JSON с температурой и ответит по фактическим данным.

**Переменные окружения сервера:** `GIGACHAT_WEATHER_URL` (база `wttr.in`),
`GIGACHAT_GEOCODING_URL`, `GIGACHAT_FORECAST_URL` (Open-Meteo),
`GIGACHAT_WEATHER_TIMEOUT` (таймаут запросов, по умолчанию 20 с).

**Как это связано со скриптом:** погодная логика существует **только** в
`mcp_weather/server.py`. `./gpt2giga_healthcheck.sh -c` запускает этот же
сервер и вызывает его инструмент по JSON-RPC, поэтому сквозной тест и агент
используют один и тот же код (через `GIGACHAT_MCP_CMD` можно подставить
свою команду запуска).

**Отличие от `./gpt2giga_healthcheck.sh -c`:**

| | Скрипт `-c` | MCP `get_weather` |
|---|---|---|
| Кто исполняет вызов инструмента | bash-скрипт (как MCP-клиент) | агент (Roo Code) |
| Кто ведёт цикл tool call | скрипт: два запроса к API | агент ведёт цикл сам |
| Назначение | health-check/CI без агента | интерактивная работа в Roo Code |
| Погодный код | общий — `mcp_weather/server.py` | общий — `mcp_weather/server.py` |

Требуется `uv` (или Python 3.10+ и `pip install -r mcp_weather/requirements.txt`)
и исходящий доступ к `wttr.in` / `api.open-meteo.com`.

## ⚙️ Конфигурация

**secrets.txt формат:**
```
ACCOUNT_NAME=BASE64_AUTH_KEY
```

**Безопасность:** secrets.txt в .gitignore

## 🔧 Проблемы и решения

| Ошибка | Решение |
|--------|---------|
| `jq не найден` | `sudo apt install jq` |
| `secrets.txt не найден` | Создайте файл с ключами |
| `SSL error` | Проверьте `russian_trusted_root.cer` |
| `401 Unauthorized` | Обновите ключи API |
| `не удалось получить токен для аккаунта X` | Проверьте ключ `X` в `secrets.txt` (раздел «Настройка API») |
| `gpt2giga.cfg не найден` | Создайте файл конфигурации по образцу выше |
| `в gpt2giga.cfg не заданы параметры` | Заполните `GIGACHAT_API_URL` и `TOKEN` |
| `файл пейлоада .../assets/tool_call.json не найден` | Восстановите файл из репозитория |
| `файл пейлоада .../assets/tool_result.json не найден` | Восстановите файл из репозитория |
| `в ответе нет tool_calls` | Модель не поддерживает tool call или игнорирует `tools` — задайте другую модель через `GIGACHAT_TOOLCALL_MODEL`/`GIGACHAT_PROBE_MODEL` |
| `в первом раунде нет вызова инструмента` | Первый раунд не вернул `tool_calls`, второй раунд невозможен — см. строку выше |
| `модель не вернула финальный текст после результата инструмента` | Проверьте, что `tools_state_id`/`id` вызова дошли без изменений и модель поддерживает второй раунд |
| `Ошибка: для -c нужен uv или python3 с пакетом mcp` | Установите `uv` либо `pip install -r mcp_weather/requirements.txt` (нужен `mcp<2`) |
| `MCP-сервер не вернул ответ на tools/call get_weather` | Сервер не стартовал/упал: проверьте `GIGACHAT_MCP_CMD`, путь к `mcp_weather/server.py`, увеличьте `GIGACHAT_MCP_TIMEOUT` |
| `get_weather не вернул результат` | Инструмент не смог получить данные — см. строку ниже |
| `не удалось получить погоду для «X»` | Нет доступа к `wttr.in` и `api.open-meteo.com` — проверьте сеть/прокси или задайте `GIGACHAT_WEATHER_URL`, `GIGACHAT_GEOCODING_URL`, `GIGACHAT_FORECAST_URL` |
| MCP: `ModuleNotFoundError: mcp.server.fastmcp` | Установлена `mcp` 2.x — закрепите `mcp<2` (`uv run --with "mcp<2"`) или `pip install -r mcp_weather/requirements.txt` |
| MCP-сервер `weather` в статусе `Error`/`Stopped` | Проверьте `uv` в `PATH` и абсолютный путь к `mcp_weather/server.py` в `.roo/mcp.json` |

## 📄 Лицензия
MIT License
