#!/usr/bin/env bash
# Usage: new-release.sh FROM TO FRAGMENT...
# Create configs/releases/zenbook-TO.config from zenbook-FROM.config plus
# fragments. Every fragment line must survive olddefconfig, and the result
# must still satisfy required-options.txt. Example:
#   asus-a14/new-release.sh hw3 hw4 asus-a14/configs/fragments/60-hw4-desktop.config
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
from=${1:?FROM}; to=${2:?TO}; shift 2; (( $# )) || die 'at least one fragment is required'
base=$(release_config "$from"); target=$(release_config "$to")
[[ -f $base ]] || die "missing $base"; [[ ! -e $target ]] || die "$target already exists"
out=$build_root/config-$to; rm -rf "$out"; mkdir -p "$out"
cp "$base" "$out/.config"
ARCH=arm64 KCONFIG_CONFIG="$out/.config" "$src/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" "$@"
make -s -C "$src" O="$out" ARCH=arm64 LOCALVERSION= olddefconfig
"$here/check-options.sh" "$out/.config" "$@"
"$here/check-options.sh" "$out/.config"
grep -qxF "CONFIG_LOCALVERSION=\"-zenbook-$to\"" "$out/.config" || die "a fragment must set CONFIG_LOCALVERSION=\"-zenbook-$to\""
cp "$out/.config" "$target"
echo "Created $target; config changes against $from:"
diff <(grep '^CONFIG_' "$base") <(grep '^CONFIG_' "$target") || true
