#!/usr/bin/env bash
# =============================================================================
# Arch Linux installer — LUKS2 + Btrfs + Dracut UKI + systemd-boot + SecureBoot
# inspired by: https://github.com/Ataraxxia/secure-arch (Btrfs adaptation with snapshots and custom snapshot menu after luks decryption and swap on LUKS partition for secure hibernate.)
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
#   4. Install procedure with TUI and preconfigured settings awaiting user confirmation or change
#   5. Post install run the post-install script for some configurations and app installs  etc.
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
"LUKS2 + Btrfs + systemd-boot + Snapshot Menu + SecureBoot\n\nBoot flow after install:\n  UEFI → systemd-boot → LUKS passphrase\n  → snapshot menu (5s timeout) → boot\n\nPress OK to begin." 14 62

# ── disk ──────────────────────────────────────────────────────────────────────
DISK_ENTRIES=()
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  size=$(echo "$line" | awk '{print $2}')
  model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
  DISK_ENTRIES+=("/dev/$name" "$size  $model")
done < <(lsblk -d -o NAME,SIZE,MODEL | grep -v 'NAME\|loop')

DISK=$(dialog --stdout --menu "Select target disk" 22 72 6 "${DISK_ENTRIES[@]}") \
  || die "No disk selected."

# ── CPU auto-detect ───────────────────────────────────────────────────────────
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
  CPU_DEFAULT="intel"
else
  CPU_DEFAULT="amd"
fi
AMD_DEFAULT=$(  [[ "$CPU_DEFAULT" == "amd"   ]] && echo "ON" || echo "OFF" )
INTEL_DEFAULT=$([[ "$CPU_DEFAULT" == "intel" ]] && echo "ON" || echo "OFF" )

# ── CPU ───────────────────────────────────────────────────────────────────────
CPU=$(dialog --stdout --radiolist \
  "CPU vendor\n\nAuto-detected: ${CPU_VENDOR:-unknown}" \
  22 72 2 \
  "amd"   "AMD (amd-ucode)"     "$AMD_DEFAULT" \
  "intel" "Intel (intel-ucode)" "$INTEL_DEFAULT") \
  || die "No CPU selected."
UCODE="${CPU}-ucode"

# ── username ──────────────────────────────────────────────────────────────────
while true; do
  USERNAME=$(dialog --stdout --inputbox \
    "Enter username\n\nRules:\n- lowercase letters, numbers, _ and - only\n- must start with a letter or _\n- max 32 characters\n\nExamples: john, my_user, dev-box" \
    14 50 "${USERNAME:-}") || die "Cancelled."
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
  dialog --msgbox "Invalid username: '${USERNAME}'\n\nPlease try again." 8 45
done

# ── hostname ──────────────────────────────────────────────────────────────────
while true; do
  HOSTNAME=$(dialog --stdout --inputbox \
    "Enter hostname\n\nRules:\n- letters and numbers only\n- hyphens allowed but not at start/end\n- max 63 characters\n\nExamples: archbox, my-laptop, dev-01" \
    14 50 "${HOSTNAME:-}") || die "Cancelled."
  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && break
  dialog --msgbox "Invalid hostname: '${HOSTNAME}'\n\nPlease try again." 8 45
done

