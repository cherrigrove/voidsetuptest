#!/usr/bin/env bash
#
# void-desktop-setup.sh
#
# Automated post-install desktop setup for Void Linux.
#   - Desktop Environment / Window Manager  (official Void repos, plus
#     well-known third-party repos for Hyprland / DankMaterialShell / Noctalia)
#   - Login manager: SDDM (Plasma/LXQt), GDM (GNOME), LightDM (XFCE/MATE/i3),
#     greetd+tuigreet (bare Wayland compositors)
#   - GPU drivers: AMD, Intel iGPU, Intel dGPU, NVIDIA Nouveau, NVIDIA
#     Proprietary, Mesa (VMs)
#   - Audio: PipeWire + WirePlumber + ALSA compatibility layer
#   - Networking: NetworkManager + wifi firmware
#   - Printing: CUPS + Avahi (network/driverless printer discovery)
#   - Xorg / Wayland core packages, sudo, user groups, file manager access
#   - Every critical package/service install is verified; the script stops
#     with a clear error instead of silently limping on.
#
# Usage:  sudo bash void-desktop-setup.sh          (or just: bash void-desktop-setup.sh)
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
die()   { err "$*"; err "See $LOG_FILE for the full command output."; exit 1; }

LOG_FILE="/var/log/void-desktop-setup.log"

# Every failed/attempted command lands in this array so the final report can
# tell the user exactly what to look at instead of a generic "it worked".
declare -a FAILED_STEPS=()

# ----------------------------------------------------------------------------
# xbps-install wrappers
#   xi        -> required package(s). Failure ABORTS the script immediately.
#   xi_soft   -> optional/nice-to-have package(s). Failure just warns.
# Both stream full xbps-install output to the terminal AND the log file, so
# nothing important is ever hidden.
# ----------------------------------------------------------------------------
# IMPORTANT: xbps-install treats a multi-package argument list as ONE
# transaction -- if even one name in the list is wrong/unavailable, the
# WHOLE transaction is rejected and nothing gets installed, including the
# packages that were perfectly fine. So both wrappers below install each
# package as its own separate transaction: one bad/renamed package name
# only affects itself, not its neighbors.
xi() {
    # required packages: install one at a time; abort with a precise
    # error naming exactly which package failed.
    local pkg failed=()
    for pkg in "$@"; do
        info "Installing (required): $pkg"
        if ! xbps-install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
            err "Failed to install required package: $pkg"
            failed+=("$pkg")
        fi
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        die "Required package(s) failed to install: ${failed[*]}"
    fi
}

xi_soft() {
    # optional/best-effort packages: install one at a time; never abort.
    local pkg ok_any=1
    for pkg in "$@"; do
        info "Installing (optional): $pkg"
        if xbps-install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
            ok_any=0
        else
            warn "Optional package failed to install, continuing: $pkg"
            FAILED_STEPS+=("optional package: $pkg")
        fi
    done
    return $ok_any
}

# Try a list of candidate package names one after another; install (and
# stop) on the first one that succeeds. Useful when a package's exact name
# is inconsistent across distros/versions (e.g. tuigreet vs greetd-tuigreet).
xi_first_available() {
    local pkg
    for pkg in "$@"; do
        info "Trying package: $pkg"
        if xbps-install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
            echo "$pkg"
            return 0
        fi
        warn "'$pkg' not available, trying next candidate..."
    done
    return 1
}

sync_repos() {
    info "Syncing repository index..."
    xbps-install -Sy 2>&1 | tee -a "$LOG_FILE" || die "Could not sync xbps repositories. Check your network connection."
}

# ----------------------------------------------------------------------------
# Service enabling, WITH verification
# ----------------------------------------------------------------------------
enable_service() {
    local svc="$1" required="${2:-soft}"
    if [ ! -d "/etc/sv/$svc" ]; then
        if [ "$required" = "hard" ]; then
            FAILED_STEPS+=("service '$svc' not found in /etc/sv -- its package did not install correctly")
            warn "/etc/sv/$svc does not exist -- the package providing it did not install correctly."
        fi
        return 1
    fi
    if [ ! -e "/var/service/$svc" ]; then
        ln -s "/etc/sv/$svc" /var/service/ 2>/dev/null
    fi
    # Give runit a moment to pick it up, then verify.
    sleep 1
    if [ -L "/var/service/$svc" ]; then
        ok "Service enabled: $svc"
        return 0
    else
        FAILED_STEPS+=("service '$svc' could not be enabled")
        warn "Could not enable service: $svc"
        return 1
    fi
}

