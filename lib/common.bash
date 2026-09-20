#!/usr/bin/env bash

readonly GRT_EXIT_USAGE=2
readonly GRT_EXIT_SAFETY=3
readonly GRT_EXIT_CHRONOLOGY=4
readonly GRT_EXIT_OBJECT=5
readonly GRT_EXIT_TRANSACTION=6
readonly GRT_EXIT_RECOVERY=7
readonly GRT_EXIT_INTERNAL=8

grt_die() {
    local code=$1
    shift
    printf 'git-retime: %s\n' "$*" >&2
    exit "$code"
}

grt_warn() {
    printf 'git-retime: warning: %s\n' "$*" >&2
}

grt_require_command() {
    command -v "$1" >/dev/null 2>&1 || grt_die "$GRT_EXIT_INTERNAL" "required command is not available: $1"
}

grt_require_git_repository() {
    git rev-parse --git-dir >/dev/null 2>&1 || grt_die "$GRT_EXIT_SAFETY" 'the current directory is not a Git repository'
}

grt_require_git_version() {
    local version major minor
    version=$(git version | awk '{print $3}')
    if [[ $version =~ ^([0-9]+)\.([0-9]+) ]]; then major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; else grt_die "$GRT_EXIT_INTERNAL" "cannot parse Git version: $version"; fi
    if (( major < 2 || (major == 2 && minor < 38) )); then grt_die "$GRT_EXIT_INTERNAL" "Git 2.38 or later is required: $version"; fi
}

grt_git_common_dir() {
    local path
    path=$(git rev-parse --git-common-dir) || return
    (cd -- "$path" && pwd -P)
}

grt_git_dir() {
    local path
    path=$(git rev-parse --git-dir) || return
    (cd -- "$path" && pwd -P)
}

grt_object_format() {
    local format
    format=$(git rev-parse --show-object-format 2>/dev/null || true)
    case "$format" in
        sha1|sha256) printf '%s\n' "$format" ;;
        *) grt_die "$GRT_EXIT_OBJECT" "unsupported Git object format: ${format:-unknown}" ;;
    esac
}

grt_make_temp_dir() {
    local common_dir
    common_dir=$(grt_git_common_dir)
    mkdir -p -- "$common_dir/git-retime/tmp"
    mktemp -d "$common_dir/git-retime/tmp/run.XXXXXXXX"
}

grt_cleanup_temp_dir() {
    if [[ -n ${GRT_TEMP_DIR:-} && -d $GRT_TEMP_DIR ]]; then
        rm -rf -- "$GRT_TEMP_DIR"
    fi
}

grt_sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        grt_die "$GRT_EXIT_INTERNAL" 'sha256sum or shasum is required'
    fi
}

grt_random_second() {
    local seed=$1 operation=$2 oid=$3 field=$4 low=$5 high=$6
    local size record digest prefix value
    (( high >= low )) || grt_die "$GRT_EXIT_CHRONOLOGY" "empty timestamp interval for $oid $field"
    size=$((high - low + 1))
    printf -v record 'git-retime-random-v1\n%s\n%s\n%s\n%s\n%s\n%s' \
        "$seed" "$operation" "$oid" "$field" "$low" "$high"
    digest=$(printf '%s' "$record" | grt_sha256_hex)
    prefix=${digest:0:13}
    value=$((16#$prefix))
    printf '%s\n' "$((low + value % size))"
}

grt_validate_integer() {
    local name=$1 value=$2
    [[ $value =~ ^-?[0-9]+$ ]] || grt_die "$GRT_EXIT_USAGE" "$name must be an integer: $value"
}

grt_validate_nonnegative_integer() {
    local name=$1 value=$2
    [[ $value =~ ^[0-9]+$ ]] || grt_die "$GRT_EXIT_USAGE" "$name must be a nonnegative integer: $value"
}

grt_oid_is_valid() {
    local format=$1 oid=$2
    case "$format" in
        sha1) [[ $oid =~ ^[0-9a-f]{40}$ ]] ;;
        sha256) [[ $oid =~ ^[0-9a-f]{64}$ ]] ;;
        *) return 1 ;;
    esac
}

grt_now_id() {
    local stamp random
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    random=$(printf '%s\n' "$$-$RANDOM-$(date +%s%N)" | grt_sha256_hex)
    printf '%s-%s\n' "$stamp" "${random:0:12}"
}

grt_write_atomic() {
    local target=$1 source=$2 directory temporary
    directory=$(dirname -- "$target")
    mkdir -p -- "$directory"
    temporary="$target.tmp.$$"
    cp -- "$source" "$temporary"
    mv -f -- "$temporary" "$target"
}
