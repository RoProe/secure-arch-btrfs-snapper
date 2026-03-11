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

## Prerequisites & Notes

- UEFI system (no legacy BIOS)
- BIOS allows enrolling custom SecureBoot keys (if using SecureBoot)
- **If using Secure Boot: enable Setup Mode in BIOS when rebooting the first time**

- I will heavily use cat and sed for editing files since the goal is to create a scriptable installer. In most cases creating and editing the files would be preferred in a manual install context.

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

For partitioning you can use your favourite tool that supports creating GPT partitions. I use sgdisk, since it can be easily reused in scripts.

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
 - _var_log for logs since they should survive rollbacks

---

## Partitioning
Example with sgdisk and assuming you want to format your nvme0n1
Note the naming difference: HDDs/SATA SSDs use sdX (partitions: sda1, sda2, ...),
NVMe SSDs use nvmeXnY (partitions: nvme0n1p1, nvme0n1p2, ...)

First delete all partition tables on the drive
```bash
sgdisk --zap-all /dev/nvme0n1
```

Next create two partitions, first with type EFI and 1G in size, the other LUKS for the entire rest of the disk.
```bash
sgdisk -n 1:0:+1024MiB -t 1:EF00 -c 1:"EFI"  /dev/nvme0n1
sgdisk -n 2:0:0        -t 2:8309 -c 2:"LUKS" /dev/nvme0n1
```

Inform kernel about new partitions
```bash
partprobe /dev/nvme0n1
```

Format the EFI partition:
```bash
mkfs.fat -F32 /dev/nvme0n1p1
```

---

## LUKS2
Create the encrypted volume and open it:
```bash
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
cryptsetup open --allow-discards --persistent /dev/nvme0n1p2 cryptroot
```

`--allow-discards` enables SSD TRIM through the encrypted layer. `--persistent` saves this flag in the LUKS2 header.
cryptroot is the name of the device (/dev/mapper/cryptroot)

---

## Btrfs filesystem
Create the btrfs filesystem on the encrypted device. Mount it to /mnt so we can create subvolumes. Unmount it afterwards so we can mount them with the correct options.
```bash
mkfs.btrfs /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@swap

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
# Swap with disabled CoW (Copy on Write) and without compression
mount -o noatime,nodatacow,nodatasum,compress=no,subvol=@swap /dev/mapper/cryptroot /mnt/swap
# EFI
mount /dev/nvme0n1p1 /mnt/boot/efi
```

- `noatime` — skip access timestamp writes. Fewer SSD writes.
- `compress=zstd` — transparent compression, typically 20–40% space saving.
- `nodatacow` on `@swap` — required for hibernate correctness (see above).

---

## Swapfile and hibernate

The swapfile lives inside LUKS — fully encrypted. No separate swap partition needed.

```bash
touch /mnt/swap/swapfile
chattr +C /mnt/swap/swapfile          # disables CoW at file level
fallocate -l 16G /mnt/swap/swapfile   # adjust to your RAM size
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile
```

Get the resume offset — needed for the kernel command line:

```bash
btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile
# example output: 1234567
```

__Note this number.__ At boot, after LUKS is unlocked, the kernel uses it to locate the hibernate image inside the swapfile. We will call it RESUME_OFFSET further down

---

## System bootstrapping
First initialize and populate the keyring 
```bash
pacman-key --init
pacman-key --populate
```

**IMPORTANT**: Change _YOUR_UCODE_PACKAGE_ to either intel-ucode or amd-ucode, depending on your cpu !
```bash
pacstrap /mnt base linux-firmware linux-headers YOUR_UCODE_PACKAGE sudo vim dracut sbsigntools iwd git efibootmgr binutils networkmanager pacman btrfs-progs snapper man-db
```
Why those packages?
- base: minimal arch base-system
- linux-firmware: firmware for hardware
- linux-headers: kernel-headers for DKMS / Modules
- YOUR_UCODE_PACKAGE: Microcode Updates for cpu
- sudo: permissions and privilege management
- vim: editing
- dracut: initramfs-Generator
- sbsigntools: Secure Boot Signing
- iwd: wifi daemon
- git: versioning and maybe later for building AUR helper
- efibootmgr: manage boot entries
- binutils: compiler helper tools, linker and assembler tools, required by dracut
- networkmanager: manage wired or wifi connections
- pacman: arch package manager
- btrfs-progs: btrfs tools
- snapper: snapshot management
- man-db: manuals are always nice to have

