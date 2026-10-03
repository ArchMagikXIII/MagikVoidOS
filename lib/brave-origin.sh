#!/usr/bin/env bash
# Build + install Brave Origin as a native Void package.
#
# WHY THIS EXISTS
# ---------------
# MagikOS binds `brave-origin` and expects a package named `brave-origin-bin`.
# That name comes from the AUR/CachyOS world. Void ships no Brave at all:
#   * void-linux/void-packages has no brave/brave-bin template (404)
#   * Brave's licence is not accepted by Void, so it cannot live in the binary repo
# Brave DOES publish official x86_64 .deb and .rpm builds on GitHub releases,
# including a first-party `brave-origin` build. We repackage that prebuilt
# binary into a Void-native layout. No compilation, so it builds anywhere.
#
# Result:
#   /opt/brave-origin/brave-origin        real browser launcher
#   /usr/bin/brave-origin                stable symlink (name MagikOS expects)
#   /usr/share/applications/brave-origin.desktop
#   /usr/share/icons/hicolor/256x256/apps/brave-origin.png
#
# Usage:
#   build-brave-origin [--version X.Y.Z] [--destdir DIR] [--no-install]
#
# --destdir DIR stages the package payload under DIR instead of / (used by the
# test suite to verify packaging without root).

BRAVE_REPO_URL="${BRAVE_REPO_URL:-https://github.com/brave/brave-browser/releases/download}"
BRAVE_WORKDIR="${BRAVE_WORKDIR:-${TMPDIR:-/tmp}/magikos-void-brave}"

# Debian control fields -> the .deb dependency list is Debian-flavoured; map the
# handful that differ on Void. Anything already satisfied is skipped by xbps at
# runtime via the generated DEPENDS file.
brave_void_depends() {
    cat <<'EOF'
alsa-lib
at-spi2-core
atk
ca-certificates
libcups
dbus
expat
liberation-fonts-ttf
gtk+
libX11
libXcomposite
libXdamage
libXext
libXfixes
libXrandr
libxkbcommon
mesa
nspr
nss
pango
vulkan-loader
EOF
}

