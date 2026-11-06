#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

MATRIX_ARTIFACTS_DIR="${tmp_dir}/missing-artifacts" \
MATRIX_SUMMARY="${tmp_dir}/matrix-summary.md" \
BUILD_SCOPE=full \
GITHUB_REPOSITORY=almared2/marble-kernel-builder \
GITHUB_RUN_ID=12345 \
bash scripts/generate-matrix-summary.sh >/dev/null

summary="${tmp_dir}/matrix-summary.md"
[[ -s "${summary}" ]] || {
  echo "FAIL: empty-artifact summary was not generated" >&2
  exit 1
}

grep -Fq "No successful build artifacts" "${summary}" || {
  echo "FAIL: summary does not identify the missing successful artifacts" >&2
  exit 1
}

grep -Fq "Inspect the failed matrix job" "${summary}" || {
  echo "FAIL: summary does not direct users to the primary build failure" >&2
  exit 1
}

if grep -Fq "0 of 0 manager builds passed" "${summary}"; then
  echo "FAIL: empty-artifact summary must not imply a successful build" >&2
  exit 1
fi

echo "Empty matrix summary test passed"
