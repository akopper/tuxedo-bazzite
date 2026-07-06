# tuxedo-bazzite

Custom [Bazzite](https://universal-blue.org/bazzite/) image with Tuxedo drivers for Tuxedo/Clevo laptops.

Adds the Tuxedo kernel modules (`tuxedo_io`, `tuxedo_keyboard`, `clevo_acpi`, etc.) and [Tuxedo Control Center](https://github.com/tuxedocomputers/tuxedo-control-center) on top of upstream Bazzite, so fan control, keyboard backlight, and temperature sensors work out of the box.

## Available Images

All images are published to `ghcr.io/akopper/`:

| Image | Base | Description |
|---|---|---|
| `tuxedo-bazzite` | `bazzite:stable` | Bazzite KDE Desktop with Tuxedo drivers |
| `tuxedo-bazzite-gnome` | `bazzite-gnome:stable` | Bazzite GNOME Desktop with Tuxedo drivers |
| `tuxedo-bazzite-nvidia` | `bazzite-nvidia:stable` | Bazzite KDE with NVIDIA drivers + Tuxedo drivers |
| `tuxedo-bazzite-gnome-nvidia` | `bazzite-gnome-nvidia:stable` | Bazzite GNOME with NVIDIA drivers + Tuxedo drivers |

## What's included

- **[Tuxedo Drivers](https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers)** — kernel modules built via `akmod-tuxedo-drivers` from the Tuxedo RPM repo, signed for Secure Boot
- **[Tuxedo Control Center](https://github.com/tuxedocomputers/tuxedo-control-center)** — GUI and `tccd` service for fan/LED/power profiles
- **[yt6801 Ethernet Driver](https://github.com/h4rm00n/yt6801-linux-driver)** — for Motorcomm NICs (signed for Secure Boot)
- Everything from upstream Bazzite

---

## Installation

### 1. Rebase to the custom image

From any Bazzite installation (or Fedora Silverblue/Kinoite with ostree):

```bash
# GNOME + NVIDIA variant (adjust image name for your variant)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/akopper/tuxedo-bazzite-gnome-nvidia:latest

# Reboot
systemctl reboot
```

> **Other variants:** Replace `tuxedo-bazzite-gnome-nvidia` with any image name from the table above.

### 2. Enroll the MOK signing key (Secure Boot)

The Tuxedo kernel modules are signed with a custom MOK (Machine Owner Key) that is **not** enrolled by default. After the first boot into the new image you must enroll it once:

```bash
# Import the key into the MOK enrollment queue
sudo mokutil --import /etc/pki/akmods/certs/akmods-persistent.der
```

You will be prompted for a password. Use:

```
password
```

Then reboot. At the blue **MOK Manager** screen:

1. Select **"Enroll MOK"**
2. Select **"View key"** (optional) then **"Continue"**
3. Enter the password: `password`
4. Select **"Reboot"**

After reboot the Tuxedo modules will load automatically.

### 3. Verify

```bash
# Check modules are loaded
lsmod | grep -E "tuxedo|clevo|uniwill"

# Check temperatures
sensors

# Tuxedo Control Center should be in your app menu, or:
tuxedo-control-center
```

---

## Rebase to signed image (optional)

Once you've verified the unsigned image works, you can switch to the cosign-signed version:

```bash
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/akopper/tuxedo-bazzite-gnome-nvidia:latest
systemctl reboot
```

Verify the signature:

```bash
cosign verify --key cosign.pub ghcr.io/akopper/tuxedo-bazzite-gnome-nvidia:latest
```

---

## How it works (Secure Boot signing)

Bazzite's base image ships with a kernel signing key ("ublue kernel") that is enrolled in MOK. Private kernel modules built during image creation (like the NVIDIA driver) are signed with this key. However, the ublue **private key** is not included in the image — it's only available in Universal Blue's build pipeline.

When this custom image builds on top of Bazzite, `kmodgenca` would normally generate a **new** signing key for akmods. That key is not enrolled in MOK, so the kernel rejects the modules with `Key was rejected by service`.

To fix this, the build injects a **persistent key pair** (stored as GitHub repo secrets `AKMODS_PRIVATE_KEY` and `AKMODS_PUBLIC_KEY`) before installing `akmod-tuxedo-drivers`. The `akmods-ostree-post` script then builds and signs the modules with this key. The same key pair is reused on every rebuild, so it only needs to be enrolled in MOK **once** per machine.

The yt6801 Ethernet driver is also manually signed with the same key using `scripts/sign-file`.

## Auto-updates

This image is automatically rebuilt twice a week (Monday & Thursday) via GitHub Actions.
[Renovate](https://www.renovatebot.com/) automatically creates PRs when upstream Bazzite base images are updated and auto-merges them.

## Credits

- [fnyaker/ublue-tuxedo-tcc](https://github.com/fnyaker/ublue-tuxedo-tcc) — Original Tuxedo driver build scripts
- [BrickMan240/ublue-tuxedo-tcc](https://github.com/BrickMan240/ublue-tuxedo-tcc) — Original Tuxedo image concept
- [Universal Blue](https://universal-blue.org/) — Bazzite base image
- [TUXEDO Computers](https://www.tuxedocomputers.com) — Drivers and Control Center
