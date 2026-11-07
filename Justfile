containerfile := "Containerfiles/bazzite-gnome-niri-nvidia/dx/Containerfile"
image_name := "tuxedo-bazzite-gnome-niri-nvidia"
podman_bin := if path_exists("/usr/bin/podman") == "true" { "/usr/bin/podman" } else { "docker" }

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    set -e
    find . -type f -name "*.just" -exec just --unstable --fmt --check -f {} \;
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" -exec just --unstable --fmt -f {} \;
    just --unstable --fmt -f Justfile

# Build the image locally.
# Export AKMODS_PRIVATE_KEY_FILE and AKMODS_PUBLIC_KEY_FILE to sign the
# kernel modules like CI does; without them the build runs unsigned
# (kmodgenca generates an ephemeral key, modules won't load under Secure
# Boot). Never point these at a file inside the build context.
[group('Utility')]
build tag="latest":
    #!/usr/bin/bash
    set -euo pipefail
    args=(--pull=newer --tag "${image_name}:${tag}" -f "${containerfile}" .)
    if [ -n "${AKMODS_PRIVATE_KEY_FILE:-}" ] && [ -n "${AKMODS_PUBLIC_KEY_FILE:-}" ]; then
        echo "Signing kernel modules with the provided key pair"
        args+=(--secret "id=akmods_private_key,src=${AKMODS_PRIVATE_KEY_FILE}")
        args+=(--secret "id=akmods_public_key,src=${AKMODS_PUBLIC_KEY_FILE}")
    else
        echo "WARNING: AKMODS_*_KEY_FILE not set - building WITHOUT module signing"
    fi
    "${podman_bin}" build "${args[@]}"
