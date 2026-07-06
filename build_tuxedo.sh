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
# Inject persistent akmods signing key (prevents kmodgenca from generating a new key)
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
# Install tuxedo-drivers via akmod (triggers akmods-ostree-post to build+sign kmods)
# ============================================================
# Installing akmod-tuxedo-drivers triggers its %post script which calls
# akmods-ostree-post, which builds the kmod for the current kernel
# and signs it with the key at /etc/pki/akmods/certs/public_key.der
rpm-ostree install akmod-tuxedo-drivers

# Verify modules were built
KERNEL_VERSION="$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
echo "Kernel version: ${KERNEL_VERSION}"
echo "Checking for built tuxedo modules..."
find /lib/modules/${KERNEL_VERSION}/extra/tuxedo-drivers -name "*.ko.xz" 2>/dev/null || {
    echo "WARNING: tuxedo-drivers kmod not found after akmod installation"
    echo "Checking if akmods-ostree-post ran..."
    find /lib/modules -path "*/tuxedo-drivers/*" -name "*.ko*" 2>/dev/null | head -10
}

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
