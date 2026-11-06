#!/bin/bash
set -ouex pipefail

# ============================================================
# Install niri + noctalia + supporting packages
# ============================================================
# Base image is bazzite-gnome (GDM). niri ships its own
# wayland-session .desktop file which GDM auto-discovers,
# so niri appears as a session option in GDM alongside GNOME.

# Core: compositor + X11 compat + portals
dnf install -y \
    niri \
    xwayland-satellite \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
    gnome-keyring

# Shell: noctalia v5 (in Fedora 44+ official repos)
dnf install -y noctalia

# Desktop essentials (not provided by noctalia)
dnf install -y \
    kitty \
    nautilus \
    grim \
    slurp \
    wl-clipboard \
    pavucontrol \
    adwaita-cursor-theme

# ============================================================
# Install system-wide niri config
# ============================================================
mkdir -p /etc/niri
cp /tmp/niri-config.kdl /etc/niri/config.kdl

# Validate config syntax at build time
niri validate -c /etc/niri/config.kdl

# ============================================================
# setup-noctalia script + justfile command
# ============================================================
install -D -m 755 /tmp/setup-noctalia /usr/bin/setup-noctalia

mkdir -p /usr/share/just
cp /tmp/noctalia.just /usr/share/just/noctalia.just

# ============================================================
# setup-dgpu script + justfile command (NVIDIA variants only)
# Configures niri to render on the dGPU to eliminate lag on
# external monitors wired to the dGPU.
# Only installed when the files are present (NVIDIA niri variant).
# ============================================================
if [ -f /tmp/setup-dgpu ]; then
    install -D -m 755 /tmp/setup-dgpu /usr/bin/setup-dgpu
    cp /tmp/dgpu.just /usr/share/just/dgpu.just
fi

# ============================================================
# Qt theming for niri session
# ============================================================
mkdir -p /etc/environment.d
cat > /etc/environment.d/niri.conf << 'EOF'
QT_QPA_PLATFORM=wayland
QT_QPA_PLATFORMTHEME=qt6ct
EOF

# ============================================================
# First-login config provisioning via systemd-tmpfiles
# ============================================================
# Copies skeleton config to ~/.config/niri/config.kdl on first
# login (only if it doesn't already exist — type "C" = copy,
# non-overwriting). The "-" prefix ignores failures for system
# users whose home is a read-only runtime dir, e.g. the GDM greeter
# under /run/gdm/home/gdm-greeter.
mkdir -p /usr/share/user-tmpfiles.d
cat > /usr/share/user-tmpfiles.d/niri.conf << 'EOF'
C- %h/.config/niri/config.kdl - - - - /usr/share/niri/defaults/config.kdl
EOF

# User default config skeleton (includes system config + user overrides)
mkdir -p /usr/share/niri/defaults
cat > /usr/share/niri/defaults/config.kdl << 'EOF'
include "/etc/niri/config.kdl"

// Add your personal niri customizations below this line.
// The include above pulls in the system-wide defaults
// (cursor theme, noctalia autostart, blur, window rules).
EOF

# ============================================================
# Remove xwaylandvideobridge (causes blank window in niri)
# ============================================================
dnf remove -y xwaylandvideobridge 2>/dev/null || true

# Drop package-manager caches and build scratch (see build_tuxedo.sh).
dnf clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/cache/ldconfig
rm -rf /run/dnf /tmp/*
rm -f /var/log/dnf5.log
rm -rf /var/lib/dnf/repos /var/roothome/.cache/pip

echo "niri + noctalia installation completed!"