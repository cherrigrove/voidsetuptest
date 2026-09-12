#!/usr/bin/env bash
#
# void-desktop-setup.sh
#
# Automated post-install desktop setup for Void Linux.
#   - Desktop Environment / Window Manager installation (from official Void
#     repos, plus optional well-known third-party repos for Hyprland/DMS/Noctalia)
#   - GPU driver installation (AMD, Intel iGPU, Intel dGPU, NVIDIA Nouveau,
#     NVIDIA Proprietary, Mesa/virtual-machine)
#   - Audio (PipeWire + WirePlumber + ALSA compatibility)
#   - Networking (NetworkManager, wifi firmware)
#   - Sudo, user groups, file manager / archive / mounting support
#   - DankMaterialShell (DMS) bundled by default on compositors it supports,
#     falling back to Noctalia Shell on compositors DMS does not support.
#
# Tested against Void Linux (glibc + musl), x86_64. Run as a normal user
# with sudo installed and in the wheel group, OR just run it -- it will
# re-exec itself with sudo automatically.
#
# Sources consulted (Void Handbook, DankMaterialShell & Noctalia docs):
#   https://docs.voidlinux.org/config/graphical-session/
#   https://docs.voidlinux.org/config/media/pipewire.html
#   https://docs.voidlinux.org/config/network/networkmanager.html
#   https://danklinux.com/docs/1.6/dankmaterialshell/installation
#   https://docs.noctalia.dev/noctalia/getting-started/installation/
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Pretty output helpers
# ----------------------------------------------------------------------------
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[31m'; C_GREEN='\033[32m'
C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'

info()  { printf "${C_BLUE}${C_BOLD}[*]${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}${C_BOLD}[OK]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}${C_BOLD}[!]${C_RESET} %s\n" "$*"; }
err()   { printf "${C_RED}${C_BOLD}[ERROR]${C_RESET} %s\n" "$*" >&2; }
header(){ printf "\n${C_CYAN}${C_BOLD}==== %s ====${C_RESET}\n" "$*"; }
die()   { err "$*"; exit 1; }

LOG_FILE="/var/log/void-desktop-setup.log"

run() {
    # Run a command, log it, and don't let a single failed package abort
    # the whole script -- just warn loudly and keep going.
    echo "+ $*" >> "$LOG_FILE" 2>/dev/null || true
    if ! "$@"; then
        warn "Command failed (continuing): $*"
        return 1
    fi
    return 0
}

xi() {
    # xbps-install wrapper: -y auto-confirms (incl. new repo key trust)
    run xbps-install -y "$@"
}

enable_service() {
    local svc="$1"
    if [ -d "/etc/sv/$svc" ]; then
        if [ ! -e "/var/service/$svc" ]; then
            ln -s "/etc/sv/$svc" /var/service/ 2>/dev/null \
                && ok "Enabled service: $svc" \
                || warn "Could not enable service: $svc"
        else
            ok "Service already enabled: $svc"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Re-exec with sudo/root if needed
# ----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    info "Root privileges are required. Re-running with sudo..."
    exec sudo -E bash "$0" "${ORIGINAL_USER:-$USER}" "$@"
fi

# Figure out which non-root account we're setting the desktop up for.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
elif [ $# -ge 1 ] && id "$1" &>/dev/null; then
    TARGET_USER="$1"
else
    header "User account"
    read -rp "Enter the username this desktop setup is for: " TARGET_USER
fi

id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist. Create it first with 'useradd -m -G wheel $TARGET_USER'."
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# ----------------------------------------------------------------------------
# Sanity checks
# ----------------------------------------------------------------------------
if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "void" ]; then
        warn "This does not look like Void Linux (ID='${ID:-unknown}'). Continuing anyway."
    fi
else
    warn "Could not read /etc/os-release. Continuing anyway."
fi

command -v xbps-install >/dev/null 2>&1 || die "xbps-install not found -- this script only works on Void Linux."

ARCH=$(xbps-uhelper arch)
LIBC="glibc"
case "$ARCH" in
    *musl*) LIBC="musl" ;;
esac
info "Detected architecture: $ARCH ($LIBC)"

: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

# ----------------------------------------------------------------------------
# Menu helper
# ----------------------------------------------------------------------------
ask_choice() {
    # ask_choice "Prompt title" min max
    local prompt="$1" min="$2" max="$3" choice
    while true; do
        read -rp "Enter your choice [$min-$max]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
            echo "$choice"
            return 0
        fi
        warn "Invalid choice. Please enter a number between $min and $max."
    done
}

# ============================================================================
# STEP 1: Desktop Environment / Window Manager selection
# ============================================================================
header "Void Linux Desktop Setup"
cat <<'EOF'
Choose a Desktop Environment/Window Manager:

  1. KDE Plasma          (full DE, Xorg + Wayland, official repos)
  2. GNOME                (full DE, Wayland by default, official repos)
  3. XFCE                 (lightweight DE, Xorg, official repos)
  4. MATE                 (lightweight DE, Xorg, official repos)
  5. LXQt                 (lightweight DE, Xorg, official repos)
  6. Hyprland             (Wayland WM, tiling)  -> bundled with Dank Material Shell
  7. Niri                 (Wayland WM, scrolling)-> bundled with Dank Material Shell
  8. Sway                 (Wayland WM, i3-like) -> bundled with Dank Material Shell
  9. Labwc                (Wayland WM, Openbox-style) -> bundled with Dank Material Shell
 10. Wayfire               (Wayland WM, 3D/compiz-like) -> bundled with Noctalia Shell
 11. River                 (Wayland WM, dynamic tiling) -> bundled with Noctalia Shell
 12. i3                    (Xorg WM, tiling, minimal)

EOF
DE_CHOICE=$(ask_choice "de" 1 12)

# ============================================================================
# STEP 2: GPU driver selection
# ============================================================================
header "GPU Driver Setup"
cat <<'EOF'
Choose your GPU Drivers:

  1. AMD
  2. Intel iGPU
  3. Intel dGPU
  4. NVIDIA Nouveau (open-source)
  5. NVIDIA Proprietary
  6. Mesa (for VMs)

EOF
GPU_CHOICE=$(ask_choice "gpu" 1 6)

header "Summary"
echo "  User:              $TARGET_USER"
echo "  Desktop/WM:        option $DE_CHOICE"
echo "  GPU driver:        option $GPU_CHOICE"
read -rp "Proceed with installation? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy] ]] || die "Aborted by user."

# ============================================================================
# STEP 3: Sync repos + enable nonfree (needed for firmware / NVIDIA)
# ============================================================================
header "Enabling repositories"
xi void-repo-nonfree
run xbps-install -Sy
ok "Repository index synced"

# ============================================================================
# STEP 4: Base graphical stack (dbus, seat management, portals, fonts)
# ============================================================================
header "Installing base system services"
BASE_PKGS=(
    dbus elogind seatd polkit
    xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal
    sudo git wget curl nano unzip zip htop
    dejavu-fonts-ttf liberation-fonts-ttf noto-fonts-emoji terminus-font
    udisks2 gvfs
)
xi "${BASE_PKGS[@]}"

enable_service dbus
enable_service polkitd
enable_service elogind
enable_service seatd

# make sure the target user can use libseat
if getent group _seatd >/dev/null 2>&1; then
    usermod -aG _seatd "$TARGET_USER"
fi

# ============================================================================
# STEP 5: Networking (NetworkManager + wifi firmware)
# ============================================================================
header "Setting up networking / WiFi"
xi NetworkManager network-manager-applet linux-firmware-network wpa_supplicant
enable_service NetworkManager

# disable dhcpcd if it's running, NetworkManager will take over
if [ -e /var/service/dhcpcd ]; then
    rm -f /var/service/dhcpcd
fi

usermod -aG network "$TARGET_USER" 2>/dev/null || true

# ============================================================================
# STEP 6: Audio (PipeWire + WirePlumber + ALSA + Bluetooth audio)
# ============================================================================
header "Setting up audio (PipeWire)"
xi pipewire alsa-pipewire libspa-bluetooth pavucontrol pamixer playerctl

mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf \
    /etc/pipewire/pipewire.conf.d/10-wireplumber.conf 2>/dev/null || true

mkdir -p /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf 2>/dev/null || true
ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/99-pipewire-default.conf 2>/dev/null || true

# Autostart pipewire graphically for environments that honor XDG autostart
mkdir -p /etc/xdg/autostart
[ -f /usr/share/applications/pipewire.desktop ] && \
    ln -sf /usr/share/applications/pipewire.desktop /etc/xdg/autostart/pipewire.desktop 2>/dev/null || true

usermod -aG audio,video,input "$TARGET_USER" 2>/dev/null || true
ok "Audio stack installed (PipeWire + ALSA compatibility layer)"

# ============================================================================
# STEP 7: GPU drivers
# ============================================================================
header "Installing GPU drivers"

# Base Vulkan loader always useful
xi vulkan-loader mesa-dri mesa-vaapi mesa-vdpau

case "$GPU_CHOICE" in
    1) # AMD
        info "Installing AMD drivers..."
        xi linux-firmware-amd mesa-vulkan-radeon xf86-video-amdgpu
        ;;
    2) # Intel iGPU
        info "Installing Intel iGPU drivers..."
        xi linux-firmware-intel mesa-vulkan-intel intel-video-accel
        ;;
    3) # Intel dGPU (Arc etc.)
        info "Installing Intel dGPU (Arc) drivers..."
        xi linux-firmware-intel mesa-vulkan-intel intel-video-accel
        warn "Intel Arc dGPUs need a recent kernel. Run 'xbps-install -Su linux' if you hit issues."
        ;;
    4) # NVIDIA Nouveau
        info "Installing NVIDIA (Nouveau, open-source) drivers..."
        xi xf86-video-nouveau mesa-vulkan-nouveau libvdpau-va-gl
        ;;
    5) # NVIDIA Proprietary
        info "Installing NVIDIA proprietary drivers..."
        xi nvidia nvidia-libs
        warn "A reboot is required for the proprietary NVIDIA driver to take effect."
        ;;
    6) # Mesa / VM
        info "Installing Mesa (generic/VM) drivers..."
        xi mesa-vulkan-swrast xf86-video-qxl xf86-video-vmware xf86-video-fbdev
        xi qemu-guest-agent spice-vdagent
        enable_service qemu-guest-agent
        enable_service spice-vdagentd
        # Detect and install proper guest tools when possible
        SYS_VENDOR=""
        [ -r /sys/class/dmi/id/sys_vendor ] && SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
        case "$SYS_VENDOR" in
            *VMware*) xi open-vm-tools; enable_service vmtoolsd ;;
            *innotek*|*VirtualBox*) xi virtualbox-ose-guest; enable_service vboxguest ;;
        esac
        ;;
