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

# systemctl [options] <verb> [unit...]
#
# Void runs runit as PID 1 and ships no systemd, so all 101 `systemctl` calls
# in the MagikOS tree (across 42 files) fail. Nearly every one is
# 2>/dev/null-guarded, so nothing is reported and the affected feature just
# quietly does nothing -- the hardest class of bug to diagnose from the inside.
#
# Two rules keep this safe:
#
#   1. If real systemd is in charge, exec the real systemctl. This shim lives in
#      $MAGIKOS_HOME/bin, which is FIRST on PATH, so without this rule it would
#      shadow systemd forever on a host that installs it later.
#   2. Never invent success. `--user` has no runit equivalent at all, so those
#      calls keep failing exactly as they do today -- only now with a stated
#      reason instead of silence. Failing loudly where the caller asked for
#      quiet is the whole point; a fake "active" would be far worse.
#
# System services genuinely do map onto runit, so those verbs are translated.
write_systemctl_shim() {
    cat <<'SHIM'
#!/usr/bin/env bash
# MagikOS Void port: systemctl shim. See lib/shims.sh for why.
set -uo pipefail

shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- rule 1: defer to the real systemctl whenever systemd is actually here ---
if [[ -d /run/systemd/system ]]; then
    real=""
    IFS=: read -ra path_dirs <<< "$PATH"
    for d in "${path_dirs[@]}"; do
        [[ -z $d || $d == "$shim_dir" ]] && continue
        if [[ -f $d/systemctl && -x $d/systemctl ]]; then
            real="$d/systemctl"
            break
        fi
    done
    if [[ -n $real ]]; then
        exec "$real" "$@"
    fi
fi

verb=""
user=0
quiet=0
now=0
units=()

while (($#)); do
    case $1 in
        --user | --user=*) user=1 ;;
        --quiet | -q | --no-pager | --no-legend | --full | --no-ask-password) quiet=1 ;;
        --now) now=1 ;;
        --) shift; while (($#)); do units+=("$1"); shift; done; break ;;
        -*) : ;;
        *)
            if [[ -z $verb ]]; then
                verb=$1
            else
                units+=("$1")
            fi
            ;;
    esac
    shift
done

if [[ -z $verb ]]; then
    echo "systemctl(shim): no verb given; Void runs runit, not systemd" >&2
    exit 1
fi

# systemd exits 3 for "inactive" and 4 for "unknown". Callers here only test
# non-zero, but matching the codes costs nothing and keeps `if systemctl
# is-active` idioms behaving.
EXIT_INACTIVE=3
EXIT_UNKNOWN=4

note() { ((quiet)) || echo "systemctl(shim): $*" >&2; }

# Void's runit service names carry no .service suffix.
norm() { printf '%s' "${1%.service}"; }

# A service runit will actually run: something in /var/service, or a definition
# in /etc/sv that has simply not been enabled yet.
svc_known() {
    local u
    u="$(norm "$1")"
    [[ -e "/var/service/$u" || -d "/etc/sv/$u" || -d "/usr/local/etc/sv/$u" ]]
}

# Enabled is answerable without privilege: /var/service is a readable symlink
# farm. Active is not -- Void keeps per-service state in
# /run/runit/supervise.<name>, mode 0700 root, so `sv status` fails for every
# service when called unprivileged. Report that as unknown rather than guessing.
svc_state() {
    local u out
    u="$(norm "$1")"
    if ! out="$(sv status "$u" 2>/dev/null)"; then
        printf 'unknown'
        return 0
    fi
    if [[ $out == run:* ]]; then
        printf 'running'
    else
        printf 'down'
    fi
}

svc_active() {
    local st
    st="$(svc_state "$1")"
    case $st in
        running) return 0 ;;
        down) return $EXIT_INACTIVE ;;
        *) return $EXIT_UNKNOWN ;;
    esac
}

need_root() {
    if ((EUID == 0)); then
        return 0
    fi
    note "$1 needs root; re-run as root or install the service manually"
    return 1
}

