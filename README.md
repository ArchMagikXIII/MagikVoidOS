# MagikOS for Void Linux (unofficial port)

This is the bootstrap installer repo for running MagikOS on Void Linux.

## Quick start
1. Clone this repo
2. Run `./install.sh` as non-root (it will prompt for sudo)
3. After reboot/log-out, select "Sway" at login
4. Brave Origin: installed via bundled tarball extraction to /opt/brave-origin

Notes:
- MagikOS runtime is cloned to `~/.local/share/magikos` from upstream Git (https://github.com/ArchMagikXIII/MagikOS) and patched with the Void port.
- The Sway session remains optional; your existing XFCE session is untouched.
- xbps is used exclusively (no AUR/pacman).

