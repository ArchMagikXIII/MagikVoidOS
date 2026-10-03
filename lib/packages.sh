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

    # Quickshell shell. quickshell pulls qt6-declarative/wayland-client itself,
    # but we pin them explicitly so a shell QML import error is never mistaken
    # for a missing package. Void does NOT ship per-QML-module packages
    # (no qml6-module-*): the imports live inside qt{5,6}-declarative.
    quickshell
    qt6-declarative
    qt6-wayland
    qt6-multimedia
    qt6-tools
    qt5-declarative
    qt5-quickcontrols2
    qt5-wayland
    # Every MagikOS theme background is .webp, and Qt6 has no WebP decoder
    # without this: Background.qml logs "Error decoding: ... Unsupported image
    # format" and the wallpaper picker shows nothing. Void's qt6-base ships only
    # gif/ico/jpeg/svg; this provides plugins/imageformats/libqwebp.so.
    qt6-imageformats

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
    Waybar
    jq

    # Decompressors. NOT optional: the Brave builder unpacks a .deb whose data
    # member is xz- or zstd-compressed, and GNU tar shells out to the `xz` /
    # `zstd` binaries rather than linking them. Without these, extraction dies
    # with "xz: Cannot exec" and the build reports a missing payload dir.
    # xbps .xbps files are zstd too, so tools that inspect them need it.
    xz
    zstd

    # Fonts + icons for the shell. fontconfig is not optional: fc-cache
    # registers the Nerd Font and fc-match verifies it, and the bar's glyphs
    # only work if "monospace" resolves to it.
    fontconfig
    liberation-fonts-ttf
    dejavu-fonts-ttf
    noto-fonts-ttf

    # Portal / session plumbing
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    polkit
    accountsservice
    gsettings-desktop-schemas
    gnome-keyring
    pipewire
    wireplumber

    # Shell/browser integration used by the menu
    gtk+
    libcups
)

# Packages the user must review before install (license / extra footprint).
VOID_OPTIONAL_PACKAGES=(
    flameshot
    fprintd
    power-profiles-daemon
    tailscale
    upower
)

# Is a package name resolvable in the enabled repositories?
#
# Use `-R -S` (repository + show), which is an *exact* pkgname lookup.
# Do NOT use `-Rs` ("search"): that also matches the description, so asking
# for `qt6` matches `AppStream-qt` and asking for a bad name like
# `qt6-qtdeclarative` can still return rows. Exact mode is the only
# trustworthy existence test.
pkg_available() {
    xbps-query -R -S "$1" >/dev/null 2>&1
}

# Check every requested name BEFORE handing anything to xbps-install.
#
# `xbps-install -y a b c` is one transaction: a single unresolvable name aborts
# the whole thing, so a typo in one entry silently installs *nothing*. That is
# exactly how quickshell went missing while the installer still said packages
# were installed. Verify names first and report every bad one at once.
verify_package_names() {
    local -a bad=()
    local p
    for p in "$@"; do
        pkg_available "$p" || bad+=("$p")
    done
    if ((${#bad[@]} == 0)); then
        return 0
    fi
    err "these package names do not exist in your Void repositories:"
    printf '        %s\n' "${bad[@]}"
    err "fix lib/packages.sh, or run: sudo xbps-install -S   # refresh the index"
    return 1
}

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

    # Guard the transaction: never ask xbps to install a name it cannot find.
    verify_package_names "${missing[@]}" || return 1

    ensure_sudo || return 1
    if [[ $DRY_RUN -eq 1 ]]; then
        _c sudo xbps-install -yS "${missing[@]}"
    else
        if ! sudo xbps-install -yS "${missing[@]}"; then
            err "xbps-install failed for: ${missing[*]}"
            err "check network/repo and try: sudo xbps-install -Syu"
            return 1
        fi
    fi
}
