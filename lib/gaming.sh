#!/usr/bin/env bash
# Gaming stack for MagikVoidOS: everything needed for games to actually run
# at hardware speed on Void.
#
# Four fixes, each detection-gated so nothing applies where it does not belong:
#
#   1. Hybrid-GPU NVIDIA driver. On laptops with a discreet NVIDIA card
#      (e.g. Ryzen + GTX 1650), Void boots with the card bound to `nouveau`,
#      which cannot drive games: every frame lands on the weak iGPU and the
#      whole desktop reads as "slower than Arch". This installs the full
#      proprietary driver (nonfree repo -> nvidia + nvidia-libs + 32-bit
#      libs + dkms module), blacklists nouveau/nova_core, sets
#      nvidia_drm.modeset=1 for Wayland PRIME offload, and stages a
#      `magikos-prime-run` launcher so a game can be pointed at the dGPU
#      without dragging the desktop onto it.
#   2. Steam + GameMode packages.
#   3. Proton-CachyOS into Steam's user compatibilitytools.d (the tuned
#      CachyOS Proton build; user-level, no root needed).
#   4. zram swap for machines with less than 32 GiB RAM: compressed in-RAM
#      swap with higher priority than any real swap, so the NVMe partition stops being
#      hit while a game pushes memory. Delivered as a runit service, because
#      /etc/rc.local is not sourced on Void runit boot.
#
# Privilege rule (rule 1): only the xbps install, modprobe.d/grub config and
# the runit service need root; everything routes through `_c sudo`, so
# --dry-run prints the plan and changes nothing.

# --- hardware detection -------------------------------------------------------

# True when lspci reports a discreet NVIDIA GPU (hybrid laptop or desktop).
# Match both orders: 'VGA compatible controller: NVIDIA ...' puts NVIDIA
# *after* the bus-class word, so a plain 'nvidia.*vga' never matches.
detect_nvidia_gpu() {
    have lspci || return 1
    lspci 2>/dev/null | grep -i nvidia | grep -qiE 'vga|3d|display'
}

# Derive the kernel + headers package names from uname -r.
#
# Void kernels are called `linux<MAJ.MIN>` with an optional flavour suffix:
#   6.12.113_1               -> linux6.12            + linux6.12-headers
#   6.19.10_1-cachyos-bore-v3 -> linux6.19-cachyos-bore-v3 + -headers
# Verified against the repo index with -R -S before anything is installed.
kernel_pkg_names() {
    local krel="$(uname -r)"
    KERN_MAJORMINOR="$(printf %s "$krel" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')"
    KERN_FLAVOUR=""
    if [[ $krel == *-* ]]; then
        KERN_FLAVOUR="${krel#*-}"
    fi
    KERN_PKG="linux${KERN_MAJORMINOR}${KERN_FLAVOUR:+-$KERN_FLAVOUR}"
    KERN_HEADERS_PKG="$KERN_PKG-headers"
}

# --- step 1: packages ---------------------------------------------------------

VOID_GAMING_PACKAGES=(
    steam
    gamemode
    libgamemode
    libgamemode-32bit
)

VOID_NVIDIA_PACKAGES=(
    nvidia
    nvidia-libs
    nvidia-libs-32bit
    dkms
)

_notify_nonfree_repo() {
    printf '  \033[33mwarn\033[0m  %s\n' \
"the NVIDIA packages live in Void's nonfree repo, which is not enabled"
}

