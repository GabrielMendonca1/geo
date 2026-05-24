#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${HOME}/.pi/agent/extensions"
LINK="${DEST_DIR}/geo-mcp"

mkdir -p "${DEST_DIR}"

if [[ -L "${LINK}" || -e "${LINK}" ]]; then
  rm -rf "${LINK}"
fi

ln -s "${SRC_DIR}" "${LINK}"

if [[ ! -L "${LINK}" ]]; then
  echo "install.sh: failed to create symlink at ${LINK}" >&2
  exit 1
fi

RESOLVED="$(readlink "${LINK}")"
if [[ "${RESOLVED}" != "${SRC_DIR}" ]]; then
  echo "install.sh: symlink resolves to ${RESOLVED}, expected ${SRC_DIR}" >&2
  exit 1
fi

echo "Linked ${LINK} -> ${SRC_DIR}"
