#!/bin/bash

MAX_LENGTH=30
SCROLL_SPEED=0.3

get_current_info() {
    local status=$(playerctl status 2>/dev/null)
    local artist=$(playerctl metadata artist 2>/dev/null)
    local title=$(playerctl metadata title 2>/dev/null)
    echo "${status}|${artist}|${title}"
}

scroll_text() {
    local text="$1"
    local original_info="$2"
    local len=${#text}
    
    #Short text, no scroll needed
    if [ $len -le $MAX_LENGTH ]; then
        printf '{"text":"%s","class":"media"}\n' "$text"
        sleep 1
        # check for change
        [ "$(get_current_info)" = "$original_info" ] && return 0 || return 1
    fi
    
    # long text, scroll
    text="${text}   ---   "
    len=${#text}
    
    for ((i=0; i<len; i++)); do
        # Check for change
        local current_info=$(get_current_info)
        
        if [ "$current_info" != "$original_info" ]; then
            return 1  # stop - there was a change
        fi
        
        local display="${text:i:MAX_LENGTH}"
        if [ ${#display} -lt $MAX_LENGTH ]; then
            local wrap="${text:0:$((MAX_LENGTH - ${#display}))}"
            display="${display}${wrap}"
        fi
        
        printf '{"text":"%s","class":"media"}\n' "$display"
        sleep $SCROLL_SPEED
    done
    
    return 0
}

# use metadata -F to react on all canges (Track, Status, etc.)
playerctl metadata -F 2>/dev/null | while read -r _; do
    status=$(playerctl status 2>/dev/null)
    artist=$(playerctl metadata artist 2>/dev/null)
    title=$(playerctl metadata title 2>/dev/null)
    
    info="${status}|${artist}|${title}"
    text="${artist} - ${title}"
    
    case "$status" in
        Playing)
            # Scrolle till change
            while scroll_text "$text" "$info"; do
                :  # Loop till scroll_text false 
            done
            ;;
        Paused)
            if [ ${#text} -le $MAX_LENGTH ]; then
                printf '{"text":"󰏤 %s","class":"media paused"}\n' "$text"
            else
                printf '{"text":"󰏤 %s...","class":"media paused"}\n' "${text:0:$((MAX_LENGTH-4))}"
            fi
            ;;
        Stopped|*)
            echo '{"text":"","class":"media"}'
            ;;
    esac
done
