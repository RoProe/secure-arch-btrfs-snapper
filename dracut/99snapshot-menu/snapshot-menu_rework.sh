#!/usr/bin/env bash

BTRFS_DEV="/dev/mapper/cryptroot"
BTRFS_MNT="/run/btrfs-root"
DONE_FLAG="/run/snapshot-menu-done"

[ -f "$DONE_FLAG" ] && return 0

mkdir -p "$BTRFS_MNT"
if ! mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT" 2>/dev/null; then
  return 0
fi
touch "$DONE_FLAG"

declare -a SNAP_IDS=()
declare -a SNAP_LABELS=()
declare -a SNAP_SEARCH=()

xml_tag() {
  sed -n "s|.*<${1}>\([^<]*\)</${1}>.*|\1|p" "$2" | head -n1
}

while IFS= read -r info; do
  num="$(echo "$info" | sed -n 's|.*/@snapshots/\([0-9][0-9]*\)/info\.xml$|\1|p')"
  [ -n "$num" ] || continue

  snap_subvol="$BTRFS_MNT/@snapshots/${num}/snapshot"
  [ -d "$snap_subvol" ] || continue

  desc="$(xml_tag description "$info")"
  [ -n "$desc" ] || desc="—"

  snap_date="$(xml_tag date "$info" | awk '{print $1}')"
  stype="$(xml_tag type "$info")"

  case "$stype" in
    timeline) color="\033[32m" ;;  # green
    pre)      color="\033[33m" ;;  # yellow
    post)     color="\033[31m" ;;  # red
    *)        color="" ;;
  esac

  SNAP_IDS+=("$num")
  SNAP_LABELS+=("${color}${snap_date} [${stype}] ${desc}\033[0m")
  SNAP_SEARCH+=("${num} ${snap_date} ${stype} ${desc}")

done < <(
  find "$BTRFS_MNT/@snapshots" -name "info.xml" 2>/dev/null \
    | sed -n 's|.*/@snapshots/\([0-9]\+\)/info\.xml$|\1 &|p' \
    | sort -nr \
    | head -20 \
    | cut -d' ' -f2-
)

umount "$BTRFS_MNT" 2>/dev/null || true

[ ${#SNAP_IDS[@]} -eq 0 ] && return 0

exec </dev/console >/dev/console 2>/dev/console

# reduce kernel spam, terminal safety and hide cursor
dmesg -n 1
trap 'stty sane 2>/dev/null; echo -e "\033[0m\033[?25h"' EXIT
echo -ne "\033[?25l"

# get screen height in rows, fallback is 24
TERM_ROWS=$(stty size 2>/dev/null | awk '{print $1}')
(( TERM_ROWS > 0 )) || TERM_ROWS=24

# Header (Box 8 rows + Search row = 9) + Footer (selected 4 rows + countdown 2 rows) = total of 14 rows used
HEADER_LINES=9
FOOTER_LINES=6
VISIBLE=$(( TERM_ROWS - HEADER_LINES - FOOTER_LINES ))
(( VISIBLE < 3 )) && VISIBLE=3

selected=0
TIMEOUT=5
start_time=$(date +%s)
user_interacted=0
remaining=$TIMEOUT

filter=""
filter_mode=0
declare -a FILTERED_IDS=()

apply_filter() {
  FILTERED_IDS=()
  local term="${filter,,}"
  for i in "${!SNAP_IDS[@]}"; do
    local search_text="${SNAP_SEARCH[$i],,}"
    if [[ -z "$term" || "$search_text" == *"$term"* ]]; then
      FILTERED_IDS+=("$i")
    fi
  done
  # reset selected
  selected=0
}

apply_filter


# ============= First MENU =========================================
pre_menu() {
  local timeout=5
  local start=$(date +%s)

  while true; do
    echo -ne "\033[2J\033[H"
    echo "┌──────────────────────────────────────────────┐"
    echo "│                 Boot Menu                    │"
    echo "├──────────────────────────────────────────────┤"
    echo "│           normal boot   (Enter/q)            │"
    echo "│           snapshot menu   (s)                │"
    echo "└──────────────────────────────────────────────┘"
    echo ""

    local now=$(date +%s)
    local elapsed=$((now - start))
    local remaining=$((timeout - elapsed))

    if (( remaining <= 0 )); then
      return 0  # normal boot
    fi

    echo "Auto boot in ${remaining}s..."

    if read -rsn1 -t 1 key; then
      case "$key" in
        $'\n'|$'\r'|"q")
          return 0
          ;;
        "s")
          return 1
          ;;
      esac
    fi
  done
}

