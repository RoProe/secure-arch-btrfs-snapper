#!/usr/bin/env bash
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }

# ── passwords ─────────────────────────────────────────────────────────────────
echo "Set ROOT password:"
passwd

# ── timezone & clock ──────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# ── locale ────────────────────────────────────────────────────────────────────
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# ── vconsole ──────────────────────────────────────────────────────────────────
printf 'KEYMAP=${KEYMAP}\n' > /etc/vconsole.conf

# ── hostname ──────────────────────────────────────────────────────────────────
echo "${HOSTNAME}" > /etc/hostname

# ── user ──────────────────────────────────────────────────────────────────────
useradd -m -G wheel "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── autologin (optional) ──────────────────────────────────────────────────────
$(if $ENABLE_AUTOLOGIN; then cat << ALEOF
info "Configuring autologin..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << AUTOEOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a ${USERNAME} --noclear %I \$TERM
AUTOEOF
ALEOF
fi)

# ── services ──────────────────────────────────────────────────────────────────
systemctl enable NetworkManager
systemctl enable fstrim.timer
systemctl enable bluetooth             2>/dev/null || true
systemctl enable ufw                   2>/dev/null || true
systemctl enable power-profiles-daemon 2>/dev/null || true
systemctl enable syncthing@${USERNAME}.service 2>/dev/null || true

# ── hibernate config (suspend-to-disk via swapfile) ───────────────────────────
$(if $ENABLE_SWAP; then cat << 'HIBEOF'
info "Configuring hibernate..."

# Override systemd sleep defaults to always hibernate, never suspend-to-RAM.
# This means closing the lid or running 'systemctl hibernate' writes RAM to
# the encrypted swapfile and powers off. On next boot LUKS is unlocked first,
# then the kernel reads the hibernate image from the swapfile.
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/hibernate.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=yes
AllowHybridSleep=no
AllowSuspendThenHibernate=no
HibernateMode=shutdown
EOF

# Allow wheel users to hibernate without sudo password via polkit
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

success "Hibernate configured. Use: systemctl hibernate"
HIBEOF
fi)

# ── snapper ───────────────────────────────────────────────────────────────────
snapper -c root create-config /
# Snapper auto-creates /.snapshots as a new subvolume, but we already have
# @snapshots mounted there. Delete it and restore the correct mount point.
btrfs subvolume delete /.snapshots 2>/dev/null || true
mkdir -p /.snapshots
chmod 750 /.snapshots
chown :wheel /.snapshots

# ── install user packages ─────────────────────────────────────────────────────
info "Installing selected packages..."
pacman -S --noconfirm --needed ${ALL_PKGS}

# ── dracut hook scripts ───────────────────────────────────────────────────────
mkdir -p /usr/local/bin /etc/pacman.d/hooks

cat > /usr/local/bin/dracut-install.sh << 'EOF'
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
kver="$(ls -1 /usr/lib/modules | sort -V | tail -n1)"
dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
EOF

cat > /usr/local/bin/dracut-remove.sh << 'EOF'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
EOF

chmod +x /usr/local/bin/dracut-install.sh /usr/local/bin/dracut-remove.sh

# ── pacman hooks for dracut ───────────────────────────────────────────────────
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

# ── dracut config ─────────────────────────────────────────────────────────────
mkdir -p /etc/dracut.conf.d

cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-${LUKS_UUID} root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@${RESUME_ARGS}"
EOF

cat > /etc/dracut.conf.d/flags.conf << 'EOF'
compress="zstd"
hostonly="no"
add_dracutmodules+=" snapshot-menu "
EOF

$(if [[ "$GPU_CHOICE" == nvidia* ]]; then cat << 'NVEOF'
# ── Nvidia dracut config ──────────────────────────────────────────────────────
cat > /etc/dracut.conf.d/nvidia.conf << 'EOF'
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF
# Wayland requires DRM modesetting; fbdev needed for early KMS
sed -i 's/"$/ nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/dracut.conf.d/cmdline.conf

cat > /etc/pacman.d/hooks/nvidia-dracut.hook << 'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = nvidia-dkms

[Action]
Description = Rebuilding UKI for nvidia driver update...
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
EOF
NVEOF
fi)

# ── post-LUKS snapshot menu — dracut module ───────────────────────────────────
#
# Two-hook design:
#   1. snapshot-menu.sh  — initqueue/settled: shows menu after LUKS unlock,
#                          writes rootflags-override if a snapshot was chosen.
#   2. apply-rootflags.sh — pre-mount: reads rootflags-override and exports
#                           $rootflags so dracut's mount step uses the snapshot.
#
info "Installing post-LUKS snapshot menu dracut module..."
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu

