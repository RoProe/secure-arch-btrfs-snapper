#!/usr/bin/env bash

OVERRIDE_FILE="/run/initramfs/rootflags-override"

# If no override was written by snapshot-menu.sh, do nothing
[ -f "$OVERRIDE_FILE" ] || exit 0

# Export rootflags so dracut's mount step picks up the snapshot subvolume
rootflags="$(cat "$OVERRIDE_FILE")"
export rootflags

return 0
