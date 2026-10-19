#!/usr/bin/env bash
# Shared helpers for the MagikOS Void installer.
# shellcheck shell=bash

MAGIKOS_UPSTREAM_URL="${MAGIKOS_UPSTREAM_URL:-https://github.com/ArchMagikXIII/MagikOS}"
MAGIKOS_HOME="${MAGIKOS_HOME:-$HOME/.local/share/magikos}"
MAGIKOS_USER_SWAY="${MAGIKOS_USER_SWAY:-$HOME/.config/sway}"
MAGIKOS_USER_CONFIG="${MAGIKOS_USER_CONFIG:-$HOME/.config/magikos}"
MAGIKOS_STATE_DIR="${MAGIKOS_STATE_DIR:-$HOME/.local/state/magikos}"
WALLPAPER="${WALLPAPER:-$HOME/Pictures/Wallpapers/Osaka.jpg}"
BRAVE_PREFIX="${BRAVE_PREFIX:-/opt/brave-origin}"
BRAVE_VERSION="${BRAVE_VERSION:-1.96.60}"
DRY_RUN=0
# Pin WLR_RENDERER=pixman automatically on machines with no usable GPU.
# Set to 0 to keep hardware rendering even if detection is wrong.
AUTO_SOFTWARE_RENDER="${AUTO_SOFTWARE_RENDER:-1}"

_c() { if [[ $DRY_RUN -eq 1 ]]; then printf '\033[2m[dry] %s\033[0m\n' "$*"; else "$@"; fi; }

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
err()  { printf '  \033[31merr\033[0m   %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    have "$1" || { err "required command not found: $1"; return 1; }
}

# Detect Void. Note: there is no /etc/xbps on Void -- the config lives in
# /etc/xbps.d and the package DB in /var/db/xbps. Checking for /etc/xbps
# (a natural-looking guess) makes this return false on a real Void install.
is_void() {
    have xbps-query || return 1
    [[ -d /var/db/xbps ]] || return 1
    xbps-query -p pkgver xbps 2>/dev/null | grep -q '^xbps-'
}

ensure_sudo() {
    [[ $EUID -eq 0 ]] && return 0
    if have sudo; then
        sudo -v || { err "need sudo privileges"; return 1; }
        return 0
    fi
    err "sudo not found and not root"
    return 1
}

# run_pacman_free_pkg_check <pkg> -> 0 if installed via xbps
pkg_installed() { xbps-query "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# ensure_dir <path> [label]
#
# Create a directory if it is missing and we can. Reports created / exists /
# could-not, and returns non-zero when the directory is absent AND we are not
# in dry-run. Every install step routes its mkdir through here so that:
#   * a fresh machine (no ~/.local, no ~/.config) works without hand setup
#   * --dry-run never touches the filesystem
#   * a path we cannot create is reported instead of failing silently later
# ---------------------------------------------------------------------------
ensure_dir() {
    local dir="$1" label="${2:-$1}"
    if [[ -d $dir ]]; then
        # Already there. Still verify it is writable, since a root-owned
        # ~/.config/sway from a previous sudo run breaks the copy silently.
        if [[ -w $dir ]]; then
            ok "$label"
            return 0
        fi
        err "$label exists but is NOT writable by $USER"
        err "     fix with: sudo chown -R $USER:$(id -gn) '$dir'"
        return 1
    fi

    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  would create %s\n' "$dir"
        return 0
    fi

    if mkdir -p "$dir" 2>/dev/null && [[ -d $dir ]]; then
        ok "created $dir"
        return 0
    fi
    err "could not create $dir"
    err "     parent: $(dirname "$dir")"
    return 1
}

# ensure_paths [--quiet]
#
# Create every directory the installer needs before any step runs. Doing this
# up front means a missing ~/.local/share or ~/.config is handled in one clear
# place instead of surfacing as a confusing failure three steps later.
ensure_paths() {
    local quiet=0
    [[ ${1:-} == --quiet ]] && quiet=1

local failures=0
    local d

    # Walk each chain parent-first and stop at the first failure, so a broken
    # ancestor does not produce a cascade of redundant "could not create"
    # messages for every descendant.
    # Runtime prefix: clone target plus its parent chain.
    if ensure_dir "$HOME/.local/share" "share root" \
       && ensure_dir "$(dirname "$MAGIKOS_HOME")" "runtime parent" \
       && ensure_dir "$MAGIKOS_HOME" "runtime dir"; then
        :
    else
        ((failures++))
    fi

    # Sway config + MagikOS user config.
    if ensure_dir "$HOME/.config" "config root" \
       && ensure_dir "$MAGIKOS_USER_SWAY" "sway config" \
       && ensure_dir "$MAGIKOS_USER_CONFIG" "magikos user config"; then
        :
    else
        ((failures++))
    fi

    # Shell state dir (quickshell logs).
    if ensure_dir "$HOME/.local/state" "state root" \
       && ensure_dir "$MAGIKOS_STATE_DIR" "magikos state"; then
        :
    else
        ((failures++))
    fi

    # Wallpaper: appearance.conf points at it; swaybg renders black if absent.
    ensure_dir "$(dirname "$WALLPAPER")" "wallpaper dir" || ((failures++))

    ((failures == 0)) || return 1
    return 0
}
