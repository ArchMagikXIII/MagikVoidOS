# MagikOS for Void Linux (unofficial port)

Bootstrap installer for running MagikOS on Void Linux. Installs the upstream
runtime with xbps at an unprivileged prefix, and builds Brave Origin as a
native Void package.

## Quick start

```sh
./install.sh --dry-run    # see everything it would do, changes nothing
./install.sh              # do it (prompts for sudo)
```

Then log out and choose **Sway** at the login screen.

Your current XFCE session is not modified. Sway is an additional session.

## Checking whether it worked

```sh
./install.sh --status
```

This runs 18 checks and prints PASS / FAIL / WARN / SKIP. Every FAIL line
includes the exact command that fixes it. It changes nothing, so it is safe to
run any time. It also runs automatically at the end of an install.

## Options

| Flag | Effect |
| --- | --- |
| *(none)* | full install |
| `--status` | run all checks, change nothing |
| `--dry-run` | show every action, change nothing |
| `--skip-brave` | do not build Brave Origin |
| `--no-packages` | do not install Void base packages |

Re-running is safe. Every step is idempotent and skips work already done, and
all required directories are created if missing.

## What gets installed

- **MagikOS runtime** -> `~/.local/share/magikos` (a real git clone, so
  `magikos-update-available` works)
- **Sway config** -> `~/.config/sway` (8 files)
- **MAGIKOS_PATH + PATH** -> appended to `~/.profile`
- **Void base packages** via xbps (see `lib/packages.sh`)
- **Brave Origin** -> `/opt/brave-origin` plus `/usr/bin/brave-origin`

Nothing requires root except the xbps install and `/opt`.

## GPU-less machines (VMs)

If your machine has no usable 3D GPU, Sway will come up black: Mesa picks the
ZINK driver, Vulkan initialisation fails, and Quickshell gets no GL context so
the bar never draws.

The installer detects this and pins software rendering automatically:

```sh
set $WLR_RENDERER pixman
set $LIBGL_ALWAYS_SOFTWARE 1
```

Check whether it applied with `./install.sh --status`. Override detection with
`AUTO_SOFTWARE_RENDER=0 ./install.sh`.

## Brave Origin

Void ships no Brave at all, and upstream expects the AUR/CachyOS package name
`brave-origin-bin`. Brave publishes an official prebuilt `brave-origin` build,
so this repackages it into a Void layout and a real `.xbps` -- no compilation.

```sh
./scripts/build-brave-origin --dry-run        # plan
./scripts/build-brave-origin --destdir /tmp/x # build, no root
sudo ./scripts/build-brave-origin             # build + install
```

## Layout

```
install.sh                  entry point
lib/common.sh               logging, Void detection, ensure_dir/ensure_paths
lib/packages.sh             curated Void package set
lib/stage-magikos.sh        clone, patch, sway overrides
lib/status.sh               the 18 checks behind --status
lib/brave-origin.sh         Brave repackaging
share/void-port.patch       the 25-file Void port
docs/PORTING-NOTES.md       what changed upstream and why
AGENTS.md                   working notes, gotchas, plan
```

See `AGENTS.md` before changing anything.

## Licensing

MIT for this repo. MagikOS is fetched at install time and keeps its own
license. Brave is downloaded, not vendored. See
`docs/UPSTREAM-LICENSE-NOTICE.md`.
