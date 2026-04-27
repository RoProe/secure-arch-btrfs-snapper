#!/usr/bin/env bash

OVERRIDE="/run/rootflags-override"
[ -f "$OVERRIDE" ] || exit 0

FLAGS="$(cat "$OVERRIDE")"
echo "snapshot-rewrite: rewriting sysroot.mount with: $FLAGS" > /dev/kmsg

mkdir -p /run/systemd/system
cat > /run/systemd/system/sysroot.mount << UNIT
[Unit]
DefaultDependencies=no
After=systemd-cryptsetup@cryptroot.service
Requires=systemd-cryptsetup@cryptroot.service

[Mount]
What=/dev/mapper/cryptroot
Where=/sysroot
Type=btrfs
Options=$FLAGS
UNIT

systemctl daemon-reload
echo "snapshot-rewrite: done" > /dev/kmsg
