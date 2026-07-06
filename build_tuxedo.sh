#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

# ============================================================
# Install build dependencies for Tuxedo drivers
# ============================================================
rpm-ostree install rpm-build
rpm-ostree install rpmdevtools
rpm-ostree install kmodtool
rpm-ostree install rpmrebuild
rpm-ostree install curl
rpm-ostree install gcc make kernel-devel

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

    # Decode keys from base64
    echo "${AKMODS_PRIVATE_KEY_B64}" | base64 -d > /etc/pki/akmods/private/akmods-persistent.priv
    echo "${AKMODS_PUBLIC_KEY_B64}" | base64 -d > /etc/pki/akmods/certs/akmods-persistent.der

    chmod 640 /etc/pki/akmods/private/akmods-persistent.priv
    chown root:akmods /etc/pki/akmods/private/akmods-persistent.priv

    # Point symlinks to our persistent key
    ln -sf /etc/pki/akmods/private/akmods-persistent.priv /etc/pki/akmods/private/private_key.priv
    ln -sf /etc/pki/akmods/certs/akmods-persistent.der /etc/pki/akmods/certs/public_key.der

    echo "Persistent signing key injected. kmodgenca will reuse this key."
else
    echo "WARNING: No persistent akmods key provided. kmodgenca will generate a new key."
    echo "Modules will NOT load under Secure Boot until the new key is enrolled in MOK."
fi

# ============================================================
# Install tuxedo-drivers DKMS source and build kernel modules
# ============================================================
# The TUXEDO repo provides a DKMS source package
# (tuxedo-drivers-*.noarch.rpm) which installs source to
# /usr/src/tuxedo-drivers-<version>/. There is no
# akmod-tuxedo-drivers package in the TUXEDO repo for Fedora 44,
# so we build the modules manually from the DKMS source.

rpm-ostree install cpio

# Download and extract tuxedo-drivers DKMS source (avoid DKMS postinstall script)
curl -s -o /tmp/tuxedo-drivers.rpm https://rpm.tuxedocomputers.com/fedora/${RELEASE}/x86_64/base/tuxedo-drivers-4.22.1-1.fc43.noarch.rpm
mkdir -p /usr/src
cd /usr/src
rpm2cpio /tmp/tuxedo-drivers.rpm | cpio -idmv
cd /tmp

KERNEL_VERSION="$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
echo "Kernel version: ${KERNEL_VERSION}"

TUXEDO_SRC_DIR="$(ls -d /usr/src/tuxedo-drivers-* 2>/dev/null | head -1)"
if [ -z "${TUXEDO_SRC_DIR}" ]; then
    echo "ERROR: tuxedo-drivers source not found in /usr/src/"
    exit 1
fi
echo "Found tuxedo-drivers source at: ${TUXEDO_SRC_DIR}"

echo "Building tuxedo-drivers modules for kernel ${KERNEL_VERSION}..."
cd "${TUXEDO_SRC_DIR}"
make V=1 -C "/lib/modules/${KERNEL_VERSION}/build" M="${TUXEDO_SRC_DIR}" modules

MODULE_INSTALL_DIR="/lib/modules/${KERNEL_VERSION}/extra/tuxedo-drivers"
mkdir -p "${MODULE_INSTALL_DIR}"

# Install all built .ko files
find "${TUXEDO_SRC_DIR}" -name "*.ko" -exec install -D -m 755 {} "${MODULE_INSTALL_DIR}/" \;

# Sign the modules with the akmods key pair (for Secure Boot)
if [ -x "/lib/modules/${KERNEL_VERSION}/build/scripts/sign-file" ]; then
    echo "Signing tuxedo-drivers modules for Secure Boot..."
    SIGN_KEY="/etc/pki/akmods/private/private_key.priv"
    SIGN_CERT="/etc/pki/akmods/certs/public_key.der"
    find "${MODULE_INSTALL_DIR}" -name "*.ko" -exec \
        /lib/modules/${KERNEL_VERSION}/build/scripts/sign-file sha256 "${SIGN_KEY}" "${SIGN_CERT}" {} \;
    echo "tuxedo-drivers modules signed"
    # Compress signed modules
    find "${MODULE_INSTALL_DIR}" -name "*.ko" -exec xz -f {} \;
