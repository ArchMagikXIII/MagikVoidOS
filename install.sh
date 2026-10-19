#!/usr/bin/env bash
# MagikOS installer for Void Linux (unofficial port).
#
# Safe by default: never touches your running session, never removes packages,
# and every privileged action goes through sudo (so you see and approve it).
#
#   ./install.sh                 # full install
#   ./install.sh --dry-run       # print every privileged action, change nothing
#   ./install.sh --skip-brave    # skip Brave Origin
#   ./install.sh --no-packages   # skip Void base packages (already handled)
#
# Re-running is safe: each step is idempotent and skips work already done.

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

DO_PACKAGES=1
DO_BRAVE=1

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --skip-brave)  DO_BRAVE=0; shift ;;
        --no-packages) DO_PACKAGES=0; shift ;;
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
    for c in git curl tar python3 xbps-query; do
        have "$c" || { err "missing: $c"; exit 1; }
    done
    ok "required tools present"

    if [[ ${XDG_SESSION_TYPE:-} == wayland && ${XDG_CURRENT_DESKTOP:-} == sway ]]; then
        warn "you are inside Sway right now"
        warn "logging out to switch sessions will end this installer run"
        warn "-> run this from your normal (XFCE/Tty) session instead"
    fi
    ((DRY_RUN)) && warn "DRY RUN: nothing will be changed" || true
}

main() {
    banner
    preflight

    if ((DO_PACKAGES)); then
        log "Step 1/3: Void base packages"
        ensure_sudo || { err "sudo required for package install"; exit 1; }
        install_base_packages || { err "package install failed"; exit 1; }
    else
        log "Step 1/3: base packages skipped (--no-packages)"
    fi

    log "Step 2/3: MagikOS runtime"
    stage_all || { err "staging failed"; exit 1; }

    log "Step 3/3: Brave Origin"
    if ((DO_BRAVE)); then
        brave_build || warn "Brave Origin build failed; you can retry later with scripts/build-brave-origin"
    else
        ok "skipped (--skip-brave)"
    fi

    printf '\n\033[1;32m  Done.\033[0m\n\n'
    cat <<EOF
Next steps:
  1. Log out, then choose "Sway" at the login screen.
  2. MagikOS lives in:      \$MAGIKOS_PATH = $MAGIKOS_HOME
  3. New shell sessions pick up MAGIKOS_PATH via ~/.profile

To check it later:
  magikos-version
  magikos-update-available
  magikos-debug
EOF
}

main "$@"