dracut's i18n module runs during kernel installation and reads locale/keymap settings at that moment. We configure them here, before pacstrap linux, so the initramfs is built with the correct settings from the start.
Change for the locale and keymap you want to use during setup.

```bash
sed -i -E "s|^[#[:space:]]*("de_DE.UTF-8"[[:space:]].*)$|\1|" /mnt/etc/locale.gen  # uncomments the desired locale in locale.gen 
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/20-i18n.conf << 'EOF'
i18n_vars="LANG LC_ALL LC_CTYPE LC_MESSAGES"
keymap="de-latin1"
EOF
```

Now we can install the kernel
```bash
pacstrap /mnt linux
```

Generate fstab:
```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Before we switch to chroot we want to note the UUID of the LUKS-Partition. Change nvme0n1p2 for your partition. 
```bash
blkid -s UUID -o value /dev/nvme0n1p2 
# example output: XXXXXXXX-...
```
__Note this number.__ We will need it later for cmdline.conf. We will call it LUKS_UUID further down

Now we can chroot into the system to perform the basic configuration
```bash
arch-chroot /mnt
```

---

## Basic system configuration (inside chroot)

Set root password:
```bash
passwd
```
Update:
```bash
pacman -Syu
```
Set timezone and generate /etc/adjtime: __Adjust to your preference__
```bash
ln -sf /usr/share/zoneinfo/<Region>/<city> /etc/localtime
hwclock --systohc
```
```bash
# Enable locale
locale-gen

# Set system locale
echo "LANG=de_DE.UTF-8" > /etc/locale.conf

# Console keyboard layout
echo "KEYMAP=de-latin1" > /etc/vconsole.conf
```


Set your hostname:
```bash
echo "yourhostname" > /etc/hostname
```

Create your user and add to wheel group:
```bash
useradd -m -G wheel YOUR_NAME
passwd YOUR_NAME
```

Activate sudo for wheel users:
```bash
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
```

Activate autologin for your user (so you don't need to type two passwords for boot and LUKS decryption)
Since LUKS already requires a passphrase at boot, a second login password is redundant on a single-user machine
```bash
mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a YOUR_NAME --noclear %I \$TERM
EOF
```

Install basic packages for functioning hyprland setup
```bash
pacman -S --noconfirm --needed neovim zsh kitty pipewire pipewire-pulse btop network-manager-applet hyprland bluez ufw power-profiles-daemon syncthing
```


Enable basic systemd units:
```bash
systemctl enable --no-reload bluetooth  
systemctl enable --no-reload ufw  
systemctl enable --no-reload power-profiles-daemon 
systemctl enable --no-reload syncthing@YOUR_NAME.service
systemctl enable --no-reload NetworkManager
systemctl enable --no-reload fstrim.timer  
```

## Prepare Hibernate

Activate Hibernate:
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

Suspend-to-RAM is intentionally disabled. RAM content is not encrypted and 
could be extracted via cold boot attack. Hibernate writes everything to the 
swapfile inside LUKS — fully encrypted at rest.



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
By default, systemd requires root to hibernate. This polkit rule allows wheel users to hibernate without sudo.

## Dracut 

Since we use dracut, we need pacman hooks that rebuild the UKI after kernel updates

```bash
mkdir -p /usr/local/bin /etc/pacman.d/hooks
```

Reads the kernel version from pacman's file list and builds a UKI at /boot/efi/EFI/Linux/bootx64.efi
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
```

Removes the UKI when the kernel is uninstalled:
```bash
cat > /usr/local/bin/dracut-remove.sh << 'EOF'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
EOF
```

make both executable
```bash
chmod +x /usr/local/bin/dracut-install.sh /usr/local/bin/dracut-remove.sh
```