# Install the gaming packages (steam + gamemode). Separate from the NVIDIA
# set on purpose: an Intel-only host must never be handed nvidia packages.
install_gaming_packages() {
    local missing=() p
    for p in "${VOID_GAMING_PACKAGES[@]}"; do
        pkg_installed "$p" || missing+=("$p")
    done
    # The discrete GPU packages depend on the nonfree repo. Verify quietly and
    # defer: only hosts with an NVIDIA card install them (install_nvidia_driver).
    if ! pkg_available void-repo-nonfree \
       && ! grep -qs '/nonfree' /etc/xbps.d/repos.conf/* /usr/share/xbps.d/repos.conf/* 2>/dev/null; then
        _notify_nonfree_repo
    fi

    if ((${#missing[@]} == 0)); then
        ok "gaming packages already installed"
        return 0
    fi

    log "Installing ${#missing[@]} gaming package(s)"
    printf '      %s\n' "${missing[@]}"
    verify_package_names "${missing[@]}" || return 1
    if ((DRY_RUN)); then
        _c sudo xbps-install -yS "${missing[@]}"
        return 0
    fi
    ensure_sudo || return 1
    sudo xbps-install -yS "${missing[@]}" || {
        err "gaming package install failed"
        err "     fix manually: sudo xbps-install -Syu ${missing[*]}"
        return 1
    }
}

# --- step 2: NVIDIA proprietary driver (hybrid + discrete) --------------------

_prime_run() {
cat <<'EOF'
#!/bin/sh
# Run a program on the discrete NVIDIA GPU of a hybrid laptop.
#
# The desktop stays on the iGPU (battery, thermals); the program delegated
# here gets GL + Vulkan offload. Usage: magikos-prime-run <game/command>.
#
# Staged by MagikVoidOS. The __VK_LAYER_NV_optimus filter is the Vulkan side
# of the same offload: without it a Vulkan app (Proton/DXVK) is free to pick
# the iGPU and never touches the dGPU at all.
export __NV_PRIME_RENDER_OFFLOAD=1
export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
EOF
}

NVIDIA_BLACKLIST_FILE=/etc/modprobe.d/nvidia-no-nouveau.conf

install_nvidia_driver() {
    # AUTO_NVIDIA=0 keeps the old behaviour of doing nothing, for a host where
    # detection is right but the owner wants nouveau anyway.
    if [[ ${AUTO_NVIDIA:-1} != 1 ]]; then
        ok "NVIDIA auto-setup disabled (AUTO_NVIDIA=0)"
        return 0
    fi

    if ! detect_nvidia_gpu; then
        ok "no NVIDIA GPU detected -- driver setup skipped"
        return 0
    fi
    if ((DRY_RUN == 0)); then
        ensure_sudo || return 1
    fi

    log "NVIDIA GPU detected -- installing the proprietary driver"
    kernel_pkg_names

    # The nonfree repo must be enabled before any nvidia* name resolves.
    if ! pkg_available nvidia && ! pkg_installed nvidia; then
        log "Enabling the nonfree repository"
        verify_package_names void-repo-nonfree || return 1
        _c sudo xbps-install -yS void-repo-nonfree || {
            err "could not enable the nonfree repo"
            err "     fix manually: sudo xbps-install -Sy void-repo-nonfree"
            return 1
        }
        _c sudo xbps-install -S || {
            err "repo index sync after enabling nonfree failed"
            err "     fix manually: sudo xbps-install -S"
            return 1
        }
        pkg_available nvidia || {
            err "nonfree repo enabled but nvidia still not resolvable"
            err "     check: xbps-query -R -S nvidia"
            return 1
        }
    fi

    # Everything to install in ONE transaction (rule 5): driver + libs + dkms +
    # this kernel's headers. dkms cannot build without matching headers, so
    # they are pulled into the same command instead of left as a follow-up.
    local want=("${VOID_NVIDIA_PACKAGES[@]}")
    if pkg_available "$KERN_HEADERS_PKG"; then
        pkg_installed "$KERN_HEADERS_PKG" || want+=("$KERN_HEADERS_PKG")
    else
        warn "kernel headers package not found in repos: $KERN_HEADERS_PKG"
        warn "dkms will not be able to build the NVIDIA module for $(uname -r)"
        warn "     fix: install the headers for your running kernel first"
    fi
    local missing=() p
    for p in "${want[@]}"; do
        pkg_installed "$p" || missing+=("$p")
    done

    if ((${#missing[@]} > 0)); then
        printf '      %s\n' "${missing[@]}"
        verify_package_names "${missing[@]}" || return 1
        _c sudo xbps-install -yS "${missing[@]}" || {
            err "NVIDIA package install failed"
            err "     fix manually: sudo xbps-install -Syu ${missing[*]}"
            return 1
        }
    fi

    # Stop nouveau and nova_core from claiming the GPU at boot. Idempotent:
    # skip when the blacklist file already names both modules.
    # Idempotent: skip when the blacklist file already names both modules.
    # Both files are world-readable, so these checks need no root and create
    # no [dry] noise for what is a pure read.
    if grep -q 'blacklist nova_core' "$NVIDIA_BLACKLIST_FILE" 2>/dev/null; then
        ok "nouveau/nova_core already blacklisted"
    else
        log "Blacklisting nouveau/nova_core ($NVIDIA_BLACKLIST_FILE)"
        local blacklist
        blacklist="$(printf '%s\n%s\n%s\n' \
            'blacklist nouveau' 'blacklist nova_core' 'options nouveau modeset=0')"
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '  \033[2mplan\033[0m  would write %s:\n' "$NVIDIA_BLACKLIST_FILE"
            printf '       %s\n' "$blacklist"
        else
            printf '%s' "$blacklist" | sudo tee "$NVIDIA_BLACKLIST_FILE" >/dev/null || {
                err "could not write $NVIDIA_BLACKLIST_FILE"
                return 1
            }
            ok "nouveau/nova_core blacklisted"
        fi
    fi

    # nvidia_drm.modeset=1 is required for Wayland PRIME offload. Add it via
    # /etc/default/grub only when GRUB is the bootloader, and only once.
    if [[ -f /etc/default/grub ]]; then
        if grep -q 'nvidia_drm.modeset=1' /etc/default/grub; then
            ok "nvidia_drm.modeset=1 already in GRUB cmdline"
        elif grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            log "Adding nvidia_drm.modeset=1 to the kernel cmdline (GRUB)"
            _c sudo sed -i 's|\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"|\1 nvidia_drm.modeset=1"|' /etc/default/grub
            if [[ -f /boot/grub/grub.cfg ]]; then
                _c sudo grub-mkconfig -o /boot/grub/grub.cfg || {
                    err "grub config regeneration failed"
                    err "     fix manually: sudo grub-mkconfig -o /boot/grub/grub.cfg"
                    return 1
                }
            fi
        fi
    fi

    # Register and build the module explicitly. Void's dkms kernel hook only
    # BUILDS modules already listed in /var/lib/dkms/*; the nvidia package
    # ships its source at /usr/src/nvidia-<ver> but nothing reliably ran
    # `dkms add` -- on this kernel the hook ran with /var/lib/dkms EMPTY and
    # built nothing. So add + install straight into the running kernel here;
    # both are idempotent (already-registered / already-built are success).
    local mod_src mod_ver=""
    mod_src="$(ls -d /usr/src/nvidia-* /usr/src/nvidia 2>/dev/null | head -1)"
    if [[ -n $mod_src && -f $mod_src/dkms.conf ]]; then
        mod_ver="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$mod_src/dkms.conf" | head -1)"
    fi
    if [[ -z $mod_ver ]]; then
        err "cannot determine the nvidia dkms module version (no $mod_src/dkms.conf)"
        err "     check: ls /usr/src/ | grep nvidia"
        return 1
    fi
    if ((DRY_RUN)); then
        _c sudo dkms install nvidia/$mod_ver -k "$(uname -r)"
    else
        sudo dkms add nvidia/$mod_ver >/dev/null 2>&1 || true
        if ! sudo dkms install nvidia/$mod_ver -k "$(uname -r)"; then
            err "dkms build of nvidia/$mod_ver failed"
            err "     log: /var/lib/dkms/nvidia/$mod_ver/build/make.log"
            err "     most common cause: driver too old for kernel $(uname -r),"
            err "     or kernel headers mismatching $(uname -r)"
            err "     retry: sudo dkms install nvidia/$mod_ver -k $(uname -r)"
            return 1
        fi
    fi

    # Rebuild the initramfs for the RUNNING kernel (the nouveau blacklist and
    # the nvidia module need to be known to dracut), and let the kernel hook
    # run depmod over the freshly built .ko.
    if pkg_installed "$KERN_PKG"; then
        log "Reconfiguring $KERN_PKG (rebuilds initramfs, runs depmod)"
        _c sudo xbps-reconfigure -f "$KERN_PKG" || {
            err "kernel reconfigure failed"
            err "     fix manually: sudo xbps-reconfigure -f $KERN_PKG"
            return 1
        }
    else
        warn "kernel package $KERN_PKG not installed (unusual for $(uname -r))"
        warn "     fix manually: sudo xbps-reconfigure -f <your linux package>"
    fi

    # Verify the module actually got built -- an install that says success
    # while leaving no .ko is worse than an honest failure (rule 8).
    if [[ $DRY_RUN -eq 0 ]] && have dkms; then
        if find "/lib/modules/$(uname -r)" -name 'nvidia.ko*' 2>/dev/null | grep -q .; then
            ok "NVIDIA module built for $(uname -r)"
        else
            err "no nvidia.ko under /lib/modules/$(uname -r) after building"
            err "     check: sudo dkms status ; cat /var/lib/dkms/nvidia/$mod_ver/build/make.log 2>/dev/null"
            return 1
        fi
    fi

    # The launcher that lets a game use the dGPU while the desktop stays on
    # the iGPU. $MAGIKOS_HOME/bin is first on PATH inside the session.
    ensure_dir "$MAGIKOS_HOME/bin" "runtime bin dir" || return 1
    if [[ $DRY_RUN -eq 1 ]]; then
        _c bash -c "write $MAGIKOS_HOME/bin/magikos-prime-run (mode 755)"
    else
        _prime_run > "$MAGIKOS_HOME/bin/magikos-prime-run.tmp" \
            && mv "$MAGIKOS_HOME/bin/magikos-prime-run.tmp" "$MAGIKOS_HOME/bin/magikos-prime-run" \
            && chmod +x "$MAGIKOS_HOME/bin/magikos-prime-run" || {
            err "could not stage magikos-prime-run into $MAGIKOS_HOME/bin"
            err "     fix with: ./install.sh --no-packages"
            return 1
        }
        ok "magikos-prime-run staged: run games with 'magikos-prime-run <game>'"
    fi

    log "reboot required to load the NVIDIA module"
    return 0
}

# --- step 3: Proton-CachyOS ----------------------------------------------------

# Download URL for a given release tag + variant on the CachyOS GitHub.
proton_cachyos_url() { # <tag> <variant>
    printf 'https://github.com/CachyOS/proton-cachyos/releases/download/%s/proton-cachyos-%s-%s.tar.xz' "$1" "$1" "$2"
}

STEAM_COMPATTOOLS_DIR="${STEAM_COMPATTOOLS_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
# Pinned default so an install is reproducible; PROTON_CACHYOS_VERSION=latest
# (or any tag) overrides it.
PROTON_CACHYOS_VERSION="${PROTON_CACHYOS_VERSION:-cachyos-11.0-20261014-slr}"

install_cachyos_proton() {
    if [[ ${AUTO_PROTON:-1} != 1 ]]; then
        ok "Proton-CachyOS install disabled (AUTO_PROTON=0)"
        return 0
    fi
    if ! pkg_installed steam; then
        warn "steam is not installed -- skipping Proton-CachyOS"
        warn "     fix with: sudo xbps-install -S steam, then re-run this step"
        return 0
    fi

    local tag="$PROTON_CACHYOS_VERSION"
    if [[ $tag == latest ]]; then
        tag="$(curl -fsSL https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest 2>/dev/null |
               grep -m1 '"tag_name"' | cut -d'"' -f4)"
        if [[ -z $tag ]]; then
            err "could not resolve the latest Proton-CachyOS tag"
            err "     fix: set PROTON_CACHYOS_VERSION=<tag> and retry, or check [https://github.com/CachyOS/proton-cachyos/releases]"
            return 1
        fi
    fi

    # x86_64_v3 = AVX2-optimised build; every CPU from ~2013 on has AVX2.
    local variant="x86_64"
    grep -qw avx2 /proc/cpuinfo 2>/dev/null && variant="x86_64_v3"

    local url
    url="$(proton_cachyos_url "$tag" "$variant")"

    # Idempotent: a complete earlier install of the same release (launcher +
    # Steam manifest + version stamp carrying this tag) satisfies the step;
    # only an incomplete or different-version install is redone. The tool dir
    # name comes from the tarball itself (the dir is 'proton-<tag>-<variant>'
    # upstream, e.g. proton-cachyos-11.0-20261014-slr-x86_64_v3), so never
    # construct it ourselves -- that is how a double 'cachyos-cachyos' rule
    # made a completed install look absent.
    local d
    for d in "$STEAM_COMPATTOOLS_DIR"/proton-cachyos-*; do
        [[ -d $d ]] || continue
        if [[ -f $d/proton && -f $d/compatibilitytool.vdf && -s $d/version ]] \
           && grep -q "$tag" "$d/version" 2>/dev/null; then
            ok "Proton-CachyOS already installed: $(basename "$d")"
            return 0
        fi
    done

    log "Installing Proton-CachyOS ($tag, $variant)"
    have xz || { err "xz missing (needed to unpack the .tar.xz)"; err "     fix: sudo xbps-install -S xz"; return 1; }

    local tarball
    tarball="$(mktemp -t proton-cachyos.XXXXXX.tar.xz)" || return 1
    if [[ $DRY_RUN -eq 1 ]]; then
        rm -f "$tarball"
        _c curl -fL "$url"
        _c tar -xf '<tarball>' -C "$STEAM_COMPATTOOLS_DIR"
        return 0
    fi
    if ! curl -fL --retry 2 -o "$tarball" "$url"; then
        err "download failed: $url"
        err "     check the release exists: https://github.com/CachyOS/proton-cachyos/releases"
        rm -f "$tarball"
        return 1
    fi

    # Never extract blindly: a tag rename or truncated download must fail here
    # rather than litter the compattools dir (a broken tool entry makes Steam
    # list a Proton that cannot launch anything).
    if ! tar -tf "$tarball" | grep -q "compatibilitytool.vdf"; then
        err "tarball for $tag ($variant) has no compatibilitytool.vdf -- refusing to install"
        rm -f "$tarball"
        return 1
    fi

    # The tool directory name is whatever the tarball says, not what we
    # guessed from the tag: upstream names it 'proton-cachyos-<ver>-<variant>',
    # and the tag adds a 'cachyos-' prefix of its own. Guessing instead of
    # reading made a completed install look absent to the idempotency check.
    local topdir
    topdir="$(tar -tf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1)"
    if [[ -z $topdir || $topdir != proton-cachyos-* ]]; then
        err "tarball layout unexpected (top dir: ${topdir:-<none>}; expected proton-cachyos-*)"
        err "     check: https://github.com/CachyOS/proton-cachyos/releases/tag/$tag"
        rm -f "$tarball"
        return 1
    fi

    local tmpd
    tmpd="$(mktemp -d -t proton-cachyos.XXXXXX)" || { rm -f "$tarball"; return 1; }
    if ! tar -xJf "$tarball" -C "$tmpd" \
       || [[ ! -f $tmpd/$topdir/proton ]] \
       || [[ ! -f $tmpd/$topdir/compatibilitytool.vdf ]] \
       || [[ ! -s $tmpd/$topdir/version ]]; then
        err "extraction of $topdir failed or payload incomplete"
        err "     check: https://github.com/CachyOS/proton-cachyos/releases/tag/$tag"
        rm -rf "$tmpd" "$tarball"
        return 1
    fi

    mkdir -p "$STEAM_COMPATTOOLS_DIR"
    mv "$tmpd/$topdir" "$STEAM_COMPATTOOLS_DIR/$topdir" &&
        rm -rf "$tmpd" "$tarball" || {
        err "could not move $topdir into $STEAM_COMPATTOOLS_DIR"
        rm -rf "$tmpd" "$tarball"
        return 1
    }
    ok "Proton-CachyOS installed: $topdir"
    warn "per-game: Properties -> Compatibility -> force tool -> $topdir"
    return 0
}

# --- step 4: zram swap ---------------------------------------------------------

ZRAM_SERVICE_DIR="${ZRAM_SERVICE_DIR:-/etc/sv/zramswap}"

zram_service_run() {
cat <<'EOF'
#!/bin/sh
# zram swap for machines with little RAM (MagikVoidOS gaming step).
#
# A compressed in-RAM swap with HIGHER priority than any real swap (-p 100):
# the kernel fills this before touching an NVMe swap partition, so heavy
# games swap from RAM instead of thrashing the disk. Half of physical RAM is
# the conservative default; zstd typically compresses ~3:1.
#
# Runit service: /etc/rc.local is NOT sourced on Void boot, so this has to be
# a proper /etc/sv service. runsv restarts this script as soon as it exits,
# so every step must tolerate re-running on a device that has already been
# configured: re-writing disksize on a live device returns EBUSY, which is
# exactly how a first-run mkswap failure used to become a permanent
# crash-loop that never reached swapon. All output goes to a file because
# runsv discards it.
set -e
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec >>/var/log/zramswap.log 2>&1

echo "=== $(date) ==="

if swapon --show=NAME --noheadings 2>/dev/null | grep -qw /dev/zram0; then
    echo "zram0 already active"
    exit 0
fi

if [ ! -d /sys/block/zram0 ]; then
    modprobe zram
fi

total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
size_bytes=$(( total_kb * 1024 / 2 ))

# comp_algorithm is settable only while disksize is 0; disksize is settable
# only from 0. Tolerate "already configured" so the second restart continues
# where the first run stopped instead of dying on EBUSY.
printf '%s\n' zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
if [ "$(cat /sys/block/zram0/disksize)" -eq 0 ]; then
    echo "$size_bytes" > /sys/block/zram0/disksize
fi

mkswap /dev/zram0
swapon -p 100 /dev/zram0
echo "zram0 active: $(cat /sys/block/zram0/disksize) bytes, zstd, priority 100"
EOF
}

zram_service_finish() {
cat <<'EOF'
#!/bin/sh
# runit calls finish when the service stops: remove the zram swap so a stop
# never leaves a dangling swap device.
swapoff /dev/zram0 2>/dev/null || exit 0
exit 0
EOF
}

setup_zramswap() {
    if [[ ${AUTO_ZRAM:-1} != 1 ]]; then
        ok "zram setup disabled (AUTO_ZRAM=0)"
        return 0
    fi

    local total_kb
    total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
    if ((total_kb >= 32 * 1024 * 1024)); then
        ok "plenty of RAM (${total_kb} kB) -- zram setup skipped"
        return 0
    fi

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qw /dev/zram0; then
        ok "zram swap already active"
        return 0
    fi

    if [[ -e /var/service/zramswap ]]; then
        if ((DRY_RUN)); then
            _c bash -c "rewrite $ZRAM_SERVICE_DIR/{run,finish} and sudo sv restart zramswap"
            return 0
        fi
        ensure_sudo || return 1
        # The service exists but /dev/zram0 is not swapped on: the most likely
        # cause is an older run script that crashed mid-sequence. Rewrite the
        # files (keep the content) and restart, instead of just restarting the
        # same broken script forever.
        printf '%s' "rewriting $ZRAM_SERVICE_DIR/{run,finish} (service was not producing swap)"
        _c sudo mkdir -p "$ZRAM_SERVICE_DIR" || return 1
        if ! zram_service_run | sudo tee "$ZRAM_SERVICE_DIR/run" >/dev/null \
           || ! zram_service_finish | sudo tee "$ZRAM_SERVICE_DIR/finish" >/dev/null \
           || ! sudo chmod 755 "$ZRAM_SERVICE_DIR/run" "$ZRAM_SERVICE_DIR/finish"; then
            err "could not rewrite $ZRAM_SERVICE_DIR/{run,finish}"
            return 1
        fi
        sudo sv restart zramswap || {
            err "could not restart the zramswap service"
            err "     fix manually: sudo sv restart zramswap"
            return 1
        }
        sleep 2
        if swapon --show=NAME --noheadings 2>/dev/null | grep -qw /dev/zram0; then
            ok "zram swap active (after restart)"
            return 0
        fi
        err "zramswap restarted but /dev/zram0 is still not swapped on"
        err "     check: sudo sv status zramswap ; cat /var/log/zramswap.log"
        return 1
    fi

    log "Setting up zram swap (runit service: $ZRAM_SERVICE_DIR)"
    if ((DRY_RUN)); then
        for file in "$ZRAM_SERVICE_DIR/run" "$ZRAM_SERVICE_DIR/finish"; do
            _c bash -c "write $file (mode 755)"
        done
        _c bash -c "ln -sf $ZRAM_SERVICE_DIR /var/service/zramswap"
        return 0
    fi
    ensure_sudo || return 1

    _c sudo mkdir -p "$ZRAM_SERVICE_DIR" || return 1
    if ! zram_service_run | sudo tee "$ZRAM_SERVICE_DIR/run" >/dev/null; then
        err "could not write $ZRAM_SERVICE_DIR/run"
        return 1
    fi
    if ! zram_service_finish | sudo tee "$ZRAM_SERVICE_DIR/finish" >/dev/null; then
        err "could not write $ZRAM_SERVICE_DIR/finish"
        return 1
    fi
    _c sudo chmod 755 "$ZRAM_SERVICE_DIR/run" "$ZRAM_SERVICE_DIR/finish" || return 1

    # Enabling a runit service = symlinking it into /var/service, which also
    # starts it immediately (runit semantics).
    if [[ -e /var/service/zramswap ]]; then
        _c sudo sv restart zramswap || {
            err "zramswap service exists but would not restart"
            err "     fix manually: sudo sv restart zramswap"
            return 1
        }
    else
        _c sudo ln -sf "$ZRAM_SERVICE_DIR" /var/service/zramswap || {
            err "could not enable the zramswap service"
            err "     fix manually: sudo ln -sf $ZRAM_SERVICE_DIR /var/service/zramswap"
            return 1
        }
    fi

    # Verify against reality, not the exit code (rule 8).
    sleep 2
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qw /dev/zram0; then
        ok "zram swap active"
    else
        err "zramswap service enabled but /dev/zram0 is not swapped on"
        err "     check the service log: sudo sv status zramswap ; cat /var/log/zramswap.log"
        err "     then: sudo sv restart zramswap && swapon --show"
        return 1
    fi
    return 0
}

# --- orchestrator --------------------------------------------------------------

# Called from install.sh as its own step. Detection-gated end to end:
#   * steam/gamemode   -> every full install
#   * Proton-CachyOS   -> wherever steam exists
#   * NVIDIA driver    -> only where an NVIDIA GPU is present
#   * zram             -> only where RAM says it matters
install_gaming_stack() {
    local rc=0
    install_gaming_packages || rc=1
    if install_cachyos_proton; then
        :
    else
        warn "Proton-CachyOS install failed; Steam falls back to its own Proton"
        rc=1
    fi
    if ! install_nvidia_driver; then
        warn "NVIDIA driver setup failed; games will fall back to the iGPU/nouveau"
        rc=1
    fi
    if ! setup_zramswap; then
        warn "zram setup failed; heavy games will keep swapping to NVMe"
        rc=1
    fi
    return $rc
}
