#!/bin/sh
#
# Build the real GL.iNet Beryl AX / GL-MT3000 sysupgrade image.
#
# Single source of truth for the device build, shared by:
#   - the public CI workflow (.github/workflows/build-openwrt.yml), and
#   - a private site repo that pins THIS repo as a git submodule and runs this
#     same script with SITE_DIR pointed at its own overlay.
#
# Steps: download + verify the official OpenWrt ImageBuilder and SDK, build the
# local gl-fan package and stage it, layer the optional private overlay
# (site-overlay.sh, a no-op unless SITE_DIR is set), run ImageBuilder, and
# collect a complete release asset set into <out-dir>. Creating the GitHub
# release from those assets is left to the calling workflow, which differs per
# repo (different repo, token, and release notes).
#
# Usage: scripts/build-image.sh <version> <target> <profile> <out-dir> [cache-root]
#   e.g. scripts/build-image.sh 25.12.4 mediatek/filogic glinet_gl-mt3000 artifacts
# Env:  SITE_DIR  optional path to a private overlay checkout
#
# ImageBuilder/SDK downloads are skipped when a valid extracted copy already
# exists under <cache-root>, so a caller can wrap those dirs with actions/cache.

set -eu

VERSION="${1:?usage: build-image.sh <version> <target> <profile> <out-dir> [cache-root]}"
TARGET="${2:?missing <target>, e.g. mediatek/filogic}"
PROFILE="${3:?missing <profile>, e.g. glinet_gl-mt3000}"
OUT_DIR="${4:?missing <out-dir>}"
CACHE_ROOT="${5:-$(pwd)/.cache}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional private site overlay (no-op unless SITE_DIR is set).
. "${SCRIPT_DIR}/site-overlay.sh"

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

TARGET_SLUG="$(echo "${TARGET}" | tr '/' '-')"
BASE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}"
IB_TARBALL="openwrt-imagebuilder-${VERSION}-${TARGET_SLUG}.Linux-x86_64.tar.zst"

IB_DIR="${CACHE_ROOT}/imagebuilder/${VERSION}/${TARGET_SLUG}"
SDK_DIR="${CACHE_ROOT}/sdk/${VERSION}/${TARGET_SLUG}"

verify_sha() {  # <file> <expected-sha>
  _actual="$(sha256sum "$1" | awk '{print $1}')"
  [ "$2" = "${_actual}" ] || {
    echo "ERROR: checksum mismatch for $1"
    echo "  expected $2"
    echo "  actual   ${_actual}"
    exit 1
  }
}

# --- ImageBuilder ----------------------------------------------------------
ensure_imagebuilder() {
  if [ -f "${IB_DIR}/Makefile" ]; then
    echo "-- ImageBuilder present (cached): ${IB_DIR}"
    return
  fi
  echo "-- downloading ImageBuilder"
  mkdir -p "${IB_DIR}"
  _dl="${WORK_DIR}/ib-dl"; mkdir -p "${_dl}"
  ( cd "${_dl}"
    curl -fSL "${BASE_URL}/sha256sums" -o sha256sums
    curl -fSLO "${BASE_URL}/${IB_TARBALL}"
    _exp="$(grep -F "${IB_TARBALL}" sha256sums | awk '{print $1}' | head -n 1)"
    [ -n "${_exp}" ] || { echo "ERROR: no checksum for ${IB_TARBALL}"; exit 1; }
    verify_sha "${IB_TARBALL}" "${_exp}"
    tar --use-compress-program=unzstd -xf "${IB_TARBALL}" -C "${IB_DIR}" --strip-components=1
  )
  test -f "${IB_DIR}/Makefile" || { echo "ERROR: extracted ImageBuilder invalid"; exit 1; }
}

# --- SDK + gl-fan ----------------------------------------------------------
ensure_sdk() {
  if [ -f "${SDK_DIR}/rules.mk" ]; then
    echo "-- SDK present (cached): ${SDK_DIR}"
    return
  fi
  echo "-- downloading SDK"
  mkdir -p "${SDK_DIR}"
  _dl="${WORK_DIR}/sdk-dl"; mkdir -p "${_dl}"
  ( cd "${_dl}"
    curl -fSL "${BASE_URL}/sha256sums" -o sha256sums
    # The SDK tarball name carries a toolchain suffix (e.g. _gcc-13.3.0_musl),
    # so read the exact name from sha256sums rather than constructing it.
    _sdk="$(grep -oE 'openwrt-sdk-[^ ]*Linux-x86_64\.tar\.(zst|xz)' sha256sums | head -n 1)"
    [ -n "${_sdk}" ] || { echo "ERROR: no SDK tarball listed in sha256sums"; exit 1; }
    curl -fSLO "${BASE_URL}/${_sdk}"
    _exp="$(grep -F "${_sdk}" sha256sums | awk '{print $1}' | head -n 1)"
    verify_sha "${_sdk}" "${_exp}"
    case "${_sdk}" in
      *.tar.zst) tar --use-compress-program=unzstd -xf "${_sdk}" -C "${SDK_DIR}" --strip-components=1 ;;
      *.tar.xz)  tar -xJf "${_sdk}" -C "${SDK_DIR}" --strip-components=1 ;;
      *) echo "ERROR: unknown SDK archive format: ${_sdk}"; exit 1 ;;
    esac
  )
  test -f "${SDK_DIR}/rules.mk" || { echo "ERROR: extracted SDK invalid"; exit 1; }
}

