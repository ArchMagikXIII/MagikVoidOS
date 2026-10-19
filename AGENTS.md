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
install.sh                  entry point (idempotent, sudo-aware, --dry-run/--status)
lib/common.sh               logging, Void detection, sudo, ensure_dir/ensure_paths
lib/packages.sh             curated Void package set (replaces magikos-base.packages)
lib/fonts.sh                Nerd Font install + fontconfig alias for bar glyphs
lib/stage-magikos.sh        clone upstream, apply port patch, patch sway, set env
lib/status.sh               the checks behind `install.sh --status`
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

## Git access (SSH)

`origin` is `git@github.com:ArchMagikXIII/MagikVoidOS.git`, i.e. push/fetch
over SSH. Agents working this repo may use the maintainer's dedicated deploy
key instead of prompting for credentials:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJeCv0YGt+ocbvDaj95+bogFbadBJOf5kA+PXS3B948Q magikxiii@void-magikos-void
```

The private half is **never** in this repo. It lives only on the maintainer's
machine at `~/.ssh/id_ed25519_github`, mode `0600`, with a matching
`~/.ssh/config` entry:

```sshconfig
Host github.com
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
    AddKeysToAgent yes
```

If that file is missing, do **not** try to synthesize a replacement key or ask
for a passphrase in chat. Clone over HTTPS instead
(`https://github.com/ArchMagikXIII/MagikVoidOS.git`) and push only when the
maintainer supplies a token out of band. Rotate the deploy key by editing
`Settings > Deploy keys` on the repo, not by committing a new one here.

## Rules for changing this repo

1. **Never require root for the MagikOS runtime.** It stages to
   `$MAGIKOS_HOME` under `$HOME`. Root is only for xbps and `/opt`.
2. **Patch the staged source, not just the user copy.**
   `magikos-refresh-sway` copies `$MAGIKOS_HOME/config/sway` over
   `~/.config/sway`. If only `~/.config/sway` is patched, the next refresh
   silently reverts the port. `apply_sway_overrides` always runs on both.
3. **`is_void()` must not check `/etc/xbps`.** Void has `/etc/xbps.d` and
   `/var/db/xbps`. The `/etc/xbps` check looks plausible and is always false.
4. **Guard every Void package-name assumption, and never guess a name.** Use
   `xbps-query -R -S <pkg>` for existence: `-R -S` is an exact pkgname lookup.
   Do **not** use `-Rs`, which searches name *and description*, so `qt6` matches
   `AppStream-qt` and a bogus name can still return rows. Name mapping that
   matters: `cups-libs`->`libcups`, `gtk3`->`gtk+`,
   `font-liberation-ttf`->`liberation-fonts-ttf`, `dejavu-ttf`->`dejavu-fonts-ttf`,
   `waybar`->`Waybar`, `qt6-qtdeclarative`->`qt6-declarative`,
   `qt6-qtwayland`->`qt6-wayland`, `qt6-qtmultimedia`->`qt6-multimedia`.
   Void ships **no per-QML-module packages** (`qml6-module-*` does not exist);
   QML imports live inside `qt5-declarative` / `qt6-declarative`.
   `verify_package_names()` in `lib/packages.sh` enforces this before any
   install.
5. **`xbps-install -y a b c` is one transaction.** One unresolvable name
   aborts the whole thing, so a single typo silently installs *nothing* while
   the installer still reports success. This is exactly how `quickshell` went
   missing on a fresh machine. Always `verify_package_names` first.
6. **Test without root.** `--destdir` for the Brave builder and `--dry-run`
   for the installer exist so changes can be validated unprivileged.
7. **`--dry-run` must not touch the filesystem.** Every mutation goes through
   `_c` or an explicit `((DRY_RUN))` branch. A `mkdir` that is not guarded is
   a bug: it creates directories for real while claiming nothing changed.
8. **Never claim success the installer did not achieve.** Step failures set a
   nonzero `rc`, and `status_report` runs at the end of every install so the
   user gets a PASS/FAIL verdict rather than a cheerful "Done". A check that
   cannot run should `echo "skip <reason>"`, not silently pass.
10. **Every failing check must name its fix.** Set `CHECK_HINT` with the exact
   command. A FAIL that does not say what to do is worse than no check.
   `check()` must therefore run the check function **in the current shell**;
   `out="$("$@" 2>&1)"` runs it in a subshell and silently discards
   `CHECK_HINT`, so every FAIL renders with an empty fix. Capture stdout to a
   temp file instead.

## Verification commands

```sh
bash -n install.sh lib/*.sh scripts/build-brave-origin   # syntax
./install.sh --status                                    # the 18 checks
./install.sh --dry-run --no-packages                     # preflight + staging plan
./scripts/build-brave-origin --destdir /tmp/bs           # brave packaging, no root
WLR_BACKENDS=headless WLR_RENDERER=pixman \
    sway --validate -c ~/.config/sway/config             # sway config
```

After any change to the Sway overrides, re-run `./install.sh --no-packages`
so both the user copy and the staged source stay in sync (see rule 2).

