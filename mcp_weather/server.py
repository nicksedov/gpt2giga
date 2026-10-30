#!/usr/bin/env python3
"""MCP-сервер с инструментом get_weather (реальная текущая погода, без API-ключей).

Цикл tool call выполняет MCP-клиент (Roo Code): он получает определение
инструмента, отправляет его модели, исполняет возвращённый вызов и отдаёт
результат обратно модели. Сам сервер только исполняет функцию.

Запуск (stdio):
    uv run --with "mcp<2" python server.py
    # или
    pip install -r requirements.txt && python3 server.py

Переменные окружения:
    GIGACHAT_WEATHER_URL       база wttr.in (по умолчанию https://wttr.in)
    GIGACHAT_GEOCODING_URL     геокодинг Open-Meteo (резервный источник)
    GIGACHAT_FORECAST_URL      прогноз Open-Meteo (резервный источник)
    GIGACHAT_WEATHER_TIMEOUT   таймаут запросов в секундах (по умолчанию 20)
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

from mcp.server.fastmcp import FastMCP

WEATHER_API_BASE = os.environ.get("GIGACHAT_WEATHER_URL", "https://wttr.in").rstrip("/")
GEOCODING_API_URL = os.environ.get(
    "GIGACHAT_GEOCODING_URL", "https://geocoding-api.open-meteo.com/v1/search"
)
FORECAST_API_URL = os.environ.get(
    "GIGACHAT_FORECAST_URL", "https://api.open-meteo.com/v1/forecast"
)
TIMEOUT = float(os.environ.get("GIGACHAT_WEATHER_TIMEOUT", "20"))

_HEADERS = {
    "Accept-Language": "ru",
    "User-Agent": "gpt2giga-mcp-weather/1.0",
}

# Точные значения wttr.in -> русское описание.
_WTTR_EXACT = {
    "Clear": "ясно",
    "Sunny": "ясно",
    "Partly cloudy": "переменная облачность",
    "Cloudy": "облачно",
    "Overcast": "пасмурно",
    "Mist": "дымка",
    "Fog": "туман",
    "Freezing fog": "ледяной туман",
    "Haze": "мгла",
    "Smoke": "дым",
    "Smog": "смог",
    "Patchy rain possible": "местами небольшой дождь",
    "Patchy rain nearby": "местами небольшой дождь",
    "Patchy light rain": "местами небольшой дождь",
    "Drizzle": "морось",
    "Light drizzle": "морось",
    "Patchy light drizzle": "морось",
    "Light rain": "небольшой дождь",
    "Light rain shower": "небольшой дождь",
    "Moderate rain": "дождь",
    "Moderate rain at times": "дождь",
    "Heavy rain": "сильный дождь",
    "Heavy rain at times": "сильный дождь",
    "Moderate or heavy rain shower": "сильный дождь",
    "Torrential rain shower": "сильный дождь",
    "Light snow": "небольшой снег",
    "Patchy light snow": "небольшой снег",
    "Light snow showers": "небольшой снег",
    "Patchy snow possible": "местами снег",
    "Patchy sleet possible": "местами снег",
    "Snow": "снег",
    "Moderate snow": "снег",
    "Moderate or heavy snow showers": "снег",
    "Heavy snow": "сильный снег",
    "Patchy heavy snow": "сильный снег",
    "Blizzard": "сильный снег",
    "Blowing snow": "сильный снег",
    "Ice pellets": "ледяная крупа",
    "Light showers of ice pellets": "ледяная крупа",
    "Moderate or heavy showers of ice pellets": "ледяная крупа",
}

# WMO-коды Open-Meteo -> русское описание.
_WMO = {
    0: "ясно",
    1: "преимущественно ясно",
    2: "переменная облачность",
    3: "пасмурно",
    45: "туман",
    48: "туман",
    51: "морось",
    53: "морось",
    55: "морось",
    56: "ледяная морось",
    57: "ледяная морось",
    61: "небольшой дождь",
    63: "дождь",
    65: "сильный дождь",
    66: "ледяной дождь",
    67: "ледяной дождь",
    71: "небольшой снег",
    73: "снег",
    75: "сильный снег",
    77: "снежная крупа",
    80: "ливни",
    81: "ливни",
    82: "сильные ливни",
    85: "снегопады",
    86: "снегопады",
    95: "гроза",
    96: "гроза с градом",
    99: "гроза с градом",
}


def _describe_wttr(description: str) -> str:
    """Переводит английское описание wttr.in на русский."""
    text = (description or "").strip()
    if not text:
        return "неизвестно"

    lowered = text.lower()
    if "thunder" in lowered:
        return "гроза"
    if "freezing rain" in lowered or "freezing drizzle" in lowered:
        return "ледяной дождь"

    return _WTTR_EXACT.get(text, text)


def _describe_wmo(code: Any) -> str:
    """Переводит WMO-код Open-Meteo на русский."""
    try:
        return _WMO.get(int(code), f"код {code}")
    except (TypeError, ValueError):
        return "неизвестно"


def _to_number(value: str) -> int | float | None:
    """Приводит строку вида «+11» или «3.5» к числу."""
    text = (value or "").strip().lstrip("+")
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        try:
            return float(text)
        except ValueError:
            return None


def _read_text(url: str) -> str | None:
    request = urllib.request.Request(url, headers=_HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def _read_json(url: str) -> Any | None:
    text = _read_text(url)
    if text is None:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def _fetch_wttr(city: str) -> dict[str, Any] | None:
    """Основной источник: wttr.in, компактный формат «%t|%f|%C|%h|%w|%l»."""
    query = urllib.parse.urlencode({"format": "%t|%f|%C|%h|%w|%l", "lang": "ru"})
    url = f"{WEATHER_API_BASE}/{urllib.parse.quote(city, safe='')}?{query}"

    raw = _read_text(url)
    if not raw:
        return None

    parts = raw.strip().split("|")
    if len(parts) < 3:
        return None

    temperature = _to_number(parts[0].replace("°C", ""))
    if temperature is None:
        return None

    feels_like = _to_number(parts[1].replace("°C", "")) if len(parts) > 1 else None

    return {
        "city": city,
        "location": parts[5] if len(parts) > 5 and parts[5] else city,
        "temperature_c": temperature,
        "feels_like_c": feels_like,
        "condition": _describe_wttr(parts[2] if len(parts) > 2 else ""),
        "humidity": parts[3] if len(parts) > 3 else None,
        "wind": parts[4] if len(parts) > 4 else None,
        "source": "wttr.in",
    }


def _fetch_open_meteo(city: str) -> dict[str, Any] | None:
    """Резервный источник: геокодинг Open-Meteo + текущие значения."""
    geocoding_url = f"{GEOCODING_API_URL}?" + urllib.parse.urlencode(
        {"name": city, "count": 1, "language": "ru", "format": "json"}
    )
    geo = _read_json(geocoding_url)
    if not isinstance(geo, dict):
        return None

    results = geo.get("results") or []
    if not results:
        return None

    place = results[0]
    latitude = place.get("latitude")
    longitude = place.get("longitude")
    if latitude is None or longitude is None:
        return None

    forecast_url = f"{FORECAST_API_URL}?" + urllib.parse.urlencode(
        {
            "latitude": latitude,
            "longitude": longitude,
            "current": "temperature_2m,apparent_temperature,weather_code",
            "timezone": "auto",
        }
    )
    forecast = _read_json(forecast_url)
    if not isinstance(forecast, dict):
        return None

    current = forecast.get("current") or {}
    temperature = current.get("temperature_2m")
    if temperature is None:
        return None

    return {
        "city": place.get("name") or city,
        "country": place.get("country"),
        "temperature_c": temperature,
        "feels_like_c": current.get("apparent_temperature"),
        "condition": _describe_wmo(current.get("weather_code")),
        "weather_code": current.get("weather_code"),
        "source": "open-meteo",
    }


mcp = FastMCP("weather")


@mcp.tool()
def get_weather(city: str = "Москва") -> str:
    """Возвращает текущую погоду в городе.

    Данные берутся из открытых API без ключей: сначала wttr.in,
    при недоступности — Open-Meteo. Возвращается JSON-строка с полями
    city, temperature_c, feels_like_c, condition, humidity, wind, source
    либо {"error": "..."}.
    """
    providers: tuple[Callable[[str], dict[str, Any] | None], ...] = (
        _fetch_wttr,
        _fetch_open_meteo,
    )

    for provider in providers:
        data = provider(city)
        if data:
            return json.dumps(data, ensure_ascii=False)

    return json.dumps(
        {
            "error": f"не удалось получить погоду для «{city}»",
            "hint": f"проверьте доступ к {WEATHER_API_BASE} и {FORECAST_API_URL}",
        },
        ensure_ascii=False,
    )


if __name__ == "__main__":
    mcp.run()
