#!/bin/bash

# Load configuration settings from gpt2giga.cfg
source gpt2giga.cfg

# Function to print help message
print_help() {
  echo "Usage: $0 [-a|-m|-t]"
  echo "-a: Execute all commands"
  echo "-m: List available models"
  echo "-t: Test chat completions API"
}

# Function to parameterized HTTP GET method
http_get() {
  echo ==================================================
  echo $1
  echo ==================================================
  curl -s \
    -X GET ${GIGACHAT_API_URL}/${2} \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' | jq
}

# Test OpenAI chat completions API
test_api() {
  echo ==================================================
  echo "API /chat/completions test"
  echo ==================================================
  curl -s \
    -X POST ${GIGACHAT_API_URL}/chat/completions \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "GigaChat",
      "messages": [{"role": "user", "content": "Тест пройден"}]
    }' | jq
}

# Parse command-line arguments
while getopts ":amt" opt; do
  case $opt in
    a)
      ALL=true
      ;;
    m)
      http_get "1. Список доступных моделей" "models"
      ;;
    t)
      test_api
      ;;
    \?)
      print_help
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))

if [ "$ALL" == true ]; then
  # Execute all commands
  http_get "1. Список доступных моделей" "models"
  test_api
elif [ "$#" -eq 0 ]; then
  # If no option is given, show help
  print_help
fi
