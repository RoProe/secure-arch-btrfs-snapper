#!/bin/bash

# CPU Usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
cpu_usage_int=${cpu_usage%.*}

# CPU Temperature
if command -v sensors &> /dev/null; then
    cpu_temp=$(sensors | grep -E 'Package id 0:|Tctl:' | awk '{print $4}' | head -n1 | cut -d'+' -f2 | cut -d'.' -f1)
    [ -z "$cpu_temp" ] && cpu_temp=$(sensors | grep 'temp1:' | head -n1 | awk '{print $2}' | cut -d'+' -f2 | cut -d'.' -f1)
else
    cpu_temp="N/A"
fi

# CPU Frequency (average)
cpu_freq=$(cat /proc/cpuinfo | grep "MHz" | awk '{sum+=$4; count++} END {printf "%.1f", sum/count/1000}')

# RAM Usage
mem_usage=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
mem_used=$(free -h | grep Mem | awk '{print $3}')
mem_total=$(free -h | grep Mem | awk '{print $2}')

# Disk Usage (root partition)
disk_usage=$(df -h / | awk 'NR==2 {print $5}' | cut -d'%' -f1)
disk_used=$(df -h / | awk 'NR==2 {print $3}')
disk_total=$(df -h / | awk 'NR==2 {print $2}')

# Brightness
if command -v brightnessctl &> /dev/null; then
    brightness=$(brightnessctl g)
    max_brightness=$(brightnessctl m)
    brightness_percent=$(( brightness * 100 / max_brightness ))
else
    brightness_percent="N/A"
fi

# Uptime
uptime_info=$(uptime -p | sed 's/up //')

# Load Average
load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}')

# Battery Cycles (if available)
if [ -f /sys/class/power_supply/BAT0/cycle_count ]; then
    battery_cycles=$(cat /sys/class/power_supply/BAT0/cycle_count)
else
    battery_cycles="N/A"
fi

# Running Processes
process_count=$(ps aux | grep -v "\[.*\]" | wc -l)

# Main display info
main_info="${cpu_usage_int}%"

# Build tooltip - each line as separate variable
line1="╭───── 󰍛 System Info ─────╮"
line2="│ 󰻠 CPU: ${cpu_usage}% @ ${cpu_freq}GHz"
line3="│ 󰔐 Temp: ${cpu_temp}°C"
line4="│ 󰍛 RAM: ${mem_used}/${mem_total} (${mem_usage}%)"
line5="│ 󰋊 Disk: ${disk_used}/${disk_total} (${disk_usage}%)"
line6="│ 󰃞 Brightness: ${brightness_percent}%"
line7="├───────  󰓦 Status ───────┤"
line8="│ 󰑮 Load: ${load_avg}"
line9="│ 󰐱 Processes: ${process_count}"
line10="│ 󰔛 Uptime: ${uptime_info}"
line11="│ 󰂄 Battery Cycles: ${battery_cycles}"
line12="╰─────────────────────────╯"

# Join with \n
tooltip="${line1}\n${line2}\n${line3}\n${line4}\n${line5}\n${line6}\n${line7}\n${line8}\n${line9}\n${line10}\n${line11}\n${line12}"

# Output JSON - using echo with -e to interpret \n
echo "{\"text\":\"󰍛 ${main_info}\",\"tooltip\":\"${tooltip}\",\"class\":\"system-info\",\"percentage\":${cpu_usage_int}}"