verify_binary() {
    local bin="$1" label="$2"
    if command -v "$bin" >/dev/null 2>&1; then
        ok "$label found ($bin)"
        return 0
    else
        FAILED_STEPS+=("$label: '$bin' not found on PATH after install")
        warn "$label: '$bin' not found after installation!"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Re-exec with root if needed (sudo will set SUDO_USER for us automatically)
# ----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    info "Root privileges are required. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
elif [ $# -ge 1 ] && id "$1" &>/dev/null; then
    TARGET_USER="$1"
else
    header "User account"
    read -rp "Enter the username this desktop setup is for: " TARGET_USER
fi

id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist. Create it first with: useradd -m -G wheel $TARGET_USER"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# ----------------------------------------------------------------------------
# Sanity checks
# ----------------------------------------------------------------------------
: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

if [ -r /etc/os-release ]; then
    . /etc/os-release
    [ "${ID:-}" = "void" ] || warn "This does not look like Void Linux (ID='${ID:-unknown}'). Continuing anyway."
fi

command -v xbps-install >/dev/null 2>&1 || die "xbps-install not found -- this script only works on Void Linux."

ARCH=$(xbps-uhelper arch)
info "Detected architecture: $ARCH"
info "Setting up desktop for user: $TARGET_USER (home: $TARGET_HOME)"

# ----------------------------------------------------------------------------
# Menu helper
# ----------------------------------------------------------------------------
ask_choice() {
    local min="$1" max="$2" choice
    while true; do
        read -rp "Enter your choice [$min-$max]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
            echo "$choice"; return 0
        fi
        warn "Invalid choice. Please enter a number between $min and $max."
    done
}

# ============================================================================
# STEP 1: Desktop Environment / Window Manager selection
# ============================================================================
DE_NAMES=(
    ""                                  # 0 unused
    "KDE Plasma"
    "GNOME"
    "XFCE"
    "MATE"
    "LXQt"
    "Hyprland + Dank Material Shell"
    "Niri + Dank Material Shell"
    "Sway + Dank Material Shell"
    "Labwc + Dank Material Shell"
    "Wayfire + Noctalia Shell"
    "River + Noctalia Shell"
    "i3"
)

header "Void Linux Desktop Setup"
cat <<'EOF'
Choose a Desktop Environment/Window Manager:

  1. KDE Plasma           (full DE, Xorg + Wayland, official repos)
  2. GNOME                 (full DE, Wayland by default, official repos)
  3. XFCE                  (lightweight DE, Xorg, official repos)
  4. MATE                  (lightweight DE, Xorg, official repos)
  5. LXQt                  (lightweight DE, Xorg, official repos)
  6. Hyprland              (Wayland WM, tiling)   -> bundled with Dank Material Shell
  7. Niri                  (Wayland WM, scrolling) -> bundled with Dank Material Shell
  8. Sway                  (Wayland WM, i3-like)   -> bundled with Dank Material Shell
  9. Labwc                 (Wayland WM, Openbox-style) -> bundled with Dank Material Shell
 10. Wayfire               (Wayland WM, 3D/compiz-like) -> bundled with Noctalia Shell
 11. River                 (Wayland WM, dynamic tiling) -> bundled with Noctalia Shell
 12. i3                    (Xorg WM, tiling, minimal)

EOF
DE_CHOICE=$(ask_choice 1 12)

# ============================================================================
# STEP 2: GPU driver selection
# ============================================================================
GPU_NAMES=(
    ""
    "AMD"
    "Intel iGPU"
    "Intel dGPU"
    "NVIDIA Nouveau (open-source)"
    "NVIDIA Proprietary"
    "Mesa (for VMs)"
)

header "GPU Driver Setup"
cat <<'EOF'
Choose your GPU Drivers:

  1. AMD
  2. Intel iGPU
  3. Intel dGPU
  4. NVIDIA Nouveau
  5. NVIDIA Proprietary
  6. Mesa (for VMs)

EOF
GPU_CHOICE=$(ask_choice 1 6)

header "Summary"
echo "  User:              $TARGET_USER"
echo "  Desktop/WM:        ${DE_NAMES[$DE_CHOICE]}"
echo "  GPU driver:        ${GPU_NAMES[$GPU_CHOICE]}"
read -rp "Proceed with installation? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy] ]] || die "Aborted by user."

# ============================================================================
# STEP 3: Full system sync/update FIRST.
# A fresh/ISO Void install often has a stale package index; installing
# desktop metapackages against it is the #1 cause of "it didn't work".
# ============================================================================
header "Updating package index and system"
sync_repos
info "Running a full system update (this can take a while on a fresh VM)..."
xbps-install -Suy 2>&1 | tee -a "$LOG_FILE"
# Void convention: if xbps itself was updated, a 2nd pass picks up the rest.
xbps-install -Suy 2>&1 | tee -a "$LOG_FILE"
ok "System is up to date."

xi void-repo-nonfree
sync_repos

# ============================================================================
# STEP 4: Base graphical stack (dbus, seat management, portals, fonts)
# ============================================================================
header "Installing base system services"
xi dbus elogind seatd polkit sudo
xi_soft xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal \
   git wget curl nano unzip zip htop \
   dejavu-fonts-ttf liberation-fonts-ttf noto-fonts-emoji terminus-font \
   udisks2 gvfs

enable_service dbus hard
enable_service polkitd
enable_service elogind
enable_service seatd

if getent group _seatd >/dev/null 2>&1; then
    usermod -aG _seatd "$TARGET_USER"
fi

# ============================================================================
# STEP 5: Networking -- NetworkManager for WiFi + Ethernet
# ============================================================================
header "Setting up networking / WiFi (NetworkManager)"
xi NetworkManager
xi_soft network-manager-applet linux-firmware-network wpa_supplicant

# Void ships dhcpcd enabled by default on some install profiles; it will
# fight with NetworkManager over the interface, so disable it if present.
[ -e /var/service/dhcpcd ] && rm -f /var/service/dhcpcd

enable_service NetworkManager hard
verify_binary nmcli "NetworkManager CLI"
usermod -aG network "$TARGET_USER" 2>/dev/null || true
ok "NetworkManager installed and enabled."

# ============================================================================
# STEP 6: Audio -- PipeWire + WirePlumber + ALSA compatibility
# ============================================================================
header "Setting up audio (PipeWire)"
xi pipewire
xi_soft alsa-pipewire libspa-bluetooth pavucontrol pamixer playerctl

mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf \
    /etc/pipewire/pipewire.conf.d/10-wireplumber.conf 2>/dev/null || true

mkdir -p /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf 2>/dev/null || true
ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/99-pipewire-default.conf 2>/dev/null || true

mkdir -p /etc/xdg/autostart
[ -f /usr/share/applications/pipewire.desktop ] && \
    ln -sf /usr/share/applications/pipewire.desktop /etc/xdg/autostart/pipewire.desktop 2>/dev/null

[ -f /usr/share/applications/pipewire-pulse.desktop ] && \
    ln -sf /usr/share/applications/pipewire-pulse.desktop /etc/xdg/autostart/pipewire-pulse.desktop 2>/dev/null

verify_binary pipewire "PipeWire"
verify_binary wireplumber "WirePlumber"
usermod -aG audio,video,input "$TARGET_USER" 2>/dev/null || true
ok "Audio stack installed (PipeWire + ALSA compatibility layer)."

# ============================================================================
# STEP 7: Printing -- CUPS + Avahi for network/driverless printers
# ============================================================================
header "Setting up printing (CUPS)"
xi cups
xi_soft cups-filters avahi nss-mdns system-config-printer

enable_service cupsd hard
enable_service avahi-daemon
verify_binary lpstat "CUPS"

if getent group lpadmin >/dev/null 2>&1; then
    usermod -aG lpadmin "$TARGET_USER"
fi
ok "CUPS installed and enabled. Manage printers at http://localhost:631 or via system-config-printer."

# ============================================================================
# STEP 8: GPU drivers
# ============================================================================
header "Installing GPU drivers"
# Only the base OpenGL bits are hard-required -- without mesa-dri there's no
# graphical output at all. Everything else here (Vulkan, VA-API, VDPAU,
# vendor-specific DDX drivers) is a performance/feature add-on: Xorg and
# Wayland compositors fall back to the generic "modesetting"/llvmpipe path
# just fine without them, so those are all soft-installed. This also means
# one wrong/renamed package name (as happened with mesa-vulkan-swrast and
# xf86-video-vmware, neither of which actually exist in Void's repos) can
# no longer take down the whole GPU step.
xi vulkan-loader mesa-dri
xi_soft mesa-vaapi libvdpau-va-gl

case "$GPU_CHOICE" in
    1) info "Installing AMD drivers..."
       xi_soft linux-firmware-amd mesa-vulkan-radeon xf86-video-amdgpu
       ;;
    2) info "Installing Intel iGPU drivers..."
       xi_soft linux-firmware-intel mesa-vulkan-intel intel-video-accel
       ;;
    3) info "Installing Intel dGPU (Arc) drivers..."
       xi_soft linux-firmware-intel mesa-vulkan-intel intel-video-accel
       warn "Intel Arc dGPUs need a recent kernel. Run 'xbps-install -Su linux' if you hit issues."
       ;;
    4) info "Installing NVIDIA (Nouveau, open-source) drivers..."
       xi_soft xf86-video-nouveau mesa-vulkan-nouveau
       ;;
    5) info "Installing NVIDIA proprietary drivers..."
       xi nvidia
       xi_soft nvidia-libs
       warn "A reboot is required for the proprietary NVIDIA driver to take effect."
       ;;
    6) info "Installing Mesa (generic/VM) drivers..."
       # mesa-vulkan-lavapipe is Void's actual name for the software Vulkan
       # rasterizer (upstream renamed it from "swrast" to "lavapipe" years
       # ago -- Void's package follows that naming). xf86-video-vmware is
       # not packaged in Void at all; VMware/QEMU guests use the generic
       # "modesetting" Xorg driver instead, which mesa-dri already covers.
       xi_soft mesa-vulkan-lavapipe xf86-video-qxl xf86-video-fbdev
       xi_soft qemu-guest-agent spice-vdagent
       enable_service qemu-guest-agent
       enable_service spice-vdagentd
       SYS_VENDOR=""
       [ -r /sys/class/dmi/id/sys_vendor ] && SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
       case "$SYS_VENDOR" in
           *VMware*) xi_soft open-vm-tools && enable_service vmtoolsd ;;
           *innotek*|*VirtualBox*) xi_soft virtualbox-ose-guest && enable_service vboxguest ;;
       esac
       ;;