# ── timezone ──────────────────────────────────────────────────────────────────
REGIONS=()
for r in /usr/share/zoneinfo/*/; do
  region=$(basename "$r")
  [[ "$region" =~ ^(posix|right|Etc)$ ]] && continue
  [[ -d "$r" ]] && REGIONS+=("$region" "")
done

while true; do
  REGION=$(dialog --stdout --menu "Select region" 22 72 10 "${REGIONS[@]}") \
    || die "Cancelled."

  CITIES=()
  while IFS= read -r f; do
    CITIES+=("$(basename "$f")" "")
  done < <(find /usr/share/zoneinfo/"$REGION" -maxdepth 1 -type f | sort)

  CITY=$(dialog --stdout --menu "Select city — $REGION" 22 72 10 "${CITIES[@]}") \
    || continue  # Escape → zurück zur Regionsauswahl

  TIMEZONE="${REGION}/${CITY}"
  break
done

# ── locale ────────────────────────────────────────────────────────────────────
LOCALE_ENTRIES=()
while IFS= read -r line; do
  # /etc/locale.gen parsen — Zeilen die mit # beginnen und ein Leerzeichen haben
  locale=$(echo "$line" | sed 's/^#[[:space:]]*//' | awk '{print $1}')
  [[ -n "$locale" ]] && LOCALE_ENTRIES+=("$locale" "")
done < <(grep -E '^\s*#?[a-zA-Z]' /etc/locale.gen | sort -u)

while true; do
  LOCALE=$(dialog --stdout --menu "Select locale" 22 72 10 "${LOCALE_ENTRIES[@]}") \
    || die "Cancelled."
  [[ -n "$LOCALE" ]] && break
done

# ── keymap ────────────────────────────────────────────────────────────────────
KEYMAP_ENTRIES=()
while IFS= read -r km; do
  [[ -n "$km" ]] && KEYMAP_ENTRIES+=("$km" "")
done < <(localectl list-keymaps)

while true; do
  KEYMAP=$(dialog --stdout --menu "Select console keymap" 22 72 10 "${KEYMAP_ENTRIES[@]}") \
    || die "Cancelled."
  [[ -n "$KEYMAP" ]] && break
done

