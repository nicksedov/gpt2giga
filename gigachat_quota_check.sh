#!/bin/bash

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
SECRETS_FILE=secrets.txt

# Имена аккаунтов на https://developers.sber.ru/studio
account_1="T2"
account_2="MTS"

# Проверяем наличие файла secrets.txt
if [[ ! -f "$SCRIPT_DIR/$SECRETS_FILE" ]]; then
    echo "Ошибка: файл $SECRETS_FILE не найден в директории скрипта ($SCRIPT_DIR)" >&2
    exit 1
fi

# Проверяем наличие jq
if ! command -v jq >/dev/null 2>&1; then
    echo "Ошибка: jq не установлен. Установите: sudo apt install jq (Debian/Ubuntu) или sudo dnf install jq (Fedora)" >&2
    exit 1
fi

# Загружаем ключи из secrets.txt (формат: имя_аккаунта=ключ. Ключ выпускается в личном кабинете, раздел "Настройка API")
declare -A AUTH_KEYS
while IFS='=' read -r key value; do
    [[ -n "$key" && -n "$value" && "$key" =~ ^[A-Za-z0-9_]+$ ]] || continue
    AUTH_KEYS["$key"]="$value"
done < "$SCRIPT_DIR/$SECRETS_FILE"

# Проверяем наличие ключей для аккаунтов
if [[ -z "${AUTH_KEYS[$account_1]}" || -z "${AUTH_KEYS[$account_2]}" ]]; then
    echo "Ошибка: в $SECRETS_FILE отсутствуют ключи для $account_1 или $account_2" >&2
    exit 1
fi

declare -A BALANCES

get_token() {
    local label="$1" auth_key="$2" token_file="$SCRIPT_DIR/token_${label}.txt"
    curl --cacert "$SCRIPT_DIR/russian_trusted_root.cer" -L -s \
        -X POST 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'Accept: application/json' \
        -H "RqUID: $(cat /proc/sys/kernel/random/uuid)" \
        -H "Authorization: Basic ${auth_key}" \
        --data-urlencode 'scope=GIGACHAT_API_PERS' | jq -r '.access_token' > "$token_file"
    cat "$token_file"
    rm "$token_file"
}

save_balance() {
    local label="$1" token="$2" balance_file="$SCRIPT_DIR/balance_${label}.json"
    curl --cacert "$SCRIPT_DIR/russian_trusted_root.cer" -L -s \
        -X GET 'https://gigachat.devices.sberbank.ru/api/v1/balance' \
        -H 'Accept: application/json' \
        -H "RqUID: $(cat /proc/sys/kernel/random/uuid)" \
        -H "Authorization: Bearer $token" > "$balance_file"
    
    while IFS=$'\t' read -r usage value; do
        [[ -n "$usage" && -n "$value" && "$usage" != "null" ]] && {
            BALANCES["${label}_${usage}"]="$value"
        }
    done < <(jq -r '.balance[] | "\(.usage)\t\(.value)"' "$balance_file")
    rm "$balance_file"
}

echo "=== Баланс токенов GigaChat на всех аккаунтах ==="

for label in "${!AUTH_KEYS[@]}"; do
    token=$(get_token "$label" "${AUTH_KEYS[$label]}")
    save_balance "$label" "$token"
done

# Таблица результатов
printf "+----------------------------------------------+\n"
printf "| %-18s | %-10s | %-10s |\n" "Model" "${account_2}" "${account_1}"
printf "|--------------------+------------+------------|\n"

# Извлечение названий моделей из имен ключей
declare -A models
for key in "${!BALANCES[@]}"; do
    model=$(echo "$key" | sed 's/.*_//')  # Только имя модели после последнего _
    [[ -n "$model" ]] && models["$model"]=1
done

# Вывод строк (сортировка)
for model in $(for m in "${!models[@]}"; do echo "$m"; done | sort); do
    printf "| %-18s | %10s | %10s |\n" "$model" \
        "${BALANCES[${account_2}_${model}]:-0}" \
        "${BALANCES[${account_1}_${model}]:-0}"
done
printf "+----------------------------------------------+\n"
