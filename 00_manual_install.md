# Installation Guide

Fully encrypted Arch Linux: LUKS2 + Btrfs + Dracut UKI + systemd-boot + post-LUKS snapshot menu + SecureBoot.

This Guide is heavily influenced by [secure-arch](https://github.com/Ataraxxia/secure-arch) by Ataraxxia.

---

## Boot flow

```
UEFI → systemd-boot (instant) → UKI loads → LUKS passphrase
     → initramfs snapshot menu (5s timeout)
          [Enter]  →  normal boot
          [s]      →  select snapshot → rollback boot
```

**Why systemd-boot instead of GRUB?**
GRUB runs *before* LUKS and must decrypt the partition itself — which forces you to use PBKDF2 as the key derivation function instead of Argon2id. systemd-boot is a pure EFI launcher that immediately hands off to the UKI. The snapshot menu runs inside the initramfs *after* LUKS is already open, so you keep full Argon2id security.

**Why btrfs instead of ext4?**
- Allows easy use of snapshots and Rollbacks
- We now use Subvolumes instead of Logical Subvolumes
- Less layers and less complex
---

## Prerequisites

- UEFI system (no legacy BIOS)
- BIOS allows enrolling custom SecureBoot keys (if using SecureBoot)
- No manufacturer backdoors in firmware

---

## Preparing USB and booting the installer 

```bash
sudo dd if=/path/to/archlinux.iso of=/dev/sdX status=progress
sync
```


Formating the Install USB Stick beforehand is redundant since it will be overwritten anyways. The Arch iso is a hybrid image and should be written raw.

**Disable SecureBoot in BIOS**, boot the USB. Connect to WiFi (if needed):

```bash
iwctl
station wlan0 connect YOUR_SSID
exit
```

---

## Disk layout

For partitioning you can use your favourtie tool that supports creating GPT partitions. I use sgdisk, since it can be easiliy reused in scripts.

```
+----------------------+---------------------------------------------------------------------+
| EFI system partition | LUKS2 encrypted partition                                           |
|                      |                                                                     |
| /boot/efi            | Btrfs volume — subvolumes:                                          |
| /dev/nvme0n1p1       |   @           → /              (root)                               |
| FAT32, unencrypted   |   @home       → /home          (excluded from root snapshots)       |
|                      |   @snapshots  → /.snapshots    (Snapper storage)                    |
|                      |   @var_log    → /var/log       (logs survive rollbacks)              |
|                      |   @swap       → /swap          (nodatacow, for hibernate)            |
+----------------------+---------------------------------------------------------------------+
                         /dev/nvme0n1p2  →  /dev/mapper/cryptroot
```

**Why each subvolume exists:**
- `@home` — personal data survives system rollbacks. Rolling back a broken update won't undo your files.
- `@snapshots` — must be its own subvolume so snapshots don't include themselves recursively.
- `@var_log` — logs shouldn't roll back. You want the log entries that explain *why* something broke.
- `@swap` — Btrfs Copy-on-Write makes file offsets non-contiguous, which breaks the kernel's `resume_offset` calculation for hibernate. This subvolume has CoW disabled.

*Changes to Ataraxia's guide:*
 - _no lvm needed anymore since we're running btrfs_
 - _added a swap subvolume for hibernate and, well, swap.._
 - _added snapshot subvolume for snapshots_
 - _home as seperate subvolume, so it can be excluded from snapshots (we don't want to loose our data with every rollback)_
 - _var_log for losg since they should survive rollbacks_

---

## Partitioning
The sizes and partition codes:

```bash
/dev/nvme0n1p1 - EFI - 1024MB;				partition code EF00
/dev/nvme0n1p2 - encrypted LUKS - remaining space;	partition code 8309 
```


Example with sgdisk:

```bash
sgdisk --zap-all /dev/nvme0n1
sgdisk -n 1:0:+1024MiB -t 1:EF00 -c 1:"EFI"  /dev/nvme0n1
sgdisk -n 2:0:0        -t 2:8309 -c 2:"LUKS" /dev/nvme0n1
partprobe /dev/nvme0n1
```

Formatting the EFI partition:
```bash
mkfs.fat -F32 /dev/nvme0n1p1
```

---

## LUKS2
Creating the encrypted volume and opening it:
```bash
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
cryptsetup open --allow-discards --persistent /dev/nvme0n1p2 cryptroot
```

`--allow-discards` enables SSD TRIM through the encrypted layer. `--persistent` saves this flag in the LUKS2 header.
`--allow-discards` (TRIM) doesn't leak clear text date but leaks free blocks. It makes sense for the live-expactancy of our SSD. If you are paranoid you can omit it.

---

## Btrfs filesystem

```bash
mkfs.btrfs /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@swap     # omit if not using hibernate

umount /mnt
```

Mount with options:

```bash
# Root subvolume
mount -o noatime,compress=zstd,subvol=@          /dev/mapper/cryptroot /mnt

mkdir -p /mnt/{home,.snapshots,var/log,swap,boot/efi}

# Home
mount -o noatime,compress=zstd,subvol=@home      /dev/mapper/cryptroot /mnt/home
# Snapshots
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
# Logs isolated from snapshots
mount -o noatime,compress=zstd,subvol=@var_log   /dev/mapper/cryptroot /mnt/var/log
# Swap with disabled CoW and compression
mount -o nodatacow,subvol=@swap          /dev/mapper/cryptroot /mnt/swap
# EFI
mount /dev/nvme0n1p1 /mnt/boot/efi
```

- `noatime` — skip access timestamp writes. Fewer SSD writes.
- `compress=zstd` — transparent compression, typically 20–40% space saving.
- `nodatacow` on `@swap` — required for hibernate correctness (see above).
- Each subvolume is mounted explicitly with its own mount options to make the configuration transparent and reproducible.

---

## Swapfile and hibernate

The swapfile lives inside LUKS — fully encrypted. No separate swap partition needed.

```bash
touch /mnt/swap/swapfile
chattr +C /mnt/swap/swapfile          # also disables CoW at file level
fallocate -l 16G /mnt/swap/swapfile   # match your RAM size
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile
```

Get the resume offset — needed for the kernel command line:

```bash
btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile
# example output: 1234567
```

__Note this number.__ At boot, after LUKS is unlocked, the kernel uses it to locate the hibernate image inside the swapfile.

---

## System bootstrapping

First initialize and populate the keyring 
```bash
pacman-key --init
pacman-key --populate
```

The pacstrap is similar to _Ataraxxia_, differences are:
- we don't need lvm2 so it got removed (no ext4)
- btrfs-progs snapper snap-pac man-db got added. btrfs-progs, since it's needed for managing Btrfs, snapper and snap-pac for snapshots and snapshot hook. 
**IMPORTANT**: Change _YOUR_UCODE_PACKAGE_ to either intel-ucode or amd-ucode, depending on your cpu !
```bash
pacstrap /mnt base linux linux-firmware YOUR_UCODE_PACKAGE sudo vim dracut sbsigntools iwd git efibootmgr binutils networkmanager pacman btrfs-progs snapper snap-pac
```

Generate fstab:
```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Now chroot into the system to perform the basic configuration
```bash
arch-chroot /mnt
```

---

## Basic system configuration (inside chroot)

Set root password:
```bash
passwd
```
Update and install man:
```bash
pacman -Syu man-db
```
Set timezone and generate /etc/adjtime:
```bash
ln -sf /usr/share/zoneinfo/<Region>/<city> /etc/localtime
hwclock --systohc
```
Set your desired locale. Instead of editing configuration files manually, we configure them non-interactively to keep the installation deterministic and scriptable.
Adjust the locale values if needed.
```bash
# Enable locale
sed -i 's/^#de_AT.UTF-8/de_AT.UTF-8/' /etc/locale.gen
locale-gen

# Set system locale
echo "LANG=de_AT.UTF-8" > /etc/locale.conf

# Console keyboard layout
echo "KEYMAP=de-latin1" > /etc/vconsole.conf
```
Set your hostname:
```bash
echo "yourhostname" > /etc/hostname
```
Create your user:
```bash
useradd -m -G wheel YOUR_NAME
passwd YOUR_NAME
```
Add your user to sudo:
```bash
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/00-wheel
chmod 440 /etc/sudoers.d/00-wheel
usermod -aG wheel YOUR_NAME
```
Enable basic systemd units:
```bash
systemctl enable NetworkManager
systemctl enable fstrim.timer
```

---

## Snapper
We create a Snapper configurtion named "root" for the filesystem monted at /
```bash
snapper -c root create-config /
```

Snapper auto-creates /.snapshots as a new Btrfs subvolume.
Delete it — we already have @snapshots mounted there via fstab.
```bash
btrfs subvolume delete /.snapshots
```
Recreate the mountpoint directory for the already-existing @snapshots subvolume, set permissions and make it group owned by wheel admins
```bash
mkdir -p /.snapshots
chmod 750 /.snapshots
chown :wheel /.snapshots
```

`snap-pac` automatically creates pre/post snapshots around every pacman transaction. No manual action needed for day-to-day use.

---

## Post-LUKS snapshot menu (dracut module)

This custom dracut module is bundled into the UKI. It runs inside the initramfs **after LUKS is unlocked** but before root is mounted. It reads the Snapper snapshots directly from the Btrfs volume and presents a simple menu:

```
┌──────────────────────────────────────────────────┐
│              Boot / Snapshot Menu                │
├──────────────────────────────────────────────────┤
│  [Enter] or 5s timeout  →  Normal boot           │
│  [s]                    →  Select snapshot        │
└──────────────────────────────────────────────────┘
```

Pressing `s` shows a numbered list of available snapshots (newest first). Selecting one mounts `@snapshots/N/snapshot` as root instead of `@` — a clean, read-consistent rollback.

Create the module directory:

```bash
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu
```

Create `module-setup.sh` and make it executabe:

```bash
cat > /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh << 'EOF'
#!/usr/bin/env bash
check()   { return 0; }
depends() { echo "btrfs"; }
install() {
    inst_hook initqueue/settled 50 "$moddir/snapshot-menu.sh"
    inst_hook pre-mount 10 "$moddir/apply-rootflags.sh"
    inst_multiple btrfs awk sed cat find mount umount
}
EOF

chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh
```

Create second hook to apply the rootflags:
```bash
cat > /usr/lib/dracut/modules.d/99snapshot-menu/apply-rootflags.sh << 'EOF'
#!/usr/bin/env bash

OVERRIDE_FILE="/run/initramfs/rootflags-override"

# If no override file exists, do nothing
[ -f "$OVERRIDE_FILE" ] || exit 0

# Read the override flags written by snapshot-menu.sh
rootflags="$(cat "$OVERRIDE_FILE")"
export rootflags

exit 0
EOF

chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/apply-rootflags.sh
```


`snapshot-menu.sh` — see full source in `snapshot-menu.sh`. Enable the module in dracut:

```bash
# /etc/dracut.conf.d/flags.conf
add_dracutmodules+=" snapshot-menu "
```

---

## Dracut UKI configuration

Create the pacman hook scripts:

```bash
cat > /usr/local/bin/dracut-install.sh << 'EOF'
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
    if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="${line#'usr/lib/modules/'}"
        kver="${kver%'/pkgbase'}"
        dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
    fi
done
EOF

cat > /usr/local/bin/dracut-remove.sh << 'EOF'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
EOF

chmod +x /usr/local/bin/dracut-*
```

Pacman hooks (`/etc/pacman.d/hooks/`):

```bash
mkdir -p /etc/pacman.d/hooks

cat > /etc/pacman.d/hooks/90-dracut-install.hook << 'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
EOF

cat > /etc/pacman.d/hooks/60-dracut-remove.hook << 'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
EOF
```

In the next steps we will need the Swap offset from before as well as the UUID. You can store them as variables or copy them.

```bash
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile)
echo "OFFSET: $RESUME_OFFSET"
LUKS_UUID=$(blkid -s UUID -o value /dev/nvme0n1p2)
echo "LUKS UUID: $LUKS_UUID"
```

Kernel command line (`/etc/dracut.conf.d/cmdline.conf`) — replace `YOUR_UUID` and `YOUR_OFFSET`:

```bash
cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-${LUKS_UUID} root=/dev/mapper/cryptroot \
rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@ \
resume=/dev/mapper/cryptroot resume_offset=${RESUME_OFFSET}"
EOF
#omit resume = and resume_offset if not using Hibernate
```
_If you are using a **Nvidia GPU** the cmdline.conf should look a little different:_
```bash
cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-${LUKS_UUID} root=/dev/mapper/cryptroot \
rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@ \
resume=/dev/mapper/cryptroot resume_offset=${RESUME_OFFSET} \
nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
EOF
```

Parameter explanation:
- rd.luks.uuid=luks-<UUID> _Tells dracut which LUKS2 container to unlock in the initramfs stage. This happens before the root filesystem is mounted._
- root=/dev/mapper/cryptroot _The decrypted device that becomes the root filesystem._
- rootfstype=btrfs _Explicitly sets the filesystem type (required for correct early mount)._
- rootflags=_rw,noatime,compress=zstd,subvol=@_
- resume / resume_offset allows kernel to locate the hibernate image inside the swapfile

create file with flags (`/etc/dracut.conf.d/flags.conf`):

```bash
cat > /etc/dracut.conf.d/flags.conf << 'EOF'
compress="zstd"
hostonly="no"
add_dracutmodules+=" snapshot-menu "
EOF
```
- compress="zstd" → smaller/faster initramfs
- hostonly="no" → more portable initramfs (includes more drivers; slightly bigger)


For Nvidia, additionally (`/etc/dracut.conf.d/nvidia.conf`): Only if you use the proprietary Nvidia driver
```bash
cat > /etc/dracut.conf.d/nvidia.conf << 'EOF'
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF
```


Finally generate the UKI:

```bash
pacman -S linux    # triggers the dracut hook → produces /boot/efi/EFI/Linux/bootx64.efi
```

Optional sanity check:
```bash
ls -lh /boot/efi/EFI/Linux/bootx64.efi
```

---

## systemd-boot

Install to the EFI partition:

```bash
bootctl --esp-path=/boot/efi install
```

Loader config (`/boot/efi/loader/loader.conf`):

```ini
default arch.conf
timeout 0
console-mode auto
editor no
```

`timeout 0` = instant boot, no systemd-boot menu visible. Hold `Space` during power-on to access the systemd-boot menu manually if needed (e.g. to boot a USB stick).

Boot entry (`/boot/efi/loader/entries/arch.conf`):

```ini
title   Arch Linux
efi     /EFI/Linux/bootx64.efi
```

The snapshot selection happens inside the UKI initramfs after LUKS unlock — systemd-boot itself stays completely out of the way.

---

## Hibernate configuration (optional, requires the offset to be set before)

Tell systemd to always hibernate (suspend-to-disk) instead of suspend-to-RAM. The hibernate image is written to the encrypted swapfile and read back after the next LUKS unlock.

```bash
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/hibernate.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=yes
AllowHybridSleep=no
AllowSuspendThenHibernate=no
HibernateMode=shutdown
EOF
```

Allow wheel users to hibernate without a sudo password:

```bash
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/10-hibernate.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF
```

To hibernate: `systemctl hibernate` — or bind it to a key in Hyprland.

---

## Autologin (optional)

Logs the user into tty1 automatically after boot. The disk is still LUKS-encrypted — autologin only skips the user password prompt after LUKS is unlocked. Suitable for a desktop that stays home; optional on a laptop.

```bash
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a yourusername --noclear %I $TERM
EOF
```

--- 


## SecureBoot (optional)

Enable Setup Mode in BIOS first.

```bash
pacman -S sbctl
sbctl create-keys
sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
```

Tell dracut to sign the UKI automatically (`/etc/dracut.conf.d/secureboot.conf`):

```bash
uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
```

Pacman hook to re-sign after every kernel update (`/etc/pacman.d/hooks/zz-sbctl.hook`):

```ini
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = boot/*
Target = efi/*
Target = usr/lib/modules/*/vmlinuz
Target = usr/lib/initcpio/*
Target = usr/lib/**/efi/*.efi*
[Action]
Description = Signing EFI binaries...
When = PostTransaction
Exec = /usr/bin/sbctl sign /boot/efi/EFI/Linux/bootx64.efi
```

After reboot:

```bash
# In BIOS: enable Setup Mode, clear existing keys
sbctl enroll-keys --microsoft    # drop --microsoft if no Windows / no MS drivers needed
# In BIOS: enable Secure Boot (UEFI-only), set BIOS password
sbctl status                     # verify
```

---

## Reboot

```bash
exit           # leave chroot
umount -R /mnt
cryptsetup close cryptroot
reboot
```

---

## After first boot

```bash
# As your user:
bash ~/post-install.sh
# → installs yay, AUR packages, sets zsh as default shell

# Restore dotfiles
cd ~/dotfiles && stow *

# Restore NM VPN configs from Borg backup
sudo cp /path/to/restored/*.nmconnection /etc/NetworkManager/system-connections/
sudo chmod 600 /etc/NetworkManager/system-connections/*
sudo systemctl restart NetworkManager
```

---

## Working with snapshots

```bash
# List all snapshots
snapper -c root list

# Create a manual snapshot
snapper -c root create --description "before risky change"

# Undo specific file changes back to a snapshot (running system)
snapper -c root undochange SNAP_NUMBER..0

# Full rollback from running system (marks snapshot as default, survives reboot)
snapper -c root rollback SNAP_NUMBER
reboot

# Emergency rollback from live ISO (system won't boot at all)
cryptsetup open /dev/nvme0n1p2 cryptroot
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
ls /mnt/@snapshots/                              # find your snapshot ID
btrfs subvolume set-default \
  /mnt/@snapshots/NUMBER/snapshot /dev/mapper/cryptroot
umount /mnt && reboot
# After confirming stable: snapper -c root rollback to make it permanent
```

`snap-pac` creates pre/post snapshots automatically around every pacman transaction — no manual intervention needed for normal use.