# ── EFI size ──────────────────────────────────────────────────────────────────
while true; do
  EFI_SIZE=$(dialog --stdout --inputbox "EFI partition size" 8 50 "${EFI_SIZE:-1024MiB}") || die "Cancelled."
  if [[ ! "$EFI_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    dialog --msgbox "Invalid format.\n\nUse e.g. 512MiB or 1GiB." 8 45
    continue
  fi
  efi_mib=$(echo "$EFI_SIZE" | grep -oP '^\d+')
  [[ "$EFI_SIZE" =~ GiB ]] && efi_mib=$(( efi_mib * 1024 ))
  if [[ "$efi_mib" -lt 512 ]]; then
    dialog --msgbox "EFI too small (${EFI_SIZE}).\n\nMinimum: 512MiB\nRecommended: 1024MiB" 9 45
    continue
  fi
  break
done

# ── swap / hibernate ──────────────────────────────────────────────────────────
ENABLE_SWAP=false
SWAP_SIZE_GIB=0
RAM_GIB=$(free -g | awk '/^Mem:/{print $2}')

if dialog --yesno \
  "Enable swap + hibernate?\n\nDetected RAM: ${RAM_GIB} GiB\nRecommended swap: ${RAM_GIB} GiB\n\nThe swapfile lives inside LUKS (fully encrypted).\nHibernate state is read after LUKS unlock at boot.\nsystemd will hibernate instead of suspend-to-RAM." \
  14 58; then
  ENABLE_SWAP=true
  while true; do
    SWAP_SIZE_GIB=$(dialog --stdout --inputbox \
      "Swapfile size in GiB\n(Recommended: ${RAM_GIB} GiB to match your RAM)" \
      10 50 "${SWAP_SIZE_GIB:-$RAM_GIB}") || die "Cancelled."
    if [[ ! "$SWAP_SIZE_GIB" =~ ^[0-9]+$ ]]; then
      dialog --msgbox "Enter a plain number, e.g. 16" 7 40
      continue
    fi
    if [[ "$SWAP_SIZE_GIB" -lt 1 ]]; then
      dialog --msgbox "Minimum swap size is 1 GiB." 7 40
      continue
    fi
    if [[ "$SWAP_SIZE_GIB" -gt 128 ]]; then
      dialog --yesno "Swap size is ${SWAP_SIZE_GIB} GiB — are you sure?\n\nThat seems very large." 9 50 \
        && break || continue
    fi
    break
  done
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

if dialog --yesno "Set up SecureBoot with sbctl?" 8 72; then
  ENABLE_SECUREBOOT=true
  if dialog --yesno \
    "Include Microsoft CA?\n\n(Required for dual-boot with Windows or\nhardware needing Microsoft-signed drivers)" \
    10 72; then
    MICROSOFT_CA=true
  fi
fi

#TODO maybe legacy gpu auto detection via lspci -k -d ::03xx and add nvidia legacy vs nvidia-open to selection
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
  "GPU Driver\n\nDetected: ${GPU_INFO:-none}\nSuggested: ${GPU_DEFAULT}\n!!If you are using a NVIDIA GPU, check which driver version you need on the archwiki nvidia page!!" 22 72 7 \
  "amd"                 "AMD — vulkan-radeon + mesa" \
  "intel"               "Intel — mesa + intel-media-driver" \
  "nvidia"              "Nvidia — nvidia-open-dkms (Turing RTX 20xx and up as well as GTX 1650)" \
  "hybrid-nvidia-intel" "Hybrid: Intel iGPU + Nvidia dGPU (Turing+)" \
  "hybrid-nvidia-amd"   "Hybrid: AMD iGPU + Nvidia dGPU (Turing+)" \
  "nvidia-legacy"       "Nvidia Legacy — (Maxwell GTX 9xx through Pascal GTX 10xx)" \
  "none"                "Skip — install manually later") || die "Cancelled."

if [[ "$GPU_CHOICE" == nvidia* || "$GPU_CHOICE" == hybrid-nvidia* ]]; then
  dialog --msgbox \
    "Nvidia GPU notice:\n\nMake sure you selected the right option!\n\n  GTX 1650 / RTX 20xx and newer  → nvidia (open)\n  GTX 10xx / GTX 9xx → nvidia-legacy \n\n Kernel params configured automatically. \n\n Hyprland env vars after dotfile restore: \n  env = LIBVA_DRIVER_NAME,nvidia\n  env = __GLX_VENDOR_LIBRARY_NAME,nvidia\n  env = WLR_NO_HARDWARE_CURSORS,1\n  env = NVD_BACKEND,direct" \
    20 68
fi


# ── WiFi auto-detection ───────────────────────────────────────────────────────
WIFI_INFO=$(lspci | grep -iE "network|wireless|wifi" || echo "")
EXTRA_WIFI_PKGS=""

if echo "$WIFI_INFO" | grep -qi "broadcom\|BCM"; then
  dialog --msgbox \
    "Broadcom WiFi detected!\n\n${WIFI_INFO}\n\nbroadcom-wl-dkms will be added automatically.\nThis requires linux-headers (already included)." \
    12 72
  EXTRA_WIFI_PKGS="broadcom-wl-dkms"
fi

# ── Thunderbolt auto-detection ────────────────────────────────────────────────
HAS_THUNDERBOLT=false
if lspci | grep -qi "thunderbolt\|usb4"; then
  HAS_THUNDERBOLT=true
fi
if ls /sys/bus/thunderbolt/devices/ 2>/dev/null | grep -q .; then
  HAS_THUNDERBOLT=true
fi
TB_DEFAULT=$( $HAS_THUNDERBOLT && echo "ON" || echo "OFF" )


# ── package selection ─────────────────────────────────────────────────────────
PKGS_HYPRLAND=$(dialog --stdout --checklist "Hyprland / Wayland stack" 22 72 18 \
  "hyprland"                    "Wayland compositor"                     ON \
  "waybar"                      "Status bar"                             ON \
  "hyprpaper"                   "Wallpaper daemon"                       ON \
  "hyprpicker"                  "Color picker"                           ON \
  "hyprsunset"                  "Blue light filter"                      ON \
  "nwg-displays"                "Display management GUI"                 ON \
  "xdg-desktop-portal-hyprland" "XDG portal for Hyprland"                ON \
  "xdg-desktop-portal-gtk"      "GTK portal backend (file dialogs)"      ON \
  "xdg-utils"                   "XDG utilities"                          ON \
  "mako"                        "Notification daemon"                    ON \
  "rofi"                        "App launcher + powermenu + alttab"      ON \
  "swayidle"                    "Idle management"                        ON \
  "swaylock"                    "Screen locker"                          ON \
  "grim"                        "Screenshot tool"                        ON \
  "slurp"                       "Region selector for screenshots"        ON \
  "satty"                       "Screenshot annotation tool"             ON \
  "cliphist"                    "Clipboard history (pulls wl-clipboard)" ON \
  "brightnessctl"               "Backlight control"                      ON) || true

PKGS_AUDIO=$(dialog --stdout --checklist "Audio" 22 72 4 \
  "pipewire"       "Audio server"             ON \
  "pipewire-pulse" "PulseAudio compatibility" ON \
  "pavucontrol"    "Volume control GUI"       ON \
  "alsa-utils"     "ALSA utilities"           ON) || true

PKGS_TERMINAL=$(dialog --stdout --checklist "Terminal and Shell" 22 72 10 \
  "kitty"   "GPU-accelerated terminal" ON \
  "zsh"     "Z shell"                  ON \
  "tmux"    "Terminal multiplexer"     ON \
  "fzf"     "Fuzzy finder"             ON \
  "zoxide"  "Smarter cd"               ON \
  "starship"  "Cross-shell prompt"     ON \
  "ripgrep"   "Fast grep (rg)"         ON \
  "fd"        "Better find"            ON \
  "wget"      "File downloader"        ON \
  "jq"        "JSON processor"         ON ) || true

PKGS_FILES=$(dialog --stdout --checklist "File management" 22 72 16 \
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
  "imagemagick"           "Image processing (kitty/yazi preview)"  ON \
  "unzip"                 "ZIP extraction"                         ON \
  "unrar"                 "RAR extraction"                         ON \
  "p7zip"                 "7z extraction"                          ON \
  "zip"                   "ZIP creation"                           ON \
  "yazi"                  "Terminal file manager"                  ON ) || true

PKGS_EDITOR=$(dialog --stdout --checklist "Editors and Dev tools" 22 72 10 \
  "neovim"         "Modern vim"                   ON  \
  "vim"            "Vi editor (fallback)"         ON \
  "git"            "Version control"              ON  \
  "stow"           "Dotfile manager"              ON  \
  "bat"            "Better cat"                   ON  \
  "eza"            "Better ls"                    ON  \
  "tree"           "Directory tree"               ON  \
  "bind"           "DNS utils (dig)"              ON  \
  "net-tools"      "Network tools (ifconfig etc)" ON  \
  "tldr"           "Simplified man pages"         ON  \
  "tmux"	   "Terminal Multiplexer"	  ON  ) || true

PKGS_APPS=$(dialog --stdout --checklist "Applications" 22 72 16 \
  "mpv"                      "Media player"                                 ON \
  "imv"                      "Image viewer"                                 ON \   
  "ffmpeg"                   "Audio/video converter (needed by many tools)" ON \
  "firefox"                  "Web browser"                                  OFF \
  "thunderbird"              "Email client"                                 OFF \
  "signal-desktop"           "Encrypted messenger"                          OFF \
  "obsidian"                 "Markdown knowledge base"                      OFF \
  "anki"                     "Flashcard app"                                OFF \
  "libreoffice-fresh"        "Office suite"                                 OFF \
  "obs-studio"               "Screen recording / streaming"                 OFF \
  "rpi-imager"               "Raspberry Pi Imager"                          OFF \
  "btop"                     "Resource monitor"                             OFF \
  "texlive-basic"            "LaTeX base"                                   OFF \
  "texlive-latexrecommended" "LaTeX recommended packages"                   OFF \
  "texlive-fontsrecommended" "LaTeX recommended fonts"                      OFF \
  "texstudio"                "LaTeX editor"                                 OFF ) || true

WEBAPPS=$(dialog --stdout --checklist "Web Apps" 22 72 8 \
  "github"      "GitHub"          OFF  \
  "zoom"        "Zoom"            OFF  \
  "whatsapp"    "WhatsApp Web"    OFF \
  "notion"      "Notion"          OFF \
  "googlemeet"  "Google Meet"     OFF \
  "protonmail"  "Proton Mail"     OFF \
  "linear"      "Linear"          OFF \
  "figma"       "Figma"           OFF) || true

PKGS_SYSTEM=$(dialog --stdout --checklist "System and Security" 22 72 17 \
  "fprintd"                    "Fingerprint daemon (pulls libfprint)"  ON \
  "blueman"                    "Bluetooth GUI (pulls bluez)"           ON \
  "power-profiles-daemon"      "Power profiles daemon"                 ON \
  "ufw"                        "Uncomplicated firewall"                ON \
  "seahorse"                   "Keyring GUI (pulls gnome-keyring)"     ON \
  "syncthing"                  "File sync"                             ON \
  "rsync"                      "File sync / backup tool"               ON \
  "borg"                       "Deduplicating backup"                  ON \
  "yubikey-manager"            "YubiKey management"                    ON \
  "network-manager-applet"     "NM tray applet (pulls networkmanager)" ON \
  "networkmanager-openconnect" "OpenConnect VPN (pulls openconnect)"   ON \
  "wireguard-tools"            "WireGuard tools"                       ON \
  "fwupd"                      "Firmware updater (BIOS, SSD, etc.)"    ON \
  "gnupg"                      "GPG encryption"                        ON \
  "lsof"                       "List open files/ports"                 ON \
  "smartmontools"              "SSD/HDD health (smartctl)"             ON \
  "bolt"                       "Thunderbolt device manager"            "$TB_DEFAULT") || true

PKGS_NETWORK=$(dialog --stdout --checklist "Networking tools" 22 72 8 \
  "nmap"            "Port scanner (pulls ncat)"         ON \
  "mtr"             "Traceroute + ping combined"         ON \
  "whois"           "Domain lookup"                      ON \
  "tcpdump"         "Packet analyzer"                    ON \
  "iperf3"          "Bandwidth tester"                   OFF \
  "ipcalc"          "Subnet calculator"                  ON \
  "gnu-netcat"      "Netcat (alternative to openbsd-nc)" OFF \
  "wireshark-cli"   "Packet analyzer GUI/CLI"         OFF) || true

PKGS_FONTS=$(dialog --stdout --checklist "Fonts" 22 72 7 \
  "ttf-jetbrains-mono-nerd"     "JetBrains Mono Nerd Font" ON \
  "ttf-hack-nerd"               "Hack Nerd Font"           ON \
  "otf-firamono-nerd"           "Fira Mono Nerd Font"      ON \
  "ttf-cascadia-code-nerd"      "Cascadia Code Nerd Font"  ON \
  "ttf-3270-nerd"               "3270 Nerd Font"           ON \
  "ttf-nerd-fonts-symbols-mono" "Nerd Font symbols"        ON \
  "noto-fonts-emoji"            "Emoji font"               ON) || true

PKGS_SPELL=$(dialog --stdout --checklist "Spell checking" 22 72 2 \
  "hunspell-en_us" "English (US) dictionary" ON \
  "hunspell-de"    "German dictionary"        ON) || true

PKGS_AUR=$(dialog --stdout --checklist \
  "AUR packages (installed after first boot via yay)" 22 72 4 \
  "deezer-enhanced-bin" "Deezer music client (enhanced)" OFF \
  "typora"              "Markdown editor"                ON  \
  "mullvad-vpn-bin"     "Mullvad VPN client"             OFF  \
  "yay-debug"           "yay debug symbols"              OFF) || true

# ── nvidia legacy — if choosen add to AUR ─────────────────────────────────────
if [[ "$GPU_CHOICE" == "nvidia-legacy" ]]; then
  dialog --msgbox \
    "Nvidia Legacy notice:\n\nnvidia-580xx-dkms will be added to your AUR list.\nAfter first boot run ~/post-install.sh immediately.\n\nSystem will boot with nouveau (open source) driver\nuntil the proprietary driver is installed." \
    12 72
  PKGS_AUR="$PKGS_AUR nvidia-580xx-dkms"
fi

# ── AUR helper ────────────────────────────────────────────────────────────────
# Only asks if AUR packages got selected..
if [[ -n "$PKGS_AUR" ]]; then
  AUR_HELPER=$(dialog --stdout --radiolist \
    "AUR Helper\n\nRequired to install your selected AUR packages after first boot.\nbase-devel will be added automatically." \
    14 72 2 \
    "paru" "Rust-based, shows PKGBUILD before install (recommended)" ON \
    "yay"  "Go-based, most widely used"                              OFF) \
    || die "Cancelled."
else
  AUR_HELPER=""
fi

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
AurHelper:   ${AUR_HELPER:-none}

WARNING: ALL DATA ON $DISK WILL BE ERASED.

Proceed with installation?" 27 65 || die "Aborted by user."

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
             "$PKGS_EDITOR" "$PKGS_APPS" "$PKGS_SYSTEM" "$PKGS_FONTS" "$PKGS_SPELL" "$PKGS_NETWORK"; do
  ALL_PKGS="$ALL_PKGS $group"
done
case "$GPU_CHOICE" in
  amd)                 ALL_PKGS="$ALL_PKGS vulkan-radeon mesa" ;;
  intel)               ALL_PKGS="$ALL_PKGS mesa intel-media-driver" ;;
  nvidia)              ALL_PKGS="$ALL_PKGS nvidia-open-dkms nvidia-utils egl-wayland lib32-nvidia-utils" ;;
  hybrid-nvidia-intel) ALL_PKGS="$ALL_PKGS nvidia-open-dkms nvidia-utils egl-wayland lib32-nvidia-utils mesa intel-media-driver" ;;
  hybrid-nvidia-amd)   ALL_PKGS="$ALL_PKGS nvidia-open-dkms nvidia-utils egl-wayland lib32-nvidia-utils vulkan-radeon mesa" ;;
  nvidia-legacy) ;;