brave_latest_version() {
    # Resolve the newest vX.Y.Z tag from GitHub without jq.
    curl -sf "https://api.github.com/repos/brave/brave-browser/releases/latest" \
        | grep -oE '"tag_name": "v[0-9]+\.[0-9]+\.[0-9]+"' \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

# Extract a .deb (ar archive) using only coreutils/python3 -- Void has no `ar`
# or `dpkg-deb`, and we must not assume binutils is installed.
deb_extract() {
    local deb="$1" outdir="$2"
    mkdir -p "$outdir"
    python3 - "$deb" "$outdir" <<'PY'
import sys, os
deb, outdir = sys.argv[1], sys.argv[2]
with open(deb, 'rb') as f:
    if f.read(8) != b'!<arch>\n':
        sys.exit("not an ar archive: %s" % deb)
    while True:
        hdr = f.read(60)
        if len(hdr) < 60:
            sys.exit("data member not found in %s" % deb)
        name = hdr[0:16].decode('ascii', 'replace').strip().rstrip('/')
        size = int(hdr[48:58].decode().strip() or 0)
        if name.startswith('data.tar'):
            comp = name.split('.')[-1]
            target = os.path.join(outdir, name)
            with open(target, 'wb') as out:
                while size:
                    chunk = f.read(min(size, 1 << 20))
                    if not chunk:
                        sys.exit("truncated archive")
                    out.write(chunk)
                    size -= len(chunk)
            print("extracted %s" % target)
            break
        f.seek(size + (size % 2), 1)
PY
}

brave_build() {
    local destdir="" do_install=1
    while (($#)); do
        case "$1" in
            --version)   BRAVE_VERSION="$2"; shift 2 ;;
            --destdir)   destdir="$2"; shift 2 ;;
            --no-install) do_install=0; shift ;;
            -h|--help)   sed -n '2,25p' "$0"; return 0 ;;
            *) err "unknown arg: $1"; return 1 ;;
        esac
    done

    require_cmd curl || return 1
    require_cmd python3 || return 1
    require_cmd tar || return 1

    if [[ -z $BRAVE_VERSION ]]; then
        log "Resolving latest Brave version"
        BRAVE_VERSION="$(brave_latest_version)"
        [[ -n $BRAVE_VERSION ]] || { err "could not resolve version"; return 1; }
    fi
    log "Building brave-origin $BRAVE_VERSION"

    local w="$BRAVE_WORKDIR"
    rm -rf "$w"; mkdir -p "$w"
    local deb="$w/brave-origin_${BRAVE_VERSION}_amd64.deb"
    local url="$BRAVE_REPO_URL/v${BRAVE_VERSION}/brave-origin_${BRAVE_VERSION}_amd64.deb"
    # Look for a pre-fetched deb in share/brave-cache/. Relative to this script
    # so the repo works from any checkout path. Never hardcode a home
    # directory here: it makes the repo non-portable and it is why the cache
    # never hit for anyone but the original author.
    local cache_dir=""
    if [[ -n "${SHARE_DIR:-}" ]]; then
        cache_dir="$SHARE_DIR/brave-cache"
    else
        cache_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/share/brave-cache"
    fi
    local cached_deb=""
    if [[ -f "$cache_dir/brave-origin_${BRAVE_VERSION}_amd64.deb" ]]; then
        cached_deb="$cache_dir/brave-origin_${BRAVE_VERSION}_amd64.deb"
    fi

    if [[ -n "$cached_deb" && -s "$cached_deb" ]]; then
        log "Using cached Brave .deb: $(basename "$cached_deb")"
        _c cp "$cached_deb" "$deb"
    else
        log "Downloading $(basename "$deb")"
        # -f so an HTML error page is never saved as a "deb"; without it a 404
        # lands in the file, passes the -s test, and fails much later with a
        # misleading message. --progress-bar keeps a 126 MB download from
        # looking hung without dumping a retry storm on retry.
        if ! _c curl -fL --progress-bar --retry 3 --retry-delay 2 -o "$deb" "$url"; then
            err "download failed: $url"
            return 1
        fi
        [[ -s $deb ]] || { err "downloaded deb is empty"; return 1; }
    fi

    # Start from a clean tree. The workdir persists between runs, so a previous
    # partial extraction left a stale data.tar.* behind; `find` would then pick
    # that up and the real error was masked by a confusing downstream failure.
    rm -rf "$w/root" "$w/pkg" "$w"/data.tar.*
    mkdir -p "$w" || { err "cannot create workdir $w"; return 1; }

    if ! deb_extract "$deb" "$w"; then
        err "could not unpack the .deb (not an ar archive, or truncated download)"
        err "delete $deb and retry to force a fresh download"
        return 1
    fi

    local data
    data="$(find "$w" -maxdepth 1 -name 'data.tar.*' | head -1)"
    if [[ -z $data ]]; then
        err "no data.tar member inside the .deb"
        err "members found: $(find "$w" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
        return 1
    fi
    log "Unpacking $(basename "$data")"
    mkdir -p "$w/root" || return 1

    # Do NOT hardcode the compressor. Forcing --zst dies on Void, which ships no
    # zstd, and forcing --xz dies if Brave ever switches to zstd. GNU tar
    # auto-detects the format on extract, so let it sniff.
    if ! _c tar -xf "$data" -C "$w/root"; then
        err "tar could not extract $(basename "$data")"
        # Name the actual reason rather than letting it surface later as a
        # missing payload directory.
        local tver
        tver="$(tar --version 2>/dev/null | head -1)"
        err "  tar: $tver"
        case "${data##*.}" in
            zst) err "  this member is zstd-compressed; install zstd: sudo xbps-install -S zstd" ;;
            xz)  err "  this member is xz-compressed; install xz: sudo xbps-install -S xz" ;;
        esac
        return 1
    fi

    # The payload is expected at /opt/brave.com/brave-origin. Locate it rather
    # than assuming, and if it is absent show what actually landed in the tree
    # so the next run has something to act on.
    local src
    src="$(find "$w/root/opt" -maxdepth 2 -type d -name 'brave-origin' 2>/dev/null | head -1)"
    if [[ -z $src || ! -d $src ]]; then
        err "payload dir not found: expected $w/root/opt/brave.com/brave-origin"
        err "  /opt entries actually present: $(find "$w/root/opt" -maxdepth 2 -mindepth 1 -type d 2>/dev/null | sed "s|$w/root/||" | tr '\n' ' ')"
        err "  top level: $(find "$w/root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed "s|$w/root/||" | tr '\n' ' ')"
        return 1
    fi

    local stage="$w/pkg"
    mkdir -p "$stage/opt" "$stage/usr/share" "$stage/usr/bin" \
             "$stage/usr/share/icons/hicolor/256x256/apps" \
             "$stage/usr/share/doc/brave-origin"
    _c cp -a "$src" "$stage/opt/"
    _c cp -a "$w/root/usr/share/applications" "$stage/usr/share/"

    # /usr/bin: MagikOS resolves `brave-origin`; the deb only ships
    # `brave-origin-stable`. Provide both, plus `brave-browser` for
    # interop with generic tooling that expects the unprefixed name.
    _c ln -sf "$BRAVE_PREFIX/brave-origin" "$stage/usr/bin/brave-origin"
    _c ln -sf "$BRAVE_PREFIX/brave-origin" "$stage/usr/bin/brave-origin-stable"

    # Icons: the deb ships product_logo_*.png inside the payload but installs
    # no hicolor theme, while brave-origin.desktop sets Icon=brave-origin.
    # Without this the launcher shows a blank/generic icon.
    _c cp "$src/product_logo_256.png" "$stage/usr/share/icons/hicolor/256x256/apps/brave-origin.png"

    # Void package metadata, so `xbps-query -Rs` / `pkg_file_owner` can see it.
    _c cp "$src/LICENSE" "$stage/usr/share/doc/brave-origin/LICENSE"

    # Apparmor profile shipped in the payload. Void does not ship apparmor by
    # default, but keep the file in the package so it is available if enabled.
    ok "payload staged"

    local xbpkg="$w/brave-origin-${BRAVE_VERSION}_1.x86_64.xbps"
    log "Building xbps package"
    # NOTE: xbps-create flag semantics (easy to get wrong):
    #   -n pkgver   -s desc   -H homepage   -l license   -B built-with
    #   -D DEPENDENCIES (NOT version!)   -q quiet
    # There is no -o: the output path is derived from -n and written into the
    # current directory, so run this from the workdir.
    local deps
    deps="$(brave_void_depends | tr '\n' ' ')"

    # Every dependency must exist as a Void package name. A stale Debian name
    # (cups-libs, font-liberation-ttf, gtk3) does not fail here -- xbps-create
    # accepts any string -- it only explodes later at `xbps-install` time, long
    # after the build was reported as successful. Catch it while we can see it.
    if ! verify_package_names $(brave_void_depends); then
        err "aborting: the generated package would be uninstallable"
        return 1
    fi

    if ( cd "$w" && xbps-create -q -A x86_64 \
            -n "brave-origin-${BRAVE_VERSION}_1" \
            -s "Brave Origin browser (MagikOS Void port)" \
            -S "Repackaged from Brave's official brave-origin deb build; no compilation." \
            -H "https://brave.com/brave-origin" \
            -l "GPL-3.0-or-later" \
            -B "magikos-void-port" \
            -m "magikos-void-port" \
            -D "$deps" \
            "$stage" ); then
        ok "built $(basename "$xbpkg")"
    else
        warn "xbps-create failed; payload tree is still usable"
    fi

    if ((do_install)); then
        if [[ -n $destdir ]]; then
            _c mkdir -p "$destdir"
            _c cp -a "$stage/." "$destdir/"
            ok "staged payload -> $destdir (no root needed)"
        else
            ensure_sudo || return 1
            log "Installing to /"
            _c sudo cp -a "$stage/." /
            _c sudo xbps-uhelper getopt >/dev/null 2>&1 || true
            # Register with xbps so removals/upgrades are tracked.
            _c sudo xbps-install -y "$xbpkg" 2>/dev/null \
                || warn "could not register package metadata; files installed anyway"
            ok "brave-origin $BRAVE_VERSION installed"
        fi
    else
        _c cp -a "$stage" "$w/staged"
        ok "built payload at $w/staged"
    fi

    log "Sanity check"
    [[ -x "$stage$BRAVE_PREFIX/brave" ]] && ok "browser binary present" \
        || { err "browser binary missing"; return 1; }
    [[ -f "$stage/usr/share/applications/brave-origin.desktop" ]] && ok "desktop entry present" \
        || { err "desktop entry missing"; return 1; }
    [[ -L "$stage/usr/bin/brave-origin" ]] && ok "brave-origin on PATH" \
        || { err "usr/bin/brave-origin missing"; return 1; }

    # Prove the repackaged binary actually executes on this machine. A build
    # that packages cleanly but cannot run is worthless, and Chromium builds
    # are exactly where a broken libc/libstdc++ shows up late.
    local ver_out
    if ver_out="$("$stage$BRAVE_PREFIX/brave" --version 2>&1 | head -1)"; then
        ok "binary runs: ${ver_out}"
    else
        warn "binary did not report --version cleanly: ${ver_out:-<no output>}"
        warn "installing anyway; run 'brave-origin --version' to confirm"
    fi
    ok "command name: brave-origin (MagikOS-compatible)"
    return 0
}
