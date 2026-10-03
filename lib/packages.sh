#!/usr/bin/env bash
# Void base package set for the MagikOS port.
#
# The upstream repo ships install/magikos-base.packages, which is a CachyOS
# package list (206 entries) and does not resolve on Void. This is the
# replacement: a curated, Void-native set covering the compositor, the
# Quickshell shell, MagikOS' bound keybindings, and the auth/portal stack.

VOID_BASE_PACKAGES=(
    # Compositor + session
    sway
    seatd
    wayland
    xorg-server-xwayland

    # Quickshell shell
    quickshell
    qt5-qtquickcontrols2
    qt6-qtdeclarative
    qt6-qtwayland
    qt6-tools
    qml6-module
    qml-module-qtquick
    qml-module-qtquick-controls
    qml-module-qtquick-layouts
    qml-module-qtmultimedia
    qt6-qtmultimedia
    qml-module-qtwayland

    # Terminal + bar/system helpers referenced by bindings & shell
    foot
    brightnessctl
    playerctl
    grim
    slurp
    swappy
    mako
    wofi
    dmenu
    wlr-randr
    wlrctl
    xkbutils
    inotify-tools
    wl-clipboard
    swaybg
    swayidle
    swaylock
    waybar
    jq

    # Fonts + icons for the shell
    font-liberation-ttf
    dejavu-ttf
    noto-fonts-ttf
    nerd-fonts-ttf
    nerd-fonts-symbols-ttf

    # Portal / session plumbing
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    xdg-desktop-portal-xcursors
    polkit
    accountsservice
    gsettings-desktop-schemas
    gnome-keyring
    pipewire
    wireplumber

    # Shell/browser integration used by the menu
    gtk3
    cups-libs
)

# Packages the user must review before install (license / extra footprint).
VOID_OPTIONAL_PACKAGES=(
    flameshot
    fprintd
    power-profiles-daemon
    tailscale
    upower
)

install_base_packages() {
    local missing=() p
    for p in "${VOID_BASE_PACKAGES[@]}"; do
        pkg_installed "$p" || missing+=("$p")
    done
    if ((${#missing[@]} == 0)); then
        ok "all base packages already installed"
        return 0
    fi
    log "Installing ${#missing[@]} base package(s) via xbps"
    printf '      %s\n' "${missing[@]}"
    ensure_sudo || return 1
    if [[ $DRY_RUN -eq 1 ]]; then
        _c sudo xbps-install -yS "${missing[@]}"
    else
        sudo xbps-install -yS "${missing[@]}"
    fi
}
