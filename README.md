# gpt2giga - Утилиты для GigaChat и gpt2giga прокси

## Описание

**gpt2giga** — набор bash-скриптов для работы с **GigaChat API** (Сбербанк) и **gpt2giga прокси**.

### Содержимое проекта:
- `gigachat_quota_check.sh` — мониторинг квот токенов GigaChat
- `gpt2giga_healthcheck.sh` — проверка работоспособности прокси
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
```
**Ключи берутся в [developers.sber.ru/studio](https://developers.sber.ru/studio) → Настройка API**

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
**Функция:** Показывает баланс токенов GigaChat для аккаунтов T2 и MTS

**Использование:**
```bash
./gigachat_quota_check.sh
```

**Вывод:**
```
+--------------------------------------------+
| Model              | MTS      | T2         |
|--------------------+----------+------------|
| GigaChat_Pro       | 1234567  | 2345678    |
| GigaChat           | 9876543  | 8765432    |
+--------------------------------------------+
```

**Зависимости:** `jq`, `secrets.txt`, `russian_trusted_root.cer`

---

### 2. `gpt2giga_healthcheck.sh`
**Функция:** Тестирование gpt2giga прокси (`https://gigachat.ydns.eu/v1`)
**Использование:**
```bash
./gpt2giga_healthcheck.sh -h  # Справка
./gpt2giga_healthcheck.sh -m  # Модели
./gpt2giga_healthcheck.sh -t  # Тест чата
./gpt2giga_healthcheck.sh -a  # Все тесты
```

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
```

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

## 📄 Лицензия
MIT License