# ============== Snapshot Menu ===========================================
draw_menu() {
  echo -ne "\033[2J\033[H"

  local total=${#FILTERED_IDS[@]}
 
  # underline in search row if in filter mode
  local search_display
  if (( filter_mode )); then
    search_display="${filter}_"
  else
    search_display="${filter}"
  fi

  echo "┌──────────────────────────────────────────────┐"
  echo "│           Boot / Snapshot Menu               │"
  echo "├──────────────────────────────────────────────┤"
  echo "│ ↑ ↓  /  w s  /  j k  =  navigate             │"
  echo "│ Enter = boot selection   q = normal boot     │"
  echo "│ g = top   G = bottom                         │"
  echo "├──────────────────────────────────────────────┤"
  printf "│ Search: %-38s│\n" "$search_display"
  echo "└──────────────────────────────────────────────┘"
  echo ""

  if (( total == 0 )); then
    echo "   (no results – ESC to clear filter)"
    for (( i=1; i<VISIBLE; i++ )); do echo ""; done
  else
    # Viewport: keep selected centered
    local viewport_start=$(( selected - VISIBLE/2 ))
    (( viewport_start < 0 )) && viewport_start=0
    local viewport_end=$(( viewport_start + VISIBLE - 1 ))
    (( viewport_end >= total )) && viewport_end=$(( total - 1 ))
    # move viewport top to keep visible full 
    (( viewport_start > viewport_end - VISIBLE + 1 )) && viewport_start=$(( viewport_end - VISIBLE + 1 ))
    (( viewport_start < 0 )) && viewport_start=0

    # scroll-indicator top
    if (( viewport_start > 0 )); then
      echo "   ↑ ${viewport_start} more above..."
    else
      echo ""
    fi

    # visible region
    for (( i=viewport_start; i<=viewport_end; i++ )); do
      local idx="${FILTERED_IDS[$i]}"
      if [[ $i -eq $selected ]]; then
        echo -e " > \033[1;37;44m ${SNAP_LABELS[$idx]} \033[0m"
      else
        echo -e "   ${SNAP_LABELS[$idx]}"
      fi
    done

    # scroll-indicator bottom
    local remaining_below=$(( total - viewport_end - 1 ))
    if (( remaining_below > 0 )); then
      echo "   ↓ ${remaining_below} more beneath..."
    else
      echo ""
    fi
  fi

  echo ""
  if (( total > 0 )); then
    local real_idx="${FILTERED_IDS[$selected]}"
    echo "  ID:   ${SNAP_IDS[$real_idx]}"
    echo "  Path: @snapshots/${SNAP_IDS[$real_idx]}/snapshot"
  else
    echo "  ID:   —"
    echo "  Path: —"
  fi
}

# --- Pre Menu ---
if pre_menu; then
  echo "booting normally..."
  return 0
fi

while true; do
  draw_menu

  now=$(date +%s)
  elapsed=$((now - start_time))
  if (( user_interacted == 0 )); then
    remaining=$((TIMEOUT - elapsed))

    if (( remaining <= 0 )); then
      echo ""
      echo "Auto boot..."
      CHOICE=0
      break
    fi
  fi

  echo ""
  if (( user_interacted == 0 )); then
    echo "Auto boot in ${remaining}s..."
  elif (( filter_mode )); then
    echo "Search mode – ESC to clear"
  else
    echo "Auto boot disabled. Press Enter or q for boot selection"
  fi

  if read -rsn1 -t 1 key; then
    user_interacted=1
  else
    continue
  fi


  # --- Filter Mode --------------------------
  if (( filter_mode )); then
    if [[ "$key" == $'\x1b' ]]; then
      filter=""
      filter_mode=0
      apply_filter
 
    elif [[ "$key" == $'\x7f' || "$key" == $'\x08' ]]; then
      # Backspace (DEL 0x7F oder BS 0x08)
      filter="${filter%?}"
      apply_filter
 
    elif [[ "$key" == $'\n' || "$key" == $'\r' || -z "$key" ]]; then
      # Enter: Suchmodus verlassen, Auswahl behalten
      filter_mode=0
 
    elif [[ "$key" =~ [[:print:]] ]]; then
      filter+="$key"
      apply_filter
    fi

  # --- Normal Mode --------------------------
  else
    if [[ "$key" == "/" ]]; then
      filter_mode=1
    
    elif [[ $key == $'\x1b' ]]; then
      if read -rsn2 -t 0.1 key; then
        case "$key" in
          "[A") ((selected--)) ;;
          "[B") ((selected++)) ;;
          "[H") selected=0 ;;
          "[F") selected=$((${#FILTERED_IDS[@]} - 1)) ;;
        esac
      else
        if [[ -n "$filter" ]]; then
          filter=""
          apply_filter
        fi
      fi

    elif [[ "$key" == "w" || "$key" == "k" ]]; then
      ((selected--))

    elif [[ "$key" == "s" || "$key" == "j" ]]; then
      ((selected++))

    elif [[ "$key" == "g" ]]; then
      selected=0

    elif [[ "$key" == "G" ]]; then
      selected=$((${#FILTERED_IDS[@]} - 1))

    elif [[ "$key" == $'\n' || "$key" == $'\r' || -z "$key" ]]; then #enter
      if (( ${#FILTERED_IDS[@]} > 0 )); then
        CHOICE="${SNAP_IDS[${FILTERED_IDS[$selected]}]}"
        break
      fi

    elif [[ "$key" == "q" ]]; then
      CHOICE=0
      break
    fi
    
    total=${#FILTERED_IDS[@]}

    if (( total == 0 )); then
      selected=0
    else
      max=$((total - 1))
      (( selected < 0 )) && selected=0
      (( selected > max )) && selected=$max
    fi
  fi
done

# restore terminal
stty sane 2>/dev/null || true
echo -ne "\033[?25h"

if [[ "$CHOICE" == "0" || -z "$CHOICE" ]]; then
  echo "Booting normally..."
  return 0
fi

SNAP_SUBVOL="@snapshots/${CHOICE}/snapshot"
echo "Booting snapshot ${CHOICE}: ${SNAP_SUBVOL}"

echo "rw,noatime,compress=zstd,subvol=${SNAP_SUBVOL}" > /run/rootflags-override

return 0
