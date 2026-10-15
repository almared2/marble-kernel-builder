#!/usr/bin/env bash
set -euo pipefail

source config/marble.env

KERNEL_DIR="${KERNEL_DIR:-kernel-source}"
BUILD_SCOPE="${BUILD_SCOPE:-image-only}"
MANAGER="${MANAGER:-none}"
ENABLE_SUSFS="${ENABLE_SUSFS:-false}"
JOBS="${JOBS:-$(nproc)}"
USE_CCACHE="${USE_CCACHE:-true}"
TOOLCHAIN="${TOOLCHAIN:-android-r416183b}"

# Limit parallelism on free GitHub-hosted runners to reduce OOM risk.
if [[ -z "${JOBS_FORCE:-}" ]]; then
  if [[ "${TOOLCHAIN}" == "llvm-22.1.8" ]] && (( JOBS > 2 )); then
    echo "Capping JOBS from ${JOBS} to 2 for ${TOOLCHAIN}"
    JOBS=2
  fi
fi

if [[ "${BUILD_SCOPE}" != "full" && "${BUILD_SCOPE}" != "image-only" ]]; then
  echo "::error::Unsupported BUILD_SCOPE: ${BUILD_SCOPE}"
  exit 1
fi

pushd "${KERNEL_DIR}" >/dev/null
mkdir -p "${OUT_DIR}" "${RELEASE_DIR}"

export ARCH
export SUBARCH="${ARCH}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-marble}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"
export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"
export CCACHE_COMPILERCHECK=content
export CCACHE_NOHASHDIR=true

if [[ -n "${ANDROID_CLANG_BIN:-}" ]]; then
  if [[ ! -x "${ANDROID_CLANG_BIN}/clang" ]]; then
    echo "::error::ANDROID_CLANG_BIN does not contain clang: ${ANDROID_CLANG_BIN}"
    exit 1
  fi
  export PATH="${ANDROID_CLANG_BIN}:${PATH}"
fi

if [[ "${USE_CCACHE}" == "true" ]] && command -v ccache >/dev/null 2>&1; then
  export CC="ccache clang"

  if [[ "${TOOLCHAIN}" == "llvm-22.1.8" ]]; then
    ccache -M 6G
  else
    ccache -M 4G
  fi

  ccache -o compression=true
  ccache -o compression_level=6 2>/dev/null || true
  ccache -z || true
else
  export CC="clang"
fi

clang --version | tee "${RELEASE_DIR}/build.log"

DEFCONFIG_MODE="${DEFCONFIG_MODE:-single}"

case "${DEFCONFIG_MODE}" in
  single)
    active_defconfig="${DEFCONFIG:-marble_defconfig}"
    echo "Using single defconfig: ${active_defconfig}" \
      | tee -a "${RELEASE_DIR}/build.log"

    make O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 \
      CC="${CC}" "${active_defconfig}" \
      2>&1 | tee -a "${RELEASE_DIR}/build.log"
    ;;

  gki_fragments)
    base_defconfig="${BASE_DEFCONFIG:-gki_defconfig}"
    echo "Using GKI base defconfig: ${base_defconfig}" \
      | tee -a "${RELEASE_DIR}/build.log"

    make O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 \
      CC="${CC}" "${base_defconfig}" \
      2>&1 | tee -a "${RELEASE_DIR}/build.log"

    if [[ -z "${CONFIG_FRAGMENTS:-}" ]]; then
      echo "::error::DEFCONFIG_MODE=gki_fragments requires CONFIG_FRAGMENTS"
      exit 1
    fi

    fragment_paths=()
    # shellcheck disable=SC2206
    fragment_list=(${CONFIG_FRAGMENTS})

    for fragment in "${fragment_list[@]}"; do
      fragment_path="arch/${ARCH}/configs/${fragment}"

      if [[ ! -f "${fragment_path}" ]]; then
        echo "::error::Missing config fragment: ${fragment_path}"
        exit 1
      fi

      fragment_paths+=("${fragment_path}")
      echo "  + fragment ${fragment_path}" \
        | tee -a "${RELEASE_DIR}/build.log"
    done

    if [[ ! -x scripts/kconfig/merge_config.sh ]]; then
      echo "::error::scripts/kconfig/merge_config.sh is missing or not executable"
      exit 1
    fi

    ./scripts/kconfig/merge_config.sh \
      -O "${OUT_DIR}" -m "${OUT_DIR}/.config" "${fragment_paths[@]}" \
      2>&1 | tee -a "${RELEASE_DIR}/build.log"
    ;;

  *)
    echo "::error::Unsupported DEFCONFIG_MODE: ${DEFCONFIG_MODE}"
    exit 1
    ;;
esac

if [[ "${MANAGER}" != "none" ]]; then
  scripts/config --file "${OUT_DIR}/.config" -e KSU