fi

depmod -a "${KERNEL_VERSION}"

echo "Verifying tuxedo-drivers module installation..."
find /lib/modules/${KERNEL_VERSION}/extra/tuxedo-drivers -name "*.ko*" | head -20

# ============================================================
# Build and install tuxedo-yt6801 network driver
# ============================================================
cd /tmp

echo "Cloning fixed yt6801 repository with kernel 6.15+ compatibility..."
git clone https://github.com/h4rm00n/yt6801-linux-driver
cd yt6801-linux-driver

echo "Source directory contents:"
ls -la

echo "Building yt6801 module manually for kernel ${KERNEL_VERSION}..."

BUILD_DIR="/tmp/_kmod_build_${KERNEL_VERSION}"
mkdir -p "${BUILD_DIR}"

if [ -d "src" ]; then
    echo "Copying src directory to build location..."
    cp -a src/* "${BUILD_DIR}/"
else
    echo "No src directory found, looking for source files in root..."
    find . -name "*.c" -o -name "*.h" -o -name "Makefile" | head -10
    echo "Copying source files to build directory..."
    find . -maxdepth 1 \( -name "*.c" -o -name "*.h" -o -name "Makefile" \) -exec cp {} "${BUILD_DIR}/" \;
fi

cd "${BUILD_DIR}"
make V=1 -C "/lib/modules/${KERNEL_VERSION}/build" M="${BUILD_DIR}" modules

MODULE_INSTALL_DIR="/lib/modules/${KERNEL_VERSION}/extra/tuxedo-yt6801"
mkdir -p "${MODULE_INSTALL_DIR}"

find "${BUILD_DIR}" -name "*.ko" -exec install -D -m 755 {} "${MODULE_INSTALL_DIR}/" \;

# Sign the yt6801 module with the akmods key pair (for Secure Boot)
if [ -x "/lib/modules/${KERNEL_VERSION}/build/scripts/sign-file" ]; then
    echo "Signing yt6801 module for Secure Boot..."
    SIGN_KEY="/etc/pki/akmods/private/private_key.priv"
    SIGN_CERT="/etc/pki/akmods/certs/public_key.der"
    find "${MODULE_INSTALL_DIR}" -name "*.ko" -exec \
        /lib/modules/${KERNEL_VERSION}/build/scripts/sign-file sha256 "${SIGN_KEY}" "${SIGN_CERT}" {} \;
    echo "yt6801 module signed"
    # Compress signed modules
    find "${MODULE_INSTALL_DIR}" -name "*.ko" -exec xz -f {} \;
fi

depmod -a "${KERNEL_VERSION}"

echo "yt6801 module installation completed"

echo "Verifying yt6801 module installation..."
find /lib/modules/${KERNEL_VERSION}/extra -name "*yt6801*" | head -5

echo "Checking if module is available to modinfo..."
modinfo yt6801 2>/dev/null && echo "yt6801 module found!" || echo "yt6801 module not found by modinfo"

# ============================================================
# Install and configure Tuxedo Control Center
# ============================================================
cd /tmp

# Hacky workaround to make TCC install elsewhere
mkdir -p /usr/share
rm /opt
ln -s /usr/share /opt

rpm-ostree install tuxedo-control-center

cd /
rm /opt
ln -s var/opt /opt
ls -al /

rm /usr/bin/tuxedo-control-center
ln -s /usr/share/tuxedo-control-center/tuxedo-control-center /usr/bin/tuxedo-control-center

sed -i 's|/opt|/usr/share|g' /etc/systemd/system/tccd.service
sed -i 's|/opt|/usr/share|g' /usr/share/applications/tuxedo-control-center.desktop

systemctl enable tccd.service
systemctl enable tccd-sleep.service

echo "Tuxedo drivers, yt6801, and Control Center installation completed!"
