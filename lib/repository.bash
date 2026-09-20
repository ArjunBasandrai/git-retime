#!/usr/bin/env bash

grt_resolve_full_branch_ref() {
    local name=$1 full
    if [[ $name == refs/heads/* ]]; then full=$name; else full="refs/heads/$name"; fi
    git show-ref --verify --quiet "$full" || grt_die "$GRT_EXIT_USAGE" "local branch does not exist: $name"
    printf '%s\n' "$full"
}

grt_collect_scope() {
    local refs_file=$1 universe_file=$2 targets_file=$3
    local -a refs=() tips=() rev_args=()
    local ref oid branch

    if (( GRT_ALL_LOCAL_BRANCHES || GRT_REPO_SCOPE )); then
        while IFS= read -r ref; do refs+=("$ref"); done < <(git for-each-ref --format='%(refname)' refs/heads | LC_ALL=C sort)
    elif (( ${#GRT_BRANCHES[@]} )); then
        for branch in "${GRT_BRANCHES[@]}"; do refs+=("$(grt_resolve_full_branch_ref "$branch")"); done
    else
        ref=$(git symbolic-ref -q HEAD || true)
        if [[ -n $ref ]]; then
            refs+=("$ref")
        else
            (( GRT_ALLOW_DETACHED )) || grt_die "$GRT_EXIT_SAFETY" 'HEAD is detached; use --allow-detached to rewrite it'
            refs+=(HEAD)
        fi
    fi

    (( ${#refs[@]} )) || grt_die "$GRT_EXIT_SAFETY" 'the selected scope has no refs'
    : >"$refs_file"
    for ref in "${refs[@]}"; do
        oid=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null) || grt_die "$GRT_EXIT_USAGE" "ref does not point to a commit: $ref"
        printf '%s\t%s\n' "$ref" "$oid" >>"$refs_file"
        tips+=("$oid")
    done
    LC_ALL=C sort -u -o "$refs_file" "$refs_file"

    git rev-list --topo-order --reverse "${tips[@]}" >"$universe_file" || grt_die "$GRT_EXIT_OBJECT" 'cannot enumerate commits'

    if [[ -n $GRT_RANGE ]]; then
        rev_args+=("$GRT_RANGE")
        if (( GRT_FIRST_PARENT )); then rev_args+=(--first-parent); fi
        git rev-list --topo-order --reverse "${rev_args[@]}" >"$targets_file" || grt_die "$GRT_EXIT_USAGE" "invalid revision range: $GRT_RANGE"
    elif (( GRT_ROOT_SCOPE )); then
        rev_args=(--max-parents=0 --topo-order --reverse)
        if (( GRT_FIRST_PARENT )); then rev_args+=(--first-parent); fi
        git rev-list "${rev_args[@]}" "${tips[@]}" >"$targets_file" || grt_die "$GRT_EXIT_OBJECT" 'cannot select root commits'
    elif (( GRT_LAST > 0 )); then
        rev_args=(--max-count="$GRT_LAST" --topo-order --reverse)
        if (( GRT_FIRST_PARENT )); then rev_args+=(--first-parent); fi
        git rev-list "${rev_args[@]}" "${tips[@]}" >"$targets_file" || grt_die "$GRT_EXIT_OBJECT" 'cannot select recent commits'
    else
        printf '%s\n' "${tips[@]}" | LC_ALL=C sort -u >"$targets_file"
    fi

    if [[ -s $targets_file ]]; then
        local outside
        outside=$(comm -23 <(LC_ALL=C sort -u "$targets_file") <(LC_ALL=C sort -u "$universe_file") | head -1)
        [[ -z $outside ]] || grt_die "$GRT_EXIT_USAGE" "target commit is outside the selected ref scope: $outside"
    else
        grt_die "$GRT_EXIT_USAGE" 'the target selection is empty'
    fi
}

grt_build_metadata() {
    local commits_file=$1 metadata_file=$2
    git log --no-walk=unsorted --stdin --format='%H%x09-%P%x09%at%x09%ai%x09%ct%x09%ci' <"$commits_file" >"$metadata_file" || \
        grt_die "$GRT_EXIT_OBJECT" 'cannot read commit metadata'
}

grt_active_operation_name() {
    local git_dir=$1
    local item
    for item in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
        if [[ -e "$git_dir/$item" ]]; then printf '%s\n' "$item"; return; fi
    done
}

grt_check_repository_safety() {
    local refs_file=$1 closure_file=${2:-}
    local git_dir common_dir active ref upstream other_path other_branch
    git_dir=$(grt_git_dir)
    common_dir=$(grt_git_common_dir)

    if (( ! GRT_ALLOW_DIRTY )); then
        git diff --quiet --ignore-submodules -- || grt_die "$GRT_EXIT_SAFETY" 'the worktree has unstaged changes; use --allow-dirty'
        git diff --cached --quiet --ignore-submodules -- || grt_die "$GRT_EXIT_SAFETY" 'the index has staged changes; use --allow-dirty'
        [[ -z $(git ls-files --others --exclude-standard | head -1) ]] || grt_die "$GRT_EXIT_SAFETY" 'the worktree has untracked files; use --allow-dirty'
    fi

    active=$(grt_active_operation_name "$git_dir")
    if [[ -n $active && $GRT_ALLOW_ACTIVE_OPERATION -eq 0 ]]; then
        grt_die "$GRT_EXIT_SAFETY" "an active Git operation was detected ($active); use --allow-active-operation"
    fi

    if [[ $(git rev-parse --is-shallow-repository) == true && $GRT_ALLOW_SHALLOW -eq 0 ]]; then
        grt_die "$GRT_EXIT_SAFETY" 'the repository is shallow; use --allow-shallow'
    fi

    if [[ -n $(git for-each-ref --format='%(refname)' refs/replace | head -1) && $GRT_ALLOW_REPLACE_REFS -eq 0 ]]; then
        grt_die "$GRT_EXIT_SAFETY" 'replace refs exist; use --allow-replace-refs'
    fi

    if (( ! GRT_ALLOW_PUBLISHED )); then
        while IFS=$'\t' read -r ref _; do
            [[ $ref == refs/heads/* ]] || continue
            upstream=$(git for-each-ref --format='%(upstream)' "$ref")
            if [[ -n $upstream ]]; then
                grt_die "$GRT_EXIT_SAFETY" "branch ${ref#refs/heads/} has an upstream; use --allow-published"
            fi
        done <"$refs_file"
    fi

    if (( ! GRT_ALLOW_LINKED_WORKTREES )); then
        local current_path='' current_branch=''
        while IFS= read -r line; do
            case "$line" in
                worktree\ *) current_path=${line#worktree }; current_branch='' ;;
                branch\ *) current_branch=${line#branch }
                    if [[ -n $current_path && $current_path != "$(pwd -P)" ]] && grep -q -F -x "$current_branch" < <(cut -f1 "$refs_file"); then
                        grt_die "$GRT_EXIT_SAFETY" "an affected branch is checked out in another worktree: $current_path; use --allow-linked-worktrees"
                    fi
                    ;;
            esac
        done < <(git worktree list --porcelain)
    fi

    if [[ -n $closure_file && -s $closure_file ]]; then
        grt_check_rewrite_metadata_safety "$closure_file"
    fi
}

grt_check_rewrite_metadata_safety() {
    local closure_file=$1 oid type target
    if (( ! GRT_ALLOW_INVALID_SIGNATURES )); then
        local signatures="$GRT_TEMP_DIR/signed-commits"
        git cat-file --batch <"$closure_file" | perl "$lib_dir/rewrite-worker.pl" scan-signatures >"$signatures" || \
            grt_die "$GRT_EXIT_OBJECT" 'cannot scan commit signatures'
        if IFS= read -r oid <"$signatures"; then
            grt_die "$GRT_EXIT_SAFETY" "rewriting signed commit $oid invalidates its signature; use --allow-invalid-signatures"
        fi
    fi

    if (( ! GRT_ALLOW_TAG_DIVERGENCE )); then
        local peeled
        while IFS=$'\t' read -r target type peeled; do
            if [[ $type == tag && -n $peeled ]]; then target=$peeled; elif [[ $type != commit ]]; then continue; fi
            if grep -q -F -x "$target" "$closure_file"; then
                grt_die "$GRT_EXIT_SAFETY" "a tag points to rewritten commit $target; use --allow-tag-divergence"
            fi
        done < <(git for-each-ref --format='%(objectname)%09%(objecttype)%09%(*objectname)' refs/tags)
    fi

    if [[ -n $(git for-each-ref --format='%(refname)' refs/notes | head -1) && $GRT_ALLOW_NOTE_DIVERGENCE -eq 0 ]]; then
        grt_die "$GRT_EXIT_SAFETY" 'notes refs exist; use --allow-note-divergence'
    fi
}

grt_calculate_closure() {
    local universe_file=$1 targets_file=$2 metadata_file=$3 closure_file=$4
    declare -A selected=() in_closure=()
    local oid parents parent
    while IFS= read -r oid; do selected[$oid]=1; done <"$targets_file"
    : >"$closure_file"
    while IFS=$'\t' read -r oid parents _; do
        parents=${parents#-}
        if [[ -n ${selected[$oid]+x} ]]; then
            in_closure[$oid]=1
        else
            for parent in $parents; do
                if [[ -n ${in_closure[$parent]+x} ]]; then in_closure[$oid]=1; break; fi
            done
        fi
        if [[ -n ${in_closure[$oid]+x} ]]; then printf '%s\n' "$oid" >>"$closure_file"; fi
    done <"$metadata_file"
}

grt_repository_id() {
    local refs_file=$1 format
    format=$(grt_object_format)
    { printf 'git-retime-repository-v1\n%s\n' "$format"; cut -f1,2 "$refs_file" | LC_ALL=C sort; } | grt_sha256_hex
}