`--status` groups checks as System / MagikOS runtime / Sway session /
Quickshell+env / Brave Origin. Brave checks only appear once brave-origin
exists, so an optional component never reads as a failure.

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

- **`ls dir/*.ttf dir/*.otf` exits non-zero when either glob matches
  nothing.** The Nerd Font zip ships TTF only, so 96 files extracted correctly
  and the step then reported "no font files extracted" and failed. Count with
  `find ... \( -name '*.ttf' -o -name '*.otf' \) | wc -l`.
- **An ignored `_c` return value reports success that did not happen.** The
  Brave install did `_c sudo cp ...` and `_c sudo xbps-install ...`, checked
  neither, then printed "installed". Check the status, and verify the artefact
  on disk (`[[ -x $BRAVE_PREFIX/brave ]]`) rather than trusting the exit code.
- **`grep -c` prints 0 and exits 1 when there are no matches**, so
  `n="$(grep -c x f || echo 0)"` yields the two-line string `0\n0` and blows
  up arithmetic expansion. Use `n="$(grep -c x f)" || n=0`.
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
- **Void ships no `zstd`**, so never force a compressor on `tar`. Let GNU tar
  auto-detect with a plain `tar -xf`. Forcing `--zst` dies, forcing `--xz` dies
  if the format ever changes.
- **`sway --validate` exits 0 even when the config failed to load.** It prints
  `[ERROR] ... Error(s) loading config!` and returns success. An exit-code-only
  check reports a broken config as healthy -- this is why a config that
  discarded every keybind went unreported. `chk_sway_validate` greps the output
  for `Error(s) loading config!` as well as checking the exit status.
- **Do not force `WLR_BACKENDS=headless` when validating.** `--validate` only
  parses config, so plain `sway --validate` works even without a usable DRM
  device; forcing a backend that this wlroots lacks fails with
  `Unable to create backend` and no `Error on line`, i.e. no diagnosis. Plain
  first, headless only as a fallback.
- **`xbps-create -D` accepts any dependency string.** A Debian name ships
  silently and only fails at `xbps-install` time. `brave_void_depends` is run
  through `verify_package_names` before packaging.
- **The xbps package index is stale** and `pkg_list_available` under-reports.

## GPU-less machines

This host has a QXL paravirtual adapter: no usable 3D, so Mesa selects the
ZINK driver, Vulkan init fails with `VK_ERROR_INITIALIZATION_FAILED`, and
Quickshell ends up with no GL context. The symptom is Sway coming up with no
bar and a black screen, which is very hard to diagnose from the inside.

`detect_no_gpu` (in `lib/status.sh`) detects this two ways: a paravirtual
adapter reported by `lspci` (QXL/bochs/vmware/Cirrus), or a ZINK failure
already present in the Quickshell log. On a match, `apply_sway_overrides`
appends to `environment.conf`:

```
set $WLR_RENDERER pixman
set $LIBGL_ALWAYS_SOFTWARE 1
```

Keep this conservative. A false positive forces software rendering and costs
performance, so require positive evidence rather than inferring from missing
tools (`glxinfo`/`vulkaninfo` are often just not installed). Disable with
`AUTO_SOFTWARE_RENDER=0`.

Verified: with these set, the ZINK errors disappear and the log contains only
the expected no-audio pipewire error.

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

`xbps-create -D` accepts *any* dependency string without complaint, so Debian
names survive into the package and only explode later at `xbps-install` time,
long after the build was reported successful. `brave_void_depends` therefore
runs through `verify_package_names` before packaging. The Debian->Void
mappings it needed: `cups-libs`->`libcups`, `gtk3`->`gtk+`,
`font-liberation-ttf`->`liberation-fonts-ttf`.

Compiling Chromium from source is not viable here (6 cores / 7.8 GiB / 33 GiB;
a Chromium build wants far more). Repackaging needs only curl + python3.

The sandbox works via unprivileged user namespaces on this host
(`max_user_namespaces = 31630`), so `chrome-sandbox` does not need setuid.

## Shell fonts

The bar draws Nerd Font codepoints using the *default* Qt family:
`Style.qml:227` sets `fontFamily: "monospace"`. Upstream Arch/CachyOS ships
Nerd Fonts so `monospace` happens to resolve to one; on Void it resolves to
DejaVu Sans Mono, which has no private-use glyphs, and every icon becomes a
tofu box.

So installing a Nerd Font is necessary but **not sufficient** -- `lib/fonts.sh`
also writes `~/.config/fontconfig/conf.d/99-magikos-nerd.conf` so `monospace`
wins the match. `chk_shell_font` verifies the resolved family.

Void's `nerd-fonts-ttf` is an every-family aggregator: **1517 MB** to download,
**7447 MB** installed, for the one family used. That is also why an earlier
installer "failed to download the fonts". `lib/fonts.sh` instead fetches
`JetBrainsMono.zip` (~128 MB) from nerd-fonts releases, cached under
`$TMPDIR`, unpacked with `python3 -m zipfile` (Void has no `unzip`
dependency; `python3` is already a bootstrap tool).

