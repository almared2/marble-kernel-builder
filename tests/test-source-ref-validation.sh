#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# A normal branch/ref must continue to resolve.
KERNEL_SOURCE=evolution-x SOURCE_REF=cnb \
  bash scripts/resolve-kernel-source.sh >/dev/null

# Newlines must be rejected before they can be appended to GITHUB_ENV.
tmp_env="$(mktemp)"
trap 'rm -f "${tmp_env}"' EXIT
if KERNEL_SOURCE=evolution-x SOURCE_REF=$'cnb\nINJECTED=value' GITHUB_ENV="${tmp_env}" \
  bash scripts/resolve-kernel-source.sh >/dev/null 2>&1; then
  echo "FAIL: newline in SOURCE_REF was accepted" >&2
  exit 1
fi
if grep -q '^INJECTED=' "${tmp_env}"; then
  echo "FAIL: invalid SOURCE_REF injected an environment variable" >&2
  exit 1
fi

echo "Source ref validation tests passed"
