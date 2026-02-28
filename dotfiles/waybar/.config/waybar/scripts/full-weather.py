#!/usr/bin/env python3
# Based on work by Balthazzahr (https://github.com/Balthazzahr)

import requests
import json
import sys
from datetime import datetime, timedelta
import calendar
import re

# ---------------- AUTO-LOCATION VIA IP
def get_location_by_ip():
    try:
        r = requests.get("https://ipinfo.io/json", timeout=5)
        r.raise_for_status()
        data = r.json()
        loc = data.get("loc", "0,0").split(",")
        lat, lon = float(loc[0]), float(loc[1])
        city = data.get("city", "Your Location")
        return lat, lon, city
    except Exception:
        return 0.0, 0.0, "Your Location"

LAT, LON, LOCATION_NAME = get_location_by_ip()
DAYS_FORECAST = 5

URL = (
    f"https://api.open-meteo.com/v1/forecast?"
    f"latitude={LAT}&longitude={LON}"
    f"&current_weather=true"
    f"&hourly=temperature_2m,apparent_temperature,weathercode,"
    f"relativehumidity_2m,windspeed_10m,precipitation_probability,precipitation"
    f"&daily=temperature_2m_max,temperature_2m_min,weathercode,precipitation_sum"
    f"&timezone=auto"
)

# ---------------- WEATHER ICONS
WEATHER_MAP = {
    0: ("☀️", "Clear sky"), 1: ("🌤️", "Mainly clear"), 2: ("⛅", "Partly cloudy"),
    3: ("☁️", "Overcast"), 45: ("🌫️", "Fog"), 48: ("🌫️", "Depositing rime fog"),
    51: ("🌦️", "Light drizzle"), 53: ("🌦️", "Moderate drizzle"), 55: ("🌦️", "Dense drizzle"),
    61: ("🌧️", "Slight rain"), 63: ("🌧️", "Moderate rain"), 65: ("🌧️", "Heavy rain"),
    66: ("🌧️", "Light freezing rain"), 67: ("🌧️", "Heavy freezing rain"),
    71: ("❄️", "Slight snow"), 73: ("❄️", "Moderate snow"), 75: ("❄️", "Heavy snow"),
    80: ("🌦️", "Slight rain showers"), 81: ("🌧️", "Moderate rain showers"), 82: ("🌧️", "Violent rain showers"),
    85: ("❄️", "Slight snow showers"), 86: ("❄️", "Heavy snow showers"),
    95: ("⛈️", "Thunderstorm"), 96: ("⛈️", "Thunderstorm with hail (slight)"), 99: ("⛈️", "Thunderstorm with hail (severe)"),
}

SHORT_DESC_MAP = {
    "Slight rain showers": "Slight rain", "Moderate rain showers": "Moderate rain", "Violent rain showers": "Heavy rain",
    "Thunderstorm with hail (slight)": "Hail Storm", "Thunderstorm with hail (severe)": "Severe Storm",
    "Light drizzle": "Drizzle", "Moderate drizzle": "Mod drizzle", "Dense drizzle": "Dense drizzle",
    "Slight rain": "Slight rain", "Moderate rain": "Mod rain", "Heavy rain": "Heavy rain",
    "Light freezing rain": "Freezing rain", "Heavy freezing rain": "Heavy freeze",
    "Slight snow": "Snow", "Moderate snow": "Mod snow", "Heavy snow": "Heavy snow",
    "Clear sky": "Clear", "Mainly clear": "Mainly clear", "Partly cloudy": "Part cloudy",
    "Overcast": "Overcast", "Fog": "Fog", "Depositing rime fog": "Rime fog",
}

# ---------------- COLORS
FG_HEADER = "#f4b8e4"
FG_TEXT = "#ffffff"

TEMP_COLORS = [
    (15, "#8caaee"), (18, "#85c1dc"), (21, "#99d1db"), (24, "#81c8be"),
    (27, "#a6d189"), (30, "#e5c890"), (32, "#ef9f76"), (33, "#ea999c"), (100, "#e78284")
]

def temp_to_color(temp):
    for t_max, color in TEMP_COLORS:
        if temp <= t_max:
            return color
    return TEMP_COLORS[-1][1]

