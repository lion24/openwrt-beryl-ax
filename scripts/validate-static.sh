#!/bin/sh
#
# Layer 1: static validation of the REAL built Beryl AX / GL-MT3000 image.
#
# QEMU cannot boot the MT7981-specific firmware, so this layer validates the
# actual artifact directly: it confirms the sysupgrade image exists and is
# intact, that every package requested in packages.txt is baked into the
# image manifest (and every removed package is absent), and that the
# uci-defaults overlay is syntactically valid.
#
# Usage: scripts/validate-static.sh <artifacts-dir>

set -eu

ARTIFACTS_DIR="${1:?usage: validate-static.sh <artifacts-dir>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGES_FILE="${REPO_ROOT}/packages.txt"
UCI_DEFAULTS="${REPO_ROOT}/files/etc/uci-defaults/99-beryl-travel"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "== Static validation of ${ARTIFACTS_DIR} =="

# --- sysupgrade image present and non-empty -------------------------------
SYSUPGRADE="$(find "${ARTIFACTS_DIR}" -maxdepth 1 -type f -name '*gl-mt3000*sysupgrade*' | head -n 1)"
[ -n "${SYSUPGRADE}" ]   || fail "no *gl-mt3000*sysupgrade* image found in ${ARTIFACTS_DIR}"
[ -s "${SYSUPGRADE}" ]   || fail "sysupgrade image is empty: ${SYSUPGRADE}"
ok "sysupgrade image: $(basename "${SYSUPGRADE}") ($(wc -c < "${SYSUPGRADE}") bytes)"

# --- manifest present ------------------------------------------------------
MANIFEST="$(find "${ARTIFACTS_DIR}" -maxdepth 1 -type f -name '*.manifest' | head -n 1)"
[ -n "${MANIFEST}" ] || fail "no *.manifest found in ${ARTIFACTS_DIR}"
ok "manifest: $(basename "${MANIFEST}")"

# --- checksum integrity (if the release sums file was collected) ----------
if [ -f "${ARTIFACTS_DIR}/release-sha256sums.txt" ]; then
  ( cd "${ARTIFACTS_DIR}" && sha256sum -c --ignore-missing release-sha256sums.txt >/dev/null ) \
    || fail "checksum verification failed against release-sha256sums.txt"
  ok "checksums verified against release-sha256sums.txt"
else
  echo "  note: release-sha256sums.txt not present, skipping checksum check"
fi

# --- package assertions ----------------------------------------------------
# packages.txt syntax: a bare name is required-present; a "-name" line means
# the package was removed and must be absent; blank lines and # comments are
# ignored. The manifest lists one "name - version" entry per installed pkg.
echo "-- verifying packages against manifest"
missing=""
present_forbidden=""
while IFS= read -r line || [ -n "${line}" ]; do
  pkg="$(printf '%s' "${line}" | sed 's/#.*//' | tr -d '[:space:]')"
  [ -n "${pkg}" ] || continue
  case "${pkg}" in
    -*)
      name="${pkg#-}"
      if grep -qE "^${name} " "${MANIFEST}"; then
        present_forbidden="${present_forbidden} ${name}"
      fi
      ;;
    *)
      if grep -qE "^${pkg} " "${MANIFEST}"; then
        ok "package present: ${pkg}"
      else
        missing="${missing} ${pkg}"
      fi
      ;;
  esac
done < "${PACKAGES_FILE}"

[ -z "${missing}" ]          || fail "requested packages missing from image:${missing}"
[ -z "${present_forbidden}" ] || fail "removed packages still present in image:${present_forbidden}"
ok "all requested packages present, all removed packages absent"

# --- overlay sanity --------------------------------------------------------
[ -f "${UCI_DEFAULTS}" ] || fail "uci-defaults overlay missing: ${UCI_DEFAULTS}"
sh -n "${UCI_DEFAULTS}"  || fail "uci-defaults overlay has shell syntax errors"
ok "uci-defaults overlay present and syntactically valid"

# --- report kernel version for visibility ---------------------------------
KVER="$(grep -E '^kernel ' "${MANIFEST}" | awk '{print $3}' | head -n 1 || true)"
[ -n "${KVER}" ] && echo "  info: kernel version in image: ${KVER}"

echo "== Static validation PASSED =="