esac

# Broadcom WiFi (auto-detected)
[[ -n "$EXTRA_WIFI_PKGS" ]] && ALL_PKGS="$ALL_PKGS $EXTRA_WIFI_PKGS"

# AUR helper braucht base-devel
[[ -n "$AUR_HELPER" ]] && ALL_PKGS="$ALL_PKGS base-devel"

# Final deduplicate
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
cryptsetup luksFormat --type luks2 "$LUKS_PART" < /dev/tty
info "Opening LUKS volume..."
cryptsetup open --allow-discards --persistent "$LUKS_PART" "$LUKS_NAME" < /dev/tty
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
  mount -o "noatime,nodatacow,nodatasum,compress=0,subvol=@swap" "$LUKS_DEV" /mnt/swap
fi
mount "$EFI_PART" /mnt/boot/efi
success "Mounted."

# ── swapfile ──────────────────────────────────────────────────────────────────
SWAP_RESUME_OFFSET=""
if $ENABLE_SWAP; then
  info "Creating ${SWAP_SIZE_GIB}G swapfile..."
  touch /mnt/swap/swapfile
  chattr +C /mnt/swap/swapfile  
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

# ── pacstrap part 1 ───────────────────────────────────────────────────────────

info "Refreshing pacman keys..."
pacman-key --init
pacman-key --populate

