#!/usr/bin/env bash
check()   { return 0; }
depends() { echo "btrfs"; }
install() {
    inst_hook pre-mount 05 "$moddir/snapshot-menu.sh"
    inst_script "$moddir/snapshot-rewrite.sh" /usr/bin/snapshot-rewrite
    inst_simple "$moddir/snapshot-rewrite.service" /usr/lib/systemd/system/snapshot-rewrite.service
    inst_multiple btrfs awk sed cat find mount umount touch sort head cut tee systemctl lsblk blkid udevadm
    
    ln_r /usr/lib/systemd/system/snapshot-rewrite.service \
         /usr/lib/systemd/system/initrd.target.wants/snapshot-rewrite.service
}
