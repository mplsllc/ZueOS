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

# This host's root umask is 027, which makes every file this script writes
# via heredoc/redirection (cat > file <<EOF) come out 640 instead of 644.
# That silently broke lightdm autologin: lightdm runs as its own dedicated
# user (uid/gid 103, not root and not in the root group), so it couldn't
# even read /etc/lightdm/lightdm.conf.d/50-xueos-autologin.conf — LightDM
# has no error message for this, it just falls back to the normal greeter.
# Same root cause explains the recurring "couldn't be accessed by user
# '_apt'" warnings throughout every build log, previously dismissed as
# cosmetic. Force a sane umask for the rest of the script rather than
# chmod every individual heredoc-written file.
umask 022

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
# deb-src lines are what make this a *dev* environment rather than just a
# desktop — without them, `apt source <pkg>`/`apt build-dep <pkg>` (the
# normal way to grab the exact upstream source matching an installed
# package and its build deps) don't work at all.
cat > "${CHROOT_DIR}/etc/apt/sources.list" <<EOF
deb ${DISTRO_MIRROR} ${DISTRO_CODENAME} main restricted universe multiverse
deb-src ${DISTRO_MIRROR} ${DISTRO_CODENAME} main restricted universe multiverse
deb ${DISTRO_MIRROR} ${DISTRO_CODENAME}-updates main restricted universe multiverse
deb-src ${DISTRO_MIRROR} ${DISTRO_CODENAME}-updates main restricted universe multiverse
deb ${DISTRO_MIRROR} ${DISTRO_CODENAME}-security main restricted universe multiverse
deb-src ${DISTRO_MIRROR} ${DISTRO_CODENAME}-security main restricted universe multiverse
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
    local -a pkgs
    IFS=',' read -ra pkgs <<< "$csv"
    log "Installing: ${pkgs[*]}"
    in_chroot apt-get install -y --no-install-recommends "${pkgs[@]}"
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

# Xubuntu's own staging PPA carries newer/pre-release XFCE builds ahead of
# what's in the stable Ubuntu archive (confirmed current: XFCE 4.20 for
# noble, https://launchpad.net/~xubuntu-dev/+archive/ubuntu/staging) — the
# obvious thing to have on an "XFCE dev environment" image. Added via
# add-apt-repository (needs software-properties-common) rather than
# hand-rolling the Launchpad signing key ourselves, since that's exactly
# what it's for and avoids hardcoding a key fingerprint that could be wrong
# or rotate. Pinned BELOW the default archive priority so it's opt-in
# (`apt install -t noble <pkg>`) rather than silently overriding stable
# packages on a routine `apt upgrade`.
log "Adding Xubuntu staging PPA (pre-release XFCE builds)"
install_pkgs "software-properties-common"
in_chroot add-apt-repository -y ppa:xubuntu-dev/staging
cat > "${CHROOT_DIR}/etc/apt/preferences.d/xubuntu-staging.pref" <<'EOF'
Package: *
Pin: release o=LP-PPA-xubuntu-dev-staging
Pin-Priority: 100
EOF
in_chroot apt-get update
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
# apt's `signed-by` needs a binary keybox, not ASCII-armored text — Mozilla's
# key is armored. apt would otherwise shell out to apt-key/gpg to dearmor it
# at verify-time, failing with a cryptic "Unknown error executing apt-key" if
# gnupg isn't around yet at that point in the build. Dearmor on the HOST
# instead (gpg is always available there for aptly) rather than depend on
# install ordering relative to software-properties-common below.
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
    | gpg --dearmor > "${CHROOT_DIR}/etc/apt/keyrings/packages.mozilla.org.gpg"
cat > "${CHROOT_DIR}/etc/apt/sources.list.d/mozilla.list" <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main
EOF
cat > "${CHROOT_DIR}/etc/apt/preferences.d/mozilla.pref" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
in_chroot apt-get update
install_pkgs "firefox"

# XFCE's own community chat is on Matrix, so a Matrix client is the natural
# default for a "come develop XFCE with us" image. Element's official repo
# (confirmed current: https://packages.element.io/debian/) already ships a
# binary (not armored) keyring, so no host-side dearmor step needed here.
log "Adding Element's APT repo for Matrix chat (XFCE's community chat is on Matrix)"
in_chroot install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.element.io/debian/element-io-archive-keyring.gpg \
    -o "${CHROOT_DIR}/etc/apt/keyrings/element-io-archive-keyring.gpg"
