#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

# ============================================================
# Base utilities
# ============================================================
# tmux and gnome-disk-utility are commonly useful on laptops.
# Folded in from the former build-base.sh to reduce script count.
rpm-ostree install tmux gnome-disk-utility

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
# Disable stale tuxedo-modules.service from older images
# ============================================================
# A previous version of this image installed
# tuxedo-modules.service and tuxedo-load-modules.sh which load
# unsigned modules from /var/lib/tuxedo-kmods/ via insmod.  Under
# Secure Boot those insmod calls silently fail and — worse — the
# script first rmmod's the properly signed modules that
# fixtuxedo loaded, leaving tccd with no fan / keyboard
# support.  Remove the service, the script, and the stale
# kmods directory so only fixtuxedo.service (modprobe on signed
# modules) remains.
systemctl disable tuxedo-modules.service 2>/dev/null || true
rm -f /etc/systemd/system/tuxedo-modules.service
rm -f /usr/local/bin/tuxedo-load-modules.sh
rm -rf /var/lib/tuxedo-kmods

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

# Download and extract tuxedo-drivers DKMS source (avoid DKMS postinstall script)
curl -s -o /tmp/tuxedo-drivers.rpm https://rpm.tuxedocomputers.com/fedora/${RELEASE}/x86_64/base/tuxedo-drivers-4.22.1-1.fc43.noarch.rpm
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
git clone https://github.com/h4rm00n/yt6801-linux-driver
cd yt6801-linux-driver

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
# Download and extract TCC RPM directly to avoid dependency issues
# (tuxedo-control-center depends on dkms and tuxedo-drivers which
# trigger DKMS postinstall scripts that fail in the CI container)
cd /tmp

curl -s -o /tmp/tuxedo-control-center.rpm https://rpm.tuxedocomputers.com/fedora/${RELEASE}/x86_64/base/tuxedo-control-center_3.0.6.rpm

# Extract TCC RPM to a temporary directory (avoid /opt symlink issues
# in ostree containers where /opt -> /var/opt)
mkdir -p /tmp/tcc-extract
cd /tmp/tcc-extract
rpm2cpio /tmp/tuxedo-control-center.rpm | cpio -idmv || true
cd /tmp

# Verify extraction succeeded
if [ ! -d /tmp/tcc-extract/opt/tuxedo-control-center ]; then
    echo "ERROR: TCC extraction failed - /tmp/tcc-extract/opt/tuxedo-control-center not found"
    exit 1
fi

# Install TCC to /usr/share (ostree prefers /usr/share over /opt)
mkdir -p /usr/share
cp -a /tmp/tcc-extract/opt/tuxedo-control-center /usr/share/tuxedo-control-center

# Create /var/opt symlink for runtime compatibility
mkdir -p /var/opt
ln -sf /usr/share/tuxedo-control-center /var/opt/tuxedo-control-center

# Create bin symlink
rm -f /usr/bin/tuxedo-control-center
ln -s /usr/share/tuxedo-control-center/tuxedo-control-center /usr/bin/tuxedo-control-center

# Set SUID on chrome-sandbox (required by Electron 5+)
chmod 4755 /usr/share/tuxedo-control-center/chrome-sandbox 2>/dev/null || true

# ============================================================
# Install service files, polkit, dbus, udev, desktop files
# from the TCC dist-data directory (normally done by RPM posttrans)
# ============================================================
DIST_DATA=/usr/share/tuxedo-control-center/resources/dist/tuxedo-control-center/data/dist-data

# Service files
cp ${DIST_DATA}/tccd.service /etc/systemd/system/tccd.service
cp ${DIST_DATA}/tccd-sleep.service /etc/systemd/system/tccd-sleep.service

# Fix service paths: replace /opt with /usr/share
sed -i 's|/opt/tuxedo-control-center|/usr/share/tuxedo-control-center|g' /etc/systemd/system/tccd.service
sed -i 's|/opt/tuxedo-control-center|/usr/share/tuxedo-control-center|g' /etc/systemd/system/tccd-sleep.service

# Polkit policies
mkdir -p /usr/share/polkit-1/actions
cp ${DIST_DATA}/com.tuxedocomputers.tccd.policy /usr/share/polkit-1/actions/com.tuxedocomputers.tccd.policy
cp ${DIST_DATA}/com.tuxedocomputers.tomte.policy /usr/share/polkit-1/actions/com.tuxedocomputers.tomte.policy 2>/dev/null || true

# DBus config
mkdir -p /usr/share/dbus-1/system.d
cp ${DIST_DATA}/com.tuxedocomputers.tccd.conf /usr/share/dbus-1/system.d/com.tuxedocomputers.tccd.conf 2>/dev/null || true

# Desktop file
cp ${DIST_DATA}/tuxedo-control-center.desktop /usr/share/applications/tuxedo-control-center.desktop 2>/dev/null || true
sed -i 's|/opt/tuxedo-control-center|/usr/share/tuxedo-control-center|g' /usr/share/applications/tuxedo-control-center.desktop

# Autostart desktop file
mkdir -p /etc/skel/.config/autostart
cp ${DIST_DATA}/tuxedo-control-center-tray.desktop /etc/skel/.config/autostart/tuxedo-control-center-tray.desktop 2>/dev/null || true

# Udev rules
cp ${DIST_DATA}/99-webcam.rules /etc/udev/rules.d/99-webcam.rules 2>/dev/null || true

# Enable services
systemctl enable tccd.service 2>/dev/null || true
systemctl enable tccd-sleep.service 2>/dev/null || true

# Clean up
rm -rf /tmp/tcc-extract

echo "Tuxedo drivers, yt6801, and Control Center installation completed!"