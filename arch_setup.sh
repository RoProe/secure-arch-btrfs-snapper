#!/usr/bin/env bash
# =============================================================================
# Arch Linux installer — LUKS2 + Btrfs + Dracut UKI + systemd-boot + SecureBoot
# Based on: https://github.com/Ataraxxia/secure-arch (Btrfs adaptation)
#
# Boot flow:
#   UEFI → systemd-boot (instant) → UKI → LUKS passphrase
#   → initramfs snapshot menu → [Enter] normal boot
#                             → [s]     select snapshot → rollback boot
#
# USAGE:
#   1. Boot Arch Linux ISO
#   2. Connect to internet (iwctl)
#   3. Run: bash install.sh
#
# WHAT THIS SCRIPT DOES NOT DO:
#   - SecureBoot key enrollment (requires BIOS interaction — done after first boot)
# =============================================================================

set -euo pipefail

# ─── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── sanity checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]       || die "Run as root."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode."
command -v dialog &>/dev/null || pacman -Sy --noconfirm dialog

# =============================================================================
# PHASE 0 — TUI CONFIGURATION
# =============================================================================

clear
dialog --title "Arch Linux Installer" --msgbox \
"LUKS2 + Btrfs + systemd-boot + Snapshot Menu + SecureBoot\n\nBased on: github.com/Ataraxxia/secure-arch\n\nBoot flow after install:\n  UEFI → systemd-boot → LUKS passphrase\n  → snapshot menu (5s timeout) → boot\n\nPress OK to begin." 14 62

# ── disk ──────────────────────────────────────────────────────────────────────
DISK_ENTRIES=()
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  size=$(echo "$line" | awk '{print $2}')
  model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
  DISK_ENTRIES+=("/dev/$name" "$size  $model")
done < <(lsblk -d -o NAME,SIZE,MODEL | grep -v 'NAME\|loop')

DISK=$(dialog --stdout --menu "Select target disk" 15 70 6 "${DISK_ENTRIES[@]}") \
  || die "No disk selected."

# ── CPU ───────────────────────────────────────────────────────────────────────
CPU=$(dialog --stdout --radiolist "CPU vendor" 10 50 2 \
  "amd"   "AMD (amd-ucode)"     ON \
  "intel" "Intel (intel-ucode)" OFF) \
  || die "No CPU selected."
UCODE="${CPU}-ucode"

# ── user & hostname ───────────────────────────────────────────────────────────
USERNAME=$(dialog --stdout --inputbox "Enter username" 8 50 "") || die "Cancelled."
[[ -n "$USERNAME" ]] || die "Username cannot be empty."

HOSTNAME=$(dialog --stdout --inputbox "Enter hostname" 8 50 "") || die "Cancelled."
[[ -n "$HOSTNAME" ]] || die "Hostname cannot be empty."

