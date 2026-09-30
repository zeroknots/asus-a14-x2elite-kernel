#!/usr/bin/env bash
# Usage: build.sh RELEASE   (e.g. hw3)
# Build Image, modules and the UX3407NA DTB from configs/releases/zenbook-RELEASE.config.
# Native arm64 build; set CROSS_COMPILE=aarch64-linux-gnu- on other hosts.
# A14_CHECK_ONLY=1 stops after verifying the config (no compile).
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
tag=${1:?usage: build.sh RELEASE}
check_base
config=$(release_config "$tag"); release=$(release_name "$tag")
out=$build_root/kernel-out-$tag
mkdir -p "$out"
cp "$config" "$out/.config"
make -s -C "$src" O="$out" ARCH=arm64 LOCALVERSION= olddefconfig
# The committed config must already be fully resolved for this tree.
cmp -s <(grep -v '^#' "$config") <(grep -v '^#' "$out/.config") || {
  diff <(grep '^CONFIG_' "$config") <(grep '^CONFIG_' "$out/.config") >&2 || true
  die "$config is not olddefconfig-stable on this tree; regenerate it with new-release.sh"
}
# hw1/hw2 predate required-options.txt; rebuild them with A14_HISTORICAL=1.
[[ ${A14_HISTORICAL:-0} == 1 ]] || "$here/check-options.sh" "$out/.config"
[[ $(make -s -C "$src" O="$out" ARCH=arm64 LOCALVERSION= kernelrelease) == "$release" ]] || die "kernelrelease is not $release"
[[ ${A14_CHECK_ONLY:-0} == 1 ]] && { echo "PASS: $release config verified (check only)"; exit 0; }
echo "Building $release in $out"
nice -n 10 make -C "$src" O="$out" ARCH=arm64 LOCALVERSION= -j"${JOBS:-$(nproc)}" Image modules "$dtb_target"
