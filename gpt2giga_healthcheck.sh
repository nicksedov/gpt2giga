#!/bin/bash
#
# gpt2giga_healthcheck.sh — проверка работоспособности прокси gpt2giga
#
# Параметры подключения (URL прокси и токен) берутся из gpt2giga.cfg,
# который находится рядом со скриптом.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_FILE="$SCRIPT_DIR/gpt2giga.cfg"

print_help() {
  cat <<EOF
Usage: $(basename "$0") [-a|-m|-t] [-h]

  -m  Список доступных моделей (/v1/models)
  -t  Тест chat completions (/v1/chat/completions)
  -a  Выполнить все проверки
  -h  Показать эту справку
EOF
}

header() {
  echo "=================================================="
  echo "$1"
  echo "=================================================="
}

# Универсальный запрос к API с проверкой HTTP-кода ответа
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

  printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
}

# --- Разбор аргументов -------------------------------------------------------

RUN_MODELS=false
RUN_TEST=false

while getopts ":amth" opt; do
  case $opt in
    a)
      RUN_MODELS=true
      RUN_TEST=true
      ;;
    m)
      RUN_MODELS=true
      ;;
    t)
      RUN_TEST=true
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

if [[ "$RUN_MODELS" == false && "$RUN_TEST" == false ]]; then
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
  header "API /chat/completions test"
  request POST "chat/completions" '{
      "model": "${GIGACHAT_PROBE_MODEL:-GigaChat}",
      "messages": [{"role": "user", "content": "Тест пройден"}]
    }' || exit_code=1
fi

exit "$exit_code"
