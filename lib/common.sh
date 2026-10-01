#!/usr/bin/env bash
# Shared helpers for the MagikOS Void installer.
# shellcheck shell=bash

MAGIKOS_UPSTREAM_URL="${MAGIKOS_UPSTREAM_URL:-https://github.com/ArchMagikXIII/MagikOS}"
MAGIKOS_HOME="${MAGIKOS_HOME:-$HOME/.local/share/magikos}"
BRAVE_PREFIX="${BRAVE_PREFIX:-/opt/brave-origin}"
BRAVE_VERSION="${BRAVE_VERSION:-1.96.60}"
DRY_RUN=0

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
