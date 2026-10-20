# Porting notes

What changed relative to upstream, and why. Machine-readable form is
`share/void-port.patch` (25 files, 705 diff lines).

## Runtime prefix

Upstream assumes the system package `/usr/share/magikos`. Void has no such
package and installing to it needs root, which breaks the "just extract and
run" property of MagikOS.

The port stages to `~/.local/share/magikos` instead. Three places care:

1. `config/sway/environment.conf` sets `$MAGIKOS_PATH` and `$PATH`.
2. `bindings.conf` and `autostart.conf` had 17 `${MAGIKOS_PATH:-/usr/share/magikos}`
   fallbacks, rewritten to `${MAGIKOS_PATH:-$HOME/.local/share/magikos}`.
3. `~/.profile` exports `MAGIKOS_PATH` and prepends its `bin` to `PATH`, so the
   `magikos-*` helpers resolve in a plain XFCE terminal, not only inside Sway.

`environment.conf` also had a `set $PATH /usr/share/magikos/bin:...` entry that
shadowed the real bin dir for every `exec` that resolves helpers by name. Fixed
in the same pass.

### Patching both copies

`magikos-refresh-sway` copies `$MAGIKOS_HOME/config/sway` over
`~/.config/sway`. Overriding only the user copy means the next refresh reverts
the port. `apply_sway_overrides` is therefore called on **both** directories.

## Sway

| File | Change |
| --- | --- |
| `environment.conf` | `MAGIKOS_PATH` + `PATH` to the user prefix |
| `bindings.conf` | 17 path fallbacks rewritten |
| `autostart.conf` | 17 path fallbacks rewritten; autotiling exec commented |
| `appearance.conf` | wallpaper -> `~/Pictures/Wallpapers/Osaka.jpg` |

`autostart.conf:6` execs `~/.venvs/autotiling/bin/autotiling`. That daemon is
referenced nowhere else in the repo and ships nowhere, so the exec is commented
with a `void-port:` marker. Default Sway tiling applies instead.

Main entry point is `config` (no `.conf`). Copying only `*.conf` produces a
config dir that fails validation with `config not found`.

## magikos-pkg-backend

Rewritten as a dual xbps/pacman backend keeping the same function interface,
so all 16 consumers work unchanged:

```
backend_is_xbps / backend_is_pacman
pkg_installed
pkg_list_available / pkg_list_installed / pkg_list_explicit / pkg_list_orphans
pkg_owns_file / pkg_file_owner
pkg_info_new / pkg_info_upgradable
```

xbps commands:

| operation | command |
| --- | --- |
| is installed | `xbps-query <pkg>` |
| installed list | `xbps-query -l` |
| explicit list | `xbps-query -x` |
| orphans | `xbps-remove -o` |
| owns file | `xbps-query -Rs` on the file path |
| file owner | `xbps-query -S -f <path>` |
| install | `xbps-install -yS` |
| remove | `xbps-remove -Ry` |
| upgrade | `xbps-install -Suy` |
| sync index | `xbps-install -S` |

### Parsing gotchas

xbps output is not package-list(1)-compatible and needed real work:

- Snapshots: `sway-1.11_1` -> `sway`
- Installed markers: `ii  `, `[-] `, and no prefix for explicit
- Remote lines carry `[-] name-version rev   description`, so the version must
  be stripped without eating the name

First implementation stripped with a `[0-9]`-anchored pattern, which mangled
snapshot names like `xkblayout-state-1b_1`. Caught by testing every primitive
against the live system rather than assuming.

## Ported scripts (23)

Query/lifecycle: `magikos-pkg-install`, `-pkg-remove`, `-update-system-pkgs`,
`-update-orphan-pkgs`, `-update-pkg-prune`, `-update-available`, `-update-restart`,
`-reinstall-pkgs`, `-version`, `-version-pkgs`, `-version-channel`, `-debug`,
`-upload-log`, `-migrate`, `-channel-current`, `-channel-set`,
`-remove-launcher-entry`, `-setup-security-fingerprint`, `-refresh-pacman`
(keeps its name; Void branch upgrades xbps), `-update-keyring`,
`-pkg-aur-add`, `-update-aur-pkgs`.

## Quickshell

| File | Change |
| --- | --- |
| `shell/services/AppLibrary.qml` | UWSM is not packaged on Void; probe for `uwsm-app`, else `gtk-launch` |
| `shell/plugins/panels/dropbox/Service.qml` | Nautilus -> Thunar |

Both were unconditional assumptions about packages absent on Void.

## Themes

All 22 upstream themes staged. Upstream count is 22, not 28; an earlier note
of 28 was a miscount.

## Not ported

See the "Deliberately not ported" section of `AGENTS.md`. Summary: AUR,
`magikos-reinstall-pkgs`, `magikos-migrate`, adaptive tiling, and the local
`pacman -U` branch in `magikos-dev-pkg-test`.

## kitty recompiles its entire Python tree on every launch

2026-10-20. The report: "apps take 1-3 s to open from keybinds or the menu".
Anchored measurements against the live compositor showed a fixed ~0.92 s
exec -> window-visible for kitty, on top of any app's own real work.

Ruled out in order: launch wrapper (`bash -lc` 40 ms), dynamic loader
(`LD_DEBUG=statistics`: microseconds), Mesa shader cache, fontconfig (11 ms
fc-match), EGL/GL bootstrap (55-80 ms with a C probe), CPU frequency ramp,
page-cache/swap IO. The delay was pure single-threaded *userspace CPU inside
the client* before its first Wayland operation -- invisible to an
open/dlopen interposer because there was no I/O in the window at all.

An unprivileged ptrace RIP sampler (`PTRACE_ATTACH` cycles when `/proc` state
is R; needs no `gdb`/`strace`/root) resolved the spins to `libpython3.14`, and
`PYTHONPROFILEIMPORTTIME=1` named the bill:

```
import time:   8062 |    814047 | kitty.main        cumulative us
```

kitty launches its embedded Python with `Py_OptimizeFlag=2`, but Void's kitty
package ships only `*.pyc` and `*.opt-1.pyc` (zero `*.opt-2.pyc`), and
`/usr/lib/kitty` is root-owned, so the `.opt-2.pyc` CPython wants to have
cannot be created by a user session. Every launch recompiled ~180 modules
from source. Reproduced against plain CPython: `python3 -OO -c 'import
kitty.main'` = 0.837 s vs 0.124 s at level 0. Upstream-repo reference: on a
distro whose packaging compiles `-OO` bytecode kitty sits at ~0.15 s.

Fix (user-land, no root, in `lib/shims.sh`):

- a `kitty` shim in `$MAGIKOS_HOME/bin` that exports
  `PYTHONPYCACHEPREFIX=$HOME/.cache/magikos/kitty-pyc2` unless the system
  already has `*.opt-2.pyc` (then it execs the real binary untouched);
- `ensure_kitty_pycache` prebuilds the opt-2 cache into that prefix at
  install time (`python3 -OO -m compileall`), so even the first launch is fast;
- after a kitty package update the cache self-heals: CPython re-derives the
  cached path from the source mtime and rewrites it in the user prefix.

Verified post-fix: Super+Return ink -> window: 0.92 s -> 0.14 s (3 runs:
0.154 / 0.135 / 0.142). Brave and other non-Python clients never had this
bug; their launch cost is their own. The equivalent permanent packaging fix
is `sudo python3 -OO -m compileall /usr/lib/kitty`, which the status hint
also offers; then the shim is inert by design.
