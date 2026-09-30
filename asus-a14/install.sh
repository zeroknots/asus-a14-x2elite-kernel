#!/usr/bin/env bash
# Usage: sudo install.sh RELEASE
# Add a packaged release as a separate, NON-default GRUB entry on an Omarchy
# Snapdragon install (oma-snap GRUB/ESP layout). It never changes the default
# entry, never removes kernels, and verifies existing entries before and after.
# Firmware is copied from the running kernel's versioned namespace
# (/usr/lib/firmware/$(uname -r)); override with A14_FIRMWARE_FROM=<release>.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
tag=${1:?usage: install.sh RELEASE}
artifact=$build_root/artifacts-$tag
entry_id=oma-a14-$tag-test
fail() { echo "install failed: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'root is required'
[[ $(uname -m) == aarch64 && $(cat /sys/class/dmi/id/board_name) == UX3407NA ]] || fail 'this is not an ASUS Zenbook A14 UX3407NA'
[[ $(findmnt -rn -M /boot -o FSTYPE) == vfat ]] || fail '/boot must be the mounted ESP'
(cd "$artifact" && sha256sum --check --quiet SHA256SUMS) || fail "artifact manifest check failed in $artifact"
release=$(cat "$artifact/release")
[[ $release == *-zenbook-$tag ]] || fail "unexpected release $release"
[[ $(fdtget "$artifact/$dtb" / compatible) == "$compatible" ]] || fail 'wrong DTB'
for module in $(required_modules); do
  [[ $(modinfo -b "$artifact/root" -k "$release" -F vermagic "$module" 2>/dev/null) == "$release "* ]] || fail "module mismatch: $module"
done
grub=/boot/oma-snap/grub/grub.cfg
entries=/boot/oma-snap/entries
entry=$entries/$entry_id
default_line=$(sed -n '/^set default=oma-snap-/p' "$grub")
[[ $(wc -l <<<"$default_line") == 1 && -n $default_line ]] || fail 'expected one oma-snap-* automatic default'
default_entry=$entries/${default_line#set default=oma-snap-}
[[ -s $default_entry/vmlinuz.efi ]] || fail "default entry $default_entry not found"
[[ ! -e $entry && ! -e /usr/lib/modules/$release && ! -e /usr/lib/firmware/$release ]] || fail "$release is already (partly) installed"
! grep -Fq "'$entry_id'" "$grub" || fail 'entry already registered'
source_fw=/usr/lib/firmware/${A14_FIRMWARE_FROM:-$(uname -r)}
[[ -s $source_fw/ath12k/QCC2072/hw1.0/board-2.bin && -d $source_fw/qcom/glymur ]] || fail "firmware namespace $source_fw is incomplete"
[[ -s $source_fw/qca/ornbtfw11.tlv.zst && -s $source_fw/qca/ornnv11.bin.zst ]] || fail 'QCC2072 Bluetooth firmware missing'
work=$(mktemp -d /var/tmp/asus-a14-install.XXXXXXXX)
stage=$entries/.$entry_id.stage
[[ ! -e $stage ]] || fail 'boot staging directory exists'
installed_modules= installed_fw=
cleanup() {
  rm -rf -- "$work"; [[ ! -d $stage ]] || rm -rf -- "$stage"
  if [[ ! -d $entry ]]; then
    [[ -z $installed_modules ]] || rm -rf -- "/usr/lib/modules/$release"
    [[ -z $installed_fw ]] || rm -rf -- "/usr/lib/firmware/$release"
  fi
}
trap cleanup EXIT
# Snapshot the default entry and verify every entry that carries a manifest.
(cd "$default_entry" && sha256sum entry.cfg vmlinuz.efi initramfs.img) > "$work/default.sha256"
verify_entries() {
  (cd "$default_entry" && sha256sum --check --quiet "$work/default.sha256") || fail 'default entry changed'
  local manifest
  for manifest in "$entries"/*/SHA256SUMS; do
    [[ -e $manifest ]] || continue
    (cd "${manifest%/SHA256SUMS}" && sha256sum --check --quiet SHA256SUMS) || fail "entry ${manifest%/SHA256SUMS} fails its manifest"
  done
}
verify_entries
installed_modules=1
cp -a "$artifact/root/lib/modules/$release" /usr/lib/modules/
installed_fw=1
cp -a --reflink=auto "$source_fw" "/usr/lib/firmware/$release"
if [[ -d /usr/lib/firmware/qcom/glymur/ASUSTeK/UX3407NA ]]; then
  install -d -m755 "/usr/lib/firmware/$release/qcom/glymur/ASUSTeK/UX3407NA"
  cp -a /usr/lib/firmware/qcom/glymur/ASUSTeK/UX3407NA/. "/usr/lib/firmware/$release/qcom/glymur/ASUSTeK/UX3407NA/"
fi
depmod "$release"
# The stock oma_snap_qcom hook copies the whole firmware namespace (~270 MB of
# qcom/<soc> firmware) into the initramfs; the 2 GB ESP cannot hold several
# such entries. Generate a copy of the hook that keeps its module list, all
# non-qcom firmware, qcom root files and qcom/glymur only. The rootfs keeps
# the complete namespace for runtime firmware loading.
stock_hook=/usr/lib/initcpio/install/oma_snap_qcom
hook_line='  add_full_dir "/usr/lib/firmware/$KERNELVERSION"'
[[ $(grep -cxF "$hook_line" "$stock_hook") == 1 ]] || fail 'unexpected oma_snap_qcom hook'
install -d "$work/initcpio/install" "$work/initcpio/hooks" "$work/initcpio/post"
{
  awk -v line="$hook_line" '$0 == line { exit } { print }' "$stock_hook"
  cat <<'HOOK'
  local fw=/usr/lib/firmware/$KERNELVERSION entry
  add_dir "$fw"
  for entry in "$fw"/* "$fw"/qcom/*; do
    [[ $entry == "$fw/qcom" ]] && continue
    if [[ -L $entry ]]; then
      add_symlink "$entry" "$(readlink "$entry")"
    elif [[ -d $entry ]]; then
      [[ $entry == "$fw"/qcom/* && $entry != "$fw/qcom/glymur" ]] || add_full_dir "$entry"
    elif [[ -f $entry ]]; then
      add_file "$entry"
    fi
  done
}
HOOK
} > "$work/initcpio/install/asus_a14_qcom"
bash -n "$work/initcpio/install/asus_a14_qcom" || fail 'generated hook is invalid'
cp /usr/share/oma-snap/mkinitcpio-installed.conf "$work/mkinitcpio.conf"
grep -q '^HOOKS=(.* oma_snap_qcom .*)$' "$work/mkinitcpio.conf" || fail 'unexpected mkinitcpio hooks'
sed -i 's/ oma_snap_qcom / asus_a14_qcom /' "$work/mkinitcpio.conf"
sed -i 's/^MODULES=.*/MODULES=(pinctrl-glymur gcc-glymur gpucc-glymur dispcc-glymur qnoc-glymur scmi_pm_domain panel-samsung-atna33xc20 i2c-hid-of msm ath12k r8152)/' "$work/mkinitcpio.conf"
local_stage=$work/entry
install -d -m755 "$local_stage"
install -m644 "$artifact/Image" "$local_stage/vmlinuz.efi"
install -m644 "$artifact/$dtb" "$local_stage/$dtb"
install -m644 "$artifact/config" "$local_stage/config"
install -m644 "$artifact/provenance.json" "$local_stage/provenance.json"
mkinitcpio --nopost -D "$work/initcpio" -D /etc/initcpio -D /usr/lib/initcpio \
  -c "$work/mkinitcpio.conf" -k "$release" -g "$local_stage/initramfs.img"
lsinitcpio "$local_stage/initramfs.img" > "$work/initramfs-files"
for required in drivers/md/dm-crypt.ko fs/btrfs/btrfs.ko "usr/lib/firmware/$release/qcom/glymur/" \
    "usr/lib/firmware/$release/qca/ornbtfw11.tlv" "usr/lib/firmware/$release/ath12k/QCC2072/hw1.0/board-2.bin"; do
  grep -Fq "$required" "$work/initramfs-files" || fail "initramfs missing $required"
done
! grep -Fq "usr/lib/firmware/$release/qcom/x1e80100/" "$work/initramfs-files" || fail 'firmware filter not applied'
diff <(cd "/usr/lib/firmware/$release/qcom/glymur" && find . -type f | sort) \
  <(sed -n "s|^usr/lib/firmware/$release/qcom/glymur/|./|p" "$work/initramfs-files" | grep -v '/$' | sort) \
  || fail 'initramfs glymur firmware is incomplete'
cmdline=$(tr -d '\r\n' </etc/kernel/cmdline)
[[ $cmdline == *root=* ]] || fail '/etc/kernel/cmdline has no root='
esp_uuid=$(findmnt -rn -M /boot -o UUID)
[[ $esp_uuid =~ ^[A-Fa-f0-9-]+$ ]] || fail 'invalid ESP UUID'
cat > "$local_stage/entry.cfg" <<CFG
menuentry 'TEST: Zenbook A14 $tag ($release)' --id '$entry_id' {
  search --no-floppy --fs-uuid --set=root $esp_uuid
  linux /oma-snap/entries/$entry_id/vmlinuz.efi $cmdline clk_ignore_unused pd_ignore_unused arm64.nopauth module_blacklist=rtc_qcom_glink
  devicetree /oma-snap/entries/$entry_id/$dtb
  initrd /oma-snap/entries/$entry_id/initramfs.img
}
CFG
(cd "$local_stage" && sha256sum vmlinuz.efi "$dtb" initramfs.img config provenance.json entry.cfg > SHA256SUMS)
need=$(( $(du -sb "$local_stage" | cut -f1) + 33554432 ))
avail=$(df --output=avail -B1 /boot | tail -1)
echo "ESP: entry needs $need bytes including a 32 MiB margin; $avail available"
(( avail >= need )) || fail "not enough ESP space; nothing was removed"
cat "$grub" "$local_stage/entry.cfg" > "$work/grub.cfg"
[[ $(sed -n '/^set default=oma-snap-/p' "$work/grub.cfg") == "$default_line" ]] || fail 'default changed'
grub-script-check "$work/grub.cfg"
cp -a "$local_stage" "$stage"
(cd "$stage" && sha256sum --check --quiet SHA256SUMS) || fail 'ESP copy does not match'
verify_entries
cp -p "$grub" "$grub.before-$entry_id"
mv "$stage" "$entry"
install -m644 "$work/grub.cfg" "$grub.asus-a14-new"
mv "$grub.asus-a14-new" "$grub"
(cd "$entry" && sha256sum --check --quiet SHA256SUMS)
verify_entries
[[ $(sed -n '/^set default=oma-snap-/p' "$grub") == "$default_line" ]] || fail 'default changed after install'
# Rebuild DKMS modules (e.g. v4l2loopback) against this release's build tree.
if command -v dkms >/dev/null; then
  out=$build_root/kernel-out-$tag
  [[ -e /usr/lib/modules/$release/build || ! -d $out ]] || ln -s "$out" "/usr/lib/modules/$release/build"
  dkms autoinstall -k "$release" || echo "WARNING: dkms autoinstall failed for $release" >&2
fi
echo "PASS: $release installed as $entry_id; default entry and existing entries unchanged."
