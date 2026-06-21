#!/bin/sh
#
# Optional private site overlay.
#
# Layers a private deployment-specific config repo on top of the public files/
# tree and packages.txt at build time. Enabled by pointing SITE_DIR at a
# checkout of that private repo, which mirrors this repo's layout:
#
#   $SITE_DIR/files/...            # same tree shape as ./files, merged on top
#   $SITE_DIR/packages.site.txt    # optional extra packages, appended
#
# With SITE_DIR unset (the default), both helpers are transparent
# pass-throughs, so the public build is byte-for-byte unchanged.
#
# Source this file; do not execute it:
#
#   . "${SCRIPT_DIR}/site-overlay.sh"
#   site_merge_files "${REPO_ROOT}/files" "${DEST}"
#   PACKAGES="$(site_merge_packages "${REPO_ROOT}/packages.txt" | tr '\n' ' ')"

# site_merge_files <public-files-dir> <dest-dir>
# Populate <dest-dir> fresh with the public files/ tree, then overlay
# $SITE_DIR/files on top (site files win on path conflicts). Modes are
# preserved so uci-defaults scripts keep their +x bit.
site_merge_files() {
  _public="$1"; _dest="$2"
  rm -rf "${_dest}"; mkdir -p "${_dest}"
  [ -d "${_public}" ] && cp -a "${_public}/." "${_dest}"/
  if [ -n "${SITE_DIR:-}" ] && [ -d "${SITE_DIR}/files" ]; then
    cp -a "${SITE_DIR}/files/." "${_dest}"/
    echo "site-overlay: merged ${SITE_DIR}/files" >&2
  fi
}

# site_merge_packages <public-packages-file>
# Echo the public package list, comments stripped, one token per line, followed
# by any $SITE_DIR/packages.site.txt. Callers flatten/filter as they see fit.
# Diagnostics go to stderr so stdout stays a clean token stream.
site_merge_packages() {
  _base="$1"
  sed 's/#.*//' "${_base}"
  if [ -n "${SITE_DIR:-}" ] && [ -f "${SITE_DIR}/packages.site.txt" ]; then
    sed 's/#.*//' "${SITE_DIR}/packages.site.txt"
    echo "site-overlay: merged ${SITE_DIR}/packages.site.txt" >&2
  fi
}
