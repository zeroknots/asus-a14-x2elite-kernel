# Shared settings for the asus-a14 scripts; sourced, not executed.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src=$(cd -- "$here/.." && pwd)
dtb=glymur-asus-zenbook-a14-ux3407na.dtb
dtb_target=qcom/$dtb
compatible='asus,zenbook-a14-ux3407na qcom,glymur'
build_root=${A14_BUILD_ROOT:-$src/../asus-a14-build}
die() { echo "asus-a14: $*" >&2; exit 1; }
release_config() { echo "$here/configs/releases/zenbook-$1.config"; }
release_name() {
  local config
  config=$(release_config "$1")
  [[ -f $config ]] || die "no release config for '$1' ($config)"
  local version localversion
  version=$(make -s -C "$src" kernelversion)
  localversion=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$config")
  [[ $localversion == "-zenbook-$1" ]] || die "$config has LOCALVERSION '$localversion'"
  # Same order as scripts/setlocalversion: localversion* files, then LOCALVERSION.
  echo "$version$(cat "$src"/localversion* 2>/dev/null | tr -d '\n')$localversion"
}
# Modules every release must ship (vermagic-checked by package.sh/install.sh).
required_modules() { grep -vE '^\s*(#|$)' "$here/required-modules.txt"; }
upstream_value() { sed -n "s/^$1=//p" "$here/UPSTREAM"; }
# Refuse to build from a tree that does not contain the recorded upstream base.
check_base() {
  local base
  base=$(upstream_value commit)
  [[ $base =~ ^[0-9a-f]{40}$ ]] || die 'UPSTREAM has no commit'
  git -C "$src" cat-file -e "$base^{commit}" 2>/dev/null || die "base $base is not in this clone; fetch $(upstream_value repo) $(upstream_value branch)"
  git -C "$src" merge-base --is-ancestor "$base" HEAD || die "HEAD does not descend from recorded base $base"
}

# build_initramfs RELEASE IMAGE WORKDIR [resume]
# Build and verify an Omarchy Snapdragon initramfs for RELEASE into IMAGE.
# The stock oma_snap_qcom hook copies the whole firmware namespace (~270 MB of
# qcom/<soc> firmware) into the initramfs; the 2 GB ESP cannot hold several
# such entries. Use a copy of that hook that keeps its module list, all
# non-qcom firmware, qcom root files and qcom/glymur only. The rootfs keeps the
# complete namespace for runtime firmware loading. With "resume", the resume
# hook runs after the encrypted root is unlocked.
build_initramfs() {
  local release=$1 image=$2 workdir=$3 mode=${4:-}
  local stock_hook=/usr/lib/initcpio/install/oma_snap_qcom
  local hook_line='  add_full_dir "/usr/lib/firmware/$KERNELVERSION"'
  local fw=/usr/lib/firmware/$release
  [[ $(grep -cxF "$hook_line" "$stock_hook") == 1 ]] || die 'unexpected oma_snap_qcom hook'
  install -d "$workdir/initcpio/install" "$workdir/initcpio/hooks" "$workdir/initcpio/post"
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
  } > "$workdir/initcpio/install/asus_a14_qcom"
  bash -n "$workdir/initcpio/install/asus_a14_qcom" || die 'generated hook is invalid'
  cp /usr/share/oma-snap/mkinitcpio-installed.conf "$workdir/mkinitcpio.conf"
  grep -q '^HOOKS=(.* oma_snap_qcom .* encrypt .*)$' "$workdir/mkinitcpio.conf" || die 'unexpected mkinitcpio hooks'
  sed -i 's/ oma_snap_qcom / asus_a14_qcom /' "$workdir/mkinitcpio.conf"
  sed -i 's/^MODULES=.*/MODULES=(pinctrl-glymur gcc-glymur gpucc-glymur dispcc-glymur qnoc-glymur scmi_pm_domain panel-samsung-atna33xc20 i2c-hid-of msm ath12k r8152)/' "$workdir/mkinitcpio.conf"
  if [[ $mode == resume ]]; then
    sed -i 's/ encrypt / encrypt resume /' "$workdir/mkinitcpio.conf"
    grep -q ' encrypt resume ' "$workdir/mkinitcpio.conf" || die 'could not add the resume hook'
  fi
  mkinitcpio --nopost -D "$workdir/initcpio" -D /etc/initcpio -D /usr/lib/initcpio \
    -c "$workdir/mkinitcpio.conf" -k "$release" -g "$image"
  lsinitcpio "$image" > "$workdir/initramfs-files"
  local required
  for required in drivers/md/dm-crypt.ko fs/btrfs/btrfs.ko "usr/lib/firmware/$release/qcom/glymur/" \
      "usr/lib/firmware/$release/qca/ornbtfw11.tlv" "usr/lib/firmware/$release/ath12k/QCC2072/hw1.0/board-2.bin"; do
    grep -Fq "$required" "$workdir/initramfs-files" || die "initramfs missing $required"
  done
  ! grep -Fq "usr/lib/firmware/$release/qcom/x1e80100/" "$workdir/initramfs-files" || die 'firmware filter not applied'
  diff <(cd "$fw/qcom/glymur" && find . -type f | sort) \
    <(sed -n "s|^usr/lib/firmware/$release/qcom/glymur/|./|p" "$workdir/initramfs-files" | grep -v '/$' | sort) \
    || die 'initramfs glymur firmware is incomplete'
  if [[ $mode == resume ]]; then
    grep -Eq '(^|/)hooks/resume$' "$workdir/initramfs-files" || die 'initramfs missing the resume hook'
  fi
}
