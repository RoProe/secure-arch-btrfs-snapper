#!/usr/bin/env bash

# Rofi Power Menu
options="󰐥 Shutdown\n󰜉 Reboot\n󰤄 Hibernate\n󰒲 Lock"

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
esac
