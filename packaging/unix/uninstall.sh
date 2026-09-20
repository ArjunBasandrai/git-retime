#!/usr/bin/env bash
set -euo pipefail

prefix=/usr/local
while (($#)); do
    case "$1" in
        --prefix) [[ $# -ge 2 ]] || { printf 'uninstall.sh: --prefix requires a value\n' >&2; exit 2; }; prefix=$2; shift 2 ;;
        *) printf 'uninstall.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

rm -f -- "$prefix/bin/git-retime"
rm -rf -- "$prefix/lib/git-retime" "$prefix/share/doc/git-retime"
printf 'Removed git-retime from %s\n' "$prefix"