cat > /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh << 'EOF'
#!/usr/bin/env bash
check()   { return 0; }
depends() { echo "btrfs"; }
install() {
    inst_hook initqueue/settled 50 "\$moddir/snapshot-menu.sh"
    inst_hook pre-mount         10 "\$moddir/apply-rootflags.sh"
    inst_multiple btrfs awk sed cat find mount umount
}
EOF
chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh

cat > /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-menu.sh << 'MENUEOF'
#!/usr/bin/env bash
# Post-LUKS snapshot menu — runs in initramfs after LUKS unlock.
set -u

BTRFS_DEV="/dev/mapper/cryptroot"
BTRFS_MNT="/run/btrfs-root"
DONE_FLAG="/run/snapshot-menu-done"
OVERRIDE_FILE="/run/initramfs/rootflags-override"

# Only run once per boot (dracut hooks can be hit multiple times)
if [ -f "\$DONE_FLAG" ]; then
  exit 0
fi
touch "\$DONE_FLAG"

# Mount the top-level Btrfs volume (subvolid=5 = top-level; all subvolumes visible)
mkdir -p "\$BTRFS_MNT"
if ! mount -o subvolid=5 "\$BTRFS_DEV" "\$BTRFS_MNT" 2>/dev/null; then
  exit 0  # LUKS not open yet or not Btrfs — skip silently
fi

# Gather snapshots from @snapshots/*/info.xml (Snapper format)
declare -a SNAP_IDS=()
declare -a SNAP_LABELS=()

# Helper: extract simple XML tag content without PCRE grep (-P)
xml_tag() {
  # \$1 = tag, \$2 = file
  sed -n "s|.*<\$1>\\([^<]*\\)</\$1>.*|\\1|p" "\$2" | head -n1
}

# Find info.xml files, sort newest snapshot IDs first, take first 20
while IFS= read -r info; do
  num="\$(echo "\$info" | sed -n 's|.*/@snapshots/\\([0-9][0-9]*\\)/info\\.xml\$|\\1|p')"
  [ -n "\$num" ] || continue
  snap_subvol="\$BTRFS_MNT/@snapshots/\${num}/snapshot"
  [ -d "\$snap_subvol" ] || continue
  desc="\$(xml_tag description "\$info")"
  [ -n "\$desc" ] || desc="—"
  date="\$(xml_tag date "\$info" | awk '{print \$1}')"
  stype="\$(xml_tag type "\$info")"
  SNAP_IDS+=("\$num")
  SNAP_LABELS+=("\${date} [\${stype}] \${desc}")
done < <(
  find "\$BTRFS_MNT/@snapshots" -name "info.xml" 2>/dev/null \
    | sed -n 's|.*/@snapshots/\([0-9]\+\)/info\.xml$|\1 &|p' \
    | sort -nr \
    | head -20 \
    | cut -d' ' -f2-
)

umount "\$BTRFS_MNT" 2>/dev/null || true