info "Running pacstrap (base system)..."
# we leave kernel for later after setting i18n and locale for correct initramfs build from start
pacstrap /mnt \
  base linux-firmware linux-headers "$UCODE" \
  sudo vim dracut sbsigntools iwd git efibootmgr binutils \
  networkmanager pacman btrfs-progs snapper man-db


# ── set locale / keymap for target system and dracut i18n ─────────────────────

info "Preparing locale/keymap + dracut i18n config (pre-pacstrap)..."

[[ -n "${LOCALE:-}" ]] || die "LOCALE is empty"
[[ -n "${KEYMAP:-}" ]] || die "KEYMAP is empty"

# 1) system locale + console keymap for the installed system
cat > /mnt/etc/locale.conf <<EOF
LANG=${LOCALE}
EOF

cat > /mnt/etc/vconsole.conf <<EOF
KEYMAP=${KEYMAP}
EOF

# 2) enable selected locale in locale.gen (so locale-gen in chroot will generate it)
#    matches lines like: "#de_AT.UTF-8 UTF-8" or "de_AT.UTF-8 UTF-8"
if ! grep -Eq "^[#[:space:]]*${LOCALE}[[:space:]]" /mnt/etc/locale.gen; then
  warn "Selected LOCALE '${LOCALE}' not found in /mnt/etc/locale.gen (will still set LANG, but locale-gen may not generate it)"
