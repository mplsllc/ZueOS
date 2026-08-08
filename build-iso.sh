#!/usr/bin/env bash
#
# build-iso.sh — XueOS ISO Build Engine
#
# Builds a bootable, hybrid BIOS+UEFI live ISO for XueOS (a minimal XFCE
# spin of Ubuntu 24.04 "noble") using debootstrap + chroot + mksquashfs +
# xorriso/grub-mkrescue.
#
# Usage:
#   sudo ./build-iso.sh [--skip-bootstrap] [--keep-work]
#
#   --skip-bootstrap  Reuse an existing chroot instead of debootstrapping
#                      from scratch (fast iteration on the later stages).
#   --keep-work        Don't delete WORK_DIR on successful exit (debugging).
#
# Must be run as root — debootstrap, chroot, and mount all require it.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Setup & argument parsing
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=config/build.conf
source "${SCRIPT_DIR}/config/build.conf"

SKIP_BOOTSTRAP=0
KEEP_WORK=0
for arg in "$@"; do
    case "$arg" in
        --skip-bootstrap) SKIP_BOOTSTRAP=1 ;;
        --keep-work)      KEEP_WORK=1 ;;
        -h|--help)
            grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: build-iso.sh must be run as root (needed for debootstrap/chroot mounts)." >&2
    echo "  sudo ${0} $*" >&2
    exit 1
fi

