#!/usr/bin/env bash
# Usage: package.sh RELEASE
# Collect Image, DTB, config, System.map and stripped modules from build.sh's
# output into $A14_BUILD_ROOT/artifacts-RELEASE with provenance and SHA256SUMS.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
tag=${1:?usage: package.sh RELEASE}
check_base
release=$(release_name "$tag")
out=$build_root/kernel-out-$tag
artifact=$build_root/artifacts-$tag
[[ ! -e $artifact ]] || die "$artifact already exists"
[[ $(make -s -C "$src" O="$out" ARCH=arm64 LOCALVERSION= kernelrelease) == "$release" ]] || die 'build output has another release'
[[ -s $out/arch/arm64/boot/Image && -s $out/arch/arm64/boot/dts/$dtb_target ]] || die 'run build.sh first'
cmp -s "$(release_config "$tag")" "$out/.config" || die 'build config differs from the committed release config'
mkdir -p "$artifact/root"
cp "$out/arch/arm64/boot/Image" "$artifact/Image"
cp "$out/arch/arm64/boot/dts/$dtb_target" "$artifact/$dtb"
cp "$out/System.map" "$artifact/System.map"
cp "$out/.config" "$artifact/config"
printf '%s\n' "$release" > "$artifact/release"
make -s -C "$src" O="$out" ARCH=arm64 LOCALVERSION= INSTALL_MOD_PATH="$artifact/root" INSTALL_MOD_STRIP=1 modules_install
depmod -b "$artifact/root" -a "$release"
dirty=false; [[ -z $(git -C "$src" status --porcelain --untracked-files=no) ]] || dirty=true
python3 - "$artifact" <<PY
import hashlib, json, pathlib, sys
artifact = pathlib.Path(sys.argv[1])
provenance = {
    "release": "$release",
    "upstream_repo": "$(upstream_value repo)",
    "upstream_branch": "$(upstream_value branch)",
    "upstream_commit": "$(upstream_value commit)",
    "source_commit": "$(git -C "$src" rev-parse HEAD)",
    "source_dirty": $( [[ $dirty == true ]] && echo True || echo False ),
    "config_sha256": hashlib.sha256((artifact / "config").read_bytes()).hexdigest(),
    "status": "BUILT_UNINSTALLED",
}
(artifact / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
with (artifact / "SHA256SUMS").open("w") as manifest:
    for path in sorted(p for p in artifact.rglob("*") if p.is_file() and not p.is_symlink() and p.name != "SHA256SUMS"):
        manifest.write(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(artifact)}\n")
PY
(cd "$artifact" && sha256sum --check --quiet SHA256SUMS)
for module in $(required_modules); do
  [[ $(modinfo -b "$artifact/root" -k "$release" -F vermagic "$module" 2>/dev/null) == "$release "* ]] || die "module missing or mismatched: $module"
done
[[ $(fdtget "$artifact/$dtb" / compatible) == "$compatible" ]] || die 'wrong DTB compatible'
[[ $(fdtget "$artifact/$dtb" /soc@0/geniqup@ac0000/serial@a98000/bluetooth compatible 2>/dev/null) == 'qcom,qcc2072-bt' ]] || die 'QCC2072 Bluetooth node missing'
[[ $(head -c2 "$artifact/Image") == MZ ]] || die 'Image lacks the EFI MZ header'
$dirty && echo 'WARNING: built from a tree with uncommitted changes' >&2
echo "PASS: $release packaged in $artifact"
