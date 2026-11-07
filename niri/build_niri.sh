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
# Kumiko theme (optional, `ujust setup-kumiko`)
# ============================================================
# Ships a self-generated Art-Deco/kumiko wallpaper, a custom Noctalia
# palette and a pinned niri theme. Nothing is enabled by default; the
# ujust command installs it into the user's config and switches Noctalia.
install -D -m 755 /tmp/setup-kumiko /usr/bin/setup-kumiko
install -D -m 644 /tmp/theme-kumiko.kdl /usr/share/kumiko/theme-kumiko.kdl
install -D -m 644 /tmp/Kumiko.json /usr/share/kumiko/Kumiko.json
install -D -m 644 /tmp/kumiko-deco.svg /usr/share/kumiko/kumiko-deco.svg
install -D -m 644 /tmp/kumiko-deco-3840x2160.png /usr/share/kumiko/kumiko-deco-3840x2160.png
install -D -m 644 /tmp/kumiko-deco-2560x1440.png /usr/share/kumiko/kumiko-deco-2560x1440.png
cp /tmp/kumiko.just /usr/share/just/kumiko.just

# Validate the theme fragment together with the system config.
printf 'include "/etc/niri/config.kdl"\ninclude "/usr/share/kumiko/theme-kumiko.kdl"\n' >/tmp/kumiko-validate.kdl
niri validate -c /tmp/kumiko-validate.kdl
rm -f /tmp/kumiko-validate.kdl

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

# Noctalia ships a native polkit authentication agent but leaves it
# disabled by default, because most desktops bring their own. niri does
# not, so without an agent every pkexec action - TCC profile/settings
# saves, prime-select, the shutdown timer - fails without ever showing a
# password prompt. Seed the Noctalia agent as a first-login default;
# users can still turn it off again in Settings -> Security.
mkdir -p /usr/share/noctalia/defaults
cat > /usr/share/noctalia/defaults/config.toml << 'EOF'
# niri has no polkit agent of its own, so register Noctalia's built-in one.
[shell]
polkit_agent = true
EOF

# Fail at build time rather than at login if the schema changes.
noctalia config validate /usr/share/noctalia/defaults/config.toml

cat > /usr/share/user-tmpfiles.d/noctalia.conf << 'EOF'
C- %h/.config/noctalia/config.toml - - - - /usr/share/noctalia/defaults/config.toml
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