cat > "${CHROOT_DIR}/etc/apt/sources.list.d/element-io.list" <<'EOF'
deb [signed-by=/etc/apt/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main
EOF
in_chroot apt-get update
install_pkgs "element-desktop"

# Wire up the XueOS apt repo (apt.mp.ls, distribution "${APTLY_DISTRIBUTION}")
# so it's present on every image from day one, ready for Besra once it has
# a real build. It's currently an empty, published-but-packageless
# distribution — nothing gets installed from it here, just the source.
log "Adding XueOS apt repo (${APT_PUBLIC_URL}, distribution ${APTLY_DISTRIBUTION})"
in_chroot install -d -m 0755 /etc/apt/keyrings
# Same armored-vs-binary issue as Mozilla's key above — dearmor on the host.
gpg --dearmor < "${APTLY_ROOT}/public/apt-key.asc" > "${CHROOT_DIR}/etc/apt/keyrings/xueos.gpg"
cat > "${CHROOT_DIR}/etc/apt/sources.list.d/xueos.list" <<EOF
deb [signed-by=/etc/apt/keyrings/xueos.gpg] ${APT_PUBLIC_URL} ${APTLY_DISTRIBUTION} ${APTLY_COMPONENT}
EOF
in_chroot apt-get update

log "Purging blocked packages: ${BLOCKED_PACKAGES}"
declare -a blocked_pkgs
IFS=',' read -ra blocked_pkgs <<< "${BLOCKED_PACKAGES}"
in_chroot apt-get purge -y "${blocked_pkgs[@]}" || true
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

    log "Refreshing icon cache and registering XueOS Plymouth theme"
    in_chroot gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
    # Ubuntu 24.04's plymouth package has no plymouth-set-default-theme
    # binary (that's an older/Debian-era tool) — the real mechanism is the
    # same update-alternatives dance every plymouth-theme-* package uses.
    in_chroot update-alternatives \
        --install /usr/share/plymouth/themes/default.plymouth default.plymouth \
        /usr/share/plymouth/themes/xueos/xueos.plymouth 150 \
        || warn "Failed to register XueOS plymouth theme via update-alternatives"
else
    warn "No overlay/ directory found at ${OVERLAY_DIR}, skipping branding"
fi

# Force initrd (re)generation for every installed kernel. This is NOT just
# for the Plymouth theme above — it's required unconditionally. Discovered
# by testing: the kernel package's own postinst trigger (initramfs-tools)
# fires during Stage 4's install but silently does nothing, because
# `update-initramfs -u` (which the trigger calls) only refreshes an initrd
# that already exists; nothing in this chroot ever runs the `-c` (create)
# that a normal non-chroot install gets from the kernel postinst hook. Without
# this, /boot/initrd.img-* never exists at all and Stage 10 fails outright.
log "Generating initramfs for installed kernel(s)"
in_chroot update-initramfs -c -k all \
    || fail "update-initramfs failed to generate an initrd — live boot would not work"

# ---------------------------------------------------------------------------
# Stage 6: default user, autologin, passwordless sudo
# ---------------------------------------------------------------------------

log "Creating default user '${DEFAULT_USER}'"
# plugdev/netdev are normally created by systemd-sysusers at boot, which
# never runs inside a chroot (no services start here — see policy-rc.d
# above). sudo's own postinst creates the "sudo" group directly so that one
# is already there, but the other two need creating by hand.
for g in sudo plugdev netdev; do
    in_chroot getent group "$g" >/dev/null 2>&1 || in_chroot groupadd --system "$g"
done
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
# casper.conf isn't documentation — it's sourced as shell by the
# casper-bottom initramfs hooks (25adduser, 15autologin, 18hostname) that
# actually create the live-session user and wire up autologin at boot.
# It was previously just the bare word "xueos" (invalid shell), which left
# $USERNAME empty: 25adduser silently no-ops (no user gets configured) and
# 15autologin writes an empty "autologin-user=" into lightdm.conf — that's
# why the live session was falling back to a login prompt instead of
# autologin.
cat > "${CHROOT_DIR}/etc/casper.conf" <<EOF
export USERNAME="${DEFAULT_USER}"
export USERFULLNAME="${XUEOS_NAME} Live User"
export HOST="xueos"
export BUILD_SYSTEM="Ubuntu"
EOF

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

# /boot must NOT be excluded here, despite casper/vmlinuz+casper/initrd
# above already covering the live-boot GRUB menu. Those two serve a
# completely different purpose: they're what GRUB loads to boot the LIVE
# session before the squashfs is even mounted. What ships INSIDE the
# squashfs is what Calamares' unpackfs module copies onto the TARGET DISK
# during an actual install — excluding /boot there meant an installed
# system would have empty /boot: no kernel, no initrd, unbootable.
# Confirmed by actually running the installer: "shellprocess@initrd_
# placeholder" failed with "No such file or directory" because /boot on
# the target didn't exist AT ALL after unpackfs ran.
log "Generating squashfs filesystem.squashfs (this can take a while)"
mksquashfs "${CHROOT_DIR}" "${ISO_STAGING_DIR}/casper/filesystem.squashfs" \
    -comp xz -noappend

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

# "-partition_offset 16" (as two bare tokens) is NOT valid xorriso syntax —
# confirmed by testing directly: xorriso rejects it as an unknown command.
# The actual syntax is "-boot_image any partition_offset=16".
grub-mkrescue -o "${OUTPUT_ISO}" "${ISO_STAGING_DIR}" \
    -volid "${ISO_LABEL}" \
    -- \
    -boot_image any partition_offset=16

[[ -s "${OUTPUT_ISO}" ]] || fail "grub-mkrescue did not produce ${OUTPUT_ISO}"

log "ISO built: ${OUTPUT_ISO} ($(du -h "${OUTPUT_ISO}" | cut -f1))"

# ---------------------------------------------------------------------------
# Stage 13: publish to web-accessible directory
# ---------------------------------------------------------------------------

log "Publishing ISO to ${WEB_PUBLISH_DIR}"
mkdir -p "${WEB_PUBLISH_DIR}"
install -m 0644 "${OUTPUT_ISO}" "${WEB_PUBLISH_DIR}/${ISO_FILENAME}"
# Plain redirection inherits root's default umask (came out 640, a 403 for
# nginx's www-data) — write to a temp file and `install` it instead, same as
# the ISO above, so it actually gets world-readable perms.
sha256sum "${OUTPUT_ISO}" | awk '{print $1}' > "${WORK_DIR}/${ISO_FILENAME}.sha256"
install -m 0644 "${WORK_DIR}/${ISO_FILENAME}.sha256" "${WEB_PUBLISH_DIR}/${ISO_FILENAME}.sha256"

log "Done. ISO published at ${WEB_PUBLISH_DIR}/${ISO_FILENAME}"
# `cleanup` runs automatically via the EXIT trap from here.
