#!/usr/bin/env bash
check()   { return 0; }
depends() { echo "btrfs"; }
install() {
    inst_hook initqueue/settled 50 "$moddir/snapshot-menu.sh"
    inst_hook pre-mount         10 "$moddir/apply-rootflags.sh"
    inst_multiple btrfs awk sed cat find mount umount
}
