#!/usr/bin/env bash
# chroot_setup.sh 
# runs via arch-chroot in new system and gets variables passed by arch_setup.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── sanity check — ensure required vars were passed ───────────────────────────
: "${USERNAME:?}" "${HOSTNAME:?}" "${TIMEZONE:?}" "${LOCALE:?}" "${KEYMAP:?}"
: "${LUKS_UUID:?}" "${GPU_CHOICE:?}" "${ALL_PKGS:?}" "${AUR_HELPER:-}" "${WEBAPPS:-}"

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
printf "KEYMAP=${KEYMAP}\n" > /etc/vconsole.conf

# ── hostname ──────────────────────────────────────────────────────────────────
echo "${HOSTNAME}" > /etc/hostname

# ── user ──────────────────────────────────────────────────────────────────────
useradd -m -G wheel "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── autologin (optional) ──────────────────────────────────────────────────────
if [[ "${ENABLE_AUTOLOGIN}" == "true" ]] ; then
  info "Configuring autologin..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a ${USERNAME} --noclear %I \$TERM
EOF
fi

# ── services ──────────────────────────────────────────────────────────────────
systemctl enable NetworkManager
systemctl enable fstrim.timer
systemctl enable bluetooth             2>/dev/null || true
systemctl enable ufw                   2>/dev/null || true
systemctl enable power-profiles-daemon 2>/dev/null || true
systemctl enable syncthing@${USERNAME}.service 2>/dev/null || true

# ── hibernate config (suspend-to-disk via swapfile) ───────────────────────────
if [[ "${ENABLE_SWAP}" == "true" ]] ; then
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
fi

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

# ── Nvidia dracut config ──────────────────────────────────────────────────────
if [[ "$GPU_CHOICE" == nvidia* ]] ; then
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
fi

# ── post-LUKS snapshot menu — dracut module ───────────────────────────────────
#
# Two-hook design:
#   1. snapshot-menu.sh  — initqueue/settled: shows menu after LUKS unlock,
#                          writes rootflags-override if a snapshot was chosen.
#   2. apply-rootflags.sh — pre-mount: reads rootflags-override and exports
#                           $rootflags so dracut's mount step uses the snapshot.
#
info "Installing snapshot menu dracut module..."
REPO_RAW="https://raw.githubusercontent.com/RoProe/secure-arch-btrfs-snapper/refs/heads/main"
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu

for f in module-setup.sh snapshot-menu.sh apply-rootflags.sh; do
  curl -fsSL "${REPO_RAW}/dracut/99snapshot-menu/${f}" \
    -o /usr/lib/dracut/modules.d/99snapshot-menu/${f}
  chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/${f}
done
success "Snapshot menu module installed."


# ── WebApps ───────────────────────────────────────────────────────────────────
if [[ -n "${WEBAPPS}" ]]; then
  DESKTOP_DIR="/home/${USERNAME}/.local/share/applications"
  mkdir -p "$DESKTOP_DIR"

  declare -A WEBAPP_URLS=(
    ["github"]="https://github.com"
    ["zoom"]="https://app.zoom.us/wc"
    ["whatsapp"]="https://web.whatsapp.com"
    ["notion"]="https://notion.so"
    ["googlemeet"]="https://meet.google.com"
    ["protonmail"]="https://mail.proton.me"
    ["linear"]="https://linear.app"
    ["figma"]="https://figma.com"
  )

  declare -A WEBAPP_NAMES=(
    ["github"]="GitHub"
    ["zoom"]="Zoom"
    ["whatsapp"]="WhatsApp"
    ["notion"]="Notion"
    ["googlemeet"]="Google Meet"
    ["protonmail"]="Proton Mail"
    ["linear"]="Linear"
    ["figma"]="Figma"
  )

  declare -A WEBAPP_CATEGORIES=(
    ["github"]="Development;"
    ["zoom"]="Network;VideoConference;"
    ["whatsapp"]="Network;InstantMessaging;"
    ["notion"]="Office;"
    ["googlemeet"]="Network;VideoConference;"
    ["protonmail"]="Network;Email;"
    ["linear"]="Office;"
    ["figma"]="Graphics;"
  )

  for app in ${WEBAPPS}; do
    [[ -z "${WEBAPP_URLS[$app]:-}" ]] && continue
    PROFILE_DIR="/home/${USERNAME}/.mozilla/firefox/webapps/${app}"
    mkdir -p "$PROFILE_DIR"

    cat > "${DESKTOP_DIR}/${app}-webapp.desktop" << EOF
