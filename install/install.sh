#!/usr/bin/env bash
# =============================================================================
# Arch Linux installer — LUKS2 + Btrfs + Dracut UKI + systemd-boot + SecureBoot
# inspired by: https://github.com/Ataraxxia/secure-arch (Btrfs adaptation with snapshots and custom snapshot menu after luks decryption and swap on LUKS partition for secure hibernate.)
#
# Boot flow:
#   UEFI → UKI → LUKS passphrase
#   → initramfs snapshot menu → [Enter / b] normal boot
#                             → [s]     open snapshot menu → rollback boot
#   snapshot menu can also navigated via arrow keys or vim-style j/k
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
[[ "$(free -m | awk '/^Mem:/{print $2}')" -lt 512 ]] && die "Not enough RAM, need 512MB+."

# =============================================================================
# PHASE 1 — TUI CONFIGURATION
# =============================================================================

clear
dialog --title "Arch Linux Installer" --msgbox \
"LUKS2 + Btrfs + Dracut UKI + Snapshot Menu + SecureBoot\n\nBoot flow after install:\n  UEFI → UKI → LUKS passphrase\n  → snapshot menu  → boot\n\nPress OK to begin." 14 62

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

DISK_SIZE_GB=$(lsblk -b -d -o SIZE "$DISK" | tail -1 | awk '{print int($1/1024/1024/1024)}')
[[ "$DISK_SIZE_GB" -lt 20 ]] && die "Disk too small (${DISK_SIZE_GB}GB, need 20GB+)."

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
  EFI_SIZE=$(dialog --stdout --inputbox "EFI partition size" 8 50 "${EFI_SIZE:-2048MiB}") || die "Cancelled."
  if [[ ! "$EFI_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    dialog --msgbox "Invalid format.\n\nUse e.g. 512MiB or 1GiB." 8 45
    continue
  fi
  efi_mib=$(echo "$EFI_SIZE" | grep -oP '^\d+')
  [[ "$EFI_SIZE" =~ GiB ]] && efi_mib=$(( efi_mib * 1024 ))
  if [[ "$efi_mib" -lt 512 ]]; then
    dialog --msgbox "EFI too small (${EFI_SIZE}).\n\nMinimum: 512MiB\nRecommended: 1024 with one UKI, 2048MiB with more UKIs / fallbacks" 9 45
    continue
  fi
  break
done

# ── Fallback Kernel ───────────────────────────────────────────────────────────
ENABLE_LTS=false
if dialog --yesno "Install LTS Fallback-Kernel?\n\n usefull if main kernel breaks \n +320MB EFI-Size \n recommended \n select it in BIOS menu" 10 58; then
    ENABLE_LTS=true
fi

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

SB_SETUP_MODE=$(cat /sys/firmware/efi/efivars/SetupMode-* 2>/dev/null \
  | xxd | awk 'END{print $NF}' || echo "unknown")
SB_CURRENT=$(cat /sys/firmware/efi/efivars/SecureBoot-* \
  | xxd | awk 'END{print $NF}' 2>/dev/null || echo "unknown")

if [[ "$SB_SETUP_MODE" == "unknown" ]]; then
  dialog --msgbox "SecureBoot not available.\nSkipping." 7 50
elif dialog --yesno \
  "Set up SecureBoot with sbctl?\n\
\n\
System status:\n\
  Setup Mode:   $( [[ "$SB_SETUP_MODE" == "01" ]] && echo "Good - available" || echo "NOT available - enable in BIOS first" )\n\
  Secure Boot:  $( [[ "$SB_CURRENT"    == "01" ]] && echo "currently ENABLED - disable in BIOS first!" || echo "Good - currently disabled" )\n\
\n\
REQUIREMENTS:\n\
- Secure Boot must be DISABLED in BIOS right now\n\
- BIOS must support Setup Mode (custom keys)" \
  16 62; then
  ENABLE_SECUREBOOT=true
  if dialog --yesno \
    "Include Microsoft CA?\n\nRequired for dual-boot with Windows.\nWARNING: CAN BRICK SYSTEM on some hardware." \
    10 62; then
    MICROSOFT_CA=true
  fi
fi


# ── GPU auto-detection ────────────────────────────────────────────────────────
GPU_INFO=$(lspci | grep -E "VGA|3D|Display" || echo "")
GPU_PCI_ID=$(lspci -nn | grep -E "VGA|3D|Display" | grep -i nvidia | grep -oP '\[10de:\K[0-9a-f]+' | head -1 || echo "")
HAS_NVIDIA=$(echo "$GPU_INFO" | grep -qi "nvidia"                    && echo true || echo false)
HAS_AMD=$(echo "$GPU_INFO"    | grep -qi "amd\|radeon\|advanced micro" && echo true || echo false)
HAS_INTEL=$(echo "$GPU_INFO"  | grep -qi "intel"                     && echo true || echo false)



if   $HAS_NVIDIA && $HAS_INTEL; then GPU_DEFAULT="hybrid-nvidia-intel"
elif $HAS_NVIDIA && $HAS_AMD;   then GPU_DEFAULT="hybrid-nvidia-amd"
elif $HAS_NVIDIA; then
  [[ -n "$GPU_PCI_ID" && $((16#${GPU_PCI_ID})) -lt $((16#1e04)) ]] && GPU_DEFAULT="nvidia-legacy" || GPU_DEFAULT="nvidia"
elif $HAS_AMD;                  then GPU_DEFAULT="amd"
elif $HAS_INTEL;                then GPU_DEFAULT="intel"
else                                 GPU_DEFAULT="none"
fi

[[ -n "$GPU_PCI_ID" ]] && GPU_DETECT_INFO="${GPU_INFO} [10de:${GPU_PCI_ID}]" || GPU_DETECT_INFO="${GPU_INFO:-none}"

GPU_CHOICE=$(dialog --stdout --menu \
  "GPU Driver\n\nDetected: ${GPU_DETECT_INFO}\nSuggested: ${GPU_DEFAULT}" 22 72 7 \
  "amd"                 "AMD - vulkan-radeon + mesa" \
  "intel"               "Intel - mesa + intel-media-driver" \
  "nvidia"              "Nvidia - nvidia-open-dkms (Turing RTX 20xx and up as well as GTX 1650)" \
  "hybrid-nvidia-intel" "Hybrid: Intel iGPU + Nvidia dGPU (Turing+)" \
  "hybrid-nvidia-amd"   "Hybrid: AMD iGPU + Nvidia dGPU (Turing+)" \
  "nvidia-legacy"       "Nvidia Legacy - (Maxwell GTX 9xx through Pascal GTX 10xx) - 580xx-dkms - installed via AUR helper" \
  "none"                "Skip . install manually later.") || die "Cancelled."

if [[ "$GPU_CHOICE" == nvidia* || "$GPU_CHOICE" == hybrid-nvidia* ]]; then
  dialog --msgbox \
    "Nvidia GPU notice:\n\n\
Detected:  ${GPU_DETECT_INFO}\n\
Suggested: ${GPU_DEFAULT}\n\n\
Driver selection guide:\n\
  Turing RTX 20xx / GTX 1650 and newer → nvidia (open)\n\
  Maxwell GTX 9xx through Volta        → nvidia-legacy (580xx-dkms, AUR)\n\
  Kepler and older                     → select 'none', install manually\n\
\n\
Kernel params configured automatically.\n\
Hyprland env vars (set in dotfiles):\n\
  LIBVA_DRIVER_NAME=nvidia\n\
  __GLX_VENDOR_LIBRARY_NAME=nvidia\n\
  WLR_NO_HARDWARE_CURSORS=1\n\
  NVD_BACKEND=direct" \
  18 65
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
  "bat"            "nicer cat"                   ON  \
  "eza"            "Better ls"                    ON  \
  "tree"           "Directory tree"               ON  \
  "bind"           "DNS utils"              ON  \
  "net-tools"      "Network tools (ifconfig etc)" ON  \
  "tldr"           "Simplified man pages"         ON  \
  "tmux"	   "Terminal Multiplexer"	  ON  ) || true

PKGS_APPS=$(dialog --stdout --checklist "Applications" 22 72 16 \
  "mpv"                      "Media player"                                 ON \
  "imv"                      "Image viewer"                                 ON \
  "ffmpeg"                   "Audio/video converter (needed by many tools)" ON \
  "firefox"                  "Web browser"                                  ON \
  "thunderbird"              "Email client"                                 OFF \
  "signal-desktop"           "Encrypted messenger"                          OFF \
  "obsidian"                 "Markdown notes"                               OFF \
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
  "protonmail"  "Proton Mail"     OFF ) || true

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
  PKGS_AUR="$PKGS_AUR nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings lib32-nvidia-580xx-utils"
fi

# ── AUR helper ────────────────────────────────────────────────────────────────
# Only asks if AUR packages got selected..
if [[ -n "$PKGS_AUR" ]]; then
  AUR_HELPER=$(dialog --stdout --radiolist \
    "AUR Helper\n\nRequired to install your selected AUR packages after first boot.\nbase-devel will be added automatically." \
    14 72 2 \
    "paru" "Rust-based, shows PKGBUILD before install" ON \
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
"Disk:            $DISK
CPU/ucode:        $UCODE
Username:         $USERNAME
Hostname:         $HOSTNAME
Locale:           $LOCALE
Timezone:         $TIMEZONE
Keymap:           $KEYMAP
EFI size:         $EFI_SIZE
Fallback-Kernel:  $ENABLE_LTS
GPU:              $GPU_CHOICE
Swap:             $SWAP_SUMMARY
Autologin:        $AL_SUMMARY
SecureBoot:       $SB_SUMMARY
AurHelper:        ${AUR_HELPER:-none}

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
# PHASE 2 — partition, format, mount
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
  mount -o "noatime,nodatacow,nodatasum,compress=no,subvol=@swap" "$LUKS_DEV" /mnt/swap
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
# PHASE 3 — pacstrap
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

info "Running pacstrap (kernel)..."
# systemd-boot is part of systemd — already in base, bootctl is the installer tool
if $ENABLE_LTS; then
  pacstrap /mnt linux linux-lts
else
  pacstrap /mnt linux
fi


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


# =============================================================================
# PHASE 4 — copy chroot script and dracut module for snapshots to target
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info "Copying chroot_setup.sh..."
cp "${SCRIPT_DIR}/chroot_setup.sh" /mnt/root/chroot_setup.sh
chmod +x /mnt/root/chroot_setup.sh

info "Copying dracut snapshot-menu module..."
mkdir -p /mnt/usr/lib/dracut/modules.d/99snapshot-menu
cp "${SCRIPT_DIR}/dracut/99snapshot-menu/"*.sh "${SCRIPT_DIR}/dracut/99snapshot-menu/"*.service /mnt/usr/lib/dracut/modules.d/99snapshot-menu/
chmod +x /mnt/usr/lib/dracut/modules.d/99snapshot-menu/*.sh

success "All scripts copied."

# =============================================================================
# PHASE 5 — enter chroot
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
  ENABLE_LTS="$ENABLE_LTS" \
  bash /root/chroot_setup.sh

echo ""
success "All done!"
rm -f /mnt/root/chroot_setup.sh
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
