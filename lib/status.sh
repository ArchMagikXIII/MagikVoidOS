#!/usr/bin/env bash
# Status/diagnostic checks for the MagikOS Void port.
#
# Answers one question: is this install actually working, and if not, what
# exactly needs fixing? Every check prints pass/fail plus the concrete command
# to fix it, so nothing has to be guessed.

CHECKS_RUN=0
CHECKS_FAILED=0
FAILED_NAMES=()

_c_pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
_c_fail() {
    printf '  \033[31mFAIL\033[0m  %s\n' "$1"
    shift
    while (($#)); do printf '          \033[2m%s\033[0m\n' "$1"; shift; done
}
_c_warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
_c_skip() { printf '  \033[2mSKIP\033[0m  %s\n' "$1"; }

SKIPPED=0

check() {
    local name="$1"; shift
    CHECKS_RUN=$((CHECKS_RUN + 1))
    # Allow a check to declare itself N/A by echoing "skip" as its first line.
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ $out == skip* ]]; then
        SKIPPED=$((SKIPPED + 1))
        _c_skip "$name -- ${out#skip}"
        return 0
    fi
    [[ -n $out ]] && printf '%s\n' "$out"
    if ((rc == 0)); then
        _c_pass "$name"
    else
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        FAILED_NAMES+=("$name")
        _c_fail "$name" "${CHECK_HINT:-}"
        CHECK_HINT=""
    fi
    return 0
}
skip() { _c_skip "$1"; }
note() { printf '          \033[2m%s\033[0m\n' "$1"; }

# detect_no_gpu
#
# True when this machine has no usable 3D acceleration. Two independent
# signals, either of which is enough:
#   1. /dev/dri/card0 exists but reports a known paravirtual/soft adapter
#   2. the Quickshell log already shows a ZINK init failure
#
# Kept deliberately conservative: a false positive forces software rendering
# and costs performance, so require positive evidence of a lack of GPU rather
# than inferring from missing tools (glxinfo/vulkaninfo are often just absent).
detect_no_gpu() {
    # Signal 2 is the most reliable: an actual failure already happened.
    if [[ -f $MAGIKOS_STATE_DIR/quickshell.log ]] \
       && grep -qa 'ZINK' "$MAGIKOS_STATE_DIR/quickshell.log" 2>/dev/null; then
        return 0
    fi

    # Signal 1: paravirtual adapters cannot do GL.
    local card vendor
    card="$(ls /dev/dri/card* 2>/dev/null | head -1)"
    if [[ -n $card ]]; then
        # virtio-gpu does work; QXL and bochs do not accelerate GL.
        if command -v lspci >/dev/null 2>&1; then
            vendor="$(lspci 2>/dev/null | grep -iE 'VGA compatible|3D controller|Display controller' | head -1)"
            if printf '%s' "$vendor" | grep -qiE 'QXL|bochs|vmware|Cirrus'; then
                return 0
            fi
            # A real vendor GPU means keep hardware rendering.
            if printf '%s' "$vendor" | grep -qiE 'nvidia|AMD|ATI|Intel'; then
                return 1
            fi
        fi
    fi

    # No /dev/dri at all: no GPU is the safest interpretation.
    [[ -z $card ]] && return 0

    # /dev/dri present but unidentifiable: assume hardware is fine.
    return 1
}

# --- individual checks ------------------------------------------------------

chk_is_void() { is_void; }

