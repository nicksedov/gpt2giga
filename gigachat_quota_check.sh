#!/bin/bash
#
# gigachat_quota_check.sh — баланс токенов GigaChat по всем аккаунтам из secrets.txt
#
# Ключи выпускаются в личном кабинете https://developers.sber.ru/studio
# (раздел «Настройка API») и хранятся в secrets.txt в формате:
#
#     ИМЯ_АККАУНТА=base64_ключ
#
# Количество аккаунтов не ограничено — таблица строится динамически.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.txt"
CA_CERT="$SCRIPT_DIR/russian_trusted_root.cer"

OAUTH_URL='https://ngw.devices.sberbank.ru:9443/api/v2/oauth'
BALANCE_URL='https://gigachat.devices.sberbank.ru/api/v1/balance'
SCOPE='GIGACHAT_API_PERS'

# Желаемый порядок колонок. Аккаунты, отсутствующие в этом списке,
# добавляются в конец в порядке их следования в secrets.txt.
ACCOUNT_ORDER=(T2 MTS SBR)

# --- Проверка окружения ------------------------------------------------------

if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Ошибка: файл $SECRETS_FILE не найден в директории скрипта ($SCRIPT_DIR)" >&2
    exit 1
fi

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Ошибка: $cmd не установлен. Установите: sudo apt install $cmd (Debian/Ubuntu) или sudo dnf install $cmd (Fedora)" >&2
        exit 1
    fi
done

CURL_OPTS=(-L -sS)
if [[ -f "$CA_CERT" ]]; then
    CURL_OPTS+=(--cacert "$CA_CERT")
else
    echo "Предупреждение: сертификат $CA_CERT не найден, запросы выполняются без --cacert" >&2
fi

# --- Чтение secrets.txt ------------------------------------------------------

declare -A AUTH_KEYS=()
SECRET_ORDER=()