log()   { printf '\033[1;32m[xueos-build]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[xueos-build][WARN]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[xueos-build][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

for bin in debootstrap mksquashfs xorriso grub-mkrescue chroot; do
    command -v "$bin" >/dev/null 2>&1 || fail "Required tool '$bin' not found. Install it (e.g. apt install debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools)."
done

# ---------------------------------------------------------------------------
# Cleanup trap — this is the safety net. It MUST be idempotent and MUST NOT
# fail even if only some mounts are present (e.g. we died mid-setup).
# ---------------------------------------------------------------------------

CHROOT_MOUNTS_ACTIVE=0

unmount_chroot() {
    # Unmount in reverse order of mounting. `|| true` on each — a mount that
    # was never made (or already torn down) must not abort the cleanup of
    # the rest.
    if [[ "${CHROOT_MOUNTS_ACTIVE}" -eq 1 ]]; then
        log "Unmounting chroot virtual filesystems..."
        umount -lf "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
        umount -lf "${CHROOT_DIR}/dev"     2>/dev/null || true
        umount -lf "${CHROOT_DIR}/sys"     2>/dev/null || true
        umount -lf "${CHROOT_DIR}/proc"    2>/dev/null || true
        umount -lf "${CHROOT_DIR}/run"     2>/dev/null || true
        # Belt-and-suspenders: anything else still mounted under the chroot.
        if mount | grep -q "${CHROOT_DIR}"; then
            warn "Stray mounts remain under ${CHROOT_DIR}, forcing lazy unmount."
            mount | awk -v d="${CHROOT_DIR}" '$3 ~ "^"d {print $3}' | sort -r | while read -r m; do
                umount -lf "$m" 2>/dev/null || true
            done
        fi
    fi
    CHROOT_MOUNTS_ACTIVE=0
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    unmount_chroot
    if [[ "${KEEP_WORK}" -eq 0 && "${exit_code}" -eq 0 ]]; then
        log "Cleaning up work directory (${WORK_DIR})..."
        rm -rf --one-file-system "${ISO_STAGING_DIR}" 2>/dev/null || true
        # Chroot is left in place on success only if --skip-bootstrap will be
        # wanted next time; here we remove it too for a fully clean state.
        rm -rf --one-file-system "${CHROOT_DIR}" 2>/dev/null || true
    elif [[ "${exit_code}" -ne 0 ]]; then
        warn "Build failed (exit ${exit_code}). Leaving ${WORK_DIR} in place for inspection."
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Stage 0: prep directories
# ---------------------------------------------------------------------------

log "Preparing work directories under ${WORK_DIR}"
mkdir -p "${CHROOT_DIR}" "${ISO_STAGING_DIR}" "${OUTPUT_DIR}" "${WEB_PUBLISH_DIR}"

# ---------------------------------------------------------------------------
# Stage 1: debootstrap base system
# ---------------------------------------------------------------------------

if [[ "${SKIP_BOOTSTRAP}" -eq 1 && -x "${CHROOT_DIR}/bin/bash" ]]; then
    log "Skipping debootstrap, reusing existing chroot at ${CHROOT_DIR}"
else
    log "Running debootstrap (${DISTRO_CODENAME}/${DISTRO_ARCH})..."
    rm -rf --one-file-system "${CHROOT_DIR}"
    mkdir -p "${CHROOT_DIR}"
    debootstrap --arch="${DISTRO_ARCH}" --variant=minbase \
        "${DISTRO_CODENAME}" "${CHROOT_DIR}" "${DISTRO_MIRROR}"
fi

# ---------------------------------------------------------------------------
# Stage 2: mount virtual filesystems for chroot
# ---------------------------------------------------------------------------

log "Bind-mounting virtual filesystems into chroot"
mount --bind /dev "${CHROOT_DIR}/dev"
mount --bind /run "${CHROOT_DIR}/run" 2>/dev/null || mount -t tmpfs tmpfs "${CHROOT_DIR}/run"
mount -t proc  proc  "${CHROOT_DIR}/proc"
mount -t sysfs sysfs "${CHROOT_DIR}/sys"
mount -t devpts devpts "${CHROOT_DIR}/dev/pts"
CHROOT_MOUNTS_ACTIVE=1

# Keep DNS working inside the chroot for apt/git.
install -m 0644 /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

# Prevent daemons from trying to start during package installs inside chroot.
cat > "${CHROOT_DIR}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${CHROOT_DIR}/usr/sbin/policy-rc.d"

# ---------------------------------------------------------------------------
# Stage 3: apt sources + base configuration inside chroot
# ---------------------------------------------------------------------------

log "Writing apt sources.list"
cat > "${CHROOT_DIR}/etc/apt/sources.list" <<EOF
deb ${DISTRO_MIRROR} ${DISTRO_CODENAME} main restricted universe multiverse
deb ${DISTRO_MIRROR} ${DISTRO_CODENAME}-updates main restricted universe multiverse
deb ${DISTRO_MIRROR} ${DISTRO_CODENAME}-security main restricted universe multiverse
EOF

log "Blocking snapd via apt pin preference"
cat > "${CHROOT_DIR}/etc/apt/preferences.d/no-snapd.pref" <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -1
EOF

# apt/dpkg config: no recommends, no docs/man to keep the image lean.
cat > "${CHROOT_DIR}/etc/apt/apt.conf.d/99xueos-no-recommends" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

# Run a command inside the chroot with a clean, non-interactive environment.
in_chroot() {
    chroot "${CHROOT_DIR}" env \
        DEBIAN_FRONTEND=noninteractive \
        DEBCONF_NONINTERACTIVE_SEEN=true \
        HOME=/root \
        LC_ALL=C \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}

log "Updating apt cache inside chroot"
in_chroot apt-get update

log "Setting hostname"
echo "xueos" > "${CHROOT_DIR}/etc/hostname"
cat > "${CHROOT_DIR}/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   xueos
EOF

# ---------------------------------------------------------------------------
# Stage 4: install package sets (base, live-boot, XFCE, dev headers)
# ---------------------------------------------------------------------------

install_pkgs() {
    local csv="$1"
    local pkgs
    pkgs="$(echo "$csv" | tr ',' ' ')"
    log "Installing: ${pkgs}"
    # shellcheck disable=SC2086
    in_chroot apt-get install -y --no-install-recommends ${pkgs}
}

install_pkgs "${BASE_PACKAGES}"

# locale-gen ships in the "locales" package (part of BASE_PACKAGES above),
# not in the debootstrap --variant=minbase base system, so this can't run
# any earlier than here.
log "Generating locale"
in_chroot locale-gen en_US.UTF-8
in_chroot update-locale LANG=en_US.UTF-8

install_pkgs "${LIVE_BOOT_PACKAGES}"
install_pkgs "${XFCE_PACKAGES}"
install_pkgs "${DEV_PACKAGES}"

# Ubuntu's own "firefox" package in the noble archive is a transitional
# stub that depends on snapd — a non-starter since we block snapd outright.
# Pull the real .deb from Mozilla's own APT repo instead (same fix Mint and
# Zorin use), pinned above the Ubuntu archive so `apt install firefox`
# resolves to Mozilla's build rather than the snap stub. This is a
# placeholder browser until Besra is buildable/installable on the image.
log "Adding Mozilla APT repo for a non-snap Firefox"
mkdir -p "${CHROOT_DIR}/etc/apt/keyrings"
in_chroot install -d -m 0755 /etc/apt/keyrings
in_chroot bash -c 'curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc'
cat > "${CHROOT_DIR}/etc/apt/sources.list.d/mozilla.list" <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF
cat > "${CHROOT_DIR}/etc/apt/preferences.d/mozilla.pref" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
in_chroot apt-get update
install_pkgs "firefox"

# Wire up the XueOS apt repo (apt.mp.ls, distribution "${APTLY_DISTRIBUTION}")
# so it's present on every image from day one, ready for Besra once it has
# a real build. It's currently an empty, published-but-packageless
# distribution — nothing gets installed from it here, just the source.
log "Adding XueOS apt repo (${APT_PUBLIC_URL}, distribution ${APTLY_DISTRIBUTION})"
in_chroot install -d -m 0755 /etc/apt/keyrings
cp "${APTLY_ROOT}/public/apt-key.asc" "${CHROOT_DIR}/etc/apt/keyrings/xueos.asc"
cat > "${CHROOT_DIR}/etc/apt/sources.list.d/xueos.list" <<EOF
deb [signed-by=/etc/apt/keyrings/xueos.asc] ${APT_PUBLIC_URL} ${APTLY_DISTRIBUTION} ${APTLY_COMPONENT}
EOF
in_chroot apt-get update

log "Purging blocked packages: ${BLOCKED_PACKAGES}"
# shellcheck disable=SC2086
in_chroot apt-get purge -y ${BLOCKED_PACKAGES} || true
in_chroot apt-get autoremove -y --purge

# Belt-and-suspenders: even if something pulls snapd back in later, this
# stops it from ever being able to install.
mkdir -p "${CHROOT_DIR}/etc/apt/preferences.d"
rm -rf "${CHROOT_DIR}/snap" "${CHROOT_DIR}/var/snap" "${CHROOT_DIR}/var/lib/snapd" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 5: branding overlay (identity, wallpapers, icons, Plymouth splash,
# LightDM theming). Applied BEFORE user creation so /etc/skel additions
# (the wallpaper-setup autostart entry) get picked up by `useradd -m`, and
# BEFORE the kernel/initrd are copied out in Stage 9 so `update-initramfs`
# bakes the new Plymouth theme into the initrd that actually ships.
# ---------------------------------------------------------------------------

OVERLAY_DIR="${SCRIPT_DIR}/overlay"
if [[ -d "${OVERLAY_DIR}" ]]; then
    log "Applying branding overlay from ${OVERLAY_DIR}"
    cp -a "${OVERLAY_DIR}/." "${CHROOT_DIR}/"

    log "Refreshing icon cache and setting Plymouth theme"
    in_chroot gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
    if in_chroot which plymouth-set-default-theme >/dev/null 2>&1; then
        in_chroot plymouth-set-default-theme -R xueos \
            || warn "plymouth-set-default-theme failed (is 'plymouth' installed? check LIVE_BOOT_PACKAGES)"
    else
        warn "plymouth-set-default-theme not found; skipping splash theme activation"
    fi
else
    warn "No overlay/ directory found at ${OVERLAY_DIR}, skipping branding"
fi

# ---------------------------------------------------------------------------
# Stage 6: default user, autologin, passwordless sudo
# ---------------------------------------------------------------------------

log "Creating default user '${DEFAULT_USER}'"
in_chroot useradd -m -s /bin/bash -G sudo,plugdev,netdev "${DEFAULT_USER}"
echo "${DEFAULT_USER}:${DEFAULT_USER_PASSWORD}" | in_chroot chpasswd

cat > "${CHROOT_DIR}/etc/sudoers.d/90-xueos-user" <<EOF
${DEFAULT_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "${CHROOT_DIR}/etc/sudoers.d/90-xueos-user"

log "Configuring lightdm autologin for '${DEFAULT_USER}'"
mkdir -p "${CHROOT_DIR}/etc/lightdm/lightdm.conf.d"
cat > "${CHROOT_DIR}/etc/lightdm/lightdm.conf.d/50-xueos-autologin.conf" <<EOF
[Seat:*]
autologin-user=${DEFAULT_USER}
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF

# ---------------------------------------------------------------------------
# Stage 7: developer environment — clone repos into /opt/xfce-dev
# ---------------------------------------------------------------------------

log "Setting up /opt/xfce-dev"
mkdir -p "${CHROOT_DIR}/opt/xfce-dev"
in_chroot chown "${DEFAULT_USER}:${DEFAULT_USER}" /opt/xfce-dev

echo "${DEV_REPOS}" | while IFS='|' read -r name url; do
    [[ -z "${name// }" ]] && continue
    log "Cloning ${name} -> /opt/xfce-dev/${name}"
    in_chroot runuser -u "${DEFAULT_USER}" -- git clone --depth=1 "${url}" "/opt/xfce-dev/${name}" \
        || warn "Failed to clone ${name} from ${url} (continuing build)"
done

# ---------------------------------------------------------------------------
# Stage 8: live-boot casper hooks + cleanup inside chroot
# ---------------------------------------------------------------------------

log "Configuring casper live-boot hostname/hooks"
echo "xueos" > "${CHROOT_DIR}/etc/casper.conf" 2>/dev/null || true

log "Cleaning apt caches inside chroot to shrink image"
in_chroot apt-get clean
rm -rf "${CHROOT_DIR}"/var/lib/apt/lists/* "${CHROOT_DIR}"/tmp/* 2>/dev/null || true
rm -f "${CHROOT_DIR}/etc/resolv.conf" "${CHROOT_DIR}/usr/sbin/policy-rc.d"

# ---------------------------------------------------------------------------
# Stage 9: unmount before we start reading the chroot as a plain directory
# tree for squashfs (mksquashfs on a live-mounted proc/sys can capture
# host-visible cruft and is generally a bad idea).
# ---------------------------------------------------------------------------

unmount_chroot

# ---------------------------------------------------------------------------
# Stage 10: build squashfs + ISO staging tree
# ---------------------------------------------------------------------------

log "Assembling ISO staging tree at ${ISO_STAGING_DIR}"
rm -rf --one-file-system "${ISO_STAGING_DIR}"
mkdir -p "${ISO_STAGING_DIR}"/{casper,isolinux,boot/grub}

log "Copying kernel + initrd into staging tree"
KERNEL_IMG="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
INITRD_IMG="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -n1)"
[[ -n "${KERNEL_IMG}" ]] || fail "No kernel image found in chroot /boot"
[[ -n "${INITRD_IMG}" ]] || fail "No initrd image found in chroot /boot"
cp "${KERNEL_IMG}" "${ISO_STAGING_DIR}/casper/vmlinuz"
cp "${INITRD_IMG}" "${ISO_STAGING_DIR}/casper/initrd"

log "Generating squashfs filesystem.squashfs (this can take a while)"
mksquashfs "${CHROOT_DIR}" "${ISO_STAGING_DIR}/casper/filesystem.squashfs" \
    -comp xz -noappend \
    -e boot

printf '%s' "$(du -sx --block-size=1 "${CHROOT_DIR}" | cut -f1)" > "${ISO_STAGING_DIR}/casper/filesystem.size"

log "Writing manifest"
in_chroot dpkg-query -W --showformat='${Package} ${Version}\n' > "${ISO_STAGING_DIR}/casper/filesystem.manifest" 2>/dev/null || \
    chroot "${CHROOT_DIR}" dpkg-query -W --showformat='${Package} ${Version}\n' > "${ISO_STAGING_DIR}/casper/filesystem.manifest"

# ---------------------------------------------------------------------------
# Stage 11: GRUB config for hybrid BIOS+UEFI boot
# ---------------------------------------------------------------------------

log "Writing GRUB config"
cat > "${ISO_STAGING_DIR}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "${XUEOS_NAME} ${XUEOS_VERSION} (live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "${XUEOS_NAME} ${XUEOS_VERSION} (safe graphics)" {
    linux /casper/vmlinuz boot=casper xforcevesa quiet splash ---
    initrd /casper/initrd
}
EOF

# ---------------------------------------------------------------------------
# Stage 12: build hybrid BIOS+UEFI ISO with grub-mkrescue + xorriso
# ---------------------------------------------------------------------------

log "Building hybrid BIOS+UEFI ISO with grub-mkrescue"
OUTPUT_ISO="${OUTPUT_DIR}/${ISO_FILENAME}"
rm -f "${OUTPUT_ISO}"

grub-mkrescue -o "${OUTPUT_ISO}" "${ISO_STAGING_DIR}" \
    -volid "${ISO_LABEL}" \
    -- \
    -partition_offset 16

[[ -s "${OUTPUT_ISO}" ]] || fail "grub-mkrescue did not produce ${OUTPUT_ISO}"

log "ISO built: ${OUTPUT_ISO} ($(du -h "${OUTPUT_ISO}" | cut -f1))"

# ---------------------------------------------------------------------------
# Stage 13: publish to web-accessible directory
# ---------------------------------------------------------------------------

log "Publishing ISO to ${WEB_PUBLISH_DIR}"
mkdir -p "${WEB_PUBLISH_DIR}"
install -m 0644 "${OUTPUT_ISO}" "${WEB_PUBLISH_DIR}/${ISO_FILENAME}"
sha256sum "${OUTPUT_ISO}" | awk '{print $1}' > "${WEB_PUBLISH_DIR}/${ISO_FILENAME}.sha256"

log "Done. ISO published at ${WEB_PUBLISH_DIR}/${ISO_FILENAME}"
# `cleanup` runs automatically via the EXIT trap from here.