chk_tools() {
    # Split the old single check in two. The desktop packages are installed by
    # Step 1 of the installer; conflating them with the installer's own
    # prerequisites made one FAIL line cover two unrelated problems, and the
    # suggested fix ("xbps-install sway quickshell git curl tar python3") read
    # as if all seven were required up front.
    local missing=()
    for c in git curl tar python3; do
        have "$c" || missing+=("$c")
    done
    if ((${#missing[@]})); then
        CHECK_HINT="missing installer prerequisites: ${missing[*]}"$'\n'"these are bootstrapped automatically by ./install.sh"$'\n'"fix with: sudo xbps-install -Syu ${missing[*]}"
        return 1
    fi
    return 0
}

chk_desktop_packages() {
    local missing=()
    for c in sway quickshell; do
        have "$c" || missing+=("$c")
    done
    if ((${#missing[@]})); then
        CHECK_HINT="missing desktop packages: ${missing[*]}"$'\n'"installed by Step 1 of ./install.sh; it did not complete"$'\n'"fix with: sudo xbps-install -Syu ${missing[*]}"
        return 1
    fi
    return 0
}

# The stale-index problem: xbps-query -Rs should find sway, since it is
# installed. If it does not, the repo index needs a sync.
chk_xbps_index() {
    xbps-query -Rs '^sway-' 2>/dev/null | grep -q 'sway-1' && return 0
    # Older xbps has no ^ anchor; fall back to a loose match.
    xbps-query -Rs 'sway' 2>/dev/null | grep -qE '\bsway-[0-9]' && return 0
    CHECK_HINT="the package index looks stale: 'sway' is installed but not in the repo listing"$'\n'"fix with: sudo xbps-install -Syu"
    return 1
}

chk_runtime_dir() {
    [[ -d $MAGIKOS_HOME ]]; local rc=$?; CHECK_HINT="fix with: ./install.sh --no-packages"; return $rc
}

chk_runtime_clone() {
    [[ -d $MAGIKOS_HOME/.git ]]; local rc=$?; CHECK_HINT="fix with: ./install.sh --no-packages"; return $rc
}

chk_port_applied() {
    # Three distinct causes, previously collapsed into one opaque FAIL:
    #   1. no runtime at all          -> nothing has been staged yet
    #   2. runtime but no .git        -> staged by an older installer, or copied
    #   3. .git present, patch absent -> `git apply` failed, or upstream moved
    # Case 3 is the one that needs a real diagnostic, so run the check for
    # dry and report git's own words.
    if [[ ! -d $MAGIKOS_HOME ]]; then
        CHECK_HINT="no runtime at $MAGIKOS_HOME"$'\n'"the installer never got as far as staging"$'\n'"fix with: ./install.sh"
        return 1
    fi
    if [[ ! -d $MAGIKOS_HOME/.git ]]; then
        CHECK_HINT="$MAGIKOS_HOME is not a git clone, so the port patch cannot be tracked"$'\n'"fix with: rm -rf '$MAGIKOS_HOME' && ./install.sh"
        return 1
    fi

    # Detect Void-specific modifications to magikos-pkg-backend
    local backend="$MAGIKOS_HOME/bin/magikos-pkg-backend"
    if grep -qE 'MAGIKOS_PKG_BACKEND.*xbps|backend_is_xbps|xbps-query|No AUR on Void|Void/xbps' "$backend" 2>/dev/null; then
        return 0
    fi

    # Not applied. Ask git why, so this names the real problem.
    local head apply_err
    head="$(git -C "$MAGIKOS_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    apply_err="$(git -C "$MAGIKOS_HOME" apply --check "$SELF_DIR/share/void-port.patch" 2>&1)"
    if [[ -n $apply_err ]]; then
        CHECK_HINT="port patch is NOT applied (runtime at $head)"$'\n'"git refuses it, so upstream has drifted from share/void-port.patch:"$'\n'"$(printf '%s' "$apply_err" | head -6 | sed 's/^/          /')"$'\n'"fix: refresh the patch against current upstream --"$'\n'"     cd '$MAGIKOS_HOME' && git apply '$SELF_DIR/share/void-port.patch'"
    else
        CHECK_HINT="port patch applies cleanly but was never applied"$'\n'"staging stopped between clone and patch"$'\n'"fix with: ./install.sh --no-packages"
    fi
    return 1
}

chk_backend() {
    if [[ ! -f $MAGIKOS_HOME/bin/magikos-pkg-backend ]]; then
        CHECK_HINT="no backend file -- see 'Void port patch applied' above for the root cause"
        return 1
    fi
    local out
    out="$(bash -c "source '$MAGIKOS_HOME/bin/magikos-pkg-backend' 2>/dev/null && echo \"\$MAGIKOS_PKG_BACKEND\"" 2>/dev/null)"
    if [[ $out == xbps ]]; then return 0; fi
    if [[ -z $out ]]; then
        # Sourcing failed, so surface why instead of just "did not load".
        local err_out
        err_out="$(bash -c "source '$MAGIKOS_HOME/bin/magikos-pkg-backend'" 2>&1 | head -3)"
        CHECK_HINT="magikos-pkg-backend exists but failed to load:"$'\n'"$(printf '%s' "$err_out" | sed 's/^/          /')"
    else
        CHECK_HINT="backend detected as '$out', expected 'xbps'"$'\n'"the port patch may be partially applied"
    fi
    return 1
}

chk_backend_funcs() {
    if [[ ! -f $MAGIKOS_HOME/bin/magikos-pkg-backend ]]; then
        CHECK_HINT="no backend file -- see 'Void port patch applied' above for the root cause"
        return 1
    fi
    local missing=()
    local fn
    for fn in pkg_installed pkg_list_available pkg_list_installed \
              pkg_list_explicit pkg_list_orphans pkg_owns_file pkg_file_owner; do
        bash -c "source '$MAGIKOS_HOME/bin/magikos-pkg-backend' 2>/dev/null && declare -F $fn" >/dev/null \
            || missing+=("$fn")
    done
    if ((${#missing[@]} == 0)); then return 0; fi
    CHECK_HINT="magikos-pkg-backend is missing ${#missing[@]} of 7 primitives: ${missing[*]}"$'\n'"the patch added the file but not its full body (partial apply)"$'\n'"fix with: ./install.sh --no-packages"
    return 1
}

chk_sway_dir() { [[ -d $MAGIKOS_USER_SWAY ]]; local rc=$?; CHECK_HINT="fix with: ./install.sh --no-packages"; return $rc; }

chk_sway_config() {
    [[ -f $MAGIKOS_USER_SWAY/config ]]; local rc=$?; CHECK_HINT="the sway entry point is 'config' (not config.conf)"$'\n'"fix with: ./install.sh --no-packages"; return $rc
}

chk_sway_nofullprefix() {
    if grep -rqs '/usr/share/magikos' "$MAGIKOS_USER_SWAY"; then
        CHECK_HINT="sway config still points at /usr/share/magikos (system prefix)"$'\n'"fix with: ./install.sh --no-packages   # re-applies the overrides"
        return 1
    fi
    return 0
}

chk_sway_validate() {
    have sway || { CHECK_HINT="install sway: sudo xbps-install -S sway"; return 1; }
    # Headless backend: a real DRM device is usually unavailable to a VM/TTY.
    local out rc
    out="$(WLR_BACKENDS=headless WLR_RENDERER=pixman \
           sway --validate -c "$MAGIKOS_USER_SWAY/config" 2>&1)"
    rc=$?
    if ((rc == 0)); then return 0; fi
    CHECK_HINT="sway --validate failed:"$'\n'"$(printf '%s' "$out" | grep -vE 'pci id' | head -5 | sed 's/^/          /')"
    return 1
}

chk_wallpaper() {
    [[ -f $WALLPAPER ]]; CHECK_HINT="no wallpaper at $WALLPAPER (Sway starts black)"$'\n'"fix: put any .jpg there, or set WALLPAPER=/path/to/image"; return $?
}

# A machine with no usable 3D GPU (VM with a paravirtual adapter, headless
# server, nested virt) makes Mesa pick the ZINK driver, which then fails with
# VK_ERROR_INITIALIZATION_FAILED. Quickshell then has no GL context and the bar
# never appears, so the session looks broken. Detect that case and say so,
# because "black screen" is the single most confusing failure here.
chk_graphics_capable() {
    local forced=0
    grep -q 'WLR_RENDERER' "$MAGIKOS_USER_SWAY/environment.conf" 2>/dev/null && forced=1
    if ((forced)); then
        note "software rendering is pinned in environment.conf (expected on a GPU-less VM)"
        return 0
    fi
    # No pinned renderer: check whether a real GL device is actually usable.
    if command -v eglinfo >/dev/null 2>&1; then
        eglinfo -B 2>/dev/null | grep -qiE 'llvmpipe|softpipe|swrast' && {
            note "software GL only; pinning WLR_RENDERER=pixman in environment.conf"
            note "   would remove the ZINK errors. Optional."
            return 0
        }
    fi
    # ZINK in the log with no pinned renderer is the concrete failure signal.
    if [[ -f $MAGIKOS_STATE_DIR/quickshell.log ]] \
       && grep -qa 'ZINK' "$MAGIKOS_STATE_DIR/quickshell.log" 2>/dev/null; then
        CHECK_HINT="ZINK/Vulkan init failed: no usable GPU on this machine, so Quickshell has no GL context and the bar will not draw"$'\n'"fix by appending these to ~/.config/sway/environment.conf:"$'\n'"    set \$WLR_RENDERER pixman"$'\n'"    set \$LIBGL_ALWAYS_SOFTWARE 1"$'\n'"   then log out and back in. See README 'GPU-less VMs'."
        return 1
    fi
    return 0
}

chk_shell_json() {
    [[ -f $MAGIKOS_USER_CONFIG/shell.json ]]; local rc=$?; CHECK_HINT="fix with: ./install.sh --no-packages"; return $rc
}

chk_env() {
    grep -q 'MAGIKOS_PATH' "$HOME/.profile" 2>/dev/null; local rc=$?; CHECK_HINT="MAGIKOS_PATH is not in ~/.profile, so 'magikos-*' only works inside Sway"$'\n'"fix with: ./install.sh --no-packages"; return $rc
}

chk_brave() {
    [[ -x $BRAVE_PREFIX/brave ]]; local rc=$?; CHECK_HINT="not installed"$'\n'"fix with: ./scripts/build-brave-origin"; return $rc
}

chk_brave_cmd() {
    command -v brave-origin >/dev/null 2>&1 || [[ -x /usr/bin/brave-origin ]]; local rc=$?; CHECK_HINT="/usr/bin/brave-origin missing"$'\n'"fix with: sudo ./scripts/build-brave-origin"; return $rc
}

chk_brave_desktop() {
    [[ -f /usr/share/applications/brave-origin.desktop ]]; local rc=$?; CHECK_HINT="desktop entry missing (no launcher icon)"$'\n'"fix with: sudo ./scripts/build-brave-origin"; return $rc
}

chk_brave_icon() {
    [[ -f /usr/share/icons/hicolor/256x256/apps/brave-origin.png ]]; local rc=$?; CHECK_HINT="icon missing; brave-origin.desktop references 'brave-origin'"$'\n'"fix with: sudo ./scripts/build-brave-origin"; return $rc
}

# Only meaningful while a Sway session is running.
chk_shell_log() {
    local f="$MAGIKOS_STATE_DIR/quickshell.log"
    if [[ ! -f $f ]]; then
        echo "skip no log yet (appears after you log into Sway)"
        return 0
    fi
    # Count with grep -c and normalise: `grep -c` prints "0" but exits 1 when
    # there are no matches, so `|| echo 0` appends a second line and yields the
    # literal "0\n0", which then breaks arithmetic expansion.
    local errs
    errs="$(grep -ac 'ERROR' "$f" 2>/dev/null)" || errs=0
    [[ $errs =~ ^[0-9]+$ ]] || errs=0
    if ((errs == 0)); then return 0; fi

    # A pipewire error is expected on a host with no audio sink, and is not a
    # Quickshell configuration problem. MESA/GL errors belong to the graphics
    # check, not here.
    local nonpipe
    nonpipe="$(grep -a 'ERROR' "$f" 2>/dev/null | grep -avcE 'pipewire|MESA')" || nonpipe=0
    [[ $nonpipe =~ ^[0-9]+$ ]] || nonpipe=0
    if ((nonpipe > 0)); then
        CHECK_HINT="$nonpipe real ERROR line(s) in $f"$'\n'"$(grep -a ERROR "$f" | grep -avE 'pipewire|MESA' | head -3 | sed 's/^/          /')"
        return 1
    fi
    _c_warn "only the expected no-audio pipewire error in $f"
    return 0
}

chk_sway_session() {
    if pgrep -x sway >/dev/null 2>&1; then
        note "sway pid $(pgrep -x sway | head -1)"
        return 0
    fi
    echo "skip not running (log into Sway to exercise this)"
    return 0
}

# --- report -----------------------------------------------------------------

status_report() {
    printf '\n\033[1m  Status\033[0m\n\n'

    printf '\033[1m  System\033[0m\n'
    check "running Void Linux"          chk_is_void
    check "required tools installed"    chk_tools
    check "desktop packages installed"  chk_desktop_packages
    check "xbps package index fresh"    chk_xbps_index

    printf '\n\033[1m  MagikOS runtime\033[0m\n'
    check "runtime dir exists ($MAGIKOS_HOME)" chk_runtime_dir
    check "runtime is a git clone"      chk_runtime_clone
    check "Void port patch applied"     chk_port_applied
    check "pkg backend detects xbps"    chk_backend
    check "pkg backend functions load"  chk_backend_funcs

    printf '\n\033[1m  Sway session\033[0m\n'
    check "sway config dir ($MAGIKOS_USER_SWAY)" chk_sway_dir
    check "sway 'config' entry point"    chk_sway_config
    check "no /usr/share/magikos refs"   chk_sway_nofullprefix
    check "sway config validates"        chk_sway_validate
    check "graphics backend usable"      chk_graphics_capable
    check "wallpaper present"            chk_wallpaper

    printf '\n\033[1m  Quickshell + env\033[0m\n'
    check "shell.json staged"            chk_shell_json
    check "MAGIKOS_PATH in ~/.profile"   chk_env
    check "Quickshell log clean"         chk_shell_log
    check "sway session running"         chk_sway_session

    printf '\n\033[1m  Brave Origin (optional)\033[0m\n'
    if ((BRAVE_OPTIONAL)); then
        check "brave-origin payload ($BRAVE_PREFIX)" chk_brave
        check "brave-origin on PATH"      chk_brave_cmd
        check "desktop entry installed"   chk_brave_desktop
        check "icon installed"            chk_brave_icon
    fi

    printf '\n'
    if ((CHECKS_FAILED == 0)); then
        printf '  \033[1;32mAll %d checks passed.\033[0m' "$CHECKS_RUN"
        ((SKIPPED)) && printf ' \033[2m(%d skipped)\033[0m' "$SKIPPED"
        printf '\n\n'
        return 0
    fi
    printf '  \033[1;31m%d of %d checks failed.\033[0m\n' "$CHECKS_FAILED" "$CHECKS_RUN"
    printf '  Fix the FAIL lines above (each shows the command), then re-run:\n'
    printf '    %s/./install.sh --status\033[0m\n\n' "$SELF_DIR"
    return 1
}

BRAVE_OPTIONAL="${BRAVE_OPTIONAL:-0}"
