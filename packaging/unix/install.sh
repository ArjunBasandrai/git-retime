#!/usr/bin/env bash
set -euo pipefail

prefix=/usr/local
while (($#)); do
    case "$1" in
        --prefix) [[ $# -ge 2 ]] || { printf 'install.sh: --prefix requires a value\n' >&2; exit 2; }; prefix=$2; shift 2 ;;
        *) printf 'install.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
install -d -- "$prefix/bin" "$prefix/lib/git-retime" "$prefix/share/doc/git-retime"
install -m 0755 -- "$source_dir/bin/git-retime" "$prefix/bin/git-retime"
for library in "$source_dir"/lib/*.bash "$source_dir"/lib/*.pl; do install -m 0644 -- "$library" "$prefix/lib/git-retime/$(basename -- "$library")"; done
install -m 0644 -- "$source_dir/README.md" "$source_dir/LICENSE" "$prefix/share/doc/git-retime/"
for document in "$source_dir"/docs/*.md; do install -m 0644 -- "$document" "$prefix/share/doc/git-retime/"; done
printf 'Installed git-retime in %s\n' "$prefix"
