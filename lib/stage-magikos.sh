#!/usr/bin/env bash
# Stage the MagikOS runtime on Void Linux:
#   1. git clone upstream -> $MAGIKOS_HOME
#   2. apply the Void port patch (xbps backend + Quickshell fixes)
#   3. apply Void Sway overrides to the user config AND the staged source
#   4. export MAGIKOS_PATH / PATH persistently
#
# Step 3 is applied to the staged source on purpose: `magikos-refresh-sway`
# copies $MAGIKOS_HOME/config/sway -> ~/.config/sway, so if only the user
# copy were patched, the next refresh would silently restore the upstream
# /usr/share/magikos paths and re-enable the nonexistent autotiling daemon.

# NOTE: the main entry point is `config`, not `config.conf`. Copying only
# *.conf yields a config dir that sway rejects with "config not found".
MAGIKOS_USER_SWAY="${MAGIKOS_USER_SWAY:-$HOME/.config/sway}"
WALLPAPER="${WALLPAPER:-$HOME/Pictures/Wallpapers/Osaka.jpg}"

# Track what stage_all actually did, so install.sh can report honestly
# instead of claiming success.
STAGE_ERRORS=0
STAGE_WARNINGS=0
stage_err()  { err "$*"; ((STAGE_ERRORS++)); }
stage_warn() { warn "$*"; ((STAGE_WARNINGS++)); }

stage_clone() {
    if [[ -d $MAGIKOS_HOME/.git ]]; then
        ok "MagikOS already cloned at \$MAGIKOS_HOME ($MAGIKOS_HOME)"
        ( cd "$MAGIKOS_HOME" && git fetch -q origin && git rev-parse --short HEAD ) || true
        return 0
    fi
    if [[ -e $MAGIKOS_HOME ]]; then
        stage_warn "$MAGIKOS_HOME exists but is not a git clone; backing it up"
        _c mv "$MAGIKOS_HOME" "${MAGIKOS_HOME}.pre-void-port.$(date +%Y%m%d%H%M%S)"
    fi
    log "Cloning MagikOS -> $MAGIKOS_HOME"
    # The parent chain is created by ensure_paths() before this runs; only
    # create it here as a fallback for when this lib is used standalone.
    ensure_dir "$(dirname "$MAGIKOS_HOME")" "runtime parent" || return 1
    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  git clone %s %s\n' "$MAGIKOS_UPSTREAM_URL" "$MAGIKOS_HOME"
        return 0
    fi
    if ! git clone -q "$MAGIKOS_UPSTREAM_URL" "$MAGIKOS_HOME"; then
        stage_err "git clone failed (network problem, or the URL is unreachable)"
        return 1
    fi
    ok "cloned $(git -C "$MAGIKOS_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"
}

stage_apply_patch() {
    local patch="${SHARE_DIR:-$SHARE_DIR}/void-port.patch"
    [[ -f $patch ]] || { stage_err "patch not found: $patch"; return 1; }
    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  apply %s\n' "$patch"
        return 0
    fi
    if [[ ! -d $MAGIKOS_HOME/.git ]]; then
        stage_err "no git clone at $MAGIKOS_HOME; cannot apply the Void port patch"
        return 1
    fi
    if git -C "$MAGIKOS_HOME" status --porcelain | grep -q .; then
        ok "Void port patch already applied (working tree has local changes)"
        return 0
    fi
    log "Applying Void port patch"
    if ! git -C "$MAGIKOS_HOME" apply "$patch"; then
        stage_err "patch failed to apply cleanly; upstream may have drifted"
        stage_err "     inspect with: git -C $MAGIKOS_HOME apply --stat $patch"
        return 1
    fi
    ok "applied $(grep -c '^diff --git' "$patch") file changes"
}