# No snapshots yet — skip menu entirely on first boot
if [ \${#SNAP_IDS[@]} -eq 0 ]; then
  exit 0
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

if [[ "\$KEY" != "s" && "\$KEY" != "S" ]]; then
  echo "Booting normally..."
  exit 0
fi

# Show numbered snapshot list
echo ""
echo "  Available snapshots (newest first):"
echo ""
for i in "\${!SNAP_IDS[@]}"; do
  printf "  %3s)  %s\n" "\${SNAP_IDS[\$i]}" "\${SNAP_LABELS[\$i]}"
done
echo ""
echo "    0)  Normal boot (cancel)"
echo ""
read -r -p "  Enter snapshot number: " CHOICE

if [[ "\$CHOICE" == "0" || -z "\$CHOICE" ]]; then
  echo "Booting normally..."
  exit 0
fi

# Validate choice
VALID=false
for id in "\${SNAP_IDS[@]}"; do
  [[ "\$id" == "\$CHOICE" ]] && VALID=true && break
done

if ! \$VALID; then
  echo "Invalid selection — booting normally."
  exit 0
fi

# Write the chosen subvolume path for the later root mount step
SNAP_SUBVOL="@snapshots/\${CHOICE}/snapshot"
echo "Booting snapshot \${CHOICE}: \${SNAP_SUBVOL}"
mkdir -p "\$(dirname "\$OVERRIDE_FILE")"
echo "rw,noatime,compress=zstd,subvol=\${SNAP_SUBVOL}" > "\$OVERRIDE_FILE"
exit 0
MENUEOF
chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-menu.sh

cat > /usr/lib/dracut/modules.d/99snapshot-menu/apply-rootflags.sh << 'EOF'
#!/usr/bin/env bash

OVERRIDE_FILE="/run/initramfs/rootflags-override"

# If no override was written by snapshot-menu.sh, do nothing
[ -f "\$OVERRIDE_FILE" ] || exit 0

# Export rootflags so dracut's mount step picks up the snapshot subvolume
rootflags="\$(cat "\$OVERRIDE_FILE")"
export rootflags

exit 0
EOF
chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/apply-rootflags.sh

success "Snapshot menu module installed."

$(if $ENABLE_SECUREBOOT; then cat << 'SBEOF'
# ── SecureBoot (sbctl) ────────────────────────────────────────────────────────
pacman -S --noconfirm sbctl
sbctl create-keys
# Note: sbctl sign happens AFTER UKI generation below

cat > /etc/dracut.conf.d/secureboot.conf << 'EOF'
uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
EOF

# Override sbctl's default pacman hook to sign our specific UKI path
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
Exec = /usr/bin/sbctl sign /boot/efi/EFI/Linux/bootx64.efi
EOF
SBEOF
fi)

# ── generate UKI (triggers dracut hook) ───────────────────────────────────────
# This reinstalls the linux package which fires 90-dracut-install.hook,
# which calls dracut-install.sh, which runs dracut --uefi to produce bootx64.efi
pacman -S --noconfirm linux

# Initial sign — must happen after UKI exists, before reboot
$(if $ENABLE_SECUREBOOT; then cat << 'SBSIGNEOF'
sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
SBSIGNEOF
fi)

# ── systemd-boot ──────────────────────────────────────────────────────────────
# systemd-boot is a minimal EFI boot manager — it just launches the UKI.
# timeout 0 = instant boot, no menu. Hold Space at power-on to access manually.
# The snapshot selection happens inside the UKI's initramfs after LUKS unlock.
info "Installing systemd-boot..."
bootctl --esp-path=/boot/efi install

mkdir -p /boot/efi/loader/entries

cat > /boot/efi/loader/loader.conf << 'EOF'
default arch.conf
timeout 0
console-mode auto
editor no
EOF

cat > /boot/efi/loader/entries/arch.conf << 'EOF'
title   Arch Linux
efi     /EFI/Linux/bootx64.efi
EOF

success "systemd-boot installed."

# ── post-install script for after first boot ──────────────────────────────────
cat > /home/${USERNAME}/post-install.sh << 'POSTEOF'
#!/usr/bin/env bash
# Run this after first boot as your regular user (not root).
# Installs yay, AUR packages, sets zsh as default shell.
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }

info "Installing yay..."
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay && makepkg -si --noconfirm
cd ~

AUR_LIST="$HOME/aur-packages.txt"
if [[ -f "\$AUR_LIST" && -s "\$AUR_LIST" ]]; then
    mapfile -t AUR_PKGS < "\$AUR_LIST"
    info "Installing AUR packages: \${AUR_PKGS[*]}"
    yay -S --noconfirm "\${AUR_PKGS[@]}"
fi

info "Setting zsh as default shell..."
chsh -s /bin/zsh

success "Post-install complete!"
echo ""
echo "Next steps:"
echo "  1. Restore dotfiles:   cd ~/dotfiles && stow *"
echo "  2. Restore NM VPN configs from Borg backup:"
echo "       sudo cp /path/*.nmconnection /etc/NetworkManager/system-connections/"
echo "       sudo chmod 600 /etc/NetworkManager/system-connections/*"
echo "       sudo systemctl restart NetworkManager"
POSTEOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/post-install.sh
chmod +x /home/${USERNAME}/post-install.sh
success "post-install.sh written to /home/${USERNAME}/"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Chroot setup complete!                                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Exit chroot and run:                                    ║"
echo "║    umount -R /mnt                                        ║"
echo "║    cryptsetup close ${LUKS_NAME}                        ║"
echo "║    reboot                                                ║"
$(if $ENABLE_SECUREBOOT; then
  echo "echo '╠══════════════════════════════════════════════════════════╣'"
  echo "echo '║  After first boot — SecureBoot:                          ║'"
  echo "echo '║    1. Enable Setup Mode in BIOS                          ║'"
  echo "echo '║    2. sbctl enroll-keys ${MICROSOFT_CA:+--microsoft}     ║'"
  echo "echo '║    3. Reboot, enable UEFI Secure Boot, set BIOS password ║'"
fi)
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Then log in as ${USERNAME} and run:                    ║"
echo "║    bash ~/post-install.sh                                ║"
echo "╚══════════════════════════════════════════════════════════╝"
CHROOT_EOF

