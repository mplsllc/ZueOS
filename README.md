<p align="center">
  <img src="art/logo-light.png" alt="XueOS" width="420">
</p>

<p align="center">
  <em>a small, cheese-loving mouse building a minimal XFCE distro</em>
</p>
---

## What is this?

**XueOS** is a minimal XFCE spin of Ubuntu 24.04 LTS, built to be two things at once:

1. **A ready-to-go XFCE development environment** — clone, build, and hack on real XFCE components (`xfce4-panel`, `xfwm4`, ...) the moment you boot it. `apt build-dep`/`apt source` work out of the box, `xfce4-dev-tools` is preinstalled, and the Xubuntu team's own staging PPA is wired in for testing pre-release XFCE builds.
2. **The home for [Besra](https://github.com/mplsllc/besra)**, a Qt6, NetSurf-esque browser under active development — the eventual default browser here. Firefox ships in the meantime so the desktop is actually usable.

The desktop itself is kept **stock XFCE** on purpose — no custom theme, no rearranged panel. If someone links to this saying "come help develop our desktop environment," they should see upstream XFCE, not a reskin.

## 🐭 What's in the box

- **Base**: Ubuntu 24.04 LTS ("noble"), amd64, debootstrapped minimal — not a full Ubuntu image
- **Desktop**: stock XFCE4, LightDM, autologin
- **Dev tooling**: `build-essential`, `xfce4-dev-tools`, `gdb`, `meson`/`ninja`, `deb-src` enabled, Qt6 dev headers (for Besra) alongside GTK3/libxfce4ui headers (for XFCE itself)
- **Browser**: Firefox (via Mozilla's own apt repo — Ubuntu's archive `firefox` package is a snap stub, and this project blocks snapd outright)
- **Chat**: [Element](https://element.io) — XFCE's own community chat lives on Matrix
- **Installer**: Calamares, so you install once and update forever after via plain `apt`
- **No snapd.** Ever. Purged and pinned to `-1` so it can't sneak back in.

## 🎨 Branding

Wallpapers, boot splash, login screen, and icon all feature Xue, the mascot — but that's where the customization stops. The desktop itself (theme, panel layout) stays stock XFCE, deliberately. See [`art/`](art/) for the source logo/wallpaper assets.

## 📦 Repository layout

```
build-iso.sh              # the ISO build engine (debootstrap → chroot → squashfs → grub-mkrescue)
Makefile                  # make build-iso / make update-repo / make clean
config/
  build.conf               # package lists, paths, repo settings
  build.local.conf.example # template for secrets — copy to build.local.conf (gitignored)
overlay/                  # files copied verbatim into the image: branding, calamares config, casper hooks
art/                      # source logo/wallpaper/icon assets
scripts/
  publish-deb.sh           # publishes a built .deb to the XueOS apt repo
ATTRIBUTION.md             # Ubuntu-base disclosure (see below)
```

## Building it yourself

```
make build-iso              # needs sudo — debootstraps + builds xueos-dev-amd64.iso
make update-repo DEBS="..." # publish .deb package(s) to the apt repo
make clean                  # tear down build state, including any stray chroot mounts
```

## Getting it

- **ISO**: https://xueos.mp.ls/iso/
- **apt repo**: `https://apt.mp.ls` (distribution `besra`) — nothing published there yet, reserved for when Besra ships

## Attribution

XueOS is a derivative of Ubuntu 24.04 LTS, not affiliated with or endorsed by Canonical. See [ATTRIBUTION.md](ATTRIBUTION.md) for the full disclosure and licensing notes.

---

<p align="center"><sub>made with 🧀 by the XueOS project</sub></p>
