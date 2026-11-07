#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

# Point the TUXEDO repo at this Fedora release before the first dnf call:
# the placeholder in tuxedo.repo is not a usable URL and the repo has
# skip_if_unavailable=False, so every dnf command fails until it is
# substituted. (Previously the Containerfile RUN did this before invoking
# the script.)
sed -i "s/FEDORA_VERSION_PLACEHOLDER/${RELEASE}/g" /etc/yum.repos.d/tuxedo.repo

# ============================================================
# Pinned dependency versions
# ============================================================
# These pins are kept up to date automatically by Renovate
# (see renovate.json -> customManagers). Do not change the format
# of the lines below without updating renovate.json.
TUXEDO_DRIVERS_VERSION="4.25.0-1.fc43"   # must be >= 4.24 for the 7.x kernels (ogc)
# 3.1.x reworked the packaging (units in /usr/lib/systemd/system, polkit/
# dbus/udev shipped directly, desktop file renamed), which is exactly why the
# TCC section installs the RPM instead of copying dist-data files. Do not go
# back below 3.1.0 without reworking that section again.
TCC_VERSION="3.1.3"
YT6801_COMMIT="36bfc255f1ad7fc1796652612a4f10e7487d4c82"

# ============================================================
# Base utilities
# ============================================================
# tmux and gnome-disk-utility are commonly useful on laptops.
# Folded in from the former build-base.sh to reduce script count.
# elementary-files is not packaged for Fedora 45; GNOME/niri already ship nautilus.
dnf install -y tmux gnome-disk-utility

# Enable podman socket for container management
systemctl enable podman.socket

# ============================================================
# Install build dependencies for Tuxedo drivers
# ============================================================
dnf install -y rpm-build rpmdevtools kmodtool rpmrebuild cpio curl gcc make kernel-devel

# ============================================================
# Setup fixtuxedo script and service
# ============================================================
chmod +x /usr/bin/fixtuxedo
systemctl enable /etc/systemd/system/fixtuxedo.service

# ============================================================
# Blacklist the built-in kernel uniwill_laptop module
# ============================================================
# The kernel ships a built-in uniwill_laptop module
# (drivers/platform/x86/uniwill/uniwill-laptop.ko) which claims the
# ABBC0F72 WMI device via DMI alias matching on TUXEDO boards. This
# prevents the tuxedo-drivers uniwill_wmi module from binding to the
# device, causing "probe: At least one Uniwill GUID missing" and TCC
# to report "interface: inactive". Blacklisting it ensures the
# tuxedo-drivers module gets exclusive access.
mkdir -p /usr/lib/modprobe.d
cat > /usr/lib/modprobe.d/tuxedo-blacklist.conf << 'EOF'
# Blacklist the built-in kernel uniwill_laptop module so that the
# tuxedo-drivers uniwill_wmi module can claim the WMI device instead.
blacklist uniwill_laptop
EOF

# ============================================================
# Inject persistent akmods signing key (prevents kmodgenca from
# generating a new key). The key pair must be enrolled in MOK on
# the target machine.
# The key is passed as a BUILD SECRET (RUN --mount=type=secret in
# the Containerfile, --secret=... on the CLI), never as a build
# arg: build args are recorded in the published image's layer
# history, which is exactly how the previous key leaked (Nov 2026).
# ============================================================
if [ -s /run/secrets/akmods_private_key ] && [ -s /run/secrets/akmods_public_key ]; then
    echo "Injecting persistent akmods signing key pair..."
    mkdir -p /etc/pki/akmods/private /etc/pki/akmods/certs
    getent group akmods >/dev/null 2>&1 || groupadd -r akmods

    install -m 640 -o root -g akmods \
        /run/secrets/akmods_private_key /etc/pki/akmods/private/akmods-persistent.priv
    install -m 644 /run/secrets/akmods_public_key /etc/pki/akmods/certs/akmods-persistent.der

    # Point symlinks to our persistent key
    ln -sfn /etc/pki/akmods/private/akmods-persistent.priv /etc/pki/akmods/private/private_key.priv
    ln -sfn /etc/pki/akmods/certs/akmods-persistent.der /etc/pki/akmods/certs/public_key.der

    echo "Persistent signing key injected. kmodgenca will reuse this key."
