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
    # "Already applied" must be tested with the patch itself, not by looking
    # for any local change: the sway overrides and the launch shims live in
    # this same working tree, so "working tree is dirty" was true even when
    # the port patch had never applied -- which is how a failed apply got
    # reported as done on the next run. A reverse --check succeeds only when
    # every hunk of the patch is present.
    if git -C "$MAGIKOS_HOME" apply --reverse --check "$patch" >/dev/null 2>&1; then
        ok "Void port patch already applied"
        return 0
    fi
    log "Applying Void port patch"
    local apply_err
    if ! apply_err="$(git -C "$MAGIKOS_HOME" apply --verbose "$patch" 2>&1)"; then
        # git's own message is the only useful diagnostic here: it names the
        # exact file and hunk that no longer matches, which is what tells you
        # upstream drifted. Swallowing it made this step unactionable.
        stage_err "patch failed to apply against upstream $(git -C "$MAGIKOS_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        printf '%s\n' "$apply_err" | head -12 | while IFS= read -r line; do
            stage_err "    $line"
        done
        stage_err "  the patch targets a different upstream revision; refresh it with:"
        stage_err "    cd '$MAGIKOS_HOME' && git apply '$patch'"
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

    # 3c. Void has no systemd user session. Upstream relies on systemd user
    #     units to socket-activate pipewire/pipewire-pulse/wireplumber, and
    #     those calls are exactly the dead `systemctl --user` ones. Nothing
    #     else starts them, so audio NEVER exists on this port: every `wpctl`
    #     call answers "Could not connect to PipeWire" and the volume keys
    #     change nothing. Start the daemons with the session instead.
    #
    #     pipewire + pipewire-pulse run exec-always WITHOUT a guard: a second
    #     instance refuses to bind the sockets and exits, so reloads cannot
    #     stack them. wireplumber runs guarded: two wireplumbers fight until
    #     the default sink disappears, and a boot duplicated one anyway from a
    #     spawner whose argv0 was the resolved absolute path with no parent.
    #     pgrep -x misses that form; pgrep -f would match this very sh -c; the
    #     bracket pattern 'wireplumbe[r]' is the only form that catches both
    #     without self-matching. The block is rebuilt wholesale on every run
    #     (awk keeps everything before the marker, then the fresh block is
    #     appended), so an older version is upgraded for free.
    if [[ -f $dir/autostart.conf ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '  \033[2mplan\033[0m  add pipewire/wireplumber exec lines to %s\n' \
                "$dir/autostart.conf"
        else
            awk '/magikos-void: session audio/{exit} {print}' \
                "$dir/autostart.conf" > "$dir/autostart.conf.tmp" &&
                mv "$dir/autostart.conf.tmp" "$dir/autostart.conf"
            tee -a "$dir/autostart.conf" >/dev/null <<'EOF'

# magikos-void: session audio. Void has no systemd user session, which is
# what upstream relies on to start these binaries automatically. Without
# them in the session, PipeWire never runs and the system is permanently
# silent (wpctl: "Could not connect to PipeWire").
exec_always pipewire
exec_always pipewire-pulse
exec_always sh -c "pgrep -f 'wireplumbe[r]' >/dev/null || wireplumber >/dev/null 2>&1"
EOF
            # Lock out XDG autostart as a second audio-daemon source in one
            # file that does not cost anything: /etc/xdg/autostart/pipewire.desktop
            # ships Exec=pipewire, and any future consumer of XDG autostart
            # (portal, dex, a session wrapper) would race the sway block with
            # its own copy. XDG autostart suppression is a Hidden=true copy
            # under $XDG_CONFIG_HOME/autostart; pipewire/pipewire-pulse
            # double-spawns waste only a fork (instance two refuses to bind),
            # but the honest defence is to not spawn at all.
            local _autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
            if [[ ! -e $_autostart_dir/pipewire.desktop ]]; then
                mkdir -p "$_autostart_dir" &&
                cat > "$_autostart_dir/pipewire.desktop" <<'PKGOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Comment=disabled: session audio belongs to the sway autostart block
Hidden=true
Exec=pipewire
PKGOF
                printf '    applied XDG-autostart override for pipewire.desktop in %s\n' \
                    "$_autostart_dir"
            fi
        fi
    fi

    # 4. Wallpaper must exist locally, else swaybg blanks the output. Create
    #    the parent dir if we can, but do NOT fabricate an image: an empty
    #    file would make swaybg fail worse than a missing one.
    if [[ -f $dir/appearance.conf ]]; then
        local wl_img
        # Prefer the configured WALLPAPER, falling back to any image already
        # in the wallpapers directory so the user never has to manually fix
        # a dangling bg line.
        if [[ -f $WALLPAPER ]]; then
            wl_img="$WALLPAPER"
        else
            local d
            d="$(dirname "$WALLPAPER")"
            ensure_dir "$d" "wallpaper dir" || true
            wl_img="$(find "$d" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | sort | head -n1)"
        fi

        if [[ -n $wl_img && -f $wl_img ]]; then
            # Rewrite both forms: 'set $wallpaper <path>' and
            # 'output * bg <path> fill' (and 'output * bg <path>' without fill).
            _c sed -i \
                -e "s|^set \$wallpaper .*|set \$wallpaper $wl_img|" \
                -e "s|^output \* bg .*|output * bg $wl_img fill|" \
                "$dir/appearance.conf"
            ok "wallpaper -> $wl_img"
        else
            # No usable image: neutralise the dangling bg line and use the
            # solid_color fallback so sway still validates.
            if grep -q '^output \* bg ' "$dir/appearance.conf"; then
                _c sed -i \
                    -e 's|^\(output \* bg \).*|\1# <no wallpaper found>|' \
                    -e 's|^# output \* bg #1e1e2e solid_color|output * bg #1e1e2e solid_color|' \
                    "$dir/appearance.conf"
            fi
            stage_warn "no wallpaper image found at or near $WALLPAPER"
            stage_warn "     sway will use a solid background instead."
        fi
    fi
    ok "applied Void sway overrides to $dir"
}

# sha256 of a file, empty when the file cannot be read (missing/unreadable).
# Taken via command substitution, so this must print ONLY the hash.
stage_file_hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

stage_sway_user_config() {
    log "Deploying Sway config -> $MAGIKOS_USER_SWAY"
    ensure_dir "$MAGIKOS_USER_SWAY" "sway config dir" || return 1
    have sha256sum || { stage_err "sha256sum (coreutils) missing; cannot track staged files"; return 1; }
    local manifest="$MAGIKOS_USER_SWAY/.stage-manifest"

    # What a previous stage left behind, keyed by target filename. Entries are
    # recorded AFTER apply_sway_overrides has had its pass below; the
    # overrides are idempotent, so on the next run the freshly overridden copy
    # hashes exactly like the record. "Record still matches" therefore means
    # nobody but this installer has touched the file -- anything else, a
    # missing entry included, is user property and must not be overwritten.
    # Without this distinction a re-run rewrote ~/.config/sway wholesale,
    # which is how local edits kept dying on every install (and, since such
    # reinstalls tended to happen right before a reboot, got blamed on the
    # restart).
    local -A staged=()
    local -A skipped_keys=()
    local -a tracked=()
    local h f
    if [[ -f $manifest ]]; then
        while read -r h f; do
            [[ -n $h && -n $f ]] || continue
            staged[$f]=$h
            tracked+=("$f")
        done <"$manifest"
    fi

    local src dst key shash dcur copied=0 current=0 skipped=0
    # NOTE: the main entry point is `config`, not `config.conf`.
    for f in config appearance autostart bindings environment input output windows; do
        src="$MAGIKOS_HOME/config/sway/$f"
        if [[ ! -f $src ]]; then
            src="$MAGIKOS_HOME/config/sway/$f.conf"
        fi
        if [[ ! -f $src ]]; then
            continue
        fi
        # Keep the source basename: templates may be `bindings.conf`, and the
        # user file must stay `bindings.conf`, not lose its extension.
        key="$(basename "$src")"
        dst="$MAGIKOS_USER_SWAY/$key"
        shash="$(stage_file_hash "$src")"
        dcur="$(stage_file_hash "$dst")"
        if [[ $dcur == "$shash" ]]; then
            # Already at template content; do not even touch the mtime.
            ((current++))
            # Content equal to the template is safe to adopt as installed
            # output: from now on, an edit to it is detected as user work.
            if [[ -z ${staged[$key]:-} ]]; then
                tracked+=("$key")
                staged[$key]="pending"
            fi
            continue
        fi
        if [[ -n $dcur && ${staged[$key]:-} != $dcur ]]; then
            # Locally edited, or staged by an older installer and re-edited
            # since. It belongs to the user now; copy nothing, and do NOT
            # adopt its content into the record below, or the next run would
            # read the user's edit as installer output and overwrite it.
            skipped_keys[$key]=1
            if [[ $shash != $dcur ]]; then
                stage_warn "left $key alone: edited locally since the last stage"
                stage_warn "     and the template differs; compare with:"
                stage_warn "     diff $src $dst"
            fi
            ((skipped++))
            continue
        fi
        _c cp "$src" "$dst" || { stage_err "copying $src -> $dst failed"; continue; }
        ((copied++))
        if [[ -z ${staged[$key]:-} ]]; then
            tracked+=("$key")
        fi
    done
    ok "sway config staged: $copied copied, $current already current, $skipped left untouched"
    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  verify %s/config exists after the copy\n' "$MAGIKOS_USER_SWAY"
    elif [[ ! -f $MAGIKOS_USER_SWAY/config ]]; then
        stage_err "no sway 'config' entry point staged; $MAGIKOS_USER_SWAY would be unusable"
        stage_err "     expected it at $MAGIKOS_HOME/config/sway/config"
        return 1
    fi
    # Overrides still run on BOTH copies (rule 2): they carry port invariants
    # -- MAGIKOS_PATH, session audio, wallpaper resolution -- not user
    # preference, so a locally-edited file must still receive them. Only the
    # copy step above yields to a local edit. Upstream `magikos-refresh-sway`
    # does not yield at all (it is a documented wholesale overwrite), so it
    # remains a way to lose local edits by hand.
    apply_sway_overrides "$MAGIKOS_HOME/config/sway"
    apply_sway_overrides "$MAGIKOS_USER_SWAY"

    # Record post-override hashes for installer-owned files, so a later run
    # can tell its own output from user work. Everything skipped this run
    # keeps its previous record (or none): re-hashing here would have
    # committed the user's edit as "installer output" and invited the very
    # overwrite this staging exists to prevent.
    if ((DRY_RUN)); then
        printf '  \033[2mplan\033[0m  rewrite %s\n' "$manifest"
        return 0
    fi
    for f in "${tracked[@]}"; do
        if [[ -n ${skipped_keys[$f]:-} ]]; then
            continue
        fi
        h="$(stage_file_hash "$MAGIKOS_USER_SWAY/$f")"
        if [[ -n $h ]]; then
            staged[$f]=$h
        fi
    done
    {
        for f in "${!staged[@]}"; do
            if [[ -n ${staged[$f]} && ${staged[$f]} != pending ]]; then
                printf '%s %s\n' "${staged[$f]}" "$f"
            fi
        done
    } | sort -k2 >"$manifest" || stage_warn "could not write $manifest"
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
    # The port patch and the sway config deployment are independent concerns.
    # A patch failure (upstream drift) must be reported, but it must not block
    # the sway config copy — otherwise ~/.config/sway/ stays empty and the
    # desktop is unusable even though the port itself is the only thing broken.
    stage_apply_patch    || true
    stage_sway_user_config || return 1
    stage_shell_config   || return 1
    stage_env            || return 1
    if ((STAGE_ERRORS == 0)); then
        ok "MagikOS staged"
    else
        warn "MagikOS staged with $STAGE_ERRORS error(s); see above"
    fi
}