else
  # uncomment exactly that locale line
  sed -i -E "s|^[#[:space:]]*(${LOCALE}[[:space:]].*)$|\1|" /mnt/etc/locale.gen
fi

# 3) dracut i18n config so dracut hook during pacstrap doesn't error out
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/20-i18n.conf <<EOF
# Generated by installer (pre-pacstrap)
i18n_vars="LANG LC_ALL LC_CTYPE LC_MESSAGES"
keymap="${KEYMAP}"
EOF

success "Locale/keymap + dracut i18n prepared."



# ── pacstrap part 2 (Kernel)────────────────────────────────────────────────────



info "Running pacstrap (base system)..."
# systemd-boot is part of systemd — already in base, bootctl is the installer tool
pacstrap /mnt linux

info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's|fmask=0022,dmask=0022|fmask=0077,dmask=0077,umask=0077|' /mnt/etc/fstab
success "pacstrap done."

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


# ============================================================================
# == PHASE 3 - CHROOT SCRIPT GEN =============================================
# ============================================================================


cat >  /mnt/root/chroot_setup.sh << 'CHROOT'
#!/usr/bin/env bash
# chroot_setup.sh 
# runs via arch-chroot in new system and gets variables passed by arch_setup.sh
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
: "${PKGS_AUR:-}" "${DISK:?}"

