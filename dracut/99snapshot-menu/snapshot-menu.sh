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
  SNAP_IDS+=("$num")
  SNAP_LABELS+=("${date} [${stype}] ${desc}")
done < <(
  find "$BTRFS_MNT/@snapshots" -name "info.xml" 2>/dev/null \
    | sed -n 's|.*/@snapshots/\([0-9]\+\)/info\.xml$|\1 &|p' \
    | sort -nr \
    | head -20 \
    | cut -d' ' -f2-
)

umount "$BTRFS_MNT" 2>/dev/null || true

if [ ${#SNAP_IDS[@]} -eq 0 ]; then
  return 0
fi

exec </dev/console >/dev/console 2>/dev/console

echo ""
echo "┌──────────────────────────────────────────────────┐"
echo "│              Boot / Snapshot Menu                │"
echo "├──────────────────────────────────────────────────┤"
echo "│  [Enter] or 5s timeout  →  Normal boot           │"
echo "│  [s]                    →  Select snapshot       │"
echo "└──────────────────────────────────────────────────┘"
echo ""

KEY=""
read -t 5 -n 1 -s -r KEY || true

if [[ "$KEY" != "s" && "$KEY" != "S" ]]; then
  echo "Booting normally..."
  return 0
fi

echo ""
echo "  Available snapshots (newest first):"
echo ""
for i in "${!SNAP_IDS[@]}"; do
  printf "  %3s)  %s\n" "${SNAP_IDS[$i]}" "${SNAP_LABELS[$i]}"
done
echo ""
echo "    0)  Normal boot (cancel)"
echo ""
read -r -p "  Enter snapshot number: " CHOICE

if [[ "$CHOICE" == "0" || -z "$CHOICE" ]]; then
  echo "Booting normally..."
  return 0
fi

VALID=false
for id in "${SNAP_IDS[@]}"; do
  [[ "$id" == "$CHOICE" ]] && VALID=true && break
done

if ! $VALID; then
  echo "Invalid selection — booting normally."
  return 0
fi

SNAP_SUBVOL="@snapshots/${CHOICE}/snapshot"
echo "Booting snapshot ${CHOICE}: ${SNAP_SUBVOL}"
echo "rw,noatime,compress=zstd,subvol=${SNAP_SUBVOL}" > /run/rootflags-override
return 0