Pacman hook — triggers `dracut-install.sh` after every kernel install or upgrade:
```bash
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
```

Pacman hook — triggers `dracut-remove.sh` before kernel removal:
```bash
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


__Attention! Here you need both values from before - your LUKS_UUID as well as your RESUME_OFFSET__
Double-check both UUIDs before proceeding.
Kernel command line passed into the UKI — tells the kernel where LUKS, root, and the hibernate image are.
In case you don't have the values: 
- LUKS_UUID = blkid -s UUID -o value /dev/nvme0n1p2
- RESUME_OFFSET = btrfs inspect-internal map-swapfile -r /swap/swapfile
```bash
cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-LUKS_UUID root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@ resume=/dev/mapper/cryptroot resume_offset=RESUME_OFFSET"
EOF
```

Global dracut build flags — `hostonly=yes` builds a smaller initramfs with only drivers needed for this machine, `snapshot-menu` enables the initramfs snapshot selection menu (as configured in the next section)
```bash
cat > /etc/dracut.conf.d/flags.conf << 'EOF'
compress="zstd"
hostonly="yes"
add_dracutmodules+=" snapshot-menu "
EOF
```
hostonly=yes builds a smaller initramfs with only drivers needed for this specific hardware.

### Note on Nvidia GPUs:
In case you are using an nvidia GPU, the cmdline.conf needs more attributes. Note the added nvidia_drm.modeset and nvidia_drm.fbdev
```bash
cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-LUKS_UUID root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@ resume=/dev/mapper/cryptroot resume_offset=RESUME_OFFSET nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
EOF
```

Also create a dracut config so the Nvidia modules are loaded early in the initramfs:
```bash
cat > /etc/dracut.conf.d/nvidia.conf << 'EOF'
force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF
```


__If you use a modern (RTX 20xx / GTX 1650) Nvidia GPU you can now install your drivers. If not refer to the arch manual and install the corresponding legacy driver later in the live system via your chosen AUR helper.__

To check which model GPU you have:
```bash
lspci -k -d ::03xx
```

If you have a RTX 20xx or newer (or GTX 1650):
```bash
pacman -S nvidia-open-dkms
```

If you have an older GPU that needs legacy drivers via AUR: After first boot we will configure an AUR helper, install the correct drivers, and add the required Nvidia parameters to the Hyprland config — see the Hyprland section below.

---

## Snapper
We create the Snapper config manually instead of using `snapper create-config` since the automatic command creates a new Btrfs subvolume at `/.snapshots` which conflicts with our already-mounted `@snapshots` subvolume from fstab.

Create a Snapper configuration named "root" for the filesystem mounted at /
```bash
mkdir -p /etc/snapper/configs
```

```bash
cat > /etc/snapper/configs/root << 'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS="wheel"
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="6"
TIMELINE_LIMIT_YEARLY="2"
EOF
```

Set permissions on the snapshots directory.
```bash
chmod 750 /.snapshots
chown :wheel /.snapshots
```

Install `snap-pac` — automatically creates pre/post snapshots around every pacman transaction and enable snapshot timeline and cleanup.
```bash
pacman -S --noconfirm snap-pac
systemctl enable --no-reload snapper-timeline.timer snapper-cleanup.timer
```


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

Pressing `s` shows a numbered list of available snapshots (newest first). Selecting one mounts `@snapshots/N/snapshot` as root instead of `@`.

### Option A — curl from repo (recommended):
```bash
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu
curl -o /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh   https://raw.githubusercontent.com/TODO
curl -o /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-menu.sh  https://raw.githubusercontent.com/TODO
curl -o /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-rewrite.sh https://raw.githubusercontent.com/TODO
curl -o /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-rewrite.service https://raw.githubusercontent.com/TODO
chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/{module-setup.sh,snapshot-menu.sh,snapshot-rewrite.sh}
```

### Option B — manual 
create directory
```bash
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu
```

`module-setup.sh`: tells dracut what to bundle into the initramfs: registers `snapshot-menu.sh` as a pre-mount hook, installs `snapshot-rewrite.sh` and its systemd service, and pulls in all required binaries.
```bash
cat > /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh << 'EOF'
#!/usr/bin/env bash
check()   { return 0; }
depends() { echo "btrfs"; }
install() {
    inst_hook pre-mount 05 "$moddir/snapshot-menu.sh"
    inst_script "$moddir/snapshot-rewrite.sh" /usr/bin/snapshot-rewrite
    inst_simple "$moddir/snapshot-rewrite.service" /usr/lib/systemd/system/snapshot-rewrite.service
    inst_multiple btrfs awk sed cat find mount umount touch sort head cut tee systemctl
    
    ln_r /usr/lib/systemd/system/snapshot-rewrite.service \
         /usr/lib/systemd/system/initrd.target.wants/snapshot-rewrite.service
}
EOF
```

`snapshot-rewrite.sh`: reads `/run/rootflags-override` and dynamically rewrites `sysroot.mount` with the selected snapshot's subvolume path before systemd mounts root.
```bash
cat > /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-rewrite.sh << 'EOF'
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
EOF
```

`snapshot-rewrite.service`: systemd unit that runs `snapshot-rewrite.sh` inside the initramfs, ordered after LUKS unlock and before `sysroot.mount`
```bash
cat > /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-rewrite.service << 'EOF'
[Unit]
Description=Snapshot sysroot.mount rewrite
DefaultDependencies=no
After=dracut-pre-mount.service
Before=sysroot.mount
ConditionPathExists=/run/rootflags-override

