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

  date="$(xml_tag date "$info" | awk '{print $1}')"
  stype="$(xml_tag type "$info")"

  case "$stype" in
    timeline) color="\033[32m" ;;  # green
    pre)      color="\033[33m" ;;  # yellow
    post)     color="\033[31m" ;;  # red
    *)        color="" ;;
  esac

  SNAP_IDS+=("$num")
  SNAP_LABELS+=("${color}${date} [${stype}] ${desc}\033[0m")

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

# Header (Box 8 rows) + Footer (selected 4 rows + countdown 2 rows) = total of 14 rows used
HEADER_LINES=8
FOOTER_LINES=6
VISIBLE=$(( TERM_ROWS - HEADER_LINES - FOOTER_LINES ))
(( VISIBLE < 3 )) && VISIBLE=3

selected=0
TIMEOUT=5
start_time=$(date +%s)

draw_menu() {
  echo -ne "\033[2J\033[H"

  echo "┌──────────────────────────────────────────────┐"
  echo "│           Boot / Snapshot Menu               │"
  echo "├──────────────────────────────────────────────┤"
  echo "│ ↑ ↓ / w s / j k = navigate                   │"
  echo "│ Enter = boot selection   q = normal boot     │"
  echo "│ g = top   G = bottom                         │"
  echo "└──────────────────────────────────────────────┘"
  echo ""


  local total=${#SNAP_IDS[@]}

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
    if [[ $i -eq $selected ]]; then
      echo -e " > \033[1;37;44m ${SNAP_LABELS[$i]} \033[0m"
    else
      echo -e "   ${SNAP_LABELS[$i]}"
    fi
  done

  # scroll-indicator bottom
  local remaining_below=$(( total - viewport_end - 1 ))
  if (( remaining_below > 0 )); then
    echo "   ↓ ${remaining_below} more beneath..."
  else
    echo ""
  fi

  echo ""
  echo "Selected:"
  echo "  ID:   ${SNAP_IDS[$selected]}"
  echo "  Path: @snapshots/${SNAP_IDS[$selected]}/snapshot"
}


user_interacted=0
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
  else
    echo "Auto boot disabled. Press Enter or q for boot selection"
  fi

  read -rsn1 -t 1 key || continue
  user_interacted=1 #deactivate countdown
  if [[ $key == $'\x1b' ]]; then
    if read -rsn2 -t 0.1 key; then
      case "$key" in
        "[A") ((selected--)) ;;
        "[B") ((selected++)) ;;
        "[H") selected=0 ;;
        "[F") selected=$((${#SNAP_IDS[@]} - 1)) ;;
      esac
    fi

  elif [[ "$key" == "w" || "$key" == "k" ]]; then
    ((selected--))

  elif [[ "$key" == "s" || "$key" == "j" ]]; then
    ((selected++))

  elif [[ "$key" == "g" ]]; then
    selected=0

  elif [[ "$key" == "G" ]]; then
    selected=$((${#SNAP_IDS[@]} - 1))
#TODO maybe a filtering option starting with / 
  elif [[ "$key" == $'\n' || "$key" == $'\r' || -z "$key" ]]; then #enter
    CHOICE="${SNAP_IDS[$selected]}"
    break

  elif [[ "$key" == "q" ]]; then
    CHOICE=0
    break
  fi

  ((selected < 0)) && selected=0
  ((selected >= ${#SNAP_IDS[@]})) && selected=$((${#SNAP_IDS[@]} - 1))
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
