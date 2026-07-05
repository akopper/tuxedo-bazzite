# tuxedo-bazzite

Bazzite with Tuxedo drivers (TCC + kmod) for Tuxedo/Clevo laptops.

## Available Images

All images are published to `ghcr.io/akopper/`:

| Image | Base | Description |
|---|---|---|
| `tuxedo-bazzite` | `bazzite:stable` | Bazzite KDE Desktop with Tuxedo drivers |
| `tuxedo-bazzite-gnome` | `bazzite-gnome:stable` | Bazzite GNOME Desktop with Tuxedo drivers |
| `tuxedo-bazzite-nvidia` | `bazzite-nvidia:stable` | Bazzite KDE with NVIDIA drivers + Tuxedo drivers |
| `tuxedo-bazzite-gnome-nvidia` | `bazzite-gnome-nvidia:stable` | Bazzite GNOME with NVIDIA drivers + Tuxedo drivers |

## What's included

- [Tuxedo Drivers](https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers) (kmod, built from source)
- [Tuxedo Control Center](https://github.com/tuxedocomputers/tuxedo-control-center)
- [yt6801 Ethernet Driver](https://github.com/h4rm00n/yt6801-linux-driver) (for Motorcomm NICs)
- Everything from upstream Bazzite

## Rebase from existing Bazzite

```bash
# First, rebase to the unsigned image to get signing keys:
rpm-ostree rebase ostree-unverified-registry:ghcr.io/akopper/tuxedo-bazzite:latest

# Reboot
systemctl reboot

# Then rebase to the signed image:
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/akopper/tuxedo-bazzite:latest

# Reboot again
systemctl reboot
```

## Verify signature

```bash
cosign verify --key cosign.pub ghcr.io/akopper/tuxedo-bazzite:latest
```

## Auto-updates

This image is automatically rebuilt twice a week (Monday & Thursday) via GitHub Actions.
Renovate bot automatically creates PRs when upstream Bazzite base images are updated and auto-merges them.

## Credits

- [fnyaker/ublue-tuxedo-tcc](https://github.com/fnyaker/ublue-tuxedo-tcc) - Original Tuxedo driver build scripts
- [BrickMan240/ublue-tuxedo-tcc](https://github.com/BrickMan240/ublue-tuxedo-tcc) - Original Tuxedo image concept
- [Universal Blue](https://universal-blue.org/) - Bazzite base image
- [TUXEDO Computers](https://www.tuxedocomputers.com) - Drivers and Control Center