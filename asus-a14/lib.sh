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