# apply_sway_overrides <dir>
apply_sway_overrides() {
    local dir="$1"
    [[ -d $dir ]] || { warn "sway dir missing: $dir"; return 0; }

    # 1. Point MAGIKOS_PATH at the unprivileged staging root, and make sure the
    #    PATH line does not keep a /usr/share/magikos entry ahead of it (that
    #    path does not exist on this install, and a stale entry shadows the
    #    real bin dir for every exec that resolves helpers by name).
    if [[ -f $dir/environment.conf ]]; then
        _c sed -i \
            -e 's|\${MAGIKOS_PATH:-/usr/share/magikos}|${MAGIKOS_PATH:-$HOME/.local/share/magikos}|g' \
            -e 's|^set \$MAGIKOS_PATH .*|set $MAGIKOS_PATH $HOME/.local/share/magikos|' \
            -e 's|^set \$PATH /usr/share/magikos/bin:|set $PATH $HOME/.local/share/magikos/bin:|' \
            "$dir/environment.conf"
    fi

    # 2. Same fallback rewrite for exec lines in bindings/autostart.
    for f in bindings.conf autostart.conf; do
        [[ -f $dir/$f ]] || continue
        _c sed -i \
            's|\${MAGIKOS_PATH:-/usr/share/magikos}|${MAGIKOS_PATH:-$HOME/.local/share/magikos}|g' \
            "$dir/$f"
    done

    # 3. autotiling ships nowhere upstream (single dangling exec in autostart.conf).
    if [[ -f $dir/autostart.conf ]]; then
        # Mark uncommented autotiling execs only. Matching the marker itself
        # would double the prefix on every re-run, since this is idempotent and
        # runs against both the user copy and the staged source.
        _c sed -i 's|^\([ \t]*exec[ \t].*autotiling.*\)$|# void-port: autotiling daemon not shipped upstream: \1|' \
            "$dir/autostart.conf"
    fi

    # 3b. GPU-less machines (VMs with a paravirtual adapter, nested virt,
    #     headless) have no usable 3D, so Mesa selects ZINK, which fails with
    #     VK_ERROR_INITIALIZATION_FAILED. Quickshell then gets no GL context and
    #     the bar silently never draws. Pin software rendering so the session
    #     is usable. Only applied when the user has not already chosen.
    if [[ -f $dir/environment.conf ]] && ((AUTO_SOFTWARE_RENDER)); then
        if ! grep -q 'WLR_RENDERER' "$dir/environment.conf"; then
            if ((DRY_RUN)) && ! detect_no_gpu; then
                printf '  \033[2mplan\033[0m  check for a usable GPU; pin software rendering if none\n'
            elif detect_no_gpu; then
                if ((DRY_RUN)); then
                    printf '  \033[2mplan\033[0m  pin WLR_RENDERER=pixman in %s (no GPU detected)\n' "$dir/environment.conf"
                    ok "software rendering would be pinned (no GPU detected)"
                fi
                _c tee -a "$dir/environment.conf" >/dev/null <<'EOF'

# Added by magikos-void: no usable 3D GPU detected on this machine.
# Without this, Mesa picks ZINK, which fails to initialise and leaves
# Quickshell without a GL context (no bar, blank/black screen).
set $WLR_RENDERER pixman
set $LIBGL_ALWAYS_SOFTWARE 1
EOF
                ok "pinned software rendering (no GPU detected)"
            fi
        fi
    fi

    # 4. Wallpaper must exist locally, else swaybg blanks the output. Create
    #    the parent dir if we can, but do NOT fabricate an image: an empty
    #    file would make swaybg fail worse than a missing one.
    if [[ -f $dir/appearance.conf ]]; then
        local wl_set=0
        grep -q '^set $wallpaper ' "$dir/appearance.conf" && wl_set=1
        if ((wl_set)) && [[ ! -f $WALLPAPER ]]; then
            ensure_dir "$(dirname "$WALLPAPER")" "wallpaper dir" || true
            if ((DRY_RUN)) && [[ ! -d $(dirname "$WALLPAPER") ]]; then
                printf '  \033[2mplan\033[0m  would create %s\n' "$(dirname "$WALLPAPER")"
            elif [[ ! -f $WALLPAPER ]]; then
                stage_warn "no wallpaper at $WALLPAPER"
                stage_warn "     Sway will start with a black background."
                stage_warn "     fix by dropping any .jpg there, or set WALLPAPER=/path/to/img"
            fi
        elif ((wl_set)); then
            _c sed -i "s|^set \$wallpaper .*|set \$wallpaper $WALLPAPER|" "$dir/appearance.conf"
            ok "wallpaper -> $WALLPAPER"
        fi
    fi
    ok "applied Void sway overrides to $dir"
}

