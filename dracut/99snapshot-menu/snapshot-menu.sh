#!/usr/bin/env bash
# Post-LUKS snapshot menu — runs in initramfs after LUKS unlock.
set -u

BTRFS_DEV="/dev/mapper/cryptroot"
BTRFS_MNT="/run/btrfs-root"
DONE_FLAG="/run/snapshot-menu-done"
OVERRIDE_FILE="/run/initramfs/rootflags-override"

# Only run once per boot (dracut hooks can be hit multiple times)
if [ -f "$DONE_FLAG" ]; then
  return 0
fi
touch "$DONE_FLAG"

# Mount the top-level Btrfs volume (subvolid=5 = top-level; all subvolumes visible)
mkdir -p "$BTRFS_MNT"
if ! mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT" 2>/dev/null; then
  return 0  # LUKS not open yet or not Btrfs — skip silently
fi

# Gather snapshots from @snapshots/*/info.xml (Snapper format)
declare -a SNAP_IDS=()
declare -a SNAP_LABELS=()

# Helper: extract simple XML tag content without PCRE grep (-P)
xml_tag() {
  # \$1 = tag, \$2 = file
  sed -n "s|.*<${1}>\\([^<]*\\)</${1}>.*|\\1|p" "$2" | head -n1
}

# Find info.xml files, sort newest snapshot IDs first, take first 20
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

# No snapshots yet — skip menu entirely on first boot
if [ ${#SNAP_IDS[@]} -eq 0 ]; then
  return 0
fi

# Show menu with 5-second timeout defaulting to normal boot
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

# Show numbered snapshot list
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

# Validate choice
VALID=false
for id in "${SNAP_IDS[@]}"; do
  [[ "$id" == "$CHOICE" ]] && VALID=true && break
done

if ! $VALID; then
  echo "Invalid selection — booting normally."
  return 0
fi

# Write the chosen subvolume path for the later root mount step
SNAP_SUBVOL="@snapshots/${CHOICE}/snapshot"
echo "Booting snapshot ${CHOICE}: ${SNAP_SUBVOL}"
mkdir -p "$(dirname "$OVERRIDE_FILE")"
echo "rw,noatime,compress=zstd,subvol=${SNAP_SUBVOL}" > "$OVERRIDE_FILE"
return 0