fi

if [[ "${ENABLE_SUSFS}" == "true" ]]; then
  scripts/config --file "${OUT_DIR}/.config" -e KSU_SUSFS
fi

# Apply selectable Clang LTO.
LTO="${LTO:-thin}"
echo "Applying LTO mode: ${LTO}" | tee -a "${RELEASE_DIR}/build.log"

case "${LTO}" in
  none)
    scripts/config --file "${OUT_DIR}/.config" \
      -d LTO_CLANG \
      -d LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -e LTO_NONE || true

    scripts/config --file "${OUT_DIR}/.config" \
      -e LTO_CLANG_NONE 2>/dev/null || true
    ;;

  thin)
    scripts/config --file "${OUT_DIR}/.config" \
      -d LTO_NONE \
      -d LTO_CLANG_NONE \
      -d LTO_CLANG_FULL \
      -e LTO_CLANG \
      -e LTO_CLANG_THIN || true
    ;;

  full)
    scripts/config --file "${OUT_DIR}/.config" \
      -d LTO_NONE \
      -d LTO_CLANG_NONE \
      -d LTO_CLANG_THIN \
      -e LTO_CLANG \
      -e LTO_CLANG_FULL || true

    echo "::warning::LTO=full is memory-heavy on free GitHub runners"
    ;;

  *)
    echo "::error::Unsupported LTO=${LTO}"
    exit 1
    ;;
esac

make O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 \
  CC="${CC}" olddefconfig \
  2>&1 | tee -a "${RELEASE_DIR}/build.log"

if [[ "${MANAGER}" != "none" ]] &&
   ! grep -q '^CONFIG_KSU=y$' "${OUT_DIR}/.config"; then
  echo "::error::CONFIG_KSU is not enabled in the final kernel config"
  exit 1
fi

if [[ "${ENABLE_SUSFS}" == "true" ]] &&
   ! grep -q '^CONFIG_KSU_SUSFS=y$' "${OUT_DIR}/.config"; then
  echo "::error::CONFIG_KSU_SUSFS is not enabled in the final kernel config"
  exit 1
fi

# Select build targets.
targets=(Image)

if [[ "${BUILD_SCOPE}" == "full" ]]; then
  targets+=(modules dtbs)
fi

# Configure ThinLTO limits and cache.
if [[ "${LTO}" == "thin" ]]; then
  THINLTO_JOBS="${THINLTO_JOBS:-2}"
  THINLTO_CACHE_DIR="${THINLTO_CACHE_DIR:-${HOME}/.cache/thinlto}"

  mkdir -p "${THINLTO_CACHE_DIR}"

  wrapper="$(pwd)/${RELEASE_DIR}/ld-thinlto-wrapper"

  {
    printf '#!/bin/bash\n'
    printf 'exec ld.lld "$@" --thinlto-jobs=%s --thinlto-cache-dir=%q\n' \
      "${THINLTO_JOBS}" "${THINLTO_CACHE_DIR}"
  } > "${wrapper}"

  chmod +x "${wrapper}"
  export LD="${wrapper}"
  export HOSTLD="${wrapper}"
  export THINLTO_CACHE_DIR

  echo "ThinLTO jobs=${THINLTO_JOBS} cache=${THINLTO_CACHE_DIR}" \
    | tee -a "${RELEASE_DIR}/build.log"
fi

# Build kernel and, for full builds, modules and DTBs.
make -j"${JOBS}" O="${OUT_DIR}" ARCH="${ARCH}" \
  LLVM=1 LLVM_IAS=1 CC="${CC}" "${targets[@]}" \
  2>&1 | tee -a "${RELEASE_DIR}/build.log"

image_path="${OUT_DIR}/arch/arm64/boot/Image"

if [[ ! -s "${image_path}" ]]; then
  echo "::error::Built Image not found at ${image_path}"
  exit 1
fi

image_size="$(stat -c%s "${image_path}")"

if [[ "${image_size}" -lt 5000000 ]]; then
  echo "::error::Built Image is unexpectedly small: ${image_size} bytes"
  exit 1
fi

if command -v file >/dev/null 2>&1; then
  file "${image_path}" | tee -a "${RELEASE_DIR}/build.log"
fi

cp "${image_path}" "${RELEASE_DIR}/Image"

for file in System.map vmlinux; do
  if [[ -s "${OUT_DIR}/${file}" ]]; then
    cp "${OUT_DIR}/${file}" "${RELEASE_DIR}/${file}"
  fi
done

