#!/usr/bin/env bash

#==============================================================================
# WORDPRESS AUTOMATION RELEASE BOOTSTRAP
#==============================================================================

set -euo pipefail

action="${1:?Action is required}"
repository="${2:?Automation repository is required}"
release_ref="${3:?Automation release is required}"
shift 3

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  [[ ! "$release_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid automation release source.\n' >&2
  exit 2
fi

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  "https://github.com/${repository}/archive/refs/tags/${release_ref}.tar.gz" |
  tar --extract --gzip --directory "$temporary_directory" --strip-components=1

bash "$temporary_directory/scripts/manage.sh" "$action" "$@"