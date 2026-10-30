#!/bin/bash
#
# gpt2giga_healthcheck.sh — проверка работоспособности прокси gpt2giga
#
# Параметры подключения (URL прокси и токен) берутся из gpt2giga.cfg,
# который находится рядом со скриптом.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_FILE="$SCRIPT_DIR/gpt2giga.cfg"
CHAT_PAYLOAD_FILE="$SCRIPT_DIR/assets/chat_test.json"
TOOL_PAYLOAD_FILE="$SCRIPT_DIR/assets/tool_call.json"
TOOL_RESULT_PAYLOAD_FILE="$SCRIPT_DIR/assets/tool_result.json"

# Модель подставляется в пейлоады из окружения — в JSON-шаблонах поля model нет.
#   GIGACHAT_MODEL           модель по умолчанию для всех проверок
#   GIGACHAT_PROBE_MODEL     то же, но только для текущего запуска (-t и -c)
#   GIGACHAT_TOOLCALL_MODEL  модель только для проверки tool call (-c),
#                            приоритетнее GIGACHAT_PROBE_MODEL
DEFAULT_MODEL="${GIGACHAT_MODEL:-GigaChat-3-Pro}"
TOOLCALL_MODEL="${GIGACHAT_TOOLCALL_MODEL:-${GIGACHAT_PROBE_MODEL:-$DEFAULT_MODEL}}"

# Инструмент get_weather исполняет MCP-сервер (mcp_weather/server.py) — это
# единственная реализация погодной логики. Скрипт выступает MCP-клиентом
# и общается с сервером по stdio JSON-RPC.
MCP_SERVER_FILE="$SCRIPT_DIR/mcp_weather/server.py"
MCP_TIMEOUT="${GIGACHAT_MCP_TIMEOUT:-90}"
MCP_CMD=()

print_help() {
  cat <<EOF
Usage: $(basename "$0") [-a|-m|-t|-c] [-h]

  -m  Список доступных моделей (/v1/models)
  -t  Тест chat completions (/v1/chat/completions), пейлоад: assets/chat_test.json
  -c  Тест вызова инструментов (tool call): раунд 1 — assets/tool_call.json,
      раунд 2 (результат инструмента) — assets/tool_result.json; результат
      инструмента берётся у MCP-сервера mcp_weather/server.py по JSON-RPC
  -a  Выполнить все проверки
  -h  Показать эту справку

Переменные окружения:
  GIGACHAT_MODEL            модель по умолчанию для всех проверок
  GIGACHAT_PROBE_MODEL      переопределяет модель для -t и -c
  GIGACHAT_TOOLCALL_MODEL   переопределяет модель только для проверки
                            tool call (-c); сейчас: ${TOOLCALL_MODEL:-—}
  GIGACHAT_MCP_CMD          команда запуска MCP-сервера
                            (по умолчанию: uv run --quiet --with "mcp<2" python …)
  GIGACHAT_MCP_TIMEOUT      таймаут ответа MCP-сервера, сек (по умолчанию ${MCP_TIMEOUT})
EOF
}

header() {
  echo "=================================================="
  echo "$1"
  echo "=================================================="
}

# Универсальный запрос к API с проверкой HTTP-кода ответа.
# Тело успешного ответа сохраняется в глобальную переменную LAST_BODY,
# отправленный пейлоад — в LAST_PAYLOAD.
LAST_BODY=""
LAST_PAYLOAD=""

# Промпт и ответ модели последней проверки tool call (для итогового вывода).
TOOL_PROMPT=""
TOOL_ANSWER=""

# Данные второго раунда tool call: вызов из ответа модели, реальный результат
# инструмента (запрос к погодному API)
# get_weather и финальный текст модели.
TOOL_CALL_ID=""
TOOL_CALL_ARGS=""
TOOL_STATE_ID=""
TOOL_CITY="Москва"
TOOL_TOOL_RESULT=""
TOOL_FINAL_ANSWER=""