while IFS='=' read -r raw_key raw_value || [[ -n "$raw_key" ]]; do
    key="${raw_key//[[:space:]]/}"
    value="${raw_value//[[:space:]]/}"
    [[ -z "$key" || -z "$value" ]] && continue
    [[ "$key" == \#* ]] && continue
    [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || continue
    AUTH_KEYS["$key"]="$value"
    SECRET_ORDER+=("$key")
done < <(tr -d '\r' < "$SECRETS_FILE")

if (( ${#AUTH_KEYS[@]} == 0 )); then
    echo "Ошибка: в $SECRETS_FILE не найдено ни одного ключа (формат: ИМЯ_АККАУНТА=КЛЮЧ)" >&2
    exit 1
fi

# Порядок аккаунтов: сначала ACCOUNT_ORDER, затем остальные из secrets.txt
ACCOUNTS=()
for name in "${ACCOUNT_ORDER[@]}"; do
    [[ -n "${AUTH_KEYS[$name]:-}" ]] && ACCOUNTS+=("$name")
done

for name in "${SECRET_ORDER[@]}"; do
    already_added=false
    for known in "${ACCOUNTS[@]}"; do
        if [[ "$known" == "$name" ]]; then
            already_added=true
            break
        fi
    done
    [[ "$already_added" == true ]] || ACCOUNTS+=("$name")
done

# --- GigaChat API ------------------------------------------------------------

get_token() {
    local auth_key="$1"
    curl "${CURL_OPTS[@]}" \
        -X POST "$OAUTH_URL" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'Accept: application/json' \
        -H "RqUID: $(cat /proc/sys/kernel/random/uuid)" \
        -H "Authorization: Basic ${auth_key}" \
        --data-urlencode "scope=${SCOPE}" \
        | jq -r '.access_token // empty' 2>/dev/null
}

get_balances() {
    local token="$1"
    curl "${CURL_OPTS[@]}" \
        -X GET "$BALANCE_URL" \
        -H 'Accept: application/json' \
        -H "RqUID: $(cat /proc/sys/kernel/random/uuid)" \
        -H "Authorization: Bearer ${token}" \
        | jq -r '.balance[]? | "\(.usage)\t\(.value)"' 2>/dev/null
}

# --- Сбор данных -------------------------------------------------------------

declare -A BALANCES=()
declare -A FAILED=()
MODELS=()
declare -A MODEL_SEEN=()

echo "=== Баланс токенов GigaChat на всех аккаунтах ==="
echo

for label in "${ACCOUNTS[@]}"; do
    token="$(get_token "${AUTH_KEYS[$label]}")"
    if [[ -z "$token" ]]; then
        echo "Предупреждение: не удалось получить токен для аккаунта $label (проверьте ключ в $SECRETS_FILE)" >&2
        FAILED["$label"]=1
        continue
    fi

    while IFS=$'\t' read -r usage value; do
        [[ -z "$usage" || "$usage" == "null" ]] && continue
        value="${value:-0}"
        # API может вернуть число в виде 1234567.0 — приводим к целому
        if [[ "$value" =~ ^(-?[0-9]+)\.0+$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        BALANCES["${label}|${usage}"]="$value"
        if [[ -z "${MODEL_SEEN[$usage]:-}" ]]; then
            MODELS+=("$usage")
            MODEL_SEEN["$usage"]=1
        fi
    done < <(get_balances "$token")
done

if (( ${#MODELS[@]} == 0 )); then
    echo "Ошибка: не удалось получить данные о балансе ни по одному аккаунту" >&2
    exit 2
fi

SORTED_MODELS=()
while IFS= read -r model; do
    SORTED_MODELS+=("$model")
done < <(printf '%s\n' "${MODELS[@]}" | sort)

# Сумма токенов одной модели по всем успешно проверенным аккаунтам
model_total() {
    local model="$1" account
    for account in "${ACCOUNTS[@]}"; do
        [[ -n "${FAILED[$account]:-}" ]] && continue
        printf '%s\n' "${BALANCES["${account}|${model}"]:-0}"
    done | awk '{s += $1 + 0} END {printf "%.0f", s}'
}

# --- Таблица -----------------------------------------------------------------

MODEL_HEADER="Model"
w_model=${#MODEL_HEADER}
for model in "${SORTED_MODELS[@]}"; do
    (( ${#model} > w_model )) && w_model=${#model}
done

# Последняя колонка TOTAL — сумма токенов модели по всем аккаунтам
TOTAL_HEADER="TOTAL"
declare -A MODEL_TOTAL=()
w_total=${#TOTAL_HEADER}
for model in "${SORTED_MODELS[@]}"; do
    MODEL_TOTAL["$model"]="$(model_total "$model")"
    (( ${#MODEL_TOTAL[$model]} > w_total )) && w_total=${#MODEL_TOTAL[$model]}
done

declare -A COL_W=()
for account in "${ACCOUNTS[@]}"; do
    width=${#account}
    if [[ -z "${FAILED[$account]:-}" ]]; then
        for model in "${SORTED_MODELS[@]}"; do
            value="${BALANCES["${account}|${model}"]:-0}"
            (( ${#value} > width )) && width=${#value}
        done
    fi
    COL_W["$account"]=$width
done

print_sep() {
    local line='' width dashes
    for width in "$@"; do
        printf -v dashes '%*s' "$((width + 2))" ''
        line+="+${dashes// /-}"
    done
    echo "${line}+"
}

# Первая колонка — по левому краю, числовые — по правому
print_row() {
    local left="$1"
    shift
    local out cell width value
    printf -v out '| %-*s ' "$w_model" "$left"
    while (( $# >= 2 )); do
        width="$1"
        value="$2"
        shift 2
        printf -v cell '%*s' "$width" "$value"
        out+="| ${cell} "
    done
    echo "${out}|"
}

sep_args=("$w_model")
header_args=()
for account in "${ACCOUNTS[@]}"; do
    sep_args+=("${COL_W[$account]}")
    header_args+=("${COL_W[$account]}" "$account")
done
sep_args+=("$w_total")
header_args+=("$w_total" "$TOTAL_HEADER")

print_sep "${sep_args[@]}"
print_row "$MODEL_HEADER" "${header_args[@]}"
print_sep "${sep_args[@]}"

for model in "${SORTED_MODELS[@]}"; do
    row_args=()
    for account in "${ACCOUNTS[@]}"; do
        if [[ -n "${FAILED[$account]:-}" ]]; then
            value='-'
        else
            value="${BALANCES["${account}|${model}"]:-0}"
        fi
        row_args+=("${COL_W[$account]}" "$value")
    done
    row_args+=("$w_total" "${MODEL_TOTAL[$model]}")
    print_row "$model" "${row_args[@]}"
done

print_sep "${sep_args[@]}"

if (( ${#FAILED[@]} > 0 )); then
    echo
    echo "Не удалось проверить аккаунты: $(printf '%s ' "${!FAILED[@]}")" >&2
    exit 3
fi
