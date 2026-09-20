#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

kind=${1:-}
repository=${2:-}
seed=${3:-1729}
size=${4:-}

[[ $kind =~ ^(linear|branches|merge|mixed)$ && -n $repository && $seed =~ ^[0-9]+$ ]] || {
    printf 'usage: generate-repository.bash linear|branches|merge|mixed PATH SEED [SIZE]\n' >&2
    exit 2
}

random_state=$seed
random_value=0
next_random() {
    random_state=$(((random_state * 1103515245 + 12345) & 0x7fffffff))
    random_value=$random_state
}

git init -q -b main "$repository"
git -C "$repository" config user.name 'Stress Fixture'
git -C "$repository" config user.email 'stress@example.com'
git -C "$repository" config git-retime.fixtureKind "$kind"
git -C "$repository" config git-retime.fixtureSeed "$seed"
stream=$(mktemp /tmp/git-retime-fast-import.XXXXXXXX)
trap 'rm -f -- "$stream"' EXIT
mark=0

emit_commit() {
    local ref=$1 parent=$2 epoch=$3 offset=$4 message=$5
    shift 5
    mark=$((mark + 1))
    {
        printf 'commit %s\nmark :%s\nauthor Stress Fixture <stress@example.com> %s %s\ncommitter Stress Fixture <stress@example.com> %s %s\ndata %s\n%s\n' \
            "$ref" "$mark" "$epoch" "$offset" "$epoch" "$offset" "${#message}" "$message"
        [[ -z $parent ]] || printf 'from :%s\n' "$parent"
        local merge
        for merge in "$@"; do printf 'merge :%s\n' "$merge"; done
        printf '\n'
    } >>"$stream"
}

case "$kind" in
    linear)
        count=${size:-10000}
        parent=''
        for ((index=1; index<=count; index++)); do
            emit_commit refs/heads/main "$parent" "$((1500000000 + index * 2))" +0000 "linear $index seed $seed"
            parent=$mark
        done
        ;;
    branches)
        branch_count=${size:-300}
        declare -a base_marks=()
        parent=''
        for ((index=1; index<=200; index++)); do
            emit_commit refs/heads/main "$parent" "$((1500000000 + index * 20))" +0000 "base $index seed $seed"
            parent=$mark; base_marks[index]=$mark
        done
        for ((branch=1; branch<=branch_count; branch++)); do
            next_random; base_index=$((1 + random_value % 200)); parent=${base_marks[$base_index]}
            next_random; length=$((1 + random_value % 12)); ref=$(printf 'refs/heads/topic/%03d' "$branch")
            for ((index=1; index<=length; index++)); do
                emit_commit "$ref" "$parent" "$((1600000000 + branch * 100 + index * 2))" +0000 "branch $branch commit $index seed $seed"
                parent=$mark
            done
        done
        ;;
    merge)
        topic_count=${size:-120}
        emit_commit refs/heads/main '' 1600000000 +0000 "merge base seed $seed"
        main_mark=$mark
        topic=1
        while ((topic <= topic_count)); do
            merges=()
            for ((slot=0; slot<6 && topic<=topic_count; slot++,topic++)); do
                ref=$(printf 'refs/heads/topic/%03d' "$topic")
                emit_commit "$ref" "$main_mark" "$((1600000000 + topic * 20))" +0000 "topic $topic first seed $seed"
                topic_parent=$mark
                emit_commit "$ref" "$topic_parent" "$((1600000001 + topic * 20))" +0000 "topic $topic second seed $seed"
                merges+=("$mark")
            done
            emit_commit refs/heads/main "$main_mark" "$((1700000000 + topic * 20))" +0000 "octopus group $topic seed $seed" "${merges[@]}"
            main_mark=$mark
        done
        ;;
    mixed)
        count=${size:-3000}
        parent=''
        offsets=(+0000 -0400 +0530 +1245 -0330)
        for ((index=1; index<=count; index++)); do
            epoch=$((1550000000 + index * 30))
            if ((index % 17 == 0)); then epoch=$((epoch - 600)); fi
            offset=${offsets[index % ${#offsets[@]}]}
            if ((index % 101 == 0)); then message=$'mixed unicode café — commit '"$index"$'\n\nline with trailing spaces  '
            else message="mixed $index seed $seed"; fi
            emit_commit refs/heads/main "$parent" "$epoch" "$offset" "$message"
            parent=$mark
        done
        ;;
esac

git -C "$repository" fast-import --quiet <"$stream"
git -C "$repository" checkout -q main

if [[ $kind == mixed ]]; then
    mapfile -t commits < <(git -C "$repository" rev-list --reverse main)
    for ((index=99; index<${#commits[@]}; index+=300)); do git -C "$repository" tag "sample-$index" "${commits[$index]}"; done
    for ((index=149; index<${#commits[@]}; index+=500)); do
        GIT_AUTHOR_DATE='@1700000000 +0000' GIT_COMMITTER_DATE='@1700000000 +0000' git -C "$repository" notes add -m "note $index seed $seed" "${commits[$index]}"
    done
    git -C "$repository" branch worktree-sample "${commits[100]}"
    git -C "$repository" worktree add -q "$repository-linked" worktree-sample
    git -C "$repository" update-ref refs/remotes/origin/main "${commits[2000]}"
fi

printf '%s\t%s\t%s\n' "$kind" "$seed" "$(git -C "$repository" rev-list --all --count)"