# ── passwords ─────────────────────────────────────────────────────────────────
echo "Set ROOT password:"
passwd < /dev/tty

# ── timezone & clock ──────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# ── locale ────────────────────────────────────────────────────────────────────
# TODO redundant since happened before chroot?
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# ── vconsole ──────────────────────────────────────────────────────────────────
# TODO redundant 
printf "KEYMAP=${KEYMAP}\n" > /etc/vconsole.conf

# ── hostname ──────────────────────────────────────────────────────────────────
echo "${HOSTNAME}" > /etc/hostname

# ── user ──────────────────────────────────────────────────────────────────────
useradd -m -G wheel "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}" < /dev/tty
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

# ── install user packages ─────────────────────────────────────────────────────
info "Installing selected packages..."
read -ra PKG_ARRAY <<< "$ALL_PKGS"
pacman -S --noconfirm --needed "${PKG_ARRAY[@]}"

# ── activate services ────────────────────────────────────────────
systemctl enable --no-reload bluetooth                     || warn "bluetooth nicht verfügbar (nicht installiert?)"
systemctl enable --no-reload ufw                           || warn "ufw nicht verfügbar (nicht installiert?)"
systemctl enable --no-reload power-profiles-daemon         || warn "power-profiles-daemon nicht verfügbar"
systemctl enable --no-reload syncthing@${USERNAME}.service || warn "syncthing nicht verfügbar (nicht installiert?)"
systemctl enable --no-reload NetworkManager                || die "NetworkManager konnte nicht aktiviert werden"
systemctl enable --no-reload fstrim.timer                  || die "fstrim.timer konnte nicht aktiviert werden"


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