esac
ok "GPU driver installation complete."

# ============================================================================
# STEP 9: DE / WM installation
# ============================================================================
header "Installing Desktop Environment / Window Manager: ${DE_NAMES[$DE_CHOICE]}"

install_dms_repo() {
    echo "repository=https://void.danklinux.com/dms/current" > /etc/xbps.d/10-dms.conf
    echo "repository=https://void.danklinux.com/danklinux/current" > /etc/xbps.d/10-danklinux.conf
    sync_repos
}

install_dank_material_shell() {
    info "Installing Dank Material Shell (DMS)..."
    install_dms_repo
    # matugen/quickshell are pulled in automatically as dependencies of dms,
    # so only dms + dgop are installed explicitly here.
    xi dms
    xi_soft dgop
    verify_binary dms "Dank Material Shell"
    ok "Dank Material Shell installed."
}

install_noctalia_repo() {
    echo "repository=https://repo.voiders.dev" > /etc/xbps.d/10-voiders-community.conf
    sync_repos
}

install_noctalia_shell() {
    info "Installing Noctalia Shell..."
    install_noctalia_repo
    xbps-remove -y quickshell 2>/dev/null || true
    xi noctalia-shell
    verify_binary noctalia-shell "Noctalia Shell"
    ok "Noctalia Shell installed."
}

