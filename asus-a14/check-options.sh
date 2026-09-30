#!/usr/bin/env bash
# Usage: check-options.sh CONFIG [OPTION-FILE...]
# Fails unless every NAME=VALUE line of each option file (default:
# required-options.txt) is satisfied by CONFIG. "=m" also accepts "=y";
# "=n" requires "# NAME is not set".
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
config=${1:?usage: check-options.sh CONFIG [OPTION-FILE...]}; shift
(( $# )) || set -- "$here/required-options.txt"
[[ -f $config ]] || die "missing config $config"
missing=0
for list in "$@"; do
  while IFS= read -r line; do
    [[ $line == CONFIG_* ]] || continue
    name=${line%%=*} value=${line#*=}
    case $value in
      n) grep -qxF "# $name is not set" "$config" ;;
      m) grep -qxE "$name=(m|y)" "$config" ;;
      *) grep -qxF "$line" "$config" ;;
    esac || { echo "missing: $line" >&2; missing=1; }
  done < "$list"
done
(( missing == 0 )) || die "$config does not satisfy the required options"
echo "PASS: $config satisfies $(cat "$@" | grep -c '^CONFIG_') options"