# ── dracut hook scripts ───────────────────────────────────────────────────────
mkdir -p /usr/local/bin /etc/pacman.d/hooks

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

#TODO double check nvidia
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

# TODO root or USER better?
echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper

chmod 750 /.snapshots
chown :wheel /.snapshots

pacman -S --noconfirm snap-pac

systemctl enable --no-reload snapper-timeline.timer snapper-cleanup.timer

# TODO description of files
# ── post-LUKS snapshot menu — dracut module ───────────────────────────────────
#
# Three-hook / One-service design:
#   1. snapshot-menu.sh  	 - initqueue/settled: shows menu after LUKS unlock,
#                         	   writes rootflags-override if a snapshot was chosen.
#   2. module-setup.sh   	 -
#   3.1 snapshot-rewrite.sh	 -
#   3.2 snapshot-rewrite.service -	
#
info "Installing snapshot menu dracut module..."
REPO_RAW="https://raw.githubusercontent.com/RoProe/secure-arch-btrfs-snapper/refs/heads/main"
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu

cat >  /usr/lib/dracut/modules.d/99snapshot-menu/module-setup.sh << 'EOF'
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

cat >  /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-rewrite.sh << 'EOF'
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

cat >  /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-rewrite.service << 'EOF'
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


cat >  /usr/lib/dracut/modules.d/99snapshot-menu/snapshot-menu.sh << 'EOF'
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

for f in module-setup.sh snapshot-menu.sh snapshot-rewrite.sh snapshot-rewrite.service; do
  chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/${f}
done
success "Snapshot menu module installed."

# ── Secure Boot ───────────────────────────────────────────────────────────────
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

#TODO Variables correct?
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
    sudo -u "${USERNAME}" mkdir -p "$PROFILE_DIR"
    sudo -u "${USERNAME}" tee "${DESKTOP_DIR}/${app}-webapp.desktop" > /dev/null << EOF
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

#TODO include Nvidia legacy drivers if needed and add nvidia variables to hyprland
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

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  [WARN] $w"
  done
  echo "══════════════════════════════════════════════════════════"
fi
CHROOT


chmod +x  /mnt/root/chroot_setup.sh 

# =============================================================================
# PHASE 4 — enter chroot
# =============================================================================
success "Pre-chroot setup done. Entering chroot..."
echo ""

### all variables to chroot
arch-chroot /mnt env \
  USERNAME="$USERNAME" \
  HOSTNAME="$HOSTNAME" \
  TIMEZONE="$TIMEZONE" \
  LOCALE="$LOCALE" \
  KEYMAP="$KEYMAP" \
  UCODE="$UCODE" \
  GPU_CHOICE="$GPU_CHOICE" \
  ALL_PKGS="$ALL_PKGS" \
  LUKS_UUID="$LUKS_UUID" \
  LUKS_NAME="$LUKS_NAME" \
  RESUME_ARGS="$RESUME_ARGS" \
  ENABLE_SWAP="$ENABLE_SWAP" \
  ENABLE_AUTOLOGIN="$ENABLE_AUTOLOGIN" \
  ENABLE_SECUREBOOT="$ENABLE_SECUREBOOT" \
  MICROSOFT_CA="$MICROSOFT_CA" \
  PKGS_AUR="$PKGS_AUR" \
  WEBAPPS="$WEBAPPS" \
  AUR_HELPER="$AUR_HELPER" \
  DISK="$DISK" \
  bash /root/chroot_setup.sh

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