esac
ok "GPU driver installation complete."

# ============================================================================
# STEP 8: DE / WM installation
# ============================================================================
header "Installing Desktop Environment / Window Manager"

install_dms_repo() {
    echo "repository=https://void.danklinux.com/dms/current" \
        | tee /etc/xbps.d/10-dms.conf >/dev/null
    echo "repository=https://void.danklinux.com/danklinux/current" \
        | tee /etc/xbps.d/10-danklinux.conf >/dev/null
    run xbps-install -Sy
}

install_dank_material_shell() {
    info "Installing Dank Material Shell (DMS)..."
    install_dms_repo
    xi dms dgop matugen
    ok "Dank Material Shell installed."
}

install_noctalia_repo() {
    echo "repository=https://repo.voiders.dev" \
        | tee /etc/xbps.d/10-voiders-community.conf >/dev/null
    run xbps-install -Sy
}

install_noctalia_shell() {
    info "Installing Noctalia Shell..."
    install_noctalia_repo
    # noctalia-qs (its quickshell fork) conflicts with a plain quickshell pkg
    xbps-remove -y quickshell 2>/dev/null || true
    xi noctalia-shell
    ok "Noctalia Shell installed."
}

install_hyprland_repo() {
    echo "repository=https://raw.githubusercontent.com/Makrennel/hyprland-void/repository-${ARCH}" \
        | tee /etc/xbps.d/10-hyprland.conf >/dev/null
    run xbps-install -Sy
}