else
    echo "WARNING: No persistent akmods key mounted. kmodgenca will generate a new key."
    echo "Modules will NOT load under Secure Boot until the new key is enrolled in MOK."
fi

# ============================================================
# Helper: build, install, and sign a kernel module from source
# ============================================================
# Usage: build_and_sign_modules <src_dir> <install_subdir>
build_and_sign_modules() {
    local SRC_DIR="$1"
    local INSTALL_SUBDIR="$2"

    echo "Building modules from ${SRC_DIR} for kernel ${KERNEL_VERSION}..."
    make V=1 -C "/lib/modules/${KERNEL_VERSION}/build" M="${SRC_DIR}" modules

    local MODULE_INSTALL_DIR="/lib/modules/${KERNEL_VERSION}/extra/${INSTALL_SUBDIR}"
    mkdir -p "${MODULE_INSTALL_DIR}"

    # Install all built .ko files
    find "${SRC_DIR}" -name "*.ko" -exec install -D -m 755 {} "${MODULE_INSTALL_DIR}/" \;

    # Sign the modules with the akmods key pair (for Secure Boot)
    if [ -x "/lib/modules/${KERNEL_VERSION}/build/scripts/sign-file" ]; then
        echo "Signing modules in ${INSTALL_SUBDIR} for Secure Boot..."
        local SIGN_KEY="/etc/pki/akmods/private/private_key.priv"
        local SIGN_CERT="/etc/pki/akmods/certs/public_key.der"
        if [ -f "${SIGN_KEY}" ] && [ -f "${SIGN_CERT}" ]; then
            find "${MODULE_INSTALL_DIR}" -name "*.ko" -exec \
                /lib/modules/${KERNEL_VERSION}/build/scripts/sign-file sha256 "${SIGN_KEY}" "${SIGN_CERT}" {} \;
            echo "${INSTALL_SUBDIR} modules signed"
        else
            echo "WARNING: Signing keys not found, skipping module signing"
        fi
        # Compress signed modules
        find "${MODULE_INSTALL_DIR}" -name "*.ko" -exec xz --check=crc32 -f {} \;
    fi

    depmod -a "${KERNEL_VERSION}"
    echo "Modules in ${INSTALL_SUBDIR} installed:"
    find "${MODULE_INSTALL_DIR}" -name "*.ko*" | head -20
}

# ============================================================
# Install tuxedo-drivers DKMS source and build kernel modules
# ============================================================
# The TUXEDO repo provides a DKMS source package
# (tuxedo-drivers-*.noarch.rpm) which installs source to
# /usr/src/tuxedo-drivers-<version>/. There is no
# akmod-tuxedo-drivers package in the TUXEDO repo for Fedora 44/45,
# so we build the modules manually from the DKMS source.
# NOTE: The version must match the kernel flavor of the base image:
# - ogc-lts (kernel 6.18, bazzite-*-nvidia): tuxedo-drivers >= 4.22 works
# - ogc (kernel 7.2, bazzite-*-nvidia-open): needs tuxedo-drivers >= 4.24

# Download and extract tuxedo-drivers DKMS source (avoid DKMS postinstall script)
# v4.24.0 is the latest release and includes kernel 7.x compatibility fixes
# -fsSL: fail loudly on 404/HTML error pages instead of feeding them to rpm2cpio
curl -fsSL -o /tmp/tuxedo-drivers.rpm https://rpm.tuxedocomputers.com/fedora/${RELEASE}/x86_64/base/tuxedo-drivers-${TUXEDO_DRIVERS_VERSION}.noarch.rpm
mkdir -p /usr/src
cd /
rpm2cpio /tmp/tuxedo-drivers.rpm | cpio -idm --quiet
cd /tmp

