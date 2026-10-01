# Upstream licensing

This repo contains no MagikOS source. At install time it clones:

    https://github.com/ArchMagikXIII/MagikOS

which carries its own `LICENSE` file, and applies `share/void-port.patch` to it.
The upstream license and terms therefore govern the installed MagikOS runtime.
Do not relicense anything derived from it.

## brave-origin

`lib/brave-origin.sh` downloads and repackages Brave's official prebuilt
`brave-origin` build from:

    https://github.com/brave/brave-browser/releases

Brave is downloaded, never vendored, so no Brave code is stored in this repo.
Brave ships its own license inside its package payload (installed as
`/usr/share/doc/brave-origin/LICENSE`).

Note that Brave's own license is not the same as this repo's MIT license, and
it is not the GPL. Void Linux does not package Brave for licensing reasons;
that is why this is a local build rather than a repository package.