# ---------------- ERROR HANDLING
def fail(msg="Weather unavailable"):
    print(json.dumps({"text": "N/A", "tooltip": f"<span foreground='{FG_HEADER}'>{msg}</span>"}))
    sys.exit(0)

# ---------------- FETCH DATA
try:
    r = requests.get(URL, timeout=10)
    r.raise_for_status()
    data = r.json()
except Exception as e:
    fail(f"Failed to fetch weather: {e}")

# ---------------- CURRENT WEATHER
try:
    current = data["current_weather"]
    temp = current["temperature"]
    code = current["weathercode"]
    icon, desc = WEATHER_MAP.get(code, ("❓", "Unknown"))

    hourly = data["hourly"]
    times = hourly["time"]
    apparent_temps = hourly.get("apparent_temperature", [temp]*len(times))
    humidity_arr = hourly.get("relativehumidity_2m", [0]*len(times))
    wind_arr = hourly.get("windspeed_10m", [0]*len(times))
    rain_arr = hourly.get("precipitation_probability", [0]*len(times))

    now = datetime.now()

    current_index = 0
    for i, t in enumerate(times):
        dt = datetime.fromisoformat(t)
        if dt.hour == now.hour and dt.date() == now.date():
            current_index = i
            break

    feels_like = apparent_temps[current_index]
    humidity = humidity_arr[current_index]
    windspeed = wind_arr[current_index]

    text = f"| {icon} <span foreground='{temp_to_color(temp)}'>{temp}°C</span>"

except Exception:
    fail("Failed to parse current weather")

# ---------------- TOOLTIP BUILDING
tooltip_lines = []

def max_line_length(lines):
    clean = [re.sub(r'<.*?>', '', line) for line in lines]
    return max((len(x) for x in clean), default=0)

# ---------------- CURRENT CONDITIONS
heading_current = f"🌍 Current Weather - {LOCATION_NAME}"

current_section_lines = [
    f"🌡️ <span foreground='{temp_to_color(temp)}'>{temp}°C</span> "
    f"(Feels like <span foreground='{temp_to_color(feels_like)}'>{feels_like}°C</span>)",
    f"{icon} {desc}",
    f"💧 Humidity: {humidity}%",
    f"🌬️ Wind Speed: {windspeed} km/h"
]

# ---------------- TODAY FORECAST
today_heading = "☀️ Today Forecast:"
today_lines = []

rain_probs_today = []
rain_start_time = None
precip_total = 0

for t, prob, precip in zip(times, rain_arr, hourly.get("precipitation", [0]*len(times))):
    dt = datetime.fromisoformat(t)
    if dt.date() == now.date() and dt >= now:
        rain_probs_today.append(prob)
        precip_total += precip
        if prob > 0 and rain_start_time is None:
            rain_start_time = dt

if rain_probs_today and max(rain_probs_today) > 0:
    max_prob_today = max(rain_probs_today)
    today_lines.append(f"🌧️ Chance of rain today: <span foreground='{FG_TEXT}'>{max_prob_today}%</span>")
    if rain_start_time:
        today_lines.append(f"⏱️ Expected rain start: {rain_start_time.strftime('%I:%M %p')}")
    else:
        today_lines.append("⏱️ Expected rain start: None predicted")
    today_lines.append(f"☔ Total predicted rain: {precip_total:.1f} mm")
    today_lines.append("")  # extra blank line


# Hourly forecast for the next 15 hours in 3-hour intervals
try:
    temps_h = hourly["temperature_2m"]
    codes_h = hourly["weathercode"]
    end_time = now + timedelta(hours=15)
    
    entries_added = 0
    for t, temp_h, code_h in zip(times, temps_h, codes_h):
        dt = datetime.fromisoformat(t)
        if dt <= now or dt > end_time:
            continue
        
        # Prüfe ob diese Stunde ca. 3h nach der letzten liegt
        hours_from_now = (dt - now).total_seconds() / 3600
        if hours_from_now >= entries_added * 3 and hours_from_now < (entries_added + 1) * 3:
            hour = dt.strftime("%H:%M")
            icon_h, desc_h = WEATHER_MAP.get(code_h, ("❓", "Unknown"))
            short_desc = SHORT_DESC_MAP.get(desc_h, desc_h)
            color = temp_to_color(temp_h)
            today_lines.append(f"{hour} - <span foreground='{color}'>{temp_h:>2}°C</span> {icon_h} {short_desc}")
            entries_added += 1
            if entries_added >= 5:
                break
