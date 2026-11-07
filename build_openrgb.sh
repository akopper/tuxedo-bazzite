#!/bin/bash
# Build the Fedora "openrgb" RPM from a newer upstream commit: the release
# shipped in the base image's Fedora repos misassigns most keys of the
# TUXEDO/Clevo per-key RGB keyboard (USB PID 0x6004). The patch adds the
# 0x6004 detector, the measured LED map of the Stellaris/Polaris Gen4 and a
# sysfs controller for the TUXEDO/Uniwill front lightbar.
#
# This script runs in a throwaway builder stage (see Containerfile). Only the
# finished RPM is copied into the final image, so neither the Qt5 toolchain
# nor the ~250 build-dependency packages end up there.

set -ouex pipefail

# Upstream commit with the fixed Clevo keyboard layout plus per-model maps.
openrgb_commit=e152374ccde52545d2a7c2e43d0f980a134e88db

workdir=/tmp/openrgb-build
mkdir -p "${workdir}" /out
cd "${workdir}"

# rpm-build for rpmbuild, dnf-plugins-core for "dnf download"/"builddep",
# forge-srpm-macros because the Fedora spec uses %forgemeta/%forgeautosetup,
# curl for the upstream archive.
dnf -y install rpm-build dnf-plugins-core forge-srpm-macros curl

# The spec of the packaged release, but built from the pinned upstream commit.
dnf -y download --source --enablerepo=fedora-source,updates-source openrgb
rpm2cpio ./*.src.rpm | cpio -idm --quiet
rm -f ./*.src.rpm ./*.tar.*
sed -i "s|^%global commit .*|%global commit ${openrgb_commit}|" ./*.spec

dnf -y builddep ./*.spec

# rpmbuild reads Source/Patch files from <topdir>/SOURCES. The _topdir define
# below points at ${workdir}/rpmbuild, so the extracted tarball and our patch
# have to be placed there.
mkdir -p "${workdir}/rpmbuild/SOURCES"
curl -fL --retry 3 -o "${workdir}/rpmbuild/SOURCES/OpenRGB-${openrgb_commit}.tar.bz2" \
    "https://gitlab.com/CalcProgrammer1/OpenRGB/-/archive/${openrgb_commit}/OpenRGB-${openrgb_commit}.tar.bz2"
cp /tmp/openrgb-tuxedo-6004.patch "${workdir}/rpmbuild/SOURCES/"

# %forgeautosetup (from forge-srpm-macros) picks Patch0 up automatically.
sed -i 's|^Source: .*|&\nPatch0:         openrgb-tuxedo-6004.patch|' ./*.spec

# Drop the udev-rules subpackage: the udev rules generator is not part of the
# source tree anymore (the Fedora spec expects the installed file), and the
# base image already ships openrgb-udev-rules. Leaving the subpackage in would
# fail at %files and would also pin the main package to a rules version that
# dnf may refuse to layer.
python3 - ./*.spec <<'PYEOF'
import re, sys

path = sys.argv[1]
text = open(path).read()

text = re.sub(r"^Requires:\s+%\{name\}-udev-rules.*$\n", "", text, flags=re.M)
text = re.sub(r"^%package\s+udev-rules.*?(?=^%prep$)", "", text, flags=re.S | re.M)
text = re.sub(r"^%post -n %\{name\}-udev-rules.*?(?=^%post$)", "", text, flags=re.S | re.M)
text = re.sub(r"^%files udev-rules.*?(?=^%changelog$)", "", text, flags=re.S | re.M)

open(path, "w").write(text)
PYEOF

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
