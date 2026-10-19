#!/usr/bin/env bash
# MagikOS installer for Void Linux (unofficial port).
#
# Safe by default: never touches your running session, never removes packages,
# and every privileged action goes through sudo (so you see and approve it).
#
#   ./install.sh                 # full install
#   ./install.sh --status        # check the install; changes nothing
#   ./install.sh --dry-run       # show every action, change nothing
#   ./install.sh --skip-brave    # skip Brave Origin
#   ./install.sh --no-packages   # skip Void base packages (already handled)
#
# Re-running is safe: each step is idempotent and skips work already done.
# Directories are created if missing. A status report always runs at the end,
# and a failed check tells you the exact command that fixes it.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="$SELF_DIR/share"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
# shellcheck source=lib/packages.sh
source "$SELF_DIR/lib/packages.sh"
# shellcheck source=lib/stage-magikos.sh
source "$SELF_DIR/lib/stage-magikos.sh"
# shellcheck source=lib/fonts.sh
source "$SELF_DIR/lib/fonts.sh"
# shellcheck source=lib/brave-origin.sh
source "$SELF_DIR/lib/brave-origin.sh"
# shellcheck source=lib/status.sh
source "$SELF_DIR/lib/status.sh"

# `sudo ./install.sh` breaks this installer, silently.
#
# Everything user-facing lives under $HOME: the runtime clone, the sway config,
# the Nerd Font, and the fontconfig alias that makes bar glyphs render. Under
# `sudo`, $HOME is /root, so all of it lands in root's home where the desktop
# session cannot see it -- the install reports success and every check then
# fails. XDG_CONFIG_HOME/XDG_DATA_HOME shift with it.
#
# Only two things here actually need root (xbps, /opt) and both already sudo
# internally. So when invoked via sudo, hand the whole job to the real user
# rather than half-doing it as root.
if ((EUID == 0)); then
    _target_user="${SUDO_USER:-}"
    if [[ -z $_target_user || $_target_user == root ]]; then
        if [[ -t 0 ]]; then
            printf '%s\n' \
"Run this as your normal user, not root:" \
"" \
"    ./install.sh" \
"" \
"Only xbps and /opt need root, and the installer already asks for that itself." \
"Running it as root stages the runtime, fonts and fontconfig alias into /root," \
"where your desktop session cannot see them." >&2
            exit 2
        fi
    else
        _target_home="$(getent passwd "$_target_user" | cut -d: -f6)"
        [[ -n $_target_home ]] || _target_home="/home/$_target_user"
        printf '%s\n' \
"=> 'sudo ./install.sh' would stage everything into /root." \
"=> Re-running as $_target_user (\$_HOME=$_target_home) instead." >&2
        # Preserve the user's session environment, otherwise Qt/DBus lookups
        # and PATH differ from a real login shell.
        exec sudo -u "$_target_user" \
            env HOME="$_target_home" \
                USER="$_target_user" LOGNAME="$_target_user" \
                XDG_CONFIG_HOME="$_target_home/.config" \
                XDG_DATA_HOME="$_target_home/.local/share" \
                XDG_CACHE_HOME="$_target_home/.cache" \
                PATH="$_target_home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            bash "$SELF_DIR/install.sh" "$@"
    fi
fi

DO_PACKAGES=1
DO_BRAVE=1
DO_STATUS=0

usage() { sed -n "2,16p" "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --skip-brave)  DO_BRAVE=0; shift ;;
        --no-packages) DO_PACKAGES=0; shift ;;
        --status)      DO_STATUS=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) err "unknown arg: $1"; usage; exit 1 ;;
    esac
done

banner() {
    printf '\n\033[1;35m  MagikOS on Void\033[0m  \033[2m(unofficial port)\033[0m\n\n'
}

preflight() {
    log "Preflight"
    if ! is_void; then
        err "this installer targets Void Linux (xbps). Aborting."
        exit 1
    fi
    ok "Void Linux detected"

    # xbps-query is the one hard requirement: without it we cannot detect Void
    # or install anything, so there is nothing to bootstrap it with.
    if ! have xbps-query; then
        err "xbps-query not found -- this does not look like a Void install"
        exit 1
    fi

    # The tools the installer needs in order to *do its job* (clone, unpack the
    # .deb, build the .xbps). A fresh Void has none of these, so requiring them
    # up front meant the installer aborted before it had installed anything.
    # Bootstrap them instead.
    bootstrap_prerequisites || {
        err "cannot continue without these tools"
        exit 1
    }

    if [[ ${XDG_SESSION_TYPE:-} == wayland && ${XDG_CURRENT_DESKTOP:-} == sway ]]; then
        warn "you are inside Sway right now"
        warn "logging out to switch sessions will end this installer run"
        warn "-> run this from your normal (XFCE/Tty) session instead"
    fi
    ((DRY_RUN)) && warn "DRY RUN: nothing will be changed" || true
}

# Create every directory we are about to write into, before any step runs.
# Reports every problem up front instead of failing three steps later.
prepare_paths() {
    log "Preparing directories"
    if ! ensure_paths; then
        err "some required directories could not be prepared (see above)"
        exit 1
    fi
}

main() {
    banner

    if ((DO_STATUS)); then
        # Status mode changes nothing. Include brave checks only if it looks
        # installed, so an optional component never reads as a failure.
        if [[ -x $BRAVE_PREFIX/brave ]] || command -v brave-origin >/dev/null 2>&1; then
            BRAVE_OPTIONAL=1
        fi
        status_report
        return $?
    fi

    preflight
    prepare_paths

    local rc=0

    if ((DO_PACKAGES)); then
        log "Step 1/4: Void base packages"
        if ! ensure_sudo; then
            err "sudo required for package install"
            err "re-run with --no-packages to skip this step"
            return 1
        fi
        if ! install_base_packages; then
            err "package install failed"
            err "try manually: sudo xbps-install -Syu"
            rc=1
        fi
    else
        log "Step 1/4: base packages skipped (--no-packages)"
    fi

    log "Step 2/4: MagikOS runtime"
    if ! stage_all; then
        err "staging failed"
        rc=1
    fi

    # Fonts are not an xbps package: Void's nerd-fonts-ttf is a 1.5 GB
    # aggregator. Fetch only the family the bar actually draws with, and make
    # "monospace" resolve to it so the glyphs are not tofu boxes.
    log "Step 3/4: shell fonts"
    if ! install_shell_fonts; then
        warn "shell font install incomplete; bar icons may render as boxes"
        warn "retry with: $SELF_DIR/install.sh --no-packages"
    fi

    log "Step 4/4: Brave Origin"
    if ((DO_BRAVE)); then
        if ! brave_build; then
            warn "Brave Origin build failed (MagikOS still works without it)"
            warn "retry later with: sudo ./scripts/build-brave-origin"
        fi
    else
        ok "skipped (--skip-brave)"
    fi

    # Always show the status report: it is the answer to "did this work?".
    if ((DO_BRAVE)) || [[ -x $BRAVE_PREFIX/brave ]]; then BRAVE_OPTIONAL=1; fi
    status_report
    local status_rc=$?

    if ((rc == 0 && status_rc == 0)); then
        printf '\n  \033[1;32mInstall complete.\033[0m\n\n'
        printf '  Log out, then choose "Sway" at the login screen.\n'
        printf '  Check on it later with:  %s/install.sh --status\n\n' "$SELF_DIR"
        return 0
    fi
    printf '\n  \033[1;31mInstall finished with problems.\033[0m The FAIL lines above say what to fix.\n\n'
    return 1
}

main "$@"