# greetd is used as the universal login manager for bare Wayland compositors
install_greetd() {
    local session_cmd="$1"
    xi greetd greetd-tuigreet
    mkdir -p /etc/greetd
    cat > /etc/greetd/config.toml <<EOFGREET
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --cmd '${session_cmd}'"
user = "greeter"
EOFGREET
    enable_service greetd
}

# Try to add an autostart line for DMS/Noctalia into a compositor's config
autostart_shell_cmd() {
    local conf_dir="$1" conf_file="$2" line="$3"
    local full="$TARGET_HOME/$conf_dir/$conf_file"
    su - "$TARGET_USER" -c "mkdir -p '$TARGET_HOME/$conf_dir'"
    if [ -f "$full" ]; then
        grep -qF "$line" "$full" 2>/dev/null || echo "$line" >> "$full"
    else
        echo "$line" > "$full"
    fi
    chown "$TARGET_USER":"$TARGET_USER" "$full" 2>/dev/null || true
}

XORG_PKGS=(xorg-minimal xorg-fonts xorg-input-drivers xterm setxkbmap)

case "$DE_CHOICE" in
    1) # KDE Plasma
        xi "${XORG_PKGS[@]}"
        xi kde-plasma kde-baseapps
        enable_service dbus
        ok "KDE Plasma installed. Login manager: SDDM."
        ;;
    2) # GNOME
        xi "${XORG_PKGS[@]}"
        xi gnome gdm gnome-browser-connector xdg-desktop-portal-gnome
        ok "GNOME installed. Login manager: GDM."
        ;;
    3) # XFCE
        xi "${XORG_PKGS[@]}"
        xi xfce4 xfce4-goodies lightdm lightdm-gtk3-greeter network-manager-applet
        enable_service lightdm
        ok "XFCE installed. Login manager: LightDM."
        ;;
    4) # MATE
        xi "${XORG_PKGS[@]}"
        xi mate mate-extra lightdm lightdm-gtk3-greeter network-manager-applet
        enable_service lightdm
        ok "MATE installed. Login manager: LightDM."
        ;;
    5) # LXQt
        xi "${XORG_PKGS[@]}"
        xi lxqt sddm network-manager-applet
        enable_service sddm
        ok "LXQt installed. Login manager: SDDM."
        ;;
    6) # Hyprland + DMS
        install_hyprland_repo
        xi hyprland hyprland-devel xdg-desktop-portal-hyprland \
           hypridle hyprlock hyprpaper qt5-wayland qt6-wayland xorg-server-xwayland pcmanfm gvfs-mtp
        install_dank_material_shell
        install_greetd "Hyprland"
        autostart_shell_cmd ".config/hypr" "hyprland.conf" "exec-once = dms run"
        ok "Hyprland + Dank Material Shell installed. Login manager: greetd/tuigreet."
        ;;
    7) # Niri + DMS
        xi niri xdg-desktop-portal-gtk xorg-server-xwayland pcmanfm gvfs-mtp
        install_dank_material_shell
        install_greetd "niri"
        autostart_shell_cmd ".config/niri" "config.kdl" "spawn-at-startup \"dms\" \"run\""
        ok "Niri + Dank Material Shell installed. Login manager: greetd/tuigreet."
        ;;
    8) # Sway + DMS
        xi sway swaylock swayidle swaybg xdg-desktop-portal-wlr xorg-server-xwayland pcmanfm gvfs-mtp
        install_dank_material_shell
        install_greetd "sway"
        autostart_shell_cmd ".config/sway" "config" "exec dms run"
        ok "Sway + Dank Material Shell installed. Login manager: greetd/tuigreet."
        ;;
    9) # Labwc + DMS
        xi labwc swaybg xdg-desktop-portal-wlr xorg-server-xwayland pcmanfm gvfs-mtp
        install_dank_material_shell
        install_greetd "labwc"
        autostart_shell_cmd ".config/labwc" "autostart" "dms run &"
        ok "Labwc + Dank Material Shell installed. Login manager: greetd/tuigreet."
        ;;
    10) # Wayfire + Noctalia (DMS does not officially support Wayfire)
        xi wayfire wf-shell wcm xdg-desktop-portal-wlr xorg-server-xwayland pcmanfm gvfs-mtp
        install_noctalia_shell
        install_greetd "wayfire"
        WF_CONF="$TARGET_HOME/.config/wayfire.ini"
        su - "$TARGET_USER" -c "mkdir -p '$TARGET_HOME/.config'"
        if [ -f "$WF_CONF" ] && grep -q '^\[autostart\]' "$WF_CONF" 2>/dev/null; then
            sed -i '/^\[autostart\]/a noctalia = noctalia-shell' "$WF_CONF"
        else
            printf '\n[autostart]\nnoctalia = noctalia-shell\n' >> "$WF_CONF"
        fi
        chown "$TARGET_USER":"$TARGET_USER" "$WF_CONF" 2>/dev/null || true
        ok "Wayfire + Noctalia Shell installed. Login manager: greetd/tuigreet."
        ;;
    11) # River + Noctalia (DMS does not officially support River)
        xi river xdg-desktop-portal-wlr xorg-server-xwayland pcmanfm gvfs-mtp
        install_noctalia_shell
        install_greetd "river"
        RIVER_INIT="$TARGET_HOME/.config/river/init"
        su - "$TARGET_USER" -c "mkdir -p '$TARGET_HOME/.config/river'"
        if [ ! -f "$RIVER_INIT" ]; then
            printf '#!/bin/sh\n\nriverctl spawn noctalia-shell\n' > "$RIVER_INIT"
        else
            grep -qF "noctalia-shell" "$RIVER_INIT" || echo "riverctl spawn noctalia-shell" >> "$RIVER_INIT"
        fi
        chown "$TARGET_USER":"$TARGET_USER" "$RIVER_INIT" 2>/dev/null || true
        chmod +x "$RIVER_INIT" 2>/dev/null || true
        ok "River + Noctalia Shell installed. Login manager: greetd/tuigreet."
        ;;
    12) # i3 (X11, no DMS/Noctalia -- both require Wayland)
        xi "${XORG_PKGS[@]}"
        xi i3 i3status i3lock dmenu picom feh lightdm lightdm-gtk3-greeter \
           pcmanfm gvfs network-manager-applet
        enable_service lightdm
        ok "i3 installed. Login manager: LightDM. (DMS/Noctalia are Wayland-only; i3 uses i3status/dmenu.)"
        ;;