[Service]
Type=oneshot
ExecStart=/usr/bin/snapshot-rewrite
RemainAfterExit=yes

[Install]
WantedBy=initrd.target
EOF
```

`snapshot-menu.sh`: runs at pre-mount stage after LUKS is open. Mounts the raw Btrfs volume, reads Snapper's `info.xml` files to build the snapshot list, and presents the interactive menu. If a snapshot is selected, it writes the target subvolume path to `/run/rootflags-override`.
```bash
cat > /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-menu.sh << 'EOF'
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
EOF
```

Make the scripts executable:
```bash
chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/{module-setup.sh,snapshot-menu.sh,snapshot-rewrite.sh}
```


---

## SecureBoot
Make sure your BIOS supports custom key enrollment and can enter setup mode (see Prerequisites).

Install sbctl and generate personal Secure Boot keys
```bash
pacman -S --noconfirm sbctl
sbctl create-keys
```

Tell dracut to automatically embed the keys when building the UKI.
```bash
cat > /etc/dracut.conf.d/secureboot.conf << 'EOF'
uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
EOF
```

pacman hook: re-signs the UKI after every kernel update. `-s` saves the path to sbctl's database so `sbctl sign-all` can re-sign it too.
```bash
cat > /etc/pacman.d/hooks/zz-sbctl.hook << 'EOF'
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
Exec = /usr/bin/sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
EOF
```

You need to enter SetupMode in BIOS after reboot, see Chapter ##After first Boot .

---

## UKI

Trigger the pacman hook by reinstalling the kernel — this tests the hook and builds the UKI in one step.
```bash
pacman -S linux
```
If successful, `/boot/efi/EFI/Linux/bootx64.efi` should now exist.
```bash
ls -lh /boot/efi/EFI/Linux/bootx64.efi
```

Generate Boot-entry - set to your desired Disk
```root
efibootmgr --create --disk /dev/nvme0n1 --part 1 --label "Arch Linux" --loader "EFI\Linux\bootx64.efi"
```


---

## Reboot

```bash
exit           # leave chroot
swapoff /mnt/swap/swapfile
umount -R /mnt
cryptsetup close cryptroot
reboot
```

---

## After first boot

### When using SecureBoot
After reboot, enter BIOS Setup Mode and clear existing keys, then boot into System.
```bash
sbctl enroll-keys --microsoft    # drop --microsoft if no Windows / no MS drivers needed
sbctl status                     # verify
```
Then reboot, enable Secure Boot in BIOS and set a BIOS password.

Verify after reboot.
```bash
sbctl status    # should show: Secure Boot: enabled
```

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