# Package all modules and DTBs for full builds.
if [[ "${BUILD_SCOPE}" == "full" ]]; then
  if find "${OUT_DIR}/arch/arm64/boot/dts" \
    -name '*.dtb' -print -quit | grep -q .; then
    find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -print0 \
      | tar --null -T - -czf "${RELEASE_DIR}/dtbs.tar.gz"
  fi

  if find "${OUT_DIR}" -name '*.ko' -print -quit | grep -q .; then
    find "${OUT_DIR}" -name '*.ko' -print0 \
      | tar --null -T - -czf "${RELEASE_DIR}/modules.tar.gz"
  fi
fi

# Build a dedicated MT7921U module package when configured as modules.
if grep -q '^CONFIG_MT7921U=m$' "${OUT_DIR}/.config"; then
  mt7921_modules=(
    "drivers/net/wireless/mediatek/mt76/mt76.ko"
    "drivers/net/wireless/mediatek/mt76/mt76-usb.ko"
    "drivers/net/wireless/mediatek/mt76/mt76-connac-lib.ko"
    "drivers/net/wireless/mediatek/mt76/mt7921/mt7921-common.ko"
    "drivers/net/wireless/mediatek/mt76/mt7921/mt7921u.ko"
  )

  # Do not silently publish an incomplete module package.
  for module in "${mt7921_modules[@]}"; do
    if [[ ! -s "${OUT_DIR}/${module}" ]]; then
      echo "::error::Expected MT7921U module is missing: ${OUT_DIR}/${module}"
      exit 1
    fi
  done

  if [[ "${BUILD_SCOPE}" == "full" ]]; then
    tar -czf "${RELEASE_DIR}/mt7921u-modules.tar.gz" \
      -C "${OUT_DIR}" "${mt7921_modules[@]}"

    sha256sum "${RELEASE_DIR}/mt7921u-modules.tar.gz" \
      > "${RELEASE_DIR}/mt7921u-modules.tar.gz.sha256"

    echo "Created MT7921U module archive" \
      | tee -a "${RELEASE_DIR}/build.log"

    # Create a KernelSU Next module ZIP.
    module_stage="$(mktemp -d)"
    trap 'rm -rf "${module_stage}"' EXIT

    mkdir -p "${module_stage}/system/lib/modules"

    for module in "${mt7921_modules[@]}"; do
      cp "${OUT_DIR}/${module}" "${module_stage}/system/lib/modules/"
    done

    cat > "${module_stage}/module.prop" <<'EOF'
id=mt7921u
name=MT7921U USB Wi-Fi Driver
version=1.0
versionCode=1
author=almared2
description=Loads MT7921U USB Wi-Fi driver modules at boot.
EOF

    cat > "${module_stage}/service.sh" <<'EOF'
#!/system/bin/sh

MODDIR="${0%/*}"
TAG="mt7921u-module"
FW_ROOT="/data/adb/modules/netkernel-modules/system/etc/firmware"
FW_DIR="${FW_ROOT}/mediatek"
FW_PARAM="/sys/module/firmware_class/parameters/path"

# Configure firmware lookup path if the firmware module is installed.
if [ -d "$FW_DIR" ] && [ -w "$FW_PARAM" ]; then
    echo -n "$FW_ROOT" > "$FW_PARAM"
fi

load_module() {
    name="$1"
    file="$2"

    if grep -q "^${name} " /proc/modules; then
        log -t "$TAG" "$name is already loaded"
        return 0
    fi

    if [ ! -s "$file" ]; then
        log -t "$TAG" "Missing module: $file"
        return 1
    fi

    if insmod "$file"; then
        log -t "$TAG" "Loaded $name"
        return 0
    fi

    log -t "$TAG" "FAILED to load $name"
    dmesg | tail -n 40 | log -t "$TAG"
    return 1
}

load_module mt76 "$MODDIR/system/lib/modules/mt76.ko"
load_module mt76_usb "$MODDIR/system/lib/modules/mt76-usb.ko"
load_module mt76_connac_lib "$MODDIR/system/lib/modules/mt76-connac-lib.ko"
load_module mt7921_common "$MODDIR/system/lib/modules/mt7921-common.ko"
load_module mt7921u "$MODDIR/system/lib/modules/mt7921u.ko"
EOF

    chmod 0755 "${module_stage}/service.sh"

    (
      cd "${module_stage}"
      zip -qr "${RELEASE_DIR}/mt7921u-kernelsu-next.zip" .
    )

    sha256sum "${RELEASE_DIR}/mt7921u-kernelsu-next.zip" \
      > "${RELEASE_DIR}/mt7921u-kernelsu-next.zip.sha256"

    rm -rf "${module_stage}"
    trap - EXIT

    echo "Created MT7921U KernelSU Next ZIP" \
      | tee -a "${RELEASE_DIR}/build.log"
  fi
fi

# Save ccache statistics.
if [[ "${USE_CCACHE}" == "true" ]] && command -v ccache >/dev/null 2>&1; then
  ccache -s | tee "${RELEASE_DIR}/ccache-stats.txt" || true
fi

popd >/dev/null