# ── timezone ──────────────────────────────────────────────────────────────────
REGIONS=()
for r in /usr/share/zoneinfo/*/; do
  region=$(basename "$r")
  [[ "$region" =~ ^(posix|right|Etc)$ ]] && continue
  [[ -d "$r" ]] && REGIONS+=("$region" "")
done
REGIONS+=("custom" "Enter manually")
REGION=$(dialog --stdout --menu "Select region" 20 50 12 "${REGIONS[@]}") || die "Cancelled."

if [[ "$REGION" == "custom" ]]; then
  TIMEZONE=$(dialog --stdout --inputbox \
    "Enter full timezone (e.g. America/New_York, Asia/Tokyo)" 8 60 "") || die "Cancelled."
  [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Timezone not found: $TIMEZONE"
else
  CITIES=()
  while IFS= read -r f; do
    CITIES+=("$(basename "$f")" "")
  done < <(find /usr/share/zoneinfo/"$REGION" -maxdepth 1 -type f | sort)
  CITIES+=("custom" "Enter manually")

  CITY=$(dialog --stdout --menu "Select city — $REGION" 20 50 12 "${CITIES[@]}") || die "Cancelled."

  if [[ "$CITY" == "custom" ]]; then
    TIMEZONE=$(dialog --stdout --inputbox \
      "Enter full timezone (e.g. ${REGION}/YourCity)" 8 60 "${REGION}/") || die "Cancelled."
  else
    TIMEZONE="${REGION}/${CITY}"
  fi
  [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Timezone not found: $TIMEZONE"
fi

# ── locale ────────────────────────────────────────────────────────────────────
_LOCALE_SEL=$(dialog --stdout --menu "Select locale" 20 55 10 \
  "en_US.UTF-8" "English (US)" \
  "en_GB.UTF-8" "English (UK)" \
  "de_DE.UTF-8" "Deutsch" \
  "de_AT.UTF-8" "Deutsch (Oesterreich)" \
  "de_CH.UTF-8" "Deutsch (Schweiz)" \
  "fr_FR.UTF-8" "Francais" \
  "es_ES.UTF-8" "Espanol" \
  "it_IT.UTF-8" "Italiano" \
  "custom"      "Enter manually") || die "Cancelled."

if [[ "$_LOCALE_SEL" == "custom" ]]; then
  LOCALE=$(dialog --stdout --inputbox \
    "Enter locale (e.g. ja_JP.UTF-8)\nSee /etc/locale.gen for full list." 9 60 "") || die "Cancelled."
  [[ -n "$LOCALE" ]] || die "Locale cannot be empty."
else
  LOCALE="$_LOCALE_SEL"
fi

# ── keymap ────────────────────────────────────────────────────────────────────
_KEYMAP_SEL=$(dialog --stdout --menu "Select console keymap" 20 55 10 \
  "us"        "English (US)" \
  "de"        "Deutsch" \
  "de-latin1" "Deutsch latin1 (recommended)" \
  "at"        "Oesterreich" \
  "fr"        "Francais" \
  "es"        "Espanol" \
  "it"        "Italiano" \
  "pl"        "Polski" \
  "custom"    "Enter manually") || die "Cancelled."

if [[ "$_KEYMAP_SEL" == "custom" ]]; then
  KEYMAP=$(dialog --stdout --inputbox \
    "Enter keymap (e.g. uk, dvorak)\nRun 'localectl list-keymaps' for full list." 9 60 "") || die "Cancelled."
  [[ -n "$KEYMAP" ]] || die "Keymap cannot be empty."
else
  KEYMAP="$_KEYMAP_SEL"
fi

# ── EFI size ──────────────────────────────────────────────────────────────────
EFI_SIZE=$(dialog --stdout --inputbox "EFI partition size" 8 50 "1024MiB") || die "Cancelled."
EFI_SIZE="${EFI_SIZE:-1024MiB}"

# ── swap / hibernate ──────────────────────────────────────────────────────────
ENABLE_SWAP=false
SWAP_SIZE_GIB=0
RAM_GIB=$(free -g | awk '/^Mem:/{print $2}')

if dialog --yesno \
  "Enable swap + hibernate?\n\nDetected RAM: ${RAM_GIB} GiB\nRecommended swap: ${RAM_GIB} GiB\n\nThe swapfile lives inside LUKS (fully encrypted).\nHibernate state is read after LUKS unlock at boot.\nsystemd will hibernate instead of suspend-to-RAM." \
  14 58; then
  ENABLE_SWAP=true
  SWAP_SIZE_GIB=$(dialog --stdout --inputbox \
    "Swapfile size in GiB\n(Recommended: ${RAM_GIB} GiB to match your RAM)" \
    10 50 "$RAM_GIB") || die "Cancelled."
  [[ "$SWAP_SIZE_GIB" =~ ^[0-9]+$ ]] || die "Invalid swap size."
fi

# ── autologin ─────────────────────────────────────────────────────────────────
ENABLE_AUTOLOGIN=false
if dialog --yesno \
  "Enable autologin for ${USERNAME}?\n\nLogs in automatically to tty1 on boot.\nThe disk is still LUKS-encrypted — autologin\nonly skips the user password after LUKS unlock.\n\nRecommended: yes for desktop, optional for laptop." \
  12 58; then
  ENABLE_AUTOLOGIN=true
fi

# ── SecureBoot ────────────────────────────────────────────────────────────────
ENABLE_SECUREBOOT=false
MICROSOFT_CA=false

if dialog --yesno "Set up SecureBoot with sbctl?" 8 50; then
  ENABLE_SECUREBOOT=true
  if dialog --yesno \
    "Include Microsoft CA?\n\n(Required for dual-boot with Windows or\nhardware needing Microsoft-signed drivers)" \
    10 55; then
    MICROSOFT_CA=true
  fi
fi

# ── GPU auto-detection ────────────────────────────────────────────────────────
GPU_INFO=$(lspci | grep -E "VGA|3D|Display" || echo "")
HAS_NVIDIA=$(echo "$GPU_INFO" | grep -qi "nvidia"                    && echo true || echo false)
HAS_AMD=$(echo "$GPU_INFO"    | grep -qi "amd\|radeon\|advanced micro" && echo true || echo false)
HAS_INTEL=$(echo "$GPU_INFO"  | grep -qi "intel"                     && echo true || echo false)

if   $HAS_NVIDIA && $HAS_INTEL; then GPU_DEFAULT="hybrid-nvidia-intel"
elif $HAS_NVIDIA && $HAS_AMD;   then GPU_DEFAULT="hybrid-nvidia-amd"
elif $HAS_NVIDIA;               then GPU_DEFAULT="nvidia"
elif $HAS_AMD;                  then GPU_DEFAULT="amd"
elif $HAS_INTEL;                then GPU_DEFAULT="intel"
else                                 GPU_DEFAULT="none"
fi

GPU_CHOICE=$(dialog --stdout --menu \
  "GPU Driver\n\nDetected: ${GPU_INFO:-none}\nSuggested: ${GPU_DEFAULT}" 20 70 6 \
  "amd"                "AMD — vulkan-radeon + mesa" \
  "intel"              "Intel — mesa + intel-media-driver" \
  "nvidia"             "Nvidia — nvidia-dkms + utils + egl-wayland" \
  "hybrid-nvidia-intel" "Hybrid: Intel iGPU + Nvidia dGPU (Optimus)" \
  "hybrid-nvidia-amd"  "Hybrid: AMD iGPU + Nvidia dGPU" \
  "none"               "Skip — install manually later") || die "Cancelled."

if [[ "$GPU_CHOICE" == nvidia* ]]; then
  dialog --msgbox \
    "Nvidia + Wayland notice:\n\nKernel params and dracut modules configured automatically.\n\nAdd to your Hyprland config after dotfile restore:\n\n  env = LIBVA_DRIVER_NAME,nvidia\n  env = __GLX_VENDOR_LIBRARY_NAME,nvidia\n  env = WLR_NO_HARDWARE_CURSORS,1\n  env = NVD_BACKEND,direct\n\nFor Optimus hybrid only:\n  env = AQ_DRM_DEVICES,/dev/dri/card1" \
    18 62
fi

# ── package selection ─────────────────────────────────────────────────────────
PKGS_HYPRLAND=$(dialog --stdout --checklist "Hyprland / Wayland stack" 28 72 17 \
  "hyprland"                    "Wayland compositor"                 ON \
  "waybar"                      "Status bar"                         ON \
  "hyprpaper"                   "Wallpaper daemon"                   ON \
  "hyprpicker"                  "Color picker"                       ON \
  "hyprsunset"                  "Blue light filter"                  ON \
  "nwg-displays"                "Display management GUI"             ON \
  "xdg-desktop-portal-hyprland" "XDG portal for Hyprland"           ON \
  "xdg-desktop-portal-gtk"      "GTK portal backend (file dialogs)"  ON \
  "xdg-utils"                   "XDG utilities"                      ON \
  "mako"                        "Notification daemon"                ON \
  "rofi"                        "App launcher + powermenu + alttab"  ON \
  "swayidle"                    "Idle management"                    ON \
  "swaylock"                    "Screen locker"                      ON \
  "grim"                        "Screenshot tool"                    ON \
  "slurp"                       "Region selector for screenshots"    ON \
  "cliphist"                    "Clipboard history (pulls wl-clipboard)" ON \
  "brightnessctl"               "Backlight control"                  ON) || true

PKGS_AUDIO=$(dialog --stdout --checklist "Audio" 12 72 4 \
  "pipewire"       "Audio server"             ON \
  "pipewire-pulse" "PulseAudio compatibility" ON \
  "pavucontrol"    "Volume control GUI"       ON \
  "alsa-utils"     "ALSA utilities"           ON) || true

PKGS_TERMINAL=$(dialog --stdout --checklist "Terminal and Shell" 13 72 5 \
  "kitty"   "GPU-accelerated terminal" ON \
  "zsh"     "Z shell"                  ON \
  "tmux"    "Terminal multiplexer"     ON \
  "fzf"     "Fuzzy finder"             ON \
  "zoxide"  "Smarter cd"               ON) || true

PKGS_FILES=$(dialog --stdout --checklist "File management" 18 72 11 \
  "thunar-archive-plugin" "Thunar + archive plugin (pulls thunar)" ON \
  "thunar-volman"         "Thunar volume manager (pulls thunar)"   ON \
  "file-roller"           "Archive manager GUI"                    ON \
  "gvfs-mtp"              "MTP/Android support (pulls gvfs)"       ON \
  "gvfs-smb"              "SMB/Samba support (pulls gvfs)"         ON \
  "tumbler"               "Thumbnail service"                      ON \
  "ffmpegthumbnailer"     "Video thumbnails"                       ON \
  "poppler-glib"          "PDF thumbnails"                         ON \
  "ntfs-3g"               "NTFS support"                           ON \
  "usbutils"              "USB utilities (lsusb)"                  ON \
  "yazi"                  "Terminal file manager"                  ON) || true

PKGS_EDITOR=$(dialog --stdout --checklist "Editors and Dev tools" 16 72 10 \
  "neovim"         "Modern vim"                   ON  \
  "vim"            "Vi editor (fallback)"         OFF \
  "git"            "Version control"              ON  \
  "stow"           "Dotfile manager"              ON  \
  "bat"            "Better cat"                   ON  \
  "eza"            "Better ls"                    ON  \
  "tree"           "Directory tree"               ON  \
  "bind"           "DNS utils (dig)"              ON  \
  "net-tools"      "Network tools (ifconfig etc)" ON  \
  "openbsd-netcat" "Netcat"                       ON) || true

PKGS_APPS=$(dialog --stdout --checklist "Applications" 20 72 11 \
  "firefox"           "Web browser"                  ON \
  "thunderbird"       "Email client"                 ON \
  "signal-desktop"    "Encrypted messenger"           ON \
  "obsidian"          "Markdown knowledge base"       ON \
  "anki"              "Flashcard app"                 ON \
  "libreoffice-fresh" "Office suite"                  ON \
  "mpv"               "Media player"                  ON \
  "imv"               "Image viewer"                  ON \
  "obs-studio"        "Screen recording / streaming"  ON \
  "rpi-imager"        "Raspberry Pi Imager"           ON \
  "btop"              "Resource monitor"              ON) || true

PKGS_SYSTEM=$(dialog --stdout --checklist "System and Security" 20 72 11 \
  "fprintd"                    "Fingerprint daemon (pulls libfprint)"  ON \
  "blueman"                    "Bluetooth GUI (pulls bluez)"           ON \
  "power-profiles-daemon"      "Power profiles daemon"                 ON \
  "ufw"                        "Uncomplicated firewall"                ON \
  "seahorse"                   "Keyring GUI (pulls gnome-keyring)"     ON \
  "syncthing"                  "File sync"                             ON \
  "yubikey-manager"            "YubiKey management"                    ON \
  "network-manager-applet"     "NM tray applet (pulls networkmanager)" ON \
  "networkmanager-openconnect" "OpenConnect VPN (pulls openconnect)"   ON \
  "wireguard-tools"            "WireGuard tools"                       ON \
  "mullvad-vpn"                "Mullvad VPN client"                    ON) || true

PKGS_FONTS=$(dialog --stdout --checklist "Fonts" 16 72 7 \
  "ttf-jetbrains-mono-nerd"     "JetBrains Mono Nerd Font" ON \
  "ttf-hack-nerd"               "Hack Nerd Font"           ON \
  "otf-firamono-nerd"           "Fira Mono Nerd Font"      ON \
  "ttf-cascadia-code-nerd"      "Cascadia Code Nerd Font"  ON \
  "ttf-3270-nerd"               "3270 Nerd Font"           ON \
  "ttf-nerd-fonts-symbols-mono" "Nerd Font symbols"        ON \
  "noto-fonts-emoji"            "Emoji font"               ON) || true

PKGS_SPELL=$(dialog --stdout --checklist "Spell checking" 10 72 2 \
  "hunspell-en_us" "English (US) dictionary" ON \
  "hunspell-de"    "German dictionary"        ON) || true

PKGS_AUR=$(dialog --stdout --checklist \
  "AUR packages (installed after first boot via yay)" 10 72 2 \
  "deezer-enhanced-bin" "Deezer music client (enhanced)" ON \
  "typora"              "Markdown editor"                ON  \
  "yay-debug"           "yay debug symbols"              OFF) || true

# ── summary & confirm ─────────────────────────────────────────────────────────
SWAP_SUMMARY="$( $ENABLE_SWAP      && echo "${SWAP_SIZE_GIB} GiB (hibernate enabled)" || echo "disabled" )"
SB_SUMMARY="$(   $ENABLE_SECUREBOOT && echo "yes (Microsoft CA: $MICROSOFT_CA)"        || echo "no" )"
AL_SUMMARY="$(   $ENABLE_AUTOLOGIN  && echo "yes"                                      || echo "no" )"

dialog --title "Configuration Summary" --yesno \
"Disk:        $DISK
CPU/ucode:   $UCODE
Username:    $USERNAME
Hostname:    $HOSTNAME
Locale:      $LOCALE
Timezone:    $TIMEZONE
Keymap:      $KEYMAP
EFI size:    $EFI_SIZE
GPU:         $GPU_CHOICE
Swap:        $SWAP_SUMMARY
Autologin:   $AL_SUMMARY
SecureBoot:  $SB_SUMMARY

WARNING: ALL DATA ON $DISK WILL BE ERASED.

Proceed with installation?" 24 65 || die "Aborted by user."

# ─── derived variables ────────────────────────────────────────────────────────
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"; LUKS_PART="${DISK}p2"
else
  EFI_PART="${DISK}1";  LUKS_PART="${DISK}2"
fi
LUKS_NAME="cryptroot"
LUKS_DEV="/dev/mapper/${LUKS_NAME}"

# Build full package list, deduplicate
ALL_PKGS=""
for group in "$PKGS_HYPRLAND" "$PKGS_AUDIO" "$PKGS_TERMINAL" "$PKGS_FILES" \
             "$PKGS_EDITOR" "$PKGS_APPS" "$PKGS_SYSTEM" "$PKGS_FONTS" "$PKGS_SPELL"; do
  ALL_PKGS="$ALL_PKGS $group"
done
case "$GPU_CHOICE" in
  amd)                 ALL_PKGS="$ALL_PKGS vulkan-radeon mesa" ;;
  intel)               ALL_PKGS="$ALL_PKGS mesa intel-media-driver" ;;
  nvidia)              ALL_PKGS="$ALL_PKGS nvidia-dkms nvidia-utils egl-wayland lib32-nvidia-utils" ;;
  hybrid-nvidia-intel) ALL_PKGS="$ALL_PKGS nvidia-dkms nvidia-utils egl-wayland lib32-nvidia-utils mesa intel-media-driver" ;;
  hybrid-nvidia-amd)   ALL_PKGS="$ALL_PKGS nvidia-dkms nvidia-utils egl-wayland lib32-nvidia-utils vulkan-radeon mesa" ;;
esac
ALL_PKGS=$(echo "$ALL_PKGS" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')

clear

# =============================================================================
# PHASE 1 — partition, format, mount
# =============================================================================
info "Partitioning ${DISK}..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+${EFI_SIZE} -t 1:EF00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:0            -t 2:8309 -c 2:"LUKS"  "$DISK"
partprobe "$DISK"
sleep 1
success "Partitioned."

info "Formatting EFI partition..."
mkfs.fat -F32 "$EFI_PART"
success "EFI formatted."

info "Setting up LUKS2 — enter your encryption passphrase when prompted."
cryptsetup luksFormat --type luks2 "$LUKS_PART"
info "Opening LUKS volume..."
cryptsetup open --allow-discards --persistent "$LUKS_PART" "$LUKS_NAME"
success "LUKS volume opened."

info "Creating Btrfs filesystem and subvolumes..."
mkfs.btrfs "$LUKS_DEV"
mount "$LUKS_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
$ENABLE_SWAP && btrfs subvolume create /mnt/@swap
umount /mnt
success "Subvolumes created."

info "Mounting filesystems..."
BTRFS_OPTS="noatime,compress=zstd"
mount -o "${BTRFS_OPTS},subvol=@"          "$LUKS_DEV" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot/efi}
mount -o "${BTRFS_OPTS},subvol=@home"      "$LUKS_DEV" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$LUKS_DEV" /mnt/.snapshots
mount -o "${BTRFS_OPTS},subvol=@var_log"   "$LUKS_DEV" /mnt/var/log
if $ENABLE_SWAP; then
  mkdir -p /mnt/swap
  # nodatacow mandatory — Btrfs CoW makes file offsets non-contiguous,
  # which breaks the kernel's hibernate resume_offset calculation
  mount -o "nodatacow,subvol=@swap" "$LUKS_DEV" /mnt/swap
fi
mount "$EFI_PART" /mnt/boot/efi
success "Mounted."

# ── swapfile ──────────────────────────────────────────────────────────────────
SWAP_RESUME_OFFSET=""
if $ENABLE_SWAP; then
  info "Creating ${SWAP_SIZE_GIB}G swapfile..."
  touch /mnt/swap/swapfile
  chattr +C /mnt/swap/swapfile   # belt-and-suspenders: also disable CoW at file level
  fallocate -l "${SWAP_SIZE_GIB}G" /mnt/swap/swapfile
  chmod 600 /mnt/swap/swapfile
  mkswap /mnt/swap/swapfile
  swapon /mnt/swap/swapfile
  SWAP_RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
  success "Swapfile created. Resume offset: ${SWAP_RESUME_OFFSET}"
fi

# =============================================================================
# PHASE 2 — pacstrap
# =============================================================================
info "Refreshing pacman keys..."
pacman-key --init
pacman-key --populate

info "Running pacstrap (base system)..."
# systemd-boot is part of systemd — already in base, bootctl is the installer tool
pacstrap /mnt \
  base linux linux-firmware "$UCODE" \
  sudo vim dracut sbsigntools iwd git efibootmgr binutils \
  networkmanager pacman btrfs-progs snapper snap-pac man-db

info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
success "pacstrap done."

# =============================================================================
# PHASE 3 — write chroot script
# =============================================================================
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")

if $ENABLE_SWAP; then
  RESUME_ARGS=" resume=/dev/mapper/cryptroot resume_offset=${SWAP_RESUME_OFFSET}"
else
  RESUME_ARGS=""
fi

if $ENABLE_SECUREBOOT; then
  ENROLL_CMD="sbctl enroll-keys$( $MICROSOFT_CA && echo ' --microsoft' || echo '' )"
else
  ENROLL_CMD=""
fi

echo "$PKGS_AUR" | tr ' ' '\n' | grep -v '^$' > /mnt/root/aur-packages.txt

info "Writing chroot setup script..."
cat > /mnt/root/chroot-setup.sh << CHROOT_EOF
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
while read -r line; do
    if [[ "$line" == usr/lib/modules/*/pkgbase ]]; then
        kver="${line#usr/lib/modules/}"
        kver="${kver%/pkgbase}"
        dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
    fi
done
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

AUR_LIST=/root/aur-packages.txt
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

chmod +x /mnt/root/chroot-setup.sh

# =============================================================================
# PHASE 4 — enter chroot
# =============================================================================
success "Pre-chroot setup done. Entering chroot..."
echo ""
arch-chroot /mnt bash /root/chroot-setup.sh

echo ""
success "All done!"
echo ""
echo "  umount -R /mnt"
echo "  cryptsetup close ${LUKS_NAME}"
echo "  reboot"
if $ENABLE_SECUREBOOT; then
  echo ""
  warn "After first boot: enable Setup Mode in BIOS, then run: ${ENROLL_CMD}"
fi
echo ""
warn "After first boot, log in as ${USERNAME} and run: bash ~/post-install.sh"
