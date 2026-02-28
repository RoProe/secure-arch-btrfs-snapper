#!/usr/bin/env bash

if pgrep swayidle > /dev/null; then
    idle_toggle="󰅶 Idle Lock: ON"
else
    idle_toggle="󰾪 Idle Lock: OFF"
fi

# Rofi Power Menu
options="󰐥 Shutdown\n󰜉 Reboot\n󰤄 Hibernate\n󰒲 Lock\n${idle_toggle}"

chosen=$(echo -e "$options" | rofi -dmenu -i -p "Power Menu" -theme-str 'window {width: 250px;}')

case $chosen in
    *Shutdown)
        systemctl poweroff
        ;;
    *Reboot)
        systemctl reboot
        ;;
    *Hibernate)
        systemctl hibernate
        ;;
    *Lock)
        swaylock -c 000000 
        ;;
    *"Idle Lock"*)
        if pgrep swayidle > /dev/null; then
            pkill swayidle
            notify-send "Idle Lock" "Disabled"
        else
            swayidle -C ~/.config/swayidle/config &
            notify-send "Idle Lock" "Enabled"
        fi
        ;;
esac