build_glfan() {
  echo "-- building gl-fan with the SDK"
  rm -rf "${SDK_DIR}/package/gl-fan"
  cp -r "${REPO_ROOT}/package/gl-fan" "${SDK_DIR}/package/gl-fan"
  make -C "${SDK_DIR}" defconfig
  make -C "${SDK_DIR}" package/gl-fan/compile V=s
  GLFAN_PKGS="$(find "${SDK_DIR}/bin" -type f \( -name 'gl-fan_*.ipk' -o -name 'gl-fan-*.apk' \))"
  [ -n "${GLFAN_PKGS}" ] || { echo "ERROR: SDK produced no gl-fan package"; exit 1; }
}

stage_glfan() {
  # ImageBuilder reads user packages from its local <imagebuilder>/packages dir;
  # the apk-based ImageBuilder regenerates the local index automatically, so a
  # plain copy suffices. Stage whichever format the SDK produced (.apk/.ipk).
  mkdir -p "${IB_DIR}/packages"
  echo "${GLFAN_PKGS}" | while IFS= read -r pkg; do
    [ -n "${pkg}" ] && cp -v "${pkg}" "${IB_DIR}/packages/"
  done
}

collect_artifacts() {
  echo "-- collecting release assets into ${OUT_DIR}"
  find "${OUT_DIR}" -mindepth 1 -delete

  find "${IB_DIR}/bin/targets" -type f \
    \( -name "*gl-mt3000*sysupgrade*" \
    -o -name "*gl-mt3000*factory*" \
    -o -name "*.manifest" \
    -o -name "profiles.json" \
    -o -name "sha256sums" \) \
    -exec cp -v {} "${OUT_DIR}/" \;

  ls "${OUT_DIR}"/*gl-mt3000*sysupgrade* >/dev/null 2>&1 \
    || { echo "ERROR: no sysupgrade image produced"; exit 1; }

  if [ -f "${OUT_DIR}/sha256sums" ]; then
    mv "${OUT_DIR}/sha256sums" "${OUT_DIR}/custom-build-sha256sums.txt"
  fi

  # Include the locally-built gl-fan package in the release.
  find "${IB_DIR}/packages" -maxdepth 1 -type f \
    \( -name "gl-fan-*.apk" -o -name "gl-fan_*.ipk" \) \
    -exec cp -v {} "${OUT_DIR}/" \;
  ls "${OUT_DIR}"/gl-fan* >/dev/null 2>&1 \
    || { echo "ERROR: gl-fan package missing from artifacts"; exit 1; }

  # Official OpenWrt GL-MT3000 initramfs recovery image (optional).
  INITRAMFS_FILE="openwrt-${VERSION}-${TARGET_SLUG}-glinet_gl-mt3000-initramfs-kernel.bin"
  _sums="${WORK_DIR}/official-sha256sums"
  curl -fSL "${BASE_URL}/sha256sums" -o "${_sums}"
  if grep -F "${INITRAMFS_FILE}" "${_sums}" >/dev/null; then
    curl -fSL "${BASE_URL}/${INITRAMFS_FILE}" -o "${OUT_DIR}/${INITRAMFS_FILE}"
    _exp="$(grep -F "${INITRAMFS_FILE}" "${_sums}" | awk '{print $1}' | head -n 1)"
    verify_sha "${OUT_DIR}/${INITRAMFS_FILE}" "${_exp}"
    echo "   official initramfs checksum OK"
  else
    echo "WARNING: official initramfs not found, continuing without it: ${INITRAMFS_FILE}"
  fi

  ( cd "${OUT_DIR}" && sha256sum * > release-sha256sums.txt )
}

echo "== Building GL-MT3000 image: OpenWrt ${VERSION} / ${TARGET} / ${PROFILE} =="

ensure_imagebuilder
ensure_sdk
build_glfan
stage_glfan

# --- merge the optional site overlay, then build ---------------------------
MERGED_FILES="${WORK_DIR}/files"
site_merge_files "${REPO_ROOT}/files" "${MERGED_FILES}"
PACKAGES="$(site_merge_packages "${REPO_ROOT}/packages.txt" | tr '\n' ' ')"

echo "-- running ImageBuilder"
make -C "${IB_DIR}" image \
  PROFILE="${PROFILE}" \
  PACKAGES="${PACKAGES}" \
  FILES="${MERGED_FILES}"

collect_artifacts

echo "== Build complete. Assets in ${OUT_DIR}: =="
ls -1 "${OUT_DIR}"