KERNEL_VERSION="$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
echo "Kernel version: ${KERNEL_VERSION}"

TUXEDO_SRC_DIR="$(ls -d /usr/src/tuxedo-drivers-* 2>/dev/null | head -1)"
if [ -z "${TUXEDO_SRC_DIR}" ]; then
    echo "ERROR: tuxedo-drivers source not found in /usr/src/"
    exit 1
fi
echo "Found tuxedo-drivers source at: ${TUXEDO_SRC_DIR}"

build_and_sign_modules "${TUXEDO_SRC_DIR}" "tuxedo-drivers"

# ============================================================
# Build and install tuxedo-yt6801 network driver
# ============================================================
# Uses the h4rm00n fork which patches the official driver for
# kernel 6.15+ API changes. The official Motorcomm driver is
# not yet mainlined.
cd /tmp

echo "Cloning yt6801 driver with kernel 6.15+ compatibility..."
# Pinned to a commit (not a branch tip) so builds are reproducible.
# Renovate bumps YT6801_COMMIT when the fork's main branch moves.
git clone https://github.com/h4rm00n/yt6801-linux-driver
cd yt6801-linux-driver
git checkout "${YT6801_COMMIT}"
echo "yt6801 checked out at ${YT6801_COMMIT}"

BUILD_DIR="/tmp/_kmod_build_${KERNEL_VERSION}"
mkdir -p "${BUILD_DIR}"