stage_sway_user_config() {
    log "Deploying Sway config -> $MAGIKOS_USER_SWAY"
    ensure_dir "$MAGIKOS_USER_SWAY" "sway config dir" || return 1
    local f copied=0
    # NOTE: the main entry point is `config`, not `config.conf`.
    for f in config appearance autostart bindings environment input output windows; do
        if [[ -f $MAGIKOS_HOME/config/sway/$f ]]; then
            _c cp "$MAGIKOS_HOME/config/sway/$f" "$MAGIKOS_USER_SWAY/"; ((copied++))
        elif [[ -f $MAGIKOS_HOME/config/sway/$f.conf ]]; then
            _c cp "$MAGIKOS_HOME/config/sway/$f.conf" "$MAGIKOS_USER_SWAY/"; ((copied++))
        fi
    done
    ok "staged $copied sway file(s)"
    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  verify %s/config exists after the copy\n' "$MAGIKOS_USER_SWAY"
    elif [[ ! -f $MAGIKOS_USER_SWAY/config ]]; then
        stage_err "no sway 'config' entry point staged; $MAGIKOS_USER_SWAY would be unusable"
        stage_err "     expected it at $MAGIKOS_HOME/config/sway/config"
        return 1
    fi
    # Patch the *staged* source too, then re-derive the user copy from it so
    # both stay identical and `magikos-refresh-sway` becomes a no-op-safe op.
    apply_sway_overrides "$MAGIKOS_HOME/config/sway"
    apply_sway_overrides "$MAGIKOS_USER_SWAY"
}

stage_shell_config() {
    log "Staging shell + themes"
    ensure_dir "$MAGIKOS_USER_CONFIG" "magikos user config" || return 1
    if [[ -f $MAGIKOS_HOME/config/magikos/shell.json && ! -f $MAGIKOS_USER_CONFIG/shell.json ]]; then
        _c cp "$MAGIKOS_HOME/config/magikos/shell.json" "$MAGIKOS_USER_CONFIG/"
        ok "shell.json -> $MAGIKOS_USER_CONFIG"
    elif [[ -f $MAGIKOS_USER_CONFIG/shell.json ]]; then
        ok "shell.json already present (left alone)"
    else
        stage_err "no shell.json found in the runtime tree"
        return 1
    fi
    local n
    n="$(ls "$MAGIKOS_HOME/themes" 2>/dev/null | wc -l)"
    if ((n > 0)); then ok "$n themes available"; else stage_warn "no themes found in $MAGIKOS_HOME/themes"; fi
}

stage_env() {
    log "Persisting MAGIKOS_PATH in shell profile"
    local f="$HOME/.profile"
    if grep -q 'MAGIKOS_PATH' "$f" 2>/dev/null; then
        ok "MAGIKOS_PATH already exported in $f"
        return 0
    fi
    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  append MAGIKOS_PATH + PATH to %s\n' "$f"
        return 0
    fi
    # $HOME must be interpolated now, so use printf rather than a quoted heredoc.
    _c printf '\n# MagikOS (Void port)\nexport MAGIKOS_PATH="%s"\nexport PATH="$MAGIKOS_PATH/bin:$PATH"\n' \
        "$MAGIKOS_HOME" >>"$f"
    ok "added MAGIKOS_PATH + PATH to $f"
}

stage_all() {
    STAGE_ERRORS=0
    STAGE_WARNINGS=0
    stage_clone          || return 1
    stage_apply_patch    || return 1
    stage_sway_user_config || return 1
    stage_shell_config   || return 1
    stage_env            || return 1
    ok "MagikOS staged"
}