[Desktop Entry]
Name=${WEBAPP_NAMES[$app]}
Exec=firefox --profile ${PROFILE_DIR} --new-window ${WEBAPP_URLS[$app]}
Icon=${app}
Type=Application
Categories=${WEBAPP_CATEGORIES[$app]}
StartupNotify=true
StartupWMClass=${WEBAPP_NAMES[$app]}
EOF
    chown -R "${USERNAME}:${USERNAME}" "$PROFILE_DIR"
    chown "${USERNAME}:${USERNAME}" "${DESKTOP_DIR}/${app}-webapp.desktop"
    success "WebApp created: ${WEBAPP_NAMES[$app]}"
  done
fi



# ── SecureBoot (optional) ─────────────────────────────────────────────────────
if [[ "${ENABLE_SECUREBOOT}" == "true" ]]; then
  pacman -S --noconfirm sbctl
  sbctl create-keys

  cat > /etc/dracut.conf.d/secureboot.conf << 'EOF'
uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
EOF

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
fi



# ── generate UKI (triggers dracut hook) ───────────────────────────────────────
# This reinstalls the linux package which fires 90-dracut-install.hook,
# which calls dracut-install.sh, which runs dracut --uefi to produce bootx64.efi
pacman -S --noconfirm linux

# Initial sign — must happen after UKI exists, before reboot
if [[ "$ENABLE_SECUREBOOT" == "true" ]] ; then
  sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
fi

# ── systemd-boot ──────────────────────────────────────────────────────────────
# systemd-boot is a minimal EFI boot manager - it just launches the UKI.
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

# ── AUR setup ─────────────────────────────────────────────────────────────────
if [[ -n "${PKGS_AUR:-}" ]] && [[ -n "${AUR_HELPER:-}" ]]; then
  echo "${PKGS_AUR}" | tr ' ' '\n' | grep -v '^$' > /home/${USERNAME}/aur-packages.txt
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/aur-packages.txt

  cat > /home/${USERNAME}/post-install.sh << EOF
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }

info "Installing ${AUR_HELPER}..."
cd /tmp
git clone https://aur.archlinux.org/${AUR_HELPER}.git
cd ${AUR_HELPER}
makepkg -si --noconfirm
cd /tmp && rm -rf ${AUR_HELPER}

AUR_LIST="\$HOME/aur-packages.txt"
if [[ -f "\$AUR_LIST" && -s "\$AUR_LIST" ]]; then
  mapfile -t AUR_PKGS < "\$AUR_LIST"
  info "Installing AUR packages: \${AUR_PKGS[*]}"
  ${AUR_HELPER} -S --noconfirm "\${AUR_PKGS[@]}"
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
EOF
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/post-install.sh
  chmod +x /home/${USERNAME}/post-install.sh
  success "post-install.sh written to /home/${USERNAME}/"
else
  # no AUR - but we still want zsh
  cat > /home/${USERNAME}/post-install.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }

info "Setting zsh as default shell..."
chsh -s /bin/zsh

success "Post-install complete!"
echo ""
echo "Next steps:"
echo "  1. Restore dotfiles:   cd ~/dotfiles && stow *"
EOF
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/post-install.sh
  chmod +x /home/${USERNAME}/post-install.sh
  success "post-install.sh written to /home/${USERNAME}/"
fi

# ──── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Chroot setup complete!                                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Exit chroot and run:                                    ║"
echo "║    umount -R /mnt                                        ║"
echo "║    cryptsetup close ${LUKS_NAME}                        ║"
echo "║    reboot                                                ║"
echo "╠══════════════════════════════════════════════════════════╣"
if [[ "${ENABLE_SECUREBOOT}" == "true" ]]; then
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  After first boot — SecureBoot:                          ║"
  echo "║    1. Enable Setup Mode in BIOS                          ║"
  if [[ "${MICROSOFT_CA}" == "true" ]]; then
    echo "║    2. sbctl enroll-keys --microsoft                      ║"
  else
    echo "║    2. sbctl enroll-keys                                  ║"
  fi
  echo "║    3. Reboot, enable UEFI Secure Boot, set BIOS password ║"
fi
echo "║  Then log in as ${USERNAME} and run:                    ║"
echo "║    bash ~/post-install.sh                                ║"
echo "╚══════════════════════════════════════════════════════════╝"

