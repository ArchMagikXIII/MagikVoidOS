# AGENTS.md

Working notes for this repo. Read this before changing anything.

## What this repo is

An unofficial port of [MagikOS](https://github.com/ArchMagikXIII/MagikOS)
from Arch/CachyOS to Void Linux. MagikOS ships a Sway + Quickshell desktop
with a large shell-script layer (`magikos-*`) that assumes pacman and a
`/usr/share/magikos` install prefix. This repo installs the upstream runtime
on Void with xbps and an unprivileged prefix.

## Layout

```
install.sh                  entry point (idempotent, sudo-aware, --dry-run)
lib/common.sh               logging, Void detection, sudo handling
lib/packages.sh             curated Void package set (replaces magikos-base.packages)
lib/stage-magikos.sh        clone upstream, apply port patch, patch sway, set env
lib/brave-origin.sh         build Brave Origin as a native Void package
scripts/build-brave-origin  CLI wrapper for the above
share/void-port.patch       the 25-file Void port, as a git patch
docs/PORTING-NOTES.md       what was changed upstream and why
```

The MagikOS runtime itself is **not** vendored here. It is cloned at install
time to `$MAGIKOS_HOME` (default `~/.local/share/magikos`) so upstream updates
flow through normally.

## Target environment

Void Linux, x86_64. Verified on Void with sway + quickshell 0.3.1.

## Rules for changing this repo

1. **Never require root for the MagikOS runtime.** It stages to
   `$MAGIKOS_HOME` under `$HOME`. Root is only for xbps and `/opt`.
2. **Patch the staged source, not just the user copy.**
   `magikos-refresh-sway` copies `$MAGIKOS_HOME/config/sway` over
   `~/.config/sway`. If only `~/.config/sway` is patched, the next refresh
   silently reverts the port. `apply_sway_overrides` always runs on both.
3. **`is_void()` must not check `/etc/xbps`.** Void has `/etc/xbps.d` and
   `/var/db/xbps`. The `/etc/xbps` check looks plausible and is always false.
4. **Guard every Void package-name assumption.** A stale xbps index makes
   `xbps-query -Rs` return wrong or empty results (it did not list `sway`
   itself). Sync the index before trusting a package query.
5. **Test without root.** `--destdir` for the Brave builder and `--dry-run`
   for the installer exist so changes can be validated unprivileged.

## Verification commands

```sh
bash -n install.sh lib/*.sh scripts/build-brave-origin   # syntax
./install.sh --dry-run --no-packages                     # preflight + staging plan
./scripts/build-brave-origin --destdir /tmp/bs           # brave packaging, no root
WLR_BACKENDS=headless WLR_RENDERER=pixman \
    sway --validate -c ~/.config/sway/config             # sway config
```

Full session smoke test:

```sh
sway --validate -c ~/.config/sway/config     # must exit 0
# log out, choose Sway, then:
magikos-version
magikos-toggle-bar
grep ERROR ~/.local/state/magikos/quickshell.log
```

A clean shell log has **no ERROR lines**. One `pipewire` ERROR is expected on
a host with no audio.

## Gotchas discovered the hard way

- **`sway --validate` needs `WLR_BACKENDS=headless`** on this machine. Plain
  invocation fails with `Unable to create backend` because the VM's
  `/dev/dri/card0` cannot be opened. That is an environment limit, not a
  config error. Do not chase it.
- **The sway entry point is `config`, not `config.conf`.** Copying only
  `*.conf` yields an unusable config dir that fails validation with
  "config not found".
- **`xbps-create` has no `-o` flag.** The output path is derived from `-n` and
  written to the current directory, so run it from the workdir.
- **`xbps-create -D` is dependencies, not version.**
- **`xbps-create -q`** suppresses a per-file `adding ...` line for every
  locale; use it or the output is unusable.
- **`.deb` files are `ar` archives.** Void ships neither `ar` nor `dpkg-deb`,
  and `zstd` may be absent. `lib/brave-origin.sh` parses the ar format in
  Python and extracts `data.tar.xz` with GNU tar.
- **The extracted tar members cannot be listed with `tar -tf`** because the
  `.xbps` is zstd-compressed and `zstd` is missing. Use Python's `tarfile`.
- **The xbps package index is stale** and `pkg_list_available` under-reports.

## Brave Origin

MagikOS binds `brave-origin` and expects a package named `brave-origin-bin`.
That name comes from AUR/CachyOS.

Void ships **no Brave at all** (`void-linux/void-packages` has no
`brave`/`brave-bin` template; Brave's licence is not accepted by Void). Brave
does publish official x86_64 `.deb` and `.rpm` builds on GitHub releases,
including a first-party `brave-origin` build.

So we repackage that prebuilt binary instead of compiling:

- payload relocated `/opt/brave.com/brave-origin` -> `/opt/brave-origin`
- `/usr/bin/brave-origin` (the name MagikOS resolves) plus `-stable`
- icon installed to `hicolor/256x256/apps/brave-origin.png` (the deb ships
  none, though the desktop entry references one)
- real `.xbps` via `xbps-create`, with Void-named deps

Compiling Chromium from source is not viable here (6 cores / 7.8 GiB / 33 GiB;
a Chromium build wants far more). Repackaging needs only curl + python3.

The sandbox works via unprivileged user namespaces on this host
(`max_user_namespaces = 31630`), so `chrome-sandbox` does not need setuid.

## Deliberately not ported

These are left as upstream no-ops or documented gaps, on purpose:

- **AUR** (`magikos-pkg-aur-add`, `-update-aur-pkgs`). No Void equivalent.
  They print an explanation instead of failing silently.
- **`magikos-reinstall-pkgs`**. Upstream `magikos-base.packages` is 206
  CachyOS packages (`cachyos-*`, `brave-origin-bin`) that cannot resolve on
  Void. `lib/packages.sh` is the curated replacement.
- **`magikos-migrate`.** 64 migrations, 10 of which write to `/etc` with
  sudo. Not installed or auto-enabled; audit before running.
- **Adaptive tiling.** Upstream `autostart.conf:6` execs
  `~/.venvs/autotiling/bin/autotiling`, which ships nowhere. Commented out;
  default Sway tiling is used.
- **`magikos-dev-pkg-test`.** Still has a local `pacman -U` branch.

## Known pre-existing upstream bugs

Five scripts fail `bash -n` in unmodified upstream. Not our regressions, not
fixed here:

```
bin/magikos-agent-usage-claude
bin/magikos-agent-usage-codex
bin/magikos-agent-usage-fireworks
bin/magikos-dev-font
bin/magikos-file-select
```

## Plan

### Done

- [x] Stage upstream at an unprivileged prefix; verify no `/usr/share/magikos`
- [x] Dual xbps/pacman `magikos-pkg-backend`; verified all primitives
      (682 installed, 45 explicit, 12 orphan, 14,791 available)
- [x] Port 23 pacman-dependent scripts
- [x] Patch Quickshell `AppLibrary.qml` (UWSM) and Dropbox `Service.qml` (Nautilus)
- [x] Patch Sway `MAGIKOS_PATH` + wallpaper + autotiling
- [x] Convert the staged tree to a real git clone so
      `magikos-update-available` works; port preserved as uncommitted changes
- [x] Verify: sway validates (exit 0), Quickshell loads with 0 QML errors,
      `magikos-toggle-bar` exits 0
- [x] Build Brave Origin as a Void package from Brave's official prebuilt deb
- [x] This installer repo + `--dry-run` / `--destdir` unprivileged test paths

### Next

- [ ] Install the Void base package set (needs sudo; index sync first)
- [ ] Install Brave Origin to `/opt` and confirm it launches under Sway
- [ ] Port `magikos-dev-pkg-test` to `xbps-install`
- [ ] Give `magikos-update-available` real xbps update detection (currently
      git-only; xbps updates are invisible to it)
- [ ] Audit the 64 migrations, or gate them behind an explicit opt-in
- [ ] Fix the five upstream `bash -n` failures (propose upstream)
- [ ] Decide on UWSM: install it for real app scoping, or drop the systemd unit
- [ ] Ship an ISO image, mirroring upstream `iso/`

### Open questions

- Should the Void package set live in this repo or a separate
  `void-packages` fork? A proper `xbps-src` template would give upgrade
  tracking for free, at the cost of depending on `xbps-src`.
- Should `brave-origin` also register with xbps metadata, or stay a plain
  `/opt` install? Currently both: files go to `/opt`, metadata is a real
  `.xbps`, but registration is best-effort.
- 22 themes ship upstream (not 28 as initially assumed); confirm all are
  wanted or pick a curated default set.

## Session log

- Ported the runtime, verified headless.
- Converted the staged copy to a git clone at commit `50c6c926`; port kept as
  25 uncommitted modified files so upstream pulls stay clean.
- Discovered Brave publishes an official `brave-origin` deb; repackaged it.
- Wrote this repo. Fixed four real bugs found by testing the builder:
  missing parent dirs, `xbps-create -o` (does not exist), `-D` misused as a
  version flag, and `is_void()` checking a nonexistent `/etc/xbps`.