esac

# ============================================================================
# STEP 9: sudo / wheel group
# ============================================================================
header "Configuring sudo"
usermod -aG wheel "$TARGET_USER"

if [ -f /etc/sudoers ]; then
    if ! grep -Eq '^[^#]*%wheel\s+ALL=\(ALL(:ALL)?\)\s+ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
        echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
        chmod 0440 /etc/sudoers.d/wheel
        if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers.d/wheel >/dev/null 2>&1; then
            warn "visudo validation failed for wheel rule -- please check /etc/sudoers.d/wheel manually."
        else
            ok "Enabled passwordless-capable sudo for group 'wheel' via /etc/sudoers.d/wheel"
        fi
    else
        ok "wheel group already has sudo rights."
    fi
fi

# ============================================================================
# STEP 10: File access niceties
# ============================================================================
header "Finishing touches"
enable_service udisks2 2>/dev/null || true
su - "$TARGET_USER" -c "xdg-user-dirs-update" 2>/dev/null || true

# ============================================================================
# Done
# ============================================================================
header "Setup complete!"
cat <<EOF
User '$TARGET_USER' has been configured with:
  - sudo (wheel group)
  - audio (PipeWire), video, input, network, _seatd group membership
  - NetworkManager for WiFi / wired networking
  - GPU drivers for option $GPU_CHOICE
  - Desktop/WM for option $DE_CHOICE

Log file: $LOG_FILE

>>> Please REBOOT now: sudo reboot <<<

After reboot you should land on a graphical login screen. If a Wayland
compositor (Hyprland/Niri/Sway/Labwc/Wayfire/River) doesn't show its shell
bar automatically on first login, check the autostart line that was added
to your compositor config in ~/.config and adjust it as needed -- config
syntax/keybind files vary between versions.
EOF
