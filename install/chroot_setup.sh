#!/usr/bin/env bash
# chroot_setup.sh runs via arch-chroot in new system and gets variables passed by arch_setup.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
WARNINGS=()
warn() { 
  echo -e "${YELLOW}[WARN]${NC} $*"
  WARNINGS+=("$*")
}
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── sanity check — ensure required vars were passed ───────────────────────────
: "${USERNAME:?}" "${HOSTNAME:?}" "${TIMEZONE:?}" "${LOCALE:?}" "${KEYMAP:?}"
: "${LUKS_UUID:?}" "${GPU_CHOICE:?}" "${ALL_PKGS:?}" "${AUR_HELPER:-}" "${WEBAPPS:-}"
: "${ENABLE_AUTOLOGIN:?}" "${ENABLE_SWAP:?}" "${ENABLE_SECUREBOOT:?}" "${MICROSOFT_CA:?}"
: "${ENABLE_LTS:?}" "${PKGS_AUR:-}" "${DISK:?}"

# ── passwords ─────────────────────────────────────────────────────────────────
echo "Set ROOT password:"
passwd < /dev/tty

# ── timezone & clock ──────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# ── locale ────────────────────────────────────────────────────────────────────
# set also before in chroot
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
passwd "${USERNAME}" < /dev/tty
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── autologin (optional) ──────────────────────────────────────────────────────
if $ENABLE_AUTOLOGIN ; then
  info "Configuring autologin..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a ${USERNAME} --noclear %I \$TERM
EOF
fi

# ── install user packages ─────────────────────────────────────────────────────
info "Installing selected packages..."
read -ra PKG_ARRAY <<< "$ALL_PKGS"
pacman -S --noconfirm --needed "${PKG_ARRAY[@]}"

# ── activate services ────────────────────────────────────────────
systemctl enable --no-reload bluetooth                     || warn "bluetooth not available"
systemctl enable --no-reload ufw                           || warn "ufw not available"
systemctl enable --no-reload power-profiles-daemon         || warn "power-profiles-daemon not available"
systemctl enable --no-reload syncthing@${USERNAME}.service || warn "syncthing not available"
systemctl enable --no-reload NetworkManager                || die "NetworkManager can't be activate"
systemctl enable --no-reload fstrim.timer                  || die "fstrim.timer can't be activated"


# ── hibernate config (suspend-to-disk via swapfile) ───────────────────────────
if $ENABLE_SWAP ; then
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

# ── dracut hook scripts ───────────────────────────────────────────────────────
# depending on active pkgbase chooses correct outfile in dracut-install or file to remove in dracut.remove
mkdir -p /usr/local/bin /etc/pacman.d/hooks

cat > /usr/local/bin/dracut-install.sh << 'EOF'
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
    if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="${line#'usr/lib/modules/'}"
        kver="${kver%'/pkgbase'}"
        pkgbase=$(cat "/usr/lib/modules/${kver}/pkgbase")
        if [[ "$pkgbase" == "linux-lts" ]]; then
          dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64-lts.efi
        else
          dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
        fi
    fi
done
EOF

cat > /usr/local/bin/dracut-remove.sh << 'EOF'
#!/usr/bin/env bash
while read -r line; do
    if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="${line#'usr/lib/modules/'}"
        kver="${kver%'/pkgbase'}"
        pkgbase=$(cat "/usr/lib/modules/${kver}/pkgbase")
        if [[ "$pkgbase" == "linux-lts" ]]; then
            rm -f /boot/efi/EFI/Linux/bootx64-lts.efi
        else
            rm -f /boot/efi/EFI/Linux/bootx64.efi
        fi
    fi
done
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
hostonly="yes"
add_dracutmodules+=" snapshot-menu "
EOF

# ── Nvidia dracut config ──────────────────────────────────────────────────────
if [[ "$GPU_CHOICE" == nvidia || "$GPU_CHOICE" == hybrid-nvidia* ]]; then
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
Target = nvidia-open-dkms

[Action]
Description = Rebuilding UKI for nvidia driver update...
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
EOF
fi

if [[ "$GPU_CHOICE" == "nvidia-legacy" ]]; then
  cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

  # prepare dracut cmdline
  sed -i 's/"$/ nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/dracut.conf.d/cmdline.conf

  cat > /etc/dracut.conf.d/nvidia.conf << 'EOF'
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF

  # hook to rebuild UKI after AUR-install
  cat > /etc/pacman.d/hooks/nvidia-legacy-dracut.hook << 'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = nvidia-580xx-dkms

[Action]
Description = Rebuilding UKI for nvidia-legacy driver update...
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
EOF
fi

# ── snapper ───────────────────────────────────────────────────────────────────

mkdir -p /etc/snapper/configs
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

echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper

chmod 750 /.snapshots
chown :wheel /.snapshots

pacman -S --noconfirm snap-pac

systemctl enable --no-reload snapper-timeline.timer snapper-cleanup.timer


# ── Secure Boot ───────────────────────────────────────────────────────────────
if $ENABLE_SECUREBOOT; then
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

  # hook for lts
  if $ENABLE_LTS; then
    cat > /etc/pacman.d/hooks/zz-sbctl-lts.hook << 'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = boot/*
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Signing LTS EFI binary...
When = PostTransaction
Exec = /usr/bin/sbctl sign /boot/efi/EFI/Linux/bootx64-lts.efi
EOF
  fi
fi

