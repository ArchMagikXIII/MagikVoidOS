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
# shellcheck source=lib/brave-origin.sh
source "$SELF_DIR/lib/brave-origin.sh"
# shellcheck source=lib/status.sh
source "$SELF_DIR/lib/status.sh"

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
    local missing=()
    for c in git curl tar python3 xbps-query; do
        have "$c" || missing+=("$c")
    done
    if ((${#missing[@]})); then
        err "missing required tools: ${missing[*]}"
        err "fix with: sudo xbps-install -Syu ${missing[*]}"
        exit 1
    fi
    ok "required tools present"

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
        log "Step 1/3: Void base packages"
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
        log "Step 1/3: base packages skipped (--no-packages)"
    fi

    log "Step 2/3: MagikOS runtime"
    if ! stage_all; then
        err "staging failed"
        rc=1
    fi

    log "Step 3/3: Brave Origin"
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