except Exception:
    today_lines.append("Hourly forecast unavailable")

# ---------------- TOMORROW FORECAST
tomorrow = now.date() + timedelta(days=1)
tomorrow_heading = "⛅ Tomorrow Forecast:"
tomorrow_lines = []

try:
    TIME_LABELS = {6: "Morning", 12: "Midday", 15: "Afternoon", 18: "Evening"}
    label_width = max(len(v) for v in TIME_LABELS.values())
    for t, temp_h, code_h in zip(times, temps_h, codes_h):
        dt = datetime.fromisoformat(t)
        if dt.date() != tomorrow:
            continue
        label = TIME_LABELS.get(dt.hour)
        if not label:
            continue
        icon_h, desc_h = WEATHER_MAP.get(code_h, ("❓", "Unknown"))
        short_desc = SHORT_DESC_MAP.get(desc_h, desc_h)
        color = temp_to_color(temp_h)
        tomorrow_lines.append(f"{label:<{label_width}} - <span foreground='{color}'>{temp_h:>2}°C</span> {icon_h} {short_desc}")
except Exception:
    tomorrow_lines.append("Tomorrow forecast unavailable")

# ---------------- DAILY FORECAST (skip today)
daily = data["daily"]
dates = daily["time"]
max_temps = daily["temperature_2m_max"]
min_temps = daily["temperature_2m_min"]
codes_d = daily["weathercode"]
daily_heading = f"📅 Upcoming {DAYS_FORECAST}-day Forecast:"
daily_lines = []

for i in range(1, min(DAYS_FORECAST+1, len(dates))):
    day_name = calendar.day_name[datetime.fromisoformat(dates[i]).weekday()][:3]
    icon_f, desc_full = WEATHER_MAP.get(codes_d[i], ("❓", "Unknown"))
        # DEBUG: Zeige unbekannte Codes
    if desc_full == "Unknown":
        print(f"DEBUG: Unknown code {codes_d[i]} for {day_name}", file=sys.stderr)
    short_desc = SHORT_DESC_MAP.get(desc_full, desc_full)
    daily_lines.append(
        f"{day_name:<3} "
        f"⬆️<span foreground='{temp_to_color(max_temps[i])}'>{max_temps[i]:>2}°C</span> "
        f"⬇️<span foreground='{temp_to_color(min_temps[i])}'>{min_temps[i]:>2}°C</span> "
        f"{icon_f} {short_desc}"
    )

# ---------------- DYNAMIC LINE LENGTH
all_for_length = (
    current_section_lines + today_lines + tomorrow_lines + daily_lines
    + [heading_current, today_heading, tomorrow_heading, daily_heading]
)
max_len = max_line_length(all_for_length)

# ---------------- RENDER SECTION
def render_section(lines, heading):
    out = []
    out.append(f"<span foreground='{FG_HEADER}' font='10'>{heading}</span>")
    out.append(f"<span foreground='#ffffff'>{'─'*max_len}</span>")
    for line in lines:
        out.append(f"<span foreground='{FG_TEXT}' font='10'>{line}</span>")
    out.append("")
    return out

tooltip_lines = []
tooltip_lines += render_section(current_section_lines, heading_current)
tooltip_lines += render_section(today_lines, today_heading)
tooltip_lines += render_section(tomorrow_lines, tomorrow_heading)
tooltip_lines += render_section(daily_lines, daily_heading)
tooltip_lines.append(f"<span foreground='{FG_HEADER}' font='10'>🖱️LMB: Full Weather  |  🖱️RMB: Radar</span>")

# ---------------- OUTPUT
print(json.dumps({
    "text": text,
    "tooltip": "\n".join(tooltip_lines),
    "markup": "pango"
}, ensure_ascii=False))