## Keybinds

Keybinds live in `~/.config/sway/bindings.conf`, which `config` includes --
the `config` file itself has zero `bindsym` lines. When `sway --validate`
fails, sway discards the whole config *including every include*, so the user
loses keybinds, output config and autostart simultaneously. That single
failure presents as "my desktop came up but nothing is bound".

`chk_sway_validate` therefore reports the offending file and line parsed from
sway's `Error on line N ...(file)` output, and `chk_sway_keybinds` counts
`bindsym` lines so a silently-empty bindings file is caught.

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

## Git remotes and credentials

Two repos, deliberately on different transports:

| repo | remote | why |
| --- | --- | --- |
| this port (`~/magikos-void`) | `git@github.com:ArchMagikXIII/MagikVoidOS.git` (SSH) | we push to it |
| MagikOS runtime (`$MAGIKOS_HOME`) | `https://github.com/ArchMagikXIII/MagikOS` (HTTPS) | we only fetch; keeps GitHub auth from ever blocking `magikos-update` |

### SSH key

Auth to GitHub uses an ed25519 key, **not** a token.

```
private key  ~/.ssh/id_ed25519_github    (mode 600)
public key   ~/.ssh/id_ed25519_github.pub (mode 644)
config      ~/.ssh/config -> Host github.com pins this key, IdentitiesOnly yes
fingerprint SHA256:JYzA0/K1F3+oDNAiIjQU2wUhzsi+9VX7Eod54csg3mg
comment     magikxiii@void-magikos-void
```

The public key starts `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJeCv0...` and is
registered on the `ArchMagikXIII` account. Verified with
`ssh -T git@github.com` -> `Hi ArchMagikXIII!`.

Rules:

1. **Never commit the private key.** Only `.pub` ever goes into a repo, and
   only if someone wants to publish it. `.gitignore` blocks `*.xbps`/`*.deb`;
   scan with `git grep -InE 'PRIVATE KEY|ssh-ed25519 AAAA'` before pushing.
2. **`IdentitiesOnly yes` in `~/.ssh/config`** means new keys will not silently
   displace this one. If auth breaks, check that file before regenerating.
3. **Verify auth before pushing**, not after a failed push:
   `ssh -T git@github.com`.
4. `known_hosts` already has `github.com` (ED25519), so there is no first-run
   prompt.

### Commit identity

`git config user.email` is `magikxiii@localhost`. **GitHub ignores that
address**, so commits do not link to the account or show on the profile. Set a
real address before expecting attribution:

```sh
git -C ~/magikos-void config user.email "you@example.com"
# retroactively fix existing commits:
git -C ~/magikos-void rebase --root --exec \
  'git commit --amend --no-edit --reset-author'
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
- [x] `ensure_dir`/`ensure_paths`: create every needed directory, create nothing
      in `--dry-run`, report unwritable paths with a `chown` fix
- [x] `install.sh --status`: 18 PASS/FAIL/WARN/SKIP checks, each FAIL naming
      its fix; runs automatically after every install
- [x] Auto-pin software rendering on GPU-less machines (fixes the black screen)
- [x] GitHub SSH auth (ed25519 key, pinned in `~/.ssh/config`) and
      `origin` -> `git@github.com:ArchMagikXIII/MagikVoidOS.git`

### Next

- [ ] Ship the icon fonts so Quickshell glyphs render: the shell resolves its
      icon font through `Style.qml` (`barToken("icon-font")`, `iconFont`), and
      the only `font.family` literal in the whole tree is `Liberation Sans`.
      Nothing nerd/icon font is installed yet, so ~24 `iconFont` sites and the
      Nerd Font codepoints in `magikos-menu.jsonc` will fall back to boxes.
      Needs: a Nerd Font (JetBrainsMono Nerd Font / Iosevka Nerd Font) plus
      `xdg-terminal-exec`, which `magikos-default-terminal` shells out to.
      `foot` itself is already installed at `/usr/bin/foot`.
- [ ] Install the Void base package set (needs sudo; index sync first)
- [ ] Log into Sway on real hardware and confirm the bar renders (only
      headless/software rendering has been exercised so far)
- [ ] Consider `--repair` to re-run only the failing checks' fixes
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
- User asked for two things: create missing paths, and make success legible.
  Both exposed real bugs:
    * an unguarded `mkdir` made `--dry-run` write to disk
    * `--dry-run` exited 0, i.e. it reported success having done nothing
    * `stage_env` used a quoted heredoc, so `$HOME` would have been written
      literally instead of expanded
    * `WALLPAPER` was defined in `stage-magikos.sh` but used by
      `ensure_paths` in `common.sh`, which loads first (load-order trap)
- Built `lib/status.sh`. Its first run immediately caught a live problem:
  a ZINK/Vulkan failure from this host's GPU-less QXL adapter, which is why
  Sway was coming up black. Now auto-fixed via pinned software rendering.
- Found a `grep -c` exit-status trap that produced `0\n0` and crashed
  arithmetic expansion inside a check.
