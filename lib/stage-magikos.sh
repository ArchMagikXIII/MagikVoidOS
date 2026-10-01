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

MAGIKOS_USER_SWAY="${MAGIKOS_USER_SWAY:-$HOME/.config/sway}"
WALLPAPER="${WALLPAPER:-$HOME/Pictures/Wallpapers/Osaka.jpg}"

stage_clone() {
    if [[ -d $MAGIKOS_HOME/.git ]]; then
        ok "MagikOS already cloned at \$MAGIKOS_HOME ($MAGIKOS_HOME)"
        ( cd "$MAGIKOS_HOME" && git fetch -q origin && git rev-parse --short HEAD ) || true
        return 0
    fi
    if [[ -e $MAGIKOS_HOME ]]; then
        warn "$MAGIKOS_HOME exists but is not a git clone; backing it up"
        _c mv "$MAGIKOS_HOME" "${MAGIKOS_HOME}.pre-void-port.$(date +%Y%m%d%H%M%S)"
    fi
    log "Cloning MagikOS -> $MAGIKOS_HOME"
    mkdir -p "$(dirname "$MAGIKOS_HOME")"
    _c git clone "$MAGIKOS_UPSTREAM_URL" "$MAGIKOS_HOME"
}

stage_apply_patch() {
    local patch="${SHARE_DIR:-$SHARE_DIR}/void-port.patch"
    [[ -f $patch ]] || { err "patch not found: $patch"; return 1; }
    if git -C "$MAGIKOS_HOME" status --porcelain | grep -q .; then
        ok "Void port patch already applied (working tree has local changes)"
        return 0
    fi
    log "Applying Void port patch"
    _c git -C "$MAGIKOS_HOME" apply "$patch"
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
        _c sed -i 's|^\(.*\)autotiling\(.*\)$|# void-port: autotiling daemon not shipped upstream: \1autotiling\2|' \
            "$dir/autostart.conf"
    fi

    # 4. Wallpaper must exist locally, else swaybg blanks the output.
    if [[ -f $dir/appearance.conf ]]; then
        local wl_set=0
        grep -q '^set $wallpaper ' "$dir/appearance.conf" && wl_set=1
        if ((wl_set)) && [[ ! -f $WALLPAPER ]]; then
            warn "wallpaper missing: $WALLPAPER (leaving appearance.conf untouched)"
        elif ((wl_set)); then
            _c sed -i "s|^set \$wallpaper .*|set \$wallpaper $WALLPAPER|" "$dir/appearance.conf"
        fi
    fi
    ok "applied Void sway overrides to $dir"
}

stage_sway_user_config() {
    log "Deploying Sway config -> $MAGIKOS_USER_SWAY"
    mkdir -p "$MAGIKOS_USER_SWAY"
    local f
    # NOTE: the main entry point is `config`, not `config.conf`.
    for f in config appearance autostart bindings environment input output windows; do
        [[ -f $MAGIKOS_HOME/config/sway/$f ]] && _c cp "$MAGIKOS_HOME/config/sway/$f" "$MAGIKOS_USER_SWAY/"
        [[ -f $MAGIKOS_HOME/config/sway/$f.conf ]] && _c cp "$MAGIKOS_HOME/config/sway/$f.conf" "$MAGIKOS_USER_SWAY/"
    done
    if [[ ! -f $MAGIKOS_USER_SWAY/config ]]; then
        err "no sway 'config' entry point staged; ~/.config/sway would be unusable"
        return 1
    fi
    # Patch the *staged* source too, then re-derive the user copy from it so
    # both stay identical and `magikos-refresh-sway` becomes a no-op-safe op.
    apply_sway_overrides "$MAGIKOS_HOME/config/sway"
    apply_sway_overrides "$MAGIKOS_USER_SWAY"
}

stage_shell_config() {
    log "Staging shell + themes"
    mkdir -p "$HOME/.config/magikos"
    if [[ -f $MAGIKOS_HOME/config/magikos/shell.json && ! -f $HOME/.config/magikos/shell.json ]]; then
        _c cp "$MAGIKOS_HOME/config/magikos/shell.json" "$HOME/.config/magikos/shell.json"
    fi
    ok "$(ls "$MAGIKOS_HOME/themes" 2>/dev/null | wc -l) themes available"
}

stage_env() {
    log "Persisting MAGIKOS_PATH in shell profile"
    local f="$HOME/.profile"
    if grep -q 'MAGIKOS_PATH' "$f" 2>/dev/null; then
        ok "MAGIKOS_PATH already exported in $f"
        return 0
    fi
    _c tee -a "$f" >/dev/null <<'EOF'

# MagikOS (Void port)
export MAGIKOS_PATH="$HOME/.local/share/magikos"
export PATH="$MAGIKOS_PATH/bin:$PATH"
EOF
    ok "added MAGIKOS_PATH + PATH to $f"
}

stage_all() {
    stage_clone || return 1
    stage_apply_patch || return 1
    stage_sway_user_config || return 1
    stage_shell_config || return 1
    stage_env || return 1
    ok "MagikOS staged"
}