if [ -d "src" ]; then
    cp -a src/* "${BUILD_DIR}/"
else
    find . -maxdepth 1 \( -name "*.c" -o -name "*.h" -o -name "Makefile" \) -exec cp {} "${BUILD_DIR}/" \;
fi

build_and_sign_modules "${BUILD_DIR}" "tuxedo-yt6801"

echo "Checking if yt6801 is available to modinfo..."
modinfo yt6801 2>/dev/null && echo "yt6801 module found!" || echo "yt6801 module not found by modinfo"

# ============================================================
# Install and configure Tuxedo Control Center
# ============================================================
# TCC 3.1.x is packaged properly for Fedora: systemd units in
# /usr/lib/systemd/system, polkit/dbus/udev rules at their standard
# paths, desktop + tray autostart shipped by the RPM. So install the
# RPM instead of hand-copying files out of the payload (which is what
# the 3.0.x line forced us to do).
#
# Two things still need manual care:
#  1. It cannot be installed via dnf: the Requires on
#     "(libayatana-appindicator3-1 or ...)" is unsatisfiable on Fedora
#     (no package provides it), and pulling tuxedo-drivers/dkms would
#     run module scriptlets that fail in the CI container.
#     -> rpm -i --nodeps --noscripts
#  2. In ostree images /opt is a relative symlink to var/opt and
#     /var/opt does not exist in the base image, so rpm cannot unpack
#     anything below /opt. We create /var/opt, install, then move the
#     payload into the immutable /usr and leave a symlink behind.
cd /tmp

# -fsSL: a removed version must abort the build with a clear HTTP error,
# not silently save a 404 page and explode later
curl -fsSL -o /tmp/tuxedo-control-center.rpm https://rpm.tuxedocomputers.com/fedora/${RELEASE}/x86_64/base/tuxedo-control-center_${TCC_VERSION}.rpm

# rpm -i bypasses dnf's repo key handling, and dnf only imports keys for
# repos it actually uses. Import the TUXEDO key explicitly so the signature
# check below succeeds.
curl -fsSL -o /tmp/tuxedo.asc https://rpm.tuxedocomputers.com/fedora/${RELEASE}/0x54840598.pub.asc
rpm --import /tmp/tuxedo.asc
rm -f /tmp/tuxedo.asc

# rpm cannot create files through the /opt -> var/opt symlink.
# Clear any pre-existing entry first, otherwise rpm would install *through*
# a stale symlink and the mv below would move the link instead of the payload.
mkdir -p /var/opt
rm -rf /var/opt/tuxedo-control-center

# --noscripts: posttrans calls systemctl for services that cannot run here
# --nodeps: see (1) above
rpm -i --nodeps --noscripts /tmp/tuxedo-control-center.rpm

# Move the payload out of /var (mutable) into /usr (immutable, ostree-managed)
mv /var/opt/tuxedo-control-center /usr/share/tuxedo-control-center
ln -sfn /usr/share/tuxedo-control-center /var/opt/tuxedo-control-center

# Describe the /var symlink for bootc: /var is not carried over verbatim, so
# without a tmpfiles entry the compatibility link would disappear on redeploy.
cat > /usr/lib/tmpfiles.d/tuxedo-control-center.conf << 'TCCTMP'
L /var/opt/tuxedo-control-center - - - - /usr/share/tuxedo-control-center
TCCTMP

# The packaged units and desktop entries still point at /opt, while our
# payload now lives in /usr/share. Rewrite those three files - and fail
# loudly if a future version renames them, instead of shipping a TCC whose
# units point nowhere.
for f in \
    /usr/lib/systemd/system/tccd.service \
    /usr/share/applications/com.tuxedocomputers.tcc.desktop \
    /etc/xdg/autostart/tuxedo-control-center-tray.desktop ; do
    if [ ! -f "${f}" ]; then
        echo "ERROR: ${f} not shipped by tuxedo-control-center ${TCC_VERSION} - packaging changed, rework this section"
        exit 1
    fi
    sed -i 's|/opt/tuxedo-control-center|/usr/share/tuxedo-control-center|g' "${f}"
done

# The polkit policy is what allows the GUI to talk to tccd
if [ ! -f /usr/share/polkit-1/actions/com.tuxedocomputers.tccd-service.policy ]; then
    echo "ERROR: polkit policy missing from tuxedo-control-center ${TCC_VERSION} - packaging changed"
    exit 1
fi

# pkexec resolves the target with realpath() before matching it against the
# policy's exec.path annotation. The payload now lives in /usr/share, so the
# shipped /opt annotation no longer matches and pkexec would fall back to the
# generic org.freedesktop.policykit.exec action, losing TCC's
# auth_admin_keep/allow_gui settings. Point the annotation at the canonical
# path (TCC still calls /opt, but the symlink resolves to /usr/share).
sed -i 's|/opt/tuxedo-control-center|/usr/share/tuxedo-control-center|g' \
    /usr/share/polkit-1/actions/com.tuxedocomputers.tccd-service.policy

# Electron needs the sandbox helper setuid (the RPM ships it 0755)
chmod 4755 /usr/share/tuxedo-control-center/chrome-sandbox

# CLI convenience (3.1.x no longer ships this link)
ln -sfn /usr/share/tuxedo-control-center/tuxedo-control-center /usr/bin/tuxedo-control-center

# ============================================================
# Migrate away from files the 3.0.x approach installed into /etc
# ============================================================
# /etc survives rebases, so leftovers from older images would shadow the
# vendor units now living in /usr/lib/systemd/system.
rm -f /etc/systemd/system/tccd.service /etc/systemd/system/tccd-sleep.service

# The tray autostart moved from /etc/skel into /etc/xdg/autostart; the old
# skel copy would start a second tray for newly created users.
rm -f /etc/skel/.config/autostart/tuxedo-control-center-tray.desktop

# Enable services (units are vendor units from the RPM)
systemctl enable tccd.service
systemctl enable tccd-sleep.service

# ============================================================
# OpenRGB (patched for the 048d:6004 keyboard and the front lightbar)
# ============================================================
# Built in the Containerfile's openrgb-builder stage from the Fedora source
# package, plus two device additions (openrgb-tuxedo-6004.patch):
#  - an extra HID detector for PID 0x6004 (upstream only matches 0x600B;
#    same ITE 8291 protocol, same HID usage page)
#  - a sysfs controller for the TUXEDO/Uniwill front lightbar. The lightbar
#    is an EC device, not part of the ITE keyboard, and the kernel driver
#    exposes it as three monochrome LEDs under /sys/class/leds.
# Installing the RPM pulls the Qt5 runtime, desktop file and icons. The base
# image ships openrgb-udev-rules, but that package only tags PID 0x600b, so
# the Gen4 keyboard stays root-only and the user service cannot open it.
if [ ! -f /tmp/openrgb.rpm ]; then
    echo "ERROR: patched openrgb RPM missing - was the openrgb-builder stage skipped?"
    exit 1
fi
dnf install -y /tmp/openrgb.rpm
rm -f /tmp/openrgb.rpm

# Without this rule /dev/hidraw0 for 048d:6004 is crw------- root:root:
# TAG+="uaccess" gives the logged-in seat user an ACL, which is what lets
# the per-user openrgb.service talk to the keyboard.
cat > /usr/lib/udev/rules.d/60-openrgb-tuxedo-6004.rules << 'ORGB6004'
SUBSYSTEMS=="usb|hidraw", ATTRS{idVendor}=="048d", ATTRS{idProduct}=="6004", TAG+="uaccess", TAG+="Clevo_Keyboard"
ORGB6004

# The front lightbar is not a USB device: tuxedo_keyboard exposes it as three
# monochrome sysfs LEDs. Their brightness attributes are root-owned 0644, so
# the per-user openrgb.service cannot write them. udev has no uaccess tagging
# for sysfs attributes, hence the explicit chmod. The rule re-runs whenever
# the LEDs are (re)registered, e.g. after a module reload.
cat > /usr/lib/udev/rules.d/60-openrgb-tuxedo-lightbar.rules << 'ORGBLB'
SUBSYSTEM=="leds", KERNEL=="lightbar_rgb:*", RUN+="/usr/bin/chmod 0666 /sys/class/leds/%k/brightness"
SUBSYSTEM=="leds", KERNEL=="lightbar_animation::status", RUN+="/usr/bin/chmod 0666 /sys/class/leds/%k/brightness"
ORGBLB

# ============================================================
# keyd (Extend/nav layer, system-wide)
# ============================================================
# keyd is not in the Fedora repos; the alternateved COPR is the maintained
# build. The config itself is copied in by the Containerfile to
# /etc/keyd/default.conf. keyd creates its own virtual keyboard, so libinput
# has to be told to treat it as internal - otherwise it is classed as an
# external keyboard and disable-while-typing cannot suppress the touchpad
# while typing. local-overrides.quirks is the only file libinput 1.31 reads
# from /etc/libinput; append instead of overwriting.
curl -fsSL -o "/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:alternateved:keyd.repo" \
    "https://copr.fedorainfracloud.org/coprs/alternateved/keyd/repo/fedora-${RELEASE}/alternateved-keyd-fedora-${RELEASE}.repo"
curl -fsSL "https://download.copr.fedorainfracloud.org/results/alternateved/keyd/pubkey.gpg" -o /tmp/keyd.asc
rpm --import /tmp/keyd.asc
rm -f /tmp/keyd.asc

dnf install -y keyd

if [ ! -f /etc/keyd/default.conf ]; then
    echo "ERROR: /etc/keyd/default.conf missing - did the Containerfile COPY fail?"
    exit 1
fi
keyd check

mkdir -p /etc/libinput
if ! grep -q 'MatchName=keyd\*keyboard' /etc/libinput/local-overrides.quirks 2>/dev/null; then
    cat >> /etc/libinput/local-overrides.quirks << 'KEYDQUIRK'

[Serial Keyboards]
MatchUdevType=keyboard
MatchName=keyd*keyboard
AttrKeyboardIntegration=internal
KEYDQUIRK
fi

systemctl enable keyd.service

# ============================================================
# Sunshine (game streaming host)
# ============================================================
# Installed as an RPM rather than the flatpak, on purpose:
#  - the flatpak cannot use KMS capture (it logs "AppImage and Flatpak do
#    not support KMS capture"), which leaves only the XDG portal path
#  - the portal path does not work on this hardware: niri serves a
#    DMA-BUF-only screencast stream whose formats never negotiate with
#    Sunshine ("no more input formats", see niri#3145 / pipewire#5353), and
#    the hybrid AMD-iGPU + NVIDIA-dGPU split breaks the dmabuf handoff in
#    mutter too
# KMS capture bypasses both: it reads the scanout buffer straight from DRM,
# so it behaves the same on niri, GNOME and Plasma and needs no compositor
# cooperation. NVENC still cannot consume the iGPU framebuffer, so Sunshine
# settles on the VCN/vulkan encoder - that is expected and streams fine on
# this laptop.
#
# COPR: upstream LizardByte channel. This is the beta channel, not stable,
# on purpose: stable still ships 2026.914, which has the duplicate-client-
# certificate bug from LizardByte/Sunshine#5696 - every re-pair appends a
# second entry for the same phone certificate, and the authorization check
# ("exactly one enabled match") then rejects the client with
# "SSL Verification error :: Client certificate identity is not enabled".
# Fixed by LizardByte/Sunshine#5737, which is only in beta/nightly builds.
curl -fsSL -o "/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:lizardbyte:beta.repo" \
    "https://copr.fedorainfracloud.org/coprs/lizardbyte/beta/repo/fedora-${RELEASE}/lizardbyte-beta-fedora-${RELEASE}.repo"
# Import the repo key up front: the build has no tty to confirm it, and an
# unconfirmed key import aborts the transaction.
curl -fsSL "https://download.copr.fedorainfracloud.org/results/lizardbyte/beta/pubkey.gpg" -o /tmp/lizardbyte.asc
rpm --import /tmp/lizardbyte.asc
rm -f /tmp/lizardbyte.asc

dnf install -y Sunshine

# CAP_SYS_ADMIN is what KMS capture needs, CAP_SYS_NICE lets Sunshine raise
# its own scheduling priority. Ostree preserves file capabilities (gamescope
# and newuidmap ship with them), so this sticks across updates - unlike a
# runtime "sudo setcap" on an ostree system, which cannot write to /usr.
setcap cap_sys_admin,cap_sys_nice+ep /usr/bin/sunshine
getcap /usr/bin/sunshine

# Force KMS capture for every user. Auto-detection is unreliable here: with
# no capture option Sunshine probes wayland/portal first and retries there,
# and when it does reach kms it tries NVENC before falling back to vulkan.
# "name=value" is a documented Sunshine command line override, so this needs
# no per-user config file.
mkdir -p /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d
cat > /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/10-kms.conf << 'SUNKMS'
[Service]
# The RPM ships ExecStart=/usr/bin/sunshine; force KMS capture.
ExecStart=
ExecStart=/usr/bin/sunshine capture=kms
SUNKMS

# The RPM ships /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service
# (Alias=sunshine.service, WantedBy=graphical-session.target). Link it in for
# every user: niri-session and GNOME both reach graphical-session.target.
mkdir -p /etc/systemd/user/graphical-session.target.wants
ln -sf /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service \
    /etc/systemd/user/graphical-session.target.wants/app-dev.lizardbyte.app.Sunshine.service
# systemd only materialises the unit's "Alias=sunshine.service" when it is
# enabled through systemctl, not when it is linked by hand - ship the alias
# explicitly so "systemctl --user status sunshine" works.
ln -sf /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service \
    /etc/systemd/user/sunshine.service

# Drop package-manager caches: they bloat the image and make bootc lint
# complain about non-cache content in /var.
dnf clean all
rm -f /tmp/tuxedo-control-center.rpm /tmp/tuxedo-drivers.rpm /var/log/dnf5.log
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/cache/ldconfig
rm -rf /run/dnf /tmp/_kmod_build_* /tmp/yt6801-linux-driver
rm -rf /var/lib/dnf/repos /var/roothome/.cache/pip

echo "Tuxedo drivers, yt6801, Control Center, and Sunshine installation completed!"