request() {
  local method="$1" path="$2" data="${3:-}"
  local raw body code
  local -a args=(
    -sS
    -w $'\n%{http_code}'
    -X "$method" "${GIGACHAT_API_URL}/${path}"
    -H "Authorization: Bearer ${TOKEN}"
    -H 'Content-Type: application/json'
  )

  [[ -n "$data" ]] && args+=(-d "$data")

  if ! raw="$(curl "${args[@]}")"; then
    echo "Ошибка: не удалось выполнить запрос ${method} /${path}" >&2
    return 1
  fi

  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  if [[ "$code" != 2* ]]; then
    echo "Ошибка: HTTP ${code} при запросе ${method} /${path}" >&2
    printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
    return 1
  fi

  LAST_BODY="$body"
  printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
}

# Универсальная проверка chat completions по пейлоаду из файла.
#   $1 — заголовок блока вывода
#   $2 — путь к JSON-пейлоаду
#   $3 — jq-условие успешного ответа (необязательно)
#   $4 — текст ошибки при невыполнении условия (необязательно)
#   $5 — модель для подстановки в пейлоад (необязательно, приоритетнее
#        GIGACHAT_PROBE_MODEL)
# Тело ответа сохраняется в LAST_BODY для дополнительного анализа вызывающим кодом.
run_chat_test() {
  local title="$1" payload_file="$2" check="${3:-}" fail_msg="${4:-}" model="${5:-}"
  local payload

  # Сбрасываем состояние предыдущих проверок
  LAST_PAYLOAD=""
  LAST_BODY=""

  header "$title"

  if [[ ! -f "$payload_file" ]]; then
    echo "Ошибка: файл пейлоада $payload_file не найден" >&2
    return 1
  fi

  if ! payload="$(cat "$payload_file")"; then
    echo "Ошибка: не удалось прочитать пейлоад $payload_file" >&2
    return 1
  fi

  model="${model:-${GIGACHAT_PROBE_MODEL:-${DEFAULT_MODEL:-}}}"
  if [[ -n "$model" ]]; then
    if ! payload="$(printf '%s' "$payload" | jq --arg m "$model" '.model = $m' 2>/dev/null)"; then
      echo "Ошибка: не удалось подставить модель $model в пейлоад $payload_file" >&2
      return 1
    fi
  fi

  LAST_PAYLOAD="$payload"

  request POST "chat/completions" "$payload" || return 1

  if [[ -n "$check" ]] && ! printf '%s' "$LAST_BODY" | jq -e "$check" >/dev/null 2>&1; then
    echo "Ошибка: ${fail_msg:-ответ не прошёл проверку jq: $check}" >&2
    return 1
  fi

  return 0
}

# Человекочитаемое представление сообщений пейлоада (промпт запроса)
describe_prompt() {
  local payload="$1"

  printf '%s' "$payload" | jq -r '
    .messages[]?
    | if .role == "user" then "Пользователь: \(.content // "")"
      elif .role == "assistant" then "Ассистент: \(.content // "")"
      elif .role == "system" then "Система: \(.content // "")"
      else "\(.role): \(.content // "")"
      end
  ' 2>/dev/null
}