install_hyprland_repo() {
    echo "repository=https://raw.githubusercontent.com/Makrennel/hyprland-void/repository-${ARCH}" > /etc/xbps.d/10-hyprland.conf
    sync_repos
}

install_greetd() {
    local session_cmd="$1" greeter_cmd
    xi greetd
    # The tuigreet package name has varied between Void package revisions
    # (tuigreet vs greetd-tuigreet). Try both; if neither is available,
    # fall back to agreety, which ships as part of the greetd package
    # itself and always works, just with a plainer prompt.
    if xi_first_available tuigreet greetd-tuigreet >/dev/null; then
        greeter_cmd="tuigreet --time --remember --cmd '${session_cmd}'"
        ok "Using tuigreet as the greetd front-end."
    else
        warn "No tuigreet package found -- falling back to greetd's built-in agreety greeter."
        greeter_cmd="agreety --cmd '${session_cmd}'"
    fi
    mkdir -p /etc/greetd
    cat > /etc/greetd/config.toml <<EOFGREET
[terminal]
vt = 1

[default_session]
command = "${greeter_cmd}"
user = "greeter"
EOFGREET
    enable_service greetd hard
}

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

# Full "xorg" meta-package (not xorg-minimal) so DDX drivers/fonts/input
# drivers are all guaranteed present -- this is a common cause of a blank
# screen or missing DM on Xorg desktops. Only "xorg" itself is treated as
# hard-required; xterm/setxkbmap/numlockx are just conveniences.
XORG_PKGS=(xorg)
XORG_EXTRAS=(xterm setxkbmap numlockx)
WAYLAND_CORE=(wayland xorg-server-xwayland)

