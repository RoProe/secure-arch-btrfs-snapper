# arch-install
## DISCLAIMER
This project is a work in progress and under active development.
It has not been extensively tested yet.
Use at your own risk and test in a VM before deploying on real hardware.
Personal Arch Linux installation setup - LUKS2 full-disk encryption, Btrfs with automatic snapshots, post-LUKS snapshot menu, hibernate via encrypted swapfile, systemd-boot + Unified Kernel Image, optional SecureBoot.

Based on [secure-arch](https://github.com/Ataraxxia/secure-arch) by Ataraxxia.



The `00_manual_install.md` file documents the manual installation process in detail and serves as a reference for understanding the automated script.


---

## TL;DR

```
bash install.sh          # TUI guides you through everything
# reboot
bash ~/post-install.sh   # installs yay + AUR packages + sets zsh
# if SecureBoot: enable Setup Mode in BIOS → sbctl enroll-keys --microsoft → reboot
```

**What you get:**

```
UEFI → systemd-boot → LUKS passphrase
     → snapshot menu (5s timeout)
          [Enter]  →  normal boot
          [s]      →  pick a Snapper snapshot → rollback boot
```

- Full LUKS2 disk encryption (Argon2id KDF - no GRUB compromise)
- Btrfs with `zstd` compression + automatic pre/post snapshots on every `pacman` operation
- Snapshot selection menu in the initramfs, after LUKS unlock, before root mount
- Hibernate to encrypted swapfile - RAM state survives power-off, restored after next LUKS unlock
- Optional autologin (disk still encrypted; only skips user password after LUKS)
- Optional SecureBoot with your own keys (sbctl)
- Auto-detected GPU driver (AMD / Intel / Nvidia / hybrid)

**What the script does NOT do:** SecureBoot key enrollment (requires BIOS interaction), restoring dotfiles, restoring NM VPN configs.

---

## Prerequisites

- UEFI system (no legacy BIOS)
- BIOS allows enrolling custom SecureBoot keys (if using SecureBoot)
- Internet on the live ISO (`iwctl` for WiFi)
- Borg backup or dotfile repo ready for post-install restore

---

## Using the install script

### 1. Boot the Arch ISO and connect to the internet

```bash
iwctl
station wlan0 connect YOUR_SSID
exit
ping archlinux.org   # verify
```

### 2. Get the script onto the machine

```bash
# From a USB stick
mount /dev/sdX1 /mnt && cp /mnt/install.sh . && umount /mnt

# Or via curl from a repo
curl -O https://your.repo/install.sh
```

### 3. Run it

```bash
bash install.sh
```

The TUI prompts:

| Step | Notes |
|------|-------|
| Target disk | Selected from auto-detected `lsblk` list |
| CPU vendor | AMD / Intel - determines microcode package |
| Username + hostname | Free text |
| Timezone | Two-step region → city selector, or type manually |
| Locale | Common locales + manual entry |
| Keymap | Common keymaps + manual entry |
| EFI size | Default 1024MiB |
| Swap + hibernate | Detects RAM size, recommends matching swap size |
| Autologin | Skips user password after LUKS unlock on boot |
| SecureBoot | sbctl setup, with or without Microsoft CA |
| GPU | Auto-detected via `lspci` - confirm or override |
| Packages | Per-category checklists, all pre-selected, deselect freely |

After confirming the summary the script is fully automated: partition → LUKS → Btrfs subvolumes → swapfile → pacstrap → chroot config → snapshot menu module → dracut UKI → systemd-boot → done.

### 4. After the script finishes

```bash
umount -R /mnt
cryptsetup close cryptroot
reboot
```

### 5. If SecureBoot was enabled

```bash
# In BIOS: enable Setup Mode, clear existing keys
sbctl enroll-keys --microsoft   # drop --microsoft if no Windows dual-boot
# In BIOS: enable Secure Boot (UEFI-only), set BIOS password
sbctl status                    # verify
```

### 6. Post-install

```bash
bash ~/post-install.sh
# installs yay → AUR packages → sets zsh as default shell
```

### 7. Restore your config

```bash
cd ~/dotfiles && stow *

# NM VPN configs from Borg backup
sudo cp /path/to/restored/*.nmconnection /etc/NetworkManager/system-connections/
sudo chmod 600 /etc/NetworkManager/system-connections/*
sudo systemctl restart NetworkManager
```

---

## What the script sets up - and why

### Disk layout

```
/dev/nvme0n1
├── p1  EFI   (FAT32, 1024MiB, unencrypted)
└── p2  LUKS2 (Argon2id)
         └── Btrfs
              ├── @           →  /
              ├── @home       →  /home
              ├── @snapshots  →  /.snapshots
              ├── @var_log    →  /var/log
              └── @swap       →  /swap  (nodatacow, optional)
```

**Why LUKS2 with Argon2id?** Argon2id is memory-hard - brute-forcing the passphrase requires significant RAM, making offline attacks much slower than with PBKDF2. GRUB cannot use Argon2id because it must decrypt the disk before the OS is loaded. systemd-boot avoids this entirely - it just launches the UKI, and LUKS is unlocked by the initramfs using full Argon2id.

**Why Btrfs instead of ext4 + LVM?** Btrfs subvolumes replace LVM logical volumes with no added complexity. You gain CoW snapshots, `zstd` compression, and data checksums - none of which ext4 offers. Though it should be remarked that zstd brings some cpu overhead, so it isn't really recommendet on old CPUs.

**Why these subvolumes?**

- `@home` : personal data survives system rollbacks. Rolling back a broken update won't undo your files.
- `@snapshots` : separate so Snapper snapshots don't include themselves recursively.
- `@var_log` : logs shouldn't roll back. You want the logs that show *why* something broke.
- `@swap` : CoW must be disabled here. Btrfs CoW makes file offsets non-contiguous, which breaks the kernel's `resume_offset` calculation for hibernate.

### Hibernate via encrypted swapfile

The swapfile lives inside the LUKS volume - it is fully encrypted. `HibernateMode=shutdown` in `systemd-sleep.conf.d` means hibernate powers the machine fully off. On next boot: systemd-boot launches the UKI → LUKS passphrase → kernel reads hibernate image from swapfile (using `resume=` and `resume_offset=` from the kernel command line) → session restored.

`AllowSuspend=no` ensures the system always hibernates, never suspends to RAM - so closing the lid or running `systemctl hibernate` always writes to disk.

### Post-LUKS snapshot menu

The snapshot menu is a custom dracut module bundled into the UKI. It runs in the initramfs after LUKS is unlocked but before root is mounted. It reads Snapper's `info.xml` files directly from the Btrfs volume and presents a numbered list. Selecting a snapshot mounts `@snapshots/N/snapshot` as root instead of `@`.

The 5-second timeout defaults to normal boot - you only see the full list if you press `s`. On the first boot there are no snapshots yet, so the menu is skipped entirely and the system boots straight through.

### systemd-boot

systemd-boot is a minimal EFI boot manager - it reads the `entries/` directory and launches the matching EFI binary. `timeout 0` makes it instant and invisible. The snapshot selection happens after LUKS unlock inside the UKI, not in the bootloader. Hold `Space` at power-on to access the systemd-boot menu manually (useful for booting a USB stick without changing BIOS settings).

### Snapper + snap-pac

`snap-pac` hooks into pacman and creates a **pre** and **post** snapshot around every transaction automatically. No need to think about it. Every `pacman -Syu` is enclosed by snapshots, accessible from the boot menu on the next start.

**Snapper quirk:** When you run `snapper create-config`, Snapper creates its own `.snapshots` subvolume. Since we already have `@snapshots` mounted at `/.snapshots`, this conflicts. The script deletes Snapper's auto-created subvolume and keeps the pre-existing mount. fstab should handle it correctly after reboot.

### GPU drivers

Auto-detected via `lspci`, confirmed in the TUI:

| Selection | Packages installed |
|-----------|--------------------|
| AMD | `vulkan-radeon`, `mesa` |
| Intel | `mesa`, `intel-media-driver` |
| Nvidia | `nvidia-dkms`, `nvidia-utils`, `egl-wayland`, `lib32-nvidia-utils` |
| Hybrid Intel+Nvidia | All of the above for both |
| Hybrid AMD+Nvidia | All of the above for both |

For Nvidia, the script also appends `nvidia_drm.modeset=1 nvidia_drm.fbdev=1` to the kernel command line and adds the Nvidia modules to the initramfs via dracut. A separate pacman hook rebuilds the UKI whenever `nvidia-dkms` updates.

You still need to add Nvidia env vars to your Hyprland config manually (I'm thinking about adding it automatically with a warning that you should remember it when you add your own dotfiles...):

```bash
# ~/.config/hypr/envs.conf
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = WLR_NO_HARDWARE_CURSORS,1
env = NVD_BACKEND,direct
# Optimus hybrid only:
env = AQ_DRM_DEVICES,/dev/dri/card1
```

### SecureBoot with sbctl

sbctl generates Platform Key, Key Exchange Key, and Database Key. UKI is signed with the Database Key. dracut is configured to re-sign the UKI automatically on every rebuild. A pacman hook re-signs after kernel updates. Key enrollment happens after first boot via BIOS Setup Mode - the script sets everything up but cannot enroll keys without physical BIOS access.

### Autologin

Configured via a systemd drop-in for `getty@tty1.service`. The disk is still fully encrypted - autologin only skips the Linux user password prompt after LUKS is unlocked. Practical for a home desktop or laptop that travels seldomly. Remember that you shouldn't let root autologin.

---

## Working with snapshots

```bash
# List all snapshots
snapper -c root list

# Manual snapshot before something risky
snapper -c root create --description "before nginx config change"

# Undo file changes back to a snapshot (running system)
snapper -c root undochange SNAP_NUMBER..0

# Full system rollback (running system, survives reboot)
snapper -c root rollback SNAP_NUMBER
reboot

# Emergency rollback from live ISO (system won't boot)
cryptsetup open /dev/nvme0n1p2 cryptroot
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
ls /mnt/@snapshots/
btrfs subvolume set-default /mnt/@snapshots/NUMBER/snapshot /dev/mapper/cryptroot
umount /mnt
reboot
# After confirming stable, make the rollback permanent:
snapper -c root rollback
```

Automatic pre/post snapshots from `snap-pac` appear in the boot menu on the next startup - no manual action needed for day-to-day use.