# --- rule 2: --user has no runit equivalent --------------------------------
if ((user)); then
    case $verb in
        is-active | is-enabled | status | show | list-units | --version)
            # Query verbs: answer what we honestly can. Querying the *system*
            # manager for a user unit would be a different question, so only
            # is-enabled has a defensible answer, and only for a unit that is
            # also a system service.
            if [[ $verb == is-enabled ]] && ((${#units[@]})) && svc_known "${units[0]}"; then
                u="$(norm "${units[0]}")"
                [[ -e "/var/service/$u" ]] && exit 0
                exit $EXIT_INACTIVE
            fi
            note "--user has no runit equivalent (Void has no per-user service manager); '$verb' cannot be answered"
            exit $EXIT_UNKNOWN
            ;;
        *)
            note "--user has no runit equivalent (Void has no per-user service manager); ignoring '$verb'"
            exit 1
            ;;
    esac
fi

# Bookkeeping verbs that systemd needs only because it unit-caches. runit
# re-reads /var/service continuously, so there is genuinely nothing to do.
case $verb in
    daemon-reload | reset-failed | preset | revert) exit 0 ;;
esac

# Most verbs need a unit; the list/query verbs deliberately do not.
case $verb in
    list-units | list-unit-files | show | --version | daemon-reload | reset-failed) : ;;
    *) ((${#units[@]})) || { note "'$verb' needs a unit name"; exit 1; } ;;
esac

case $verb in
    is-active)
        svc_known "${units[0]}" || exit $EXIT_UNKNOWN
        svc_active "${units[0]}"
        rc=$?
        # Preserve the distinction: svc_active returns EXIT_UNKNOWN when runit
        # state is unreadable (Void keeps it root-only), and collapsing that
        # into EXIT_INACTIVE would report a running service as stopped.
        ((rc == 0)) && exit 0
        exit "$rc"
        ;;
    is-enabled)
        u="$(norm "${units[0]}")"
        [[ -e "/var/service/$u" ]] && exit 0
        exit $EXIT_INACTIVE
        ;;
    status | show)
        u="$(norm "${units[0]}")"
        if [[ ! -e "/var/service/$u" ]]; then
            note "$u is not enabled (no /var/service/$u)"
            exit $EXIT_INACTIVE
        fi
        st="$(svc_state "$u")"
        if [[ $st == unknown ]]; then
            note "$u is enabled, but runit state is root-only; re-run as root to see it"
            exit $EXIT_UNKNOWN
        fi
        sv status "$u" 2>/dev/null
        exit $?
        ;;
    enable)
        need_root "systemctl enable" || exit 1
        u="$(norm "${units[0]}")"
        if [[ -e "/var/service/$u" ]]; then
            ((quiet)) || echo "$u already enabled"
            ((now)) && sv up "$u" 2>/dev/null
            exit 0
        fi
        [[ -d "/etc/sv/$u" ]] || { note "no /etc/sv/$u to enable"; exit 1; }
        ln -s "/etc/sv/$u" "/var/service/$u" || exit 1
        echo "$u enabled (runit: linked into /var/service)"
        ((now)) && sv up "$u" 2>/dev/null
        exit 0
        ;;
    disable)
        need_root "systemctl disable" || exit 1
        u="$(norm "${units[0]}")"
        [[ -e "/var/service/$u" ]] || { ((quiet)) || echo "$u is not enabled"; exit 0; }
        sv down "$u" 2>/dev/null
        rm -f "/var/service/$u" || exit 1
        echo "$u disabled (runit: unlinked from /var/service)"
        exit 0
        ;;
    start | restart | reload-or-restart | reload-or-try-restart | try-restart)
        need_root "systemctl $verb" || exit 1
        u="$(norm "${units[0]}")"
        [[ -e "/var/service/$u" ]] || { note "$u is not enabled in /var/service"; exit 1; }
        case $verb in
            start) sv up "$u" || exit 1 ;;
            restart) sv restart "$u" || exit 1 ;;
            try-restart) sv up "$u" 2>/dev/null || : ;;
            *) sv up "$u" 2>/dev/null || sv restart "$u" || exit 1 ;;
        esac
        exit 0
        ;;
    stop)
        need_root "systemctl stop" || exit 1
        u="$(norm "${units[0]}")"
        [[ -e "/var/service/$u" ]] || exit 0
        sv down "$u" 2>/dev/null
        exit 0
        ;;
    reload | hup)
        u="$(norm "${units[0]}")"
        # sv hup only signals, and only root may signal the supervisor, so this
        # is a root-only operation like the rest.
        need_root "systemctl reload" || exit 1
        [[ -e "/var/service/$u" ]] || { note "$u is not enabled"; exit 1; }
        sv hup "$u" 2>/dev/null || exit 1
        exit 0
        ;;
    list-units | list-unit-files)
        printf '%-34s %-10s %s\n' UNIT LOAD STATE
        for l in /var/service/*; do
            [[ -e $l ]] || continue
            b="${l##*/}"
            printf '%-34s %-10s %s\n' "$b" loaded "$(svc_state "$b")"
        done
        exit 0
        ;;
    *)
        note "'$verb' has no runit mapping; Void runs runit, not systemd"
        exit 1
        ;;
esac
SHIM
}

install_launch_shims() {
    have setsid || { err "setsid not found (util-linux); shims need it"; return 1; }

    if ((DRY_RUN)); then
        _c mkdir -p "$SHIMS_DIR"
        log "would install launch shims: uwsm-app, systemd-run, systemctl -> $SHIMS_DIR"
        return 0
    fi

    mkdir -p "$SHIMS_DIR" || { err "cannot create $SHIMS_DIR"; return 1; }

    local n=0 f
    for f in uwsm-app systemd-run systemctl; do
        case "$f" in
            uwsm-app)   write_uwsm_app_shim   > "$SHIMS_DIR/$f" ;;
            systemd-run) write_systemd_run_shim > "$SHIMS_DIR/$f" ;;
            systemctl)  write_systemctl_shim  > "$SHIMS_DIR/$f" ;;
        esac
        chmod 0755 "$SHIMS_DIR/$f" || { err "cannot chmod $SHIMS_DIR/$f"; return 1; }
        n=$((n + 1))
    done
    ok "installed $n launch shim(s) in $SHIMS_DIR"
    printf '        %s\n' "$SHIMS_DIR/uwsm-app" "$SHIMS_DIR/systemd-run" "$SHIMS_DIR/systemctl"
}

# Are the shims present AND first on PATH? A shim that exists but is shadowed
# by a real binary elsewhere is worse than none, because it silently does
# nothing different from what the caller expected.
shims_working() {
    local s
    for s in uwsm-app systemd-run systemctl; do
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