# ── generate UKI (triggers dracut hook) ───────────────────────────────────────
# This reinstalls the linux package which fires 90-dracut-install.hook,
# which calls dracut-install.sh, which runs dracut --uefi to produce bootx64.efi
pacman -S --noconfirm linux

if $ENABLE_LTS; then
  pacman -S --noconfirm linux-lts
fi

# Initial sign — must happen after UKI exists, before reboot
if $ENABLE_SECUREBOOT; then
  sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
  if $ENABLE_LTS; then
    sbctl sign -s /boot/efi/EFI/Linux/bootx64-lts.efi
  fi
fi

if $ENABLE_LTS; then
  efibootmgr --create --disk "${DISK}" --part 1 --label "Arch Linux LTS" --loader '\EFI\Linux\bootx64-lts.efi'
fi
efibootmgr --create --disk "${DISK}" --part 1 --label "Arch Linux" --loader '\EFI\Linux\bootx64.efi'

# ── WebApps ───────────────────────────────────────────────────────────────────
if [[ -n "${WEBAPPS}" ]]; then
  DESKTOP_DIR="/home/${USERNAME}/.local/share/applications"
  mkdir -p "$DESKTOP_DIR"

  declare -A WEBAPP_URLS=(
    ["github"]="https://github.com"
    ["zoom"]="https://app.zoom.us/wc"
    ["whatsapp"]="https://web.whatsapp.com"
    ["notion"]="https://notion.so"
    ["protonmail"]="https://mail.proton.me"
  )

  declare -A WEBAPP_NAMES=(
    ["github"]="GitHub"
    ["zoom"]="Zoom"
    ["whatsapp"]="WhatsApp"
    ["notion"]="Notion"
    ["protonmail"]="Proton Mail"
  )

  declare -A WEBAPP_CATEGORIES=(
    ["github"]="Development;"
    ["zoom"]="Network;VideoConference;"
    ["whatsapp"]="Network;InstantMessaging;"
    ["notion"]="Office;"
    ["protonmail"]="Network;Email;"
  )

  for app in ${WEBAPPS}; do
    [[ -z "${WEBAPP_URLS[$app]:-}" ]] && continue
    PROFILE_DIR="/home/${USERNAME}/.mozilla/firefox/webapps/${app}"
    mkdir -p "$PROFILE_DIR"
    tee "${DESKTOP_DIR}/${app}-webapp.desktop" > /dev/null << EOF
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

# ── Post Install Script and AUR setup ───────────────────────────────────────────────────────────

# --- base ---------------------------------------------------------------------------------------
cat > /home/${USERNAME}/post-install.sh << EOF
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }
EOF

# --- AUR (optional) -----------------------------------------------------------------------------
if [[ -n "${PKGS_AUR:-}" ]] && [[ -n "${AUR_HELPER:-}" ]]; then
  echo "${PKGS_AUR}" | tr ' ' '\n' | grep -v '^$' > /home/${USERNAME}/aur-packages.txt
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/aur-packages.txt

  cat >> /home/${USERNAME}/post-install.sh << EOF
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
EOF
fi

# --- Nvidia (optional) ---------------------------------------------------------------------------
if [[ "${GPU_CHOICE:-}" == nvidia* || "${GPU_CHOICE:-}" == hybrid-nvidia* ]]; then
  cat >> /home/${USERNAME}/post-install.sh << 'EOF'
info "Writing Hyprland nvidia env config..."
mkdir -p "$HOME/.config/hypr"
cat > "$HOME/.config/hypr/nvidia.conf" << 'HYPRCONF'
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
env = WLR_NO_HARDWARE_CURSORS,1
HYPRCONF
echo ""
echo "  Add the following to ~/.config/hypr/hyprland.conf:"
echo "      source = ~/.config/hypr/nvidia.conf"
EOF
fi

#TODO fetch dotfiles from repo, set up zsh with highlighting, fuzzyfind, basic rice, QOL features

# --- add summary and set zsh as default ----------------------------------------------------------
cat >> /home/${USERNAME}/post-install.sh << 'EOF'
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

# --- ownership and make executable ----------------------------------------------------------------
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/post-install.sh
chmod +x /home/${USERNAME}/post-install.sh
success "post-install.sh written to /home/${USERNAME}/"


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
if $ENABLE_SECUREBOOT; then
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  After first boot — SecureBoot:                          ║"
  echo "║    1. Enable Setup Mode in BIOS                          ║"
  if $MICROSOFT_CA; then
    echo "║    2. sbctl enroll-keys --microsoft                      ║"
  else
    echo "║    2. sbctl enroll-keys                                  ║"
  fi
  echo "║    3. Reboot, enable UEFI Secure Boot, set BIOS password ║"
  echo "╠══════════════════════════════════════════════════════════╣"
fi
if [[ "$GPU_CHOICE" == nvidia* || "$GPU_CHOICE" == hybrid-nvidia* ]]; then
  echo "║    4. Add the following to ~/.config/hypr/hyprland.conf: ║"
  echo "║    -->     source = ~/.config/hypr/nvidia.conf           ║"
  echo "╠══════════════════════════════════════════════════════════╣"
fi
echo "║  Then log in as ${USERNAME} and run:                     ║"
echo "║    bash ~/post-install.sh                                ║"
echo "╚══════════════════════════════════════════════════════════╝"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  [WARN] $w"
  done
  echo "══════════════════════════════════════════════════════════"
fi
