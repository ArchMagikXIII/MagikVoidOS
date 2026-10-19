#!/usr/bin/env bash
# Launch shims for MagikOS on Void.
#
# WHY
#
# Upstream MagikOS assumes systemd and Universal Wm Sway Manager:
#
#   * 26 scripts in bin/ launch apps via `uwsm-app -- <cmd>`
#   * 6 more use `systemd-run --user ... --scope <cmd>`
#
# Void uses runit and has neither. Both calls fail, and because they are
# backgrounded with `>/dev/null 2>&1 &` the failure is invisible: the shell
# reports "launching <app>" and nothing ever appears. That is the "apps are
# launching but nothing happened" symptom.
#
# What these tools actually provide is process scoping -- keeping a launched
# app tied to a unit so it can be found or killed. With no user systemd there
# is no unit to join, and the correct Void behaviour is to launch the command
# detached from the terminal. `setsid` gives exactly that, so the shim is a
# faithful substitute rather than a stub.
#
# The shims live in $MAGIKOS_HOME/bin, which the port puts on PATH via
# environment.conf, so every existing call site picks them up unchanged.

SHIMS_DIR="${SHIMS_DIR:-$MAGIKOS_HOME/bin}"

# uwsm-app [--] <cmd> [args...]
# Drop a leading "--" separator, then launch detached.
write_uwsm_app_shim() {
    cat <<'SHIM'
#!/usr/bin/env bash
# MagikOS Void port: uwsm-app shim.
# UWsm scopes a launched app to a systemd user unit. Void has no user systemd,
# so there is no unit to join; launch detached with setsid instead.
set -uo pipefail
[[ ${1:-} == "--" ]] && shift
if (($# == 0)); then
    echo "uwsm-app(shim): no command given" >&2
    exit 1
fi
exec setsid "$@"
SHIM
}

# systemd-run [options] <cmd> [args...]
# Handle the two forms upstream uses:
#   1. immediate:  --user --quiet --collect --unit=X --scope <cmd>
#   2. delayed:    --user --on-active=2s --unit=X <cmd>   (a timer)
# Option flags are consumed until the first non-flag word, which is the command.
write_systemd_run_shim() {
    cat <<'SHIM'
#!/usr/bin/env bash
# MagikOS Void port: systemd-run shim.
# Void uses runit and has no user systemd, so there is no transient unit to
# create. Immediate invocations run detached; --on-active=N is honoured with a
# plain background sleep.
set -uo pipefail

delay=""
while (($#)); do
    case "$1" in
        --on-active=*) delay="${1#*=}" ;;
        --user|--scope|--collect|--quiet|--no-block|--wait|--pipe)
            ;;
        --unit=*|--property=*|--timer-property=*|--description=*|-p|-d|-M|-E)
            ;;
        --) shift; break ;;
        -*) ;;
        *) break ;;
    esac
    shift
done

# Void has no systemctl; map the two lifecycle actions upstream schedules.
if [[ ${1:-} == systemctl ]]; then
    shift
    case "${1:-}" in
        reboot)   set -- reboot ;;
        poweroff) set -- poweroff ;;
    esac
fi

if (($# == 0)); then
    echo "systemd-run(shim): no command given" >&2
    exit 1
fi

# Strip a leading unit suffix from a delay like "2s", "5m", "1h".
if [[ -n $delay ]]; then
    case "$delay" in
        *s) secs="${delay%s}" ;;
        *m) secs=$(( ${delay%m} * 60 )) ;;
        *h) secs=$(( ${delay%h} * 3600 )) ;;
        *) secs="$delay" ;;
    esac
    exec setsid bash -c "sleep $secs; exec \"\$@\"" sh "$@"
fi

exec setsid "$@"
SHIM
}

install_launch_shims() {
    have setsid || { err "setsid not found (util-linux); shims need it"; return 1; }

    if ((DRY_RUN)); then
        _c mkdir -p "$SHIMS_DIR"
        log "would install launch shims: uwsm-app, systemd-run -> $SHIMS_DIR"
        return 0
    fi

    mkdir -p "$SHIMS_DIR" || { err "cannot create $SHIMS_DIR"; return 1; }

    local n=0 f
    for f in uwsm-app systemd-run; do
        case "$f" in
            uwsm-app)   write_uwsm_app_shim   > "$SHIMS_DIR/$f" ;;
            systemd-run) write_systemd_run_shim > "$SHIMS_DIR/$f" ;;
        esac
        chmod 0755 "$SHIMS_DIR/$f" || { err "cannot chmod $SHIMS_DIR/$f"; return 1; }
        n=$((n + 1))
    done
    ok "installed $n launch shim(s) in $SHIMS_DIR"
    printf '        %s\n' "$SHIMS_DIR/uwsm-app" "$SHIMS_DIR/systemd-run"
}

# Are the shims present AND first on PATH? A shim that exists but is shadowed
# by a real binary elsewhere is worse than none, because it silently does
# nothing different from what the caller expected.
shims_working() {
    local s
    for s in uwsm-app systemd-run; do
        [[ -x "$SHIMS_DIR/$s" ]] || return 1
    done
    # "$SHIMS_DIR" must come before any other copy on PATH.
    local resolved
    resolved="$(command -v uwsm-app 2>/dev/null)"
    [[ $resolved == "$SHIMS_DIR/uwsm-app" ]] || return 1
    return 0
}