case "$DE_CHOICE" in
    1) xi "${XORG_PKGS[@]}"; xi_soft "${XORG_EXTRAS[@]}"
       xi kde-plasma
       xi_soft kde-baseapps
       enable_service sddm hard
       verify_binary sddm "SDDM"
       ok "KDE Plasma installed. Login manager: SDDM."
       ;;
    2) xi "${XORG_PKGS[@]}"; xi_soft "${XORG_EXTRAS[@]}"
       xi gnome gdm
       xi_soft gnome-browser-connector xdg-desktop-portal-gnome
       enable_service gdm hard
       verify_binary gdm "GDM"
       ok "GNOME installed. Login manager: GDM."
       ;;
    3) xi "${XORG_PKGS[@]}"; xi_soft "${XORG_EXTRAS[@]}"
       xi xfce4 lightdm lightdm-gtk3-greeter
       xi_soft xfce4-goodies network-manager-applet
       enable_service lightdm hard
       verify_binary lightdm "LightDM"
       ok "XFCE installed. Login manager: LightDM."
       ;;
    4) xi "${XORG_PKGS[@]}"; xi_soft "${XORG_EXTRAS[@]}"
       xi mate lightdm lightdm-gtk3-greeter
       xi_soft mate-extra network-manager-applet
       enable_service lightdm hard
       verify_binary lightdm "LightDM"
       ok "MATE installed. Login manager: LightDM."
       ;;
    5) xi "${XORG_PKGS[@]}"; xi_soft "${XORG_EXTRAS[@]}"
       xi lxqt sddm
       xi_soft network-manager-applet
       enable_service sddm hard
       verify_binary sddm "SDDM"
       ok "LXQt installed. Login manager: SDDM."
       ;;
    6) install_hyprland_repo
       xi hyprland "${WAYLAND_CORE[@]}"
       xi_soft hyprland-devel xdg-desktop-portal-hyprland \
          hypridle hyprlock hyprpaper qt5-wayland qt6-wayland pcmanfm gvfs-mtp
       install_dank_material_shell
       install_greetd "Hyprland"
       autostart_shell_cmd ".config/hypr" "hyprland.conf" "exec-once = dms run"
       ok "Hyprland + Dank Material Shell installed. Login manager: greetd."
       ;;
    7) xi niri "${WAYLAND_CORE[@]}"
       xi_soft xdg-desktop-portal-gtk pcmanfm gvfs-mtp
       install_dank_material_shell
       install_greetd "niri"
       autostart_shell_cmd ".config/niri" "config.kdl" "spawn-at-startup \"dms\" \"run\""
       ok "Niri + Dank Material Shell installed. Login manager: greetd."
       ;;
    8) xi sway "${WAYLAND_CORE[@]}"
       xi_soft swaylock swayidle swaybg xdg-desktop-portal-wlr pcmanfm gvfs-mtp
       install_dank_material_shell
       install_greetd "sway"
       autostart_shell_cmd ".config/sway" "config" "exec dms run"
       ok "Sway + Dank Material Shell installed. Login manager: greetd."
       ;;
    9) xi labwc "${WAYLAND_CORE[@]}"
       xi_soft swaybg xdg-desktop-portal-wlr pcmanfm gvfs-mtp
       install_dank_material_shell
       install_greetd "labwc"
       autostart_shell_cmd ".config/labwc" "autostart" "dms run &"
       ok "Labwc + Dank Material Shell installed. Login manager: greetd."
       ;;
    10) xi wayfire "${WAYLAND_CORE[@]}"
        xi_soft wf-shell wcm xdg-desktop-portal-wlr pcmanfm gvfs-mtp
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
        ok "Wayfire + Noctalia Shell installed. Login manager: greetd."
        ;;
    11) xi river "${WAYLAND_CORE[@]}"
        xi_soft xdg-desktop-portal-wlr pcmanfm gvfs-mtp
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
        ok "River + Noctalia Shell installed. Login manager: greetd."
        ;;
    12) xi "${XORG_PKGS[@]}"; xi_soft "${XORG_EXTRAS[@]}"
        xi i3 lightdm lightdm-gtk3-greeter
        xi_soft i3status i3lock dmenu picom feh pcmanfm gvfs network-manager-applet
        enable_service lightdm hard
        verify_binary lightdm "LightDM"
        ok "i3 installed. Login manager: LightDM. (DMS/Noctalia are Wayland-only; i3 uses i3status/dmenu.)"
        ;;
