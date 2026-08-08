#!/usr/bin/env bash
#
# publish-deb.sh — add a .deb (e.g. a freshly built Besra package) to the
# existing native aptly repository and re-publish it.
#
# This intentionally reuses the aptly instance already running on this box
# (~/.aptly, serving https://apt.mp.ls, currently publishing the "qtirc"
# repo under distribution "stable"). Rather than deploy a second Dockerized
# aptly, new packages get their own local repo + distribution so this never
# touches the existing qtirc publish.
#
# Usage:
#   ./publish-deb.sh /path/to/besra_1.2.3_amd64.deb [more.deb ...]
#
# Result:
#   - package(s) added to the aptly local repo "${APTLY_REPO_NAME}"
#   - repo (re)published, GPG-signed, under distribution
#     "${APTLY_DISTRIBUTION}" at ${APT_PUBLIC_URL}
#   - end users add:
#       echo "deb ${APT_PUBLIC_URL} ${APTLY_DISTRIBUTION} ${APTLY_COMPONENT}" \
#         | sudo tee /etc/apt/sources.list.d/besra.list

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../config/build.conf
source "${SCRIPT_DIR}/../config/build.conf"

log()  { printf '\033[1;32m[publish-deb]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[publish-deb][WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[publish-deb][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aptly >/dev/null 2>&1 || fail "aptly is not installed (apt install aptly)."

if [[ "$#" -eq 0 ]]; then
    fail "Usage: $0 /path/to/package.deb [more.deb ...]"
fi

for deb in "$@"; do
    [[ -f "$deb" ]] || fail "No such file: $deb"
    case "$deb" in
        *.deb) ;;
        *) fail "Not a .deb file: $deb" ;;
    esac
done

# --- Ensure the local repo exists (idempotent) ------------------------------

if ! aptly repo show "${APTLY_REPO_NAME}" >/dev/null 2>&1; then
    log "Creating local repo '${APTLY_REPO_NAME}'"
    aptly repo create \
        -distribution="${APTLY_DISTRIBUTION}" \
        -component="${APTLY_COMPONENT}" \
        -comment="${APTLY_REPO_COMMENT}" \
        "${APTLY_REPO_NAME}"
else
    log "Local repo '${APTLY_REPO_NAME}' already exists"
fi

# --- Add the package(s) -----------------------------------------------------

log "Adding $# package(s) to '${APTLY_REPO_NAME}'"
aptly repo add "${APTLY_REPO_NAME}" "$@"

# --- Publish (or re-publish) ------------------------------------------------

GPG_ARGS=()
if [[ -n "${APTLY_GPG_KEY}" ]]; then
    GPG_ARGS+=(-gpg-key="${APTLY_GPG_KEY}")
fi

if [[ -d "${APTLY_ROOT}/public/dists/${APTLY_DISTRIBUTION}" ]]; then
    log "Distribution '${APTLY_DISTRIBUTION}' already published, updating it"
    aptly publish update "${GPG_ARGS[@]}" "${APTLY_DISTRIBUTION}"
else
    log "Publishing distribution '${APTLY_DISTRIBUTION}' (component '${APTLY_COMPONENT}') for the first time"
    aptly publish repo "${GPG_ARGS[@]}" \
        -distribution="${APTLY_DISTRIBUTION}" \
        -component="${APTLY_COMPONENT}" \
        "${APTLY_REPO_NAME}"
fi

log "Published. End users can install with:"
cat <<EOF
  curl -fsSL ${APT_PUBLIC_URL}/qtirc-apt-key.asc | sudo tee /etc/apt/trusted.gpg.d/besra.asc
  echo "deb ${APT_PUBLIC_URL} ${APTLY_DISTRIBUTION} ${APTLY_COMPONENT}" | sudo tee /etc/apt/sources.list.d/besra.list
  sudo apt update
EOF