# MagikOS ships 22 themes but installs none, and both the wallpaper picker and
# the theme picker read their contents from theme state. With no theme set,
# theme.name is missing, the backgrounds list is empty and the theme picker
# shows nothing -- which reads as "the pickers are broken" rather than "no theme
# has been chosen yet". Apply a default so the desktop is usable on first boot,
# without overriding a theme the user already picked.
MAGIKOS_DEFAULT_THEME="catppuccin"

theme_is_set() {
    [[ -s "$HOME/.local/state/magikos/current/theme.name" ]]
}

ensure_default_theme() {
    if theme_is_set; then
        ok "theme already set: $(<"$HOME/.local/state/magikos/current/theme.name")"
        return 0
    fi

    if ! have magikos-theme-set; then
        warn "magikos-theme-set not found; wallpaper/theme pickers stay empty"
        return 0
    fi

    local themes="${MAGIKOS_PATH:-$HOME/.local/share/magikos}/themes"
    local theme="$MAGIKOS_DEFAULT_THEME"
    if [[ ! -d "$themes/$theme" ]]; then
        theme="$(find "$themes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n1)"
    fi
    if [[ -z $theme ]]; then
        warn "no themes found under $themes; pickers will stay empty"
        return 0
    fi

    log "Applying default theme: $theme"
    if _c magikos-theme-set "$theme" >/dev/null; then
        ok "default theme set: $theme"
    else
        warn "could not set default theme; pickers will stay empty"
        warn "fix with: magikos-theme-set $theme"
        return 1
    fi
}

# Void's installer enables a getty on every console tty, including the one
# LightDM wants. Both then contend for tty1: runsv restarts the getty the
# instant it is exited, so the user types `exit` two or three times before
# LightDM finally wins the VT. It presents as "the desktop started late, with
# errors before it", which is a miserable thing to debug from the inside.
#
# Disable the getty that actually collides (DM_TTY, default tty1). tty2..tty6
# are separate virtual terminals and do not interfere, so they are left alone
# unless the caller asks.
#
# Never restarts LightDM: that would terminate the running sway session. The
# getty change lands at once; the lightdm.conf edits need the next login.
reconcile_desktop_gettys() {
    local dm_tty="${DM_TTY:-tty1}"
    local getty_link="/var/service/agetty-$dm_tty"
    local lightdm_conf=/etc/lightdm/lightdm.conf
    local changed=0

    # Everything here writes outside $HOME. In --dry-run we still report what
    # would change, but must not touch anything (rule 7).
    if ! [[ -L $getty_link ]] && ! grep -qsE '^[[:space:]]*autologin-user=' "$lightdm_conf" 2>/dev/null; then
        ok "no getty/LightDM conflict to reconcile"
        return 0
    fi

    if [[ -L $getty_link ]]; then
        if ((DRY_RUN)); then
            printf '  \033[2mplan\033[0m  would disable %s (LightDM needs tty%s)\n' "$getty_link" "${dm_tty#tty}"
        elif rm "$getty_link"; then
            ok "disabled agetty-$dm_tty (it was contending with LightDM for tty${dm_tty#tty})"
        else
            warn "could not remove $getty_link; the login prompt will still shadow LightDM"
            warn "fix with: rm $getty_link"
        fi
        changed=1
    fi

    # Void's live-image defaults name a user that does not exist on an installed
    # system and autologin into xfce, which is not the session here. LightDM
    # logs an error on every boot and drops to the greeter. Comment the dead
    # keys out with the reason inline rather than deleting them, so the file
    # stays legible and the change is reversible without the backup.
    if grep -qsE '^[[:space:]]*autologin-user=' "$lightdm_conf" 2>/dev/null; then
        if ((DRY_RUN)); then
            printf '  \033[2mplan\033[0m  would clean the dead autologin keys out of %s\n' "$lightdm_conf"
        else
            local backup="$lightdm_conf.bak.$(date +%Y%m%d%H%M%S)"
            if ! cp -a "$lightdm_conf" "$backup"; then
                warn "could not back up $lightdm_conf; leaving it untouched"
                return 1
            fi
            sed -i \
                -e 's|^\([[:space:]]*\)autologin-user=.*|\1# autologin disabled by install.sh: no autologin user on this host|' \
                -e 's|^\([[:space:]]*\)autologin-user-timeout=.*|\1# autologin disabled by install.sh|' \
                -e 's|^\([[:space:]]*\)autologin-session=.*|\1# autologin disabled by install.sh: this host runs sway, not xfce|' \
                -e 's|^\([[:space:]]*\)user-session=.*|\1user-session=sway|' \
                "$lightdm_conf"
            ok "cleaned the live-image autologin keys out of $lightdm_conf"
            ok "backup: $backup"
        fi
        changed=1
    fi

    if ((changed)) && ! ((DRY_RUN)); then
        printf '  \033[2mthe getty is gone now; the LightDM edits apply at next login\033[0m\n'
    fi
    return 0
}