esac

# ============================================================================
# STEP 10: sudo / wheel group
# ============================================================================
header "Configuring sudo"
usermod -aG wheel "$TARGET_USER"

if [ -f /etc/sudoers ]; then
    if ! grep -Eq '^[^#]*%wheel\s+ALL=\(ALL(:ALL)?\)\s+ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
        echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
        chmod 0440 /etc/sudoers.d/wheel
        if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers.d/wheel >/dev/null 2>&1; then
            FAILED_STEPS+=("visudo validation failed for /etc/sudoers.d/wheel")
            warn "visudo validation failed for wheel rule -- please check /etc/sudoers.d/wheel manually."
        else
            ok "Enabled sudo for group 'wheel' via /etc/sudoers.d/wheel"
        fi
    else
        ok "wheel group already has sudo rights."
    fi
fi

# ============================================================================
# STEP 11: File access niceties
# ============================================================================
header "Finishing touches"
enable_service udisks2
su - "$TARGET_USER" -c "xdg-user-dirs-update" 2>/dev/null || true

# ============================================================================
# STEP 12: Verification report
# ============================================================================
header "Verification report"
printf "%-28s %s\n" "Component" "Status"
printf "%-28s %s\n" "---------" "------"
check_line() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        printf "%-28s ${C_GREEN}PASS${C_RESET}\n" "$label"
    else
        printf "%-28s ${C_RED}FAIL${C_RESET}\n" "$label"
        FAILED_STEPS+=("$label")
    fi
}
check_line "dbus service"          '[ -L /var/service/dbus ]'
check_line "NetworkManager"        '[ -L /var/service/NetworkManager ] && command -v nmcli >/dev/null'
check_line "PipeWire"              'command -v pipewire >/dev/null'
check_line "CUPS"                  '[ -L /var/service/cupsd ] && command -v lpstat >/dev/null'
check_line "wheel sudo rule"       'grep -Eq "wheel.*ALL=" /etc/sudoers /etc/sudoers.d/* 2>/dev/null'
case "$DE_CHOICE" in
    1|5) check_line "Login manager (SDDM)" '[ -L /var/service/sddm ]' ;;
    2)   check_line "Login manager (GDM)"  '[ -L /var/service/gdm ]' ;;
    3|4|12) check_line "Login manager (LightDM)" '[ -L /var/service/lightdm ]' ;;
    6|7|8|9|10|11) check_line "Login manager (greetd)" '[ -L /var/service/greetd ]' ;;
esac

# ============================================================================
# Done
# ============================================================================
header "Setup complete"
echo "User:        $TARGET_USER"
echo "Desktop/WM:  ${DE_NAMES[$DE_CHOICE]}"
echo "GPU driver:  ${GPU_NAMES[$GPU_CHOICE]}"
echo "Log file:    $LOG_FILE"
echo

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    warn "The following items need attention before you reboot:"
    for item in "${FAILED_STEPS[@]}"; do
        printf "   - %s\n" "$item"
    done
    warn "Check $LOG_FILE for the exact xbps-install error output for each of these."
else
    ok "All checks passed."
fi

echo
echo ">>> Reboot now: sudo reboot <<<"
echo
echo "After reboot you should land on a graphical login screen. If a Wayland"
echo "compositor (Hyprland/Niri/Sway/Labwc/Wayfire/River) doesn't show its shell"
echo "bar automatically on first login, check the autostart line added to your"
echo "compositor config under ~/.config -- exact config syntax can shift"
echo "between versions of these still-young projects."
