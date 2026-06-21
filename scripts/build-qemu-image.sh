#!/bin/sh
#
# Layer 2a: build a QEMU-bootable OpenWrt image that mirrors the Beryl AX
# configuration on a target QEMU can actually emulate.
#
# The real device is a MediaTek MT7981 (mediatek/filogic) for which QEMU has
# no machine model. Instead we build the ARM SystemReady target (armsr/armv8,
# also aarch64) with the SAME packages.txt and the SAME files/ overlay. This
# lets QEMU validate the configuration and userspace package selection.
#
# Hardware-specific kernel modules (kmod-*) are dropped: they are tied to the
# MT7981 kernel/Wi-Fi and cannot be tested in QEMU anyway. The locally built
# gl-fan package is dropped too: it is not in the standard armsr feed and is a
# no-op without the device's fan/thermal sysfs. The static layer
# (validate-static.sh) already verifies all of these in the real image.
#
# Usage: scripts/build-qemu-image.sh <openwrt-version> <out-dir>
# Output: <out-dir>/openwrt-armsr-qemu.img  (raw ext4-combined disk image)

set -eu

VERSION="${1:?usage: build-qemu-image.sh <openwrt-version> <out-dir>}"
OUT_DIR="${2:?usage: build-qemu-image.sh <openwrt-version> <out-dir>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional private site overlay (no-op unless SITE_DIR is set).
. "${SCRIPT_DIR}/site-overlay.sh"

# Resolve OUT_DIR to an absolute path before we cd into the temp work dir,
# otherwise a relative path would be written under (and deleted with) it.
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

TARGET="armsr/armv8"
SLUG="armsr-armv8"
BASE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}"
IB_TARBALL="openwrt-imagebuilder-${VERSION}-${SLUG}.Linux-x86_64.tar.zst"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "== Building QEMU image (armsr/armv8) for OpenWrt ${VERSION} =="

# --- download + verify + extract ImageBuilder ------------------------------
cd "${WORK_DIR}"
echo "-- downloading ImageBuilder"
curl -fSL "${BASE_URL}/sha256sums" -o sha256sums
curl -fSLO "${BASE_URL}/${IB_TARBALL}"

EXPECTED="$(grep -F "${IB_TARBALL}" sha256sums | awk '{print $1}' | head -n 1)"
[ -n "${EXPECTED}" ] || { echo "ERROR: no checksum for ${IB_TARBALL}"; exit 1; }
ACTUAL="$(sha256sum "${IB_TARBALL}" | awk '{print $1}')"
[ "${EXPECTED}" = "${ACTUAL}" ] || { echo "ERROR: ImageBuilder checksum mismatch"; exit 1; }
echo "   checksum OK"

mkdir -p ib
tar --use-compress-program=unzstd -xf "${IB_TARBALL}" -C ib --strip-components=1
test -f ib/Makefile || { echo "ERROR: extracted ImageBuilder looks invalid"; exit 1; }

# --- merge the optional site overlay into a throwaway files/ tree ----------
MERGED_FILES="${WORK_DIR}/files"
site_merge_files "${REPO_ROOT}/files" "${MERGED_FILES}"

# --- derive the QEMU package set (drop hardware-specific kmods) ------------
# The kmod-/gl-fan filter applies to site packages too: they can't be tested
# in QEMU any more than the public ones can.
PACKAGES="$(site_merge_packages "${REPO_ROOT}/packages.txt" \
  | grep -v '^[[:space:]]*$' \
  | grep -v '^kmod-' \
  | grep -v '^gl-fan[[:space:]]*$' \
  | tr '\n' ' ')"
echo "-- packages for QEMU build: ${PACKAGES}"

# --- build ----------------------------------------------------------------
echo "-- running ImageBuilder"
make -C ib image \
  PROFILE="generic" \
  PACKAGES="${PACKAGES}" \
  FILES="${MERGED_FILES}"

# --- collect the ext4-combined disk image ---------------------------------
IMG_GZ="$(find ib/bin/targets/${TARGET} -type f -name '*ext4-combined*.img.gz' | head -n 1)"
[ -n "${IMG_GZ}" ] || { echo "ERROR: no ext4-combined image produced"; find ib/bin/targets/${TARGET} -type f; exit 1; }

OUT_IMG="${OUT_DIR}/openwrt-armsr-qemu.img"
gunzip -c "${IMG_GZ}" > "${OUT_IMG}"

echo "== QEMU image ready: ${OUT_IMG} =="