# Человекочитаемое представление ответа модели: текст ассистента (если есть)
# и вызванные инструменты (если есть) выводятся вместе.
describe_answer() {
  local body="$1" content calls
  local printed=false

  # content может быть строкой или массивом частей (multimodal)
  content="$(printf '%s' "$body" | jq -r '
    .choices[0].message.content
    | if type == "array" then ([.[]? | if type == "string" then . else (.text? // empty) end] | join(""))
      else (. // "" | tostring)
      end
  ' 2>/dev/null)"
  content="$(printf '%s' "$content" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  calls="$(printf '%s' "$body" | jq -r '
    .choices[0].message.tool_calls[]?
    | "  — вызвана функция \(.function.name) с аргументами \(.function.arguments // "{}")"
  ' 2>/dev/null)"

  if [[ -n "$content" ]]; then
    echo "Текст ассистента: ${content}"
    printed=true
  fi

  if [[ -n "$calls" ]]; then
    echo "Вызовы инструментов:"
    printf '%s\n' "$calls"
    printed=true
  fi

  if [[ "$printed" == false ]]; then
    echo "(модель не вернула ни текста, ни вызова инструментов)"
  fi
}


# --- MCP-клиент (stdio JSON-RPC) ---------------------------------------------

# Команда запуска MCP-сервера: GIGACHAT_MCP_CMD, иначе uv, иначе python3 с mcp.
build_mcp_cmd() {
  MCP_CMD=()

  if [[ -n "${GIGACHAT_MCP_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    MCP_CMD=(${GIGACHAT_MCP_CMD})
  elif command -v uv >/dev/null 2>&1; then
    MCP_CMD=(uv run --quiet --with "mcp<2" python "$MCP_SERVER_FILE")
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import mcp.server.fastmcp' >/dev/null 2>&1; then
    MCP_CMD=(python3 "$MCP_SERVER_FILE")
  else
    return 1
  fi

  return 0
}

# Вызов MCP-инструмента: initialize -> notifications/initialized -> tools/call.
#   $1 — имя инструмента, $2 — JSON-объект аргументов
# В stdout печатается строка ответа JSON-RPC на tools/call (id=2).
mcp_call_tool() {
  local tool="$1" args="$2"
  local init request tmpdir fifo out pid waited=0 resp=""

  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gpt2giga-healthcheck","version":"1.0"}}}'
  request="$(jq -cn --arg tool "$tool" --argjson args "$args" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$tool,arguments:$args}}')"

  tmpdir="$(mktemp -d)" || return 1
  fifo="$tmpdir/stdin"
  out="$tmpdir/stdout"

  if ! mkfifo "$fifo"; then
    rm -rf "$tmpdir"
    return 1
  fi

  # stdin сервера держим открытым через FIFO, иначе он завершится по EOF
  "${MCP_CMD[@]}" <"$fifo" >"$out" 2>/dev/null &
  pid=$!

  exec 3>"$fifo"
  printf '%s\n%s\n%s\n' \
    "$init" \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "$request" >&3

  while (( waited < MCP_TIMEOUT * 5 )); do
    if grep -q '"id":2' "$out" 2>/dev/null; then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done

  exec 3>&-
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  resp="$(grep '"id":2' "$out" 2>/dev/null | head -n 1)"
  rm -rf "$tmpdir"

  [[ -n "$resp" ]] || return 1
  printf '%s' "$resp"
}

# Погода через MCP-инструмент get_weather (единственная реализация — Python).
#   $1 — город; в stdout печатается JSON-строка результата инструмента.
mcp_get_weather() {
  local city="${1:-Москва}" args response result

  args="$(jq -cn --arg city "$city" '{city: $city}')"

  if ! response="$(mcp_call_tool "get_weather" "$args")"; then
    echo "Ошибка: MCP-сервер не вернул ответ на tools/call get_weather" >&2
    return 1
  fi

  if [[ "$(printf '%s' "$response" | jq -r '.result.isError // false' 2>/dev/null)" == "true" ]]; then
    echo "Ошибка: инструмент get_weather вернул ответ с isError=true" >&2
    return 1
  fi

  result="$(printf '%s' "$response" | jq -r '.result.content[]? | select(.type == "text") | .text' 2>/dev/null)"

  if [[ -z "$result" ]] || ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
    echo "Ошибка: get_weather не вернул корректный JSON" >&2
    return 1
  fi

  if printf '%s' "$result" | jq -e '.error' >/dev/null 2>&1; then
    echo "Ошибка: $(printf '%s' "$result" | jq -r '.error')" >&2
    return 1
  fi

  printf '%s' "$result"
}

# Сборка пейлоада второго раунда на основе шаблона assets/tool_result.json.
#   $1 — путь к шаблону
#   $2 — id вызова инструмента из ответа модели
#   $3 — аргументы вызова из ответа модели
#   $4 — tools_state_id (GigaChat), может быть пустым
#   $5 — результат инструмента (JSON от get_weather)
#   $6 — модель (пустая строка — оставить модель из шаблона)
build_tool_result_payload() {
  local template="$1" call_id="$2" call_args="$3" state_id="$4" result="$5" model="$6"

  jq -c \
    --arg id "$call_id" \
    --arg args "$call_args" \
    --arg state "$state_id" \
    --argjson result "$result" \
    --arg model "$model" '
      (if $model == "" then . else .model = $model end)
      | .messages |= map(
          if .role == "assistant" then
            .tool_calls |= map(
              .id = $id
              | .function.arguments = (if $args == "" then .function.arguments else $args end)
              | if $state == "" then . else .tools_state_id = $state end
            )
          elif .role == "tool" then
            .tool_call_id = $id
            | .content = ($result | tojson)
          else . end
        )
    ' "$template"
}

# Тест chat completions (пейлоад assets/chat_test.json)
chat_test() {
  run_chat_test "API /chat/completions test" "$CHAT_PAYLOAD_FILE"
}

# Проверка поддержки вызова инструментов (tool/function calling).
# Пейлоад берётся из файла assets/tool_call.json и отправляется как есть.
# Промпт и ответ модели запоминаются в TOOL_PROMPT/TOOL_ANSWER для итогового блока.
tool_check() {
  local -a calls=()
  local status=0

  if run_chat_test "API tool call test (assets/tool_call.json)" "$TOOL_PAYLOAD_FILE" \
    '.choices[0].message.tool_calls | length > 0' \
    'в ответе нет tool_calls — модель не вызвала инструмент' \
    "$TOOLCALL_MODEL"; then
    while IFS= read -r name; do
      [[ -n "$name" ]] && calls+=("$name")
    done < <(printf '%s' "$LAST_BODY" | jq -r '.choices[0].message.tool_calls[]?.function.name // empty' 2>/dev/null)
    echo "OK: вызваны инструменты: ${calls[*]:-—}"

    # Данные вызова нужны для второго раунда (передача результата инструмента).
    TOOL_CALL_ID="$(printf '%s' "$LAST_BODY" | jq -r '.choices[0].message.tool_calls[0].id // empty' 2>/dev/null)"
    TOOL_CALL_ARGS="$(printf '%s' "$LAST_BODY" | jq -r '.choices[0].message.tool_calls[0].function.arguments // empty' 2>/dev/null)"
    TOOL_STATE_ID="$(printf '%s' "$LAST_BODY" | jq -r '.choices[0].message.tool_calls[0].tools_state_id // empty' 2>/dev/null)"
    TOOL_CITY="$(printf '%s' "$LAST_BODY" | jq -r '
      .choices[0].message.tool_calls[0].function.arguments | fromjson? | .city // empty
    ' 2>/dev/null)"
    [[ -n "$TOOL_CITY" ]] || TOOL_CITY="Москва"
  else
    status=1
  fi

  TOOL_PROMPT="$(describe_prompt "$LAST_PAYLOAD")"
  [[ -n "$TOOL_PROMPT" ]] || TOOL_PROMPT="(промпт недоступен)"

  if [[ -n "$LAST_BODY" ]]; then
    TOOL_ANSWER="$(describe_answer "$LAST_BODY")"
  else
    TOOL_ANSWER="(ответ модели не получен)"
  fi

  return "$status"
}

# Второй раунд проверки tool call: результат «вызова» инструмента возвращается
# модели, и она должна сформировать финальный ответ (например, «+3 °C»).
tool_result_check() {
  local payload model status=0

  header "API tool call result test (assets/tool_result.json)"

  if [[ ! -f "$TOOL_RESULT_PAYLOAD_FILE" ]]; then
    echo "Ошибка: файл пейлоада $TOOL_RESULT_PAYLOAD_FILE не найден" >&2
    return 1
  fi

  if [[ -z "$TOOL_CALL_ID" ]]; then
    echo "Ошибка: в первом раунде нет вызова инструмента — второй раунд невозможен" >&2
    return 1
  fi

  if ! build_mcp_cmd; then
    echo "Ошибка: для -c нужен uv или python3 с пакетом mcp (см. README, раздел MCP)" >&2
    return 1
  fi

  if ! TOOL_TOOL_RESULT="$(mcp_get_weather "$TOOL_CITY")"; then
    echo "Ошибка: get_weather не вернул результат" >&2
    TOOL_TOOL_RESULT=""
    return 1
  fi

  model="${TOOLCALL_MODEL:-}"

  if ! payload="$(build_tool_result_payload "$TOOL_RESULT_PAYLOAD_FILE" \
    "$TOOL_CALL_ID" "$TOOL_CALL_ARGS" "$TOOL_STATE_ID" "$TOOL_TOOL_RESULT" "$model" 2>/dev/null)"; then
    echo "Ошибка: не удалось собрать пейлоад второго раунда из $TOOL_RESULT_PAYLOAD_FILE" >&2
    return 1
  fi

  LAST_PAYLOAD="$payload"
  LAST_BODY=""

  request POST "chat/completions" "$payload" || return 1

  TOOL_FINAL_ANSWER="$(printf '%s' "$LAST_BODY" | jq -r '
    .choices[0].message.content
    | if type == "array" then ([.[]? | if type == "string" then . else (.text? // empty) end] | join(""))
      else (. // "" | tostring)
      end
  ' 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [[ -z "$TOOL_FINAL_ANSWER" ]]; then
    echo "Ошибка: модель не вернула финальный текст после результата инструмента" >&2
    status=1
  else
    echo "OK: модель учла результат инструмента и вернула финальный ответ"
  fi

  return "$status"
}

# --- Разбор аргументов -------------------------------------------------------

RUN_MODELS=false
RUN_TEST=false
RUN_TOOL=false

while getopts ":amcth" opt; do
  case $opt in
    a)
      RUN_MODELS=true
      RUN_TEST=true
      RUN_TOOL=true
      ;;
    m)
      RUN_MODELS=true
      ;;
    t)
      RUN_TEST=true
      ;;
    c)
      RUN_TOOL=true
      ;;
    h)
      print_help
      exit 0
      ;;
    \?)
      echo "Неизвестный параметр: -${OPTARG}" >&2
      print_help
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))

if [[ "$RUN_MODELS" == false && "$RUN_TEST" == false && "$RUN_TOOL" == false ]]; then
  print_help
  exit 0
fi

# --- Проверка окружения ------------------------------------------------------

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: $cmd не установлен. Установите: sudo apt install $cmd (Debian/Ubuntu) или sudo dnf install $cmd (Fedora)" >&2
    exit 1
  fi
done

if [[ ! -f "$CFG_FILE" ]]; then
  echo "Ошибка: файл конфигурации $CFG_FILE не найден. Создайте его по образцу из README.md" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CFG_FILE"

GIGACHAT_API_URL="${GIGACHAT_API_URL:-}"
TOKEN="${TOKEN:-}"

missing=()
[[ -z "$GIGACHAT_API_URL" ]] && missing+=("GIGACHAT_API_URL")
[[ -z "$TOKEN" ]] && missing+=("TOKEN")

if (( ${#missing[@]} > 0 )); then
  echo "Ошибка: в $CFG_FILE не заданы параметры: ${missing[*]}" >&2
  exit 1
fi

# Убираем завершающий слэш, чтобы не получить двойной //
GIGACHAT_API_URL="${GIGACHAT_API_URL%/}"

# --- Проверки ----------------------------------------------------------------

exit_code=0

if [[ "$RUN_MODELS" == true ]]; then
  header "1. Список доступных моделей"
  request GET "models" || exit_code=1
fi

if [[ "$RUN_TEST" == true ]]; then
  chat_test || exit_code=1
fi

if [[ "$RUN_TOOL" == true ]]; then
  tool_check || exit_code=1
  tool_result_check || exit_code=1

  header "Итог проверки tool call"
  printf 'Промпт:\n%s\n\n' "${TOOL_PROMPT:-—}"
  printf 'Ответ модели (раунд 1, вызов инструмента):\n%s\n\n' "${TOOL_ANSWER:-—}"
  printf 'Результат инструмента get_weather:\n%s\n\n' "${TOOL_TOOL_RESULT:-—}"
  printf 'Финальный ответ модели (раунд 2):\n%s\n' "${TOOL_FINAL_ANSWER:-—}"
fi

exit "$exit_code"
