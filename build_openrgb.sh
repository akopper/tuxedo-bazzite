#!/bin/bash
# Build the Fedora "openrgb" RPM with one extra HID detector so OpenRGB
# recognises the TUXEDO/Clevo per-key RGB keyboard with USB PID 0x6004.
#
# This script runs in a throwaway builder stage (see Containerfile). Only the
# finished RPM is copied into the final image, so neither the Qt5 toolchain
# nor the ~250 build-dependency packages end up there.

set -ouex pipefail

workdir=/tmp/openrgb-build
mkdir -p "${workdir}" /out
cd "${workdir}"

# rpm-build for rpmbuild, dnf-plugins-core for "dnf download"/"builddep",
# forge-srpm-macros because the Fedora spec uses %forgemeta/%forgeautosetup.
dnf -y install rpm-build dnf-plugins-core forge-srpm-macros

# Same source release as the package in the base image's Fedora repos.
dnf -y download --source --enablerepo=fedora-source,updates-source openrgb
rpm2cpio ./*.src.rpm | cpio -idm --quiet
rm -f ./*.src.rpm

dnf -y builddep ./*.spec

# rpmbuild reads Source/Patch files from <topdir>/SOURCES. The _topdir define
# below points at ${workdir}/rpmbuild, so the extracted tarball and our patch
# have to be placed there.
mkdir -p "${workdir}/rpmbuild/SOURCES"
cp ./*.tar.* "${workdir}/rpmbuild/SOURCES/"
cp /tmp/openrgb-tuxedo-6004.patch "${workdir}/rpmbuild/SOURCES/"

# %forgeautosetup (from forge-srpm-macros) picks Patch0 up automatically.
sed -i 's|^Source: .*|&\nPatch0:         openrgb-tuxedo-6004.patch|' ./*.spec
# Do not pin the build to the base image's openrgb-udev-rules version:
# Fedora updates both packages independently and rpm-ostree would then
# refuse the layered override. The base image already ships the rules.
sed -i '/^Requires: *%{name}-udev-rules/d' ./*.spec

rpmbuild -bb \
    --define "_topdir ${workdir}/rpmbuild" \
    --define "_rpmdir ${workdir}/rpms" \
    --define "debug_package %{nil}" \
    ./*.spec

# Only the main package (openrgb-<version>...): the udev rules already come
# from the base image's openrgb-udev-rules, shipping them twice would be a
# file conflict. debuginfo/debugsource are not built (debug_package above).
for f in "${workdir}"/rpms/*/openrgb-[0-9]*.rpm; do
    cp "${f}" /out/openrgb.rpm
done

test -s /out/openrgb.rpm
