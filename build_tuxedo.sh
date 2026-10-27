#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

# ============================================================
# Pinned dependency versions
# ============================================================
# These pins are kept up to date automatically by Renovate
# (see renovate.json -> customManagers). Do not change the format
# of the lines below without updating renovate.json.
TUXEDO_DRIVERS_VERSION="4.24.0-1.fc43"   # must be >= 4.24 for the 7.x kernels (ogc)
# 3.1.x reworked the packaging (units in /usr/lib/systemd/system, polkit/
# dbus/udev shipped directly, desktop file renamed), which is exactly why the
# TCC section installs the RPM instead of copying dist-data files. Do not go
# back below 3.1.0 without reworking that section again.
TCC_VERSION="3.1.2"
YT6801_COMMIT="36bfc255f1ad7fc1796652612a4f10e7487d4c82"
DICTUX_COMMIT="99a49cbc2a3886c8eba6106d9c5ed29adf4c0ae5"
CPTR_VERSION="0.9.21"

# ============================================================
# Base utilities
# ============================================================
# tmux and gnome-disk-utility are commonly useful on laptops.
# Folded in from the former build-base.sh to reduce script count.
rpm-ostree install tmux gnome-disk-utility ydotool pipx elementary-files

# Enable podman socket for container management
systemctl enable podman.socket

# ============================================================
# Install build dependencies for Tuxedo drivers
# ============================================================
rpm-ostree install rpm-build rpmdevtools kmodtool rpmrebuild cpio curl gcc make kernel-devel

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
# generating a new key)
# The key pair must be enrolled in MOK on the target machine.
# ============================================================
if [ -n "${AKMODS_PRIVATE_KEY_B64:-}" ] && [ -n "${AKMODS_PUBLIC_KEY_B64:-}" ]; then
    echo "Injecting persistent akmods signing key pair..."
    mkdir -p /etc/pki/akmods/private /etc/pki/akmods/certs
    getent group akmods >/dev/null 2>&1 || groupadd -r akmods

    # Decode keys from base64
    echo "${AKMODS_PRIVATE_KEY_B64}" | base64 -d > /etc/pki/akmods/private/akmods-persistent.priv
    echo "${AKMODS_PUBLIC_KEY_B64}" | base64 -d > /etc/pki/akmods/certs/akmods-persistent.der

    chmod 640 /etc/pki/akmods/private/akmods-persistent.priv
    chown root:akmods /etc/pki/akmods/private/akmods-persistent.priv

    # Point symlinks to our persistent key
    ln -sfn /etc/pki/akmods/private/akmods-persistent.priv /etc/pki/akmods/private/private_key.priv
    ln -sfn /etc/pki/akmods/certs/akmods-persistent.der /etc/pki/akmods/certs/public_key.der

    echo "Persistent signing key injected. kmodgenca will reuse this key."
else
    echo "WARNING: No persistent akmods key provided. kmodgenca will generate a new key."
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
# akmod-tuxedo-drivers package in the TUXEDO repo for Fedora 44,
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
rpm2cpio /tmp/tuxedo-drivers.rpm | cpio -idmv || true
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
# Install pipx-managed apps (dictux, cptr)
# ============================================================
# These are installed system-wide via pipx --global so they survive
# rebases and are available to all users.
echo "Installing pipx-managed apps..."

# Ensure pipx global dirs exist
PIPX_GLOBAL_HOME="/opt/pipx"
PIPX_GLOBAL_BIN_DIR="/usr/local/bin"
export PIPX_GLOBAL_HOME PIPX_GLOBAL_BIN_DIR

# Install dictux (voice dictation) - not on PyPI, install from GitHub.
# Pinned to a commit: Renovate bumps DICTUX_COMMIT when master moves.
pipx install --global "git+https://github.com/nitishkp001/dictux.git@${DICTUX_COMMIT}"

# Install cptr (AI assistant) - Renovate bumps CPTR_VERSION from PyPI
pipx install --global "cptr==${CPTR_VERSION}"

echo "pipx-managed apps installed."

# ============================================================
# Install systemd user service files for dictux + ydotoold
# ============================================================
mkdir -p /etc/skel/.config/systemd/user

cat > /etc/skel/.config/systemd/user/ydotoold.service << 'YDSRV'
[Unit]
Description=ydotool daemon for Wayland input injection
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=/usr/bin/ydotoold
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
YDSRV

cat > /etc/skel/.config/systemd/user/dictux.service << 'DXSRV'
[Unit]
Description=Dictux voice dictation tray app
After=graphical-session.target
PartOf=graphical-session.target
Requires=ydotoold.service

[Service]
Type=simple
Environment=HF_HUB_OFFLINE=1
ExecStart=/usr/local/bin/dictux
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
DXSRV

cat > /etc/skel/.config/systemd/user/cptr.service << 'CPTSRV'
[Unit]
Description=cptr - Your computer, from anywhere
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cptr run --headless
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
CPTSRV

# Add PATH to skel bashrc
echo 'export PATH="$PATH:/usr/local/bin"' >> /etc/skel/.bashrc

# Clean up the downloaded RPM so it does not end up in the image layer
rm -f /tmp/tuxedo-control-center.rpm

echo "Tuxedo drivers, yt6801, Control Center, dictux, and cptr installation completed!"