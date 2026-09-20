#!/usr/bin/env bash

grt_usage() {
    cat <<'EOF'
usage: git retime <command> [options]

Commands:
  show audit set shift backdate schedule normalize edit batch
  operations undo redo recover prune-backups apply-plan completion

Run "git retime <command> --help" or read docs/cli.md for the command contract.
EOF
}

grt_initialize_options() {
    GRT_BRANCHES=()
    GRT_ALL_LOCAL_BRANCHES=0 GRT_REPO_SCOPE=0 GRT_LAST=0 GRT_RANGE='' GRT_ROOT_SCOPE=0 GRT_FIRST_PARENT=0
    GRT_FIELD_MODE=both GRT_DATE='' GRT_BY='' GRT_BEFORE='' GRT_START='' GRT_END='' GRT_FILE=''
    GRT_TIMEZONE=Z GRT_SEED="auto-$$-$RANDOM-$(date -u +%s%N)" GRT_MINIMUM_GAP=1 GRT_CHRONOLOGY=strict
    GRT_DRY_RUN=0 GRT_SAVE_PLAN='' GRT_OLDER_THAN=30 GRT_POSITIONAL=()
    GRT_ALLOW_DIRTY=0 GRT_ALLOW_ACTIVE_OPERATION=0 GRT_ALLOW_SHALLOW=0 GRT_ALLOW_REPLACE_REFS=0
    GRT_ALLOW_LINKED_WORKTREES=0 GRT_ALLOW_DETACHED=0 GRT_ALLOW_PUBLISHED=0 GRT_ALLOW_INVALID_SIGNATURES=0
    GRT_ALLOW_TAG_DIVERGENCE=0 GRT_ALLOW_NOTE_DIVERGENCE=0
}

grt_need_option_value() {
    local option=$1 count=$2
    (( count >= 2 )) || grt_die "$GRT_EXIT_USAGE" "option requires a value: $option"
}

grt_parse_options() {
    while (( $# )); do
        case "$1" in
            --branch) grt_need_option_value "$1" "$#"; GRT_BRANCHES+=("$2"); shift 2 ;;
            --all-local-branches) GRT_ALL_LOCAL_BRANCHES=1; shift ;;
            --repo) GRT_REPO_SCOPE=1; shift ;;
            --last) grt_need_option_value "$1" "$#"; GRT_LAST=$2; shift 2 ;;
            --range) grt_need_option_value "$1" "$#"; GRT_RANGE=$2; shift 2 ;;
            --root) GRT_ROOT_SCOPE=1; shift ;;
            --first-parent) GRT_FIRST_PARENT=1; shift ;;
            --author) GRT_FIELD_MODE=author; shift ;;
            --committer) GRT_FIELD_MODE=committer; shift ;;
            --both) GRT_FIELD_MODE=both; shift ;;
            --date) grt_need_option_value "$1" "$#"; GRT_DATE=$2; shift 2 ;;
            --by) grt_need_option_value "$1" "$#"; GRT_BY=$2; shift 2 ;;
            --before) grt_need_option_value "$1" "$#"; GRT_BEFORE=$2; shift 2 ;;
            --start) grt_need_option_value "$1" "$#"; GRT_START=$2; shift 2 ;;
            --end) grt_need_option_value "$1" "$#"; GRT_END=$2; shift 2 ;;
            --file) grt_need_option_value "$1" "$#"; GRT_FILE=$2; shift 2 ;;
            --timezone) grt_need_option_value "$1" "$#"; GRT_TIMEZONE=$2; shift 2 ;;
            --seed) grt_need_option_value "$1" "$#"; GRT_SEED=$2; shift 2 ;;
            --minimum-gap) grt_need_option_value "$1" "$#"; GRT_MINIMUM_GAP=$2; shift 2 ;;
            --chronology) grt_need_option_value "$1" "$#"; GRT_CHRONOLOGY=$2; shift 2 ;;
            --dry-run) GRT_DRY_RUN=1; shift ;;
            --save-plan) grt_need_option_value "$1" "$#"; GRT_SAVE_PLAN=$2; shift 2 ;;
            --older-than) grt_need_option_value "$1" "$#"; GRT_OLDER_THAN=$2; shift 2 ;;
            --allow-dirty) GRT_ALLOW_DIRTY=1; shift ;;
            --allow-active-operation) GRT_ALLOW_ACTIVE_OPERATION=1; shift ;;
            --allow-shallow) GRT_ALLOW_SHALLOW=1; shift ;;
            --allow-replace-refs) GRT_ALLOW_REPLACE_REFS=1; shift ;;
            --allow-linked-worktrees) GRT_ALLOW_LINKED_WORKTREES=1; shift ;;
            --allow-detached) GRT_ALLOW_DETACHED=1; shift ;;
            --allow-published) GRT_ALLOW_PUBLISHED=1; shift ;;
            --allow-invalid-signatures) GRT_ALLOW_INVALID_SIGNATURES=1; shift ;;
            --allow-tag-divergence) GRT_ALLOW_TAG_DIVERGENCE=1; shift ;;
            --allow-note-divergence) GRT_ALLOW_NOTE_DIVERGENCE=1; shift ;;
            --help|-h) grt_usage; exit 0 ;;
            --) shift; while (( $# )); do GRT_POSITIONAL+=("$1"); shift; done ;;
            -*) grt_die "$GRT_EXIT_USAGE" "unknown option: $1" ;;
            *) GRT_POSITIONAL+=("$1"); shift ;;
        esac
    done
    grt_validate_nonnegative_integer '--last' "$GRT_LAST"
    grt_validate_nonnegative_integer '--minimum-gap' "$GRT_MINIMUM_GAP"
    grt_validate_nonnegative_integer '--older-than' "$GRT_OLDER_THAN"
    [[ $GRT_CHRONOLOGY == strict || $GRT_CHRONOLOGY == off ]] || grt_die "$GRT_EXIT_USAGE" '--chronology must be strict or off'
    [[ $GRT_SEED != *$'\t'* && $GRT_SEED != *$'\n'* && $GRT_SEED != *$'\r'* ]] || grt_die "$GRT_EXIT_USAGE" '--seed cannot contain a tab or line break'
    (( !(GRT_ALL_LOCAL_BRANCHES && ${#GRT_BRANCHES[@]} > 0) )) || grt_die "$GRT_EXIT_USAGE" '--all-local-branches and --branch cannot be used together'
    (( !(GRT_REPO_SCOPE && ${#GRT_BRANCHES[@]} > 0) )) || grt_die "$GRT_EXIT_USAGE" '--repo and --branch cannot be used together'
}

grt_plan_target_record() {
    local oid=$1 al=$2 ah=$3 ao=$4 cl=$5 ch=$6 co=$7
    case "$GRT_FIELD_MODE" in
        author) cl=-; ch=-; co=- ;;
        committer) al=-; ah=-; ao=- ;;
    esac
    printf 'target\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$oid" "$al" "$ah" "$ao" "$cl" "$ch" "$co"
}

grt_generate_operation_plan() {
    local operation=$1 refs_file=$2 targets_file=$3 metadata_file=$4 plan=$5
    local records="$GRT_TEMP_DIR/target-records" oid parents at ai ct ci low high zone duration
    declare -A is_target=()
    while IFS= read -r oid; do is_target[$oid]=1; done <"$targets_file"
    : >"$records"

    case "$operation" in
        set)
            [[ -n $GRT_DATE ]] || grt_die "$GRT_EXIT_USAGE" 'set requires --date'
            IFS=$'\t' read -r low high zone < <(grt_parse_date_interval "$GRT_DATE" "$GRT_TIMEZONE")
            while IFS= read -r oid; do grt_plan_target_record "$oid" "$low" "$high" "$zone" "$low" "$high" "$zone"; done <"$targets_file" >"$records"
            ;;
        shift)
            [[ -n $GRT_BY ]] || grt_die "$GRT_EXIT_USAGE" 'shift requires --by'
            duration=$(grt_parse_duration "$GRT_BY")
            while IFS=$'\t' read -r oid parents at ai ct ci; do
                parents=${parents#-}
                [[ -n ${is_target[$oid]+x} ]] || continue
                grt_plan_target_record "$oid" "$((at + duration))" "$((at + duration))" "${ai: -5}" "$((ct + duration))" "$((ct + duration))" "${ci: -5}"
            done <"$metadata_file" >"$records"
            ;;
        backdate)
            [[ -n $GRT_BEFORE ]] || grt_die "$GRT_EXIT_USAGE" 'backdate requires --before'
            IFS=$'\t' read -r low high zone < <(grt_parse_date_interval "$GRT_BEFORE" "$GRT_TIMEZONE")
            while IFS=$'\t' read -r oid parents at ai ct ci; do
                parents=${parents#-}
                [[ -n ${is_target[$oid]+x} ]] || continue
                local ah=$high ch=$high
                (( at - 1 < ah )) && ah=$((at - 1))
                (( ct - 1 < ch )) && ch=$((ct - 1))
                if [[ $GRT_FIELD_MODE != committer && $low -gt $ah ]]; then grt_die "$GRT_EXIT_CHRONOLOGY" "backdate interval is not earlier than author timestamp of commit $oid"; fi
                if [[ $GRT_FIELD_MODE != author && $low -gt $ch ]]; then grt_die "$GRT_EXIT_CHRONOLOGY" "backdate interval is not earlier than committer timestamp of commit $oid"; fi
                grt_plan_target_record "$oid" "$low" "$ah" "$zone" "$low" "$ch" "$zone"
            done <"$metadata_file" >"$records"
            ;;
        schedule)
            [[ -n $GRT_START && -n $GRT_END ]] || grt_die "$GRT_EXIT_USAGE" 'schedule requires --start and --end'
            local start_low start_high start_zone end_low end_high end_zone count index=0 value
            IFS=$'\t' read -r start_low start_high start_zone < <(grt_parse_date_interval "$GRT_START" "$GRT_TIMEZONE")
            IFS=$'\t' read -r end_low end_high end_zone < <(grt_parse_date_interval "$GRT_END" "$GRT_TIMEZONE")
            (( start_low <= end_high )) || grt_die "$GRT_EXIT_USAGE" 'schedule start is after schedule end'
            count=$(wc -l <"$targets_file")
            while IFS= read -r oid; do
                if (( count == 1 )); then value=$start_low; else value=$((start_low + index * (end_high - start_low) / (count - 1))); fi
                grt_plan_target_record "$oid" "$value" "$value" "$start_zone" "$value" "$value" "$start_zone"
                index=$((index + 1))
            done <"$targets_file" >"$records"
            ;;
        normalize)
            grt_generate_normalize_records "$metadata_file" "$records"
            ;;
        *) grt_die "$GRT_EXIT_INTERNAL" "unsupported plan operation: $operation" ;;
    esac
    [[ -s $records ]] || grt_die "$GRT_EXIT_USAGE" 'the operation does not select a timestamp change'
    grt_write_plan_header "$plan" "$operation" "$(grt_object_format)"
    LC_ALL=C sort -t $'\t' -k2,2 "$records" >>"$plan"
    grt_append_plan_refs "$plan" "$refs_file"
}

grt_generate_normalize_records() {
    local metadata_file=$1 records=$2 oid parents at ai ct ci parent lower new_at new_ct changed
    declare -A author_value=() committer_value=()
    : >"$records"
    while IFS=$'\t' read -r oid parents at ai ct ci; do
        parents=${parents#-}
        new_at=$at; new_ct=$ct
        for parent in $parents; do
            lower=$((author_value[$parent] + GRT_MINIMUM_GAP)); (( lower > new_at )) && new_at=$lower
            lower=$((committer_value[$parent] + GRT_MINIMUM_GAP)); (( lower > new_ct )) && new_ct=$lower
        done
        author_value[$oid]=$new_at; committer_value[$oid]=$new_ct
        changed=0
        [[ $GRT_FIELD_MODE == committer ]] || (( new_at != at )) && changed=1
        [[ $GRT_FIELD_MODE == author ]] || (( new_ct != ct )) && changed=1
        if (( changed )); then
            grt_plan_target_record "$oid" "$new_at" "$new_at" "${ai: -5}" "$new_ct" "$new_ct" "${ci: -5}" >>"$records"
        fi
    done <"$metadata_file"
}

grt_generate_batch_plan() {
    local refs_file=$1 universe_file=$2 input=$3 plan=$4 records="$GRT_TEMP_DIR/target-records"
    local line_no=0 revision author_date committer_date oid al ah ao cl ch co extra
    [[ -f $input ]] || grt_die "$GRT_EXIT_USAGE" "batch file does not exist: $input"
    : >"$records"
    while IFS=$'\t' read -r revision author_date committer_date extra || [[ -n ${revision:-} ]]; do
        line_no=$((line_no + 1))
        committer_date=${committer_date%$'\r'}
        [[ -n $revision && $revision != \#* ]] || continue
        [[ -z ${extra:-} ]] || grt_die "$GRT_EXIT_USAGE" "extra batch field at line $line_no"
        oid=$(git rev-parse --verify "$revision^{commit}" 2>/dev/null) || grt_die "$GRT_EXIT_USAGE" "invalid batch revision at line $line_no: $revision"
        grep -q -F -x "$oid" "$universe_file" || grt_die "$GRT_EXIT_USAGE" "batch revision is outside the selected scope at line $line_no"
        if [[ $author_date == - || -z $author_date ]]; then al=-; ah=-; ao=-; else IFS=$'\t' read -r al ah ao < <(grt_parse_date_interval "$author_date" "$GRT_TIMEZONE"); fi
        if [[ $committer_date == - || -z $committer_date ]]; then cl=-; ch=-; co=-; else IFS=$'\t' read -r cl ch co < <(grt_parse_date_interval "$committer_date" "$GRT_TIMEZONE"); fi
        [[ $al != - || $cl != - ]] || grt_die "$GRT_EXIT_USAGE" "batch line $line_no changes no field"
        printf 'target\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$oid" "$al" "$ah" "$ao" "$cl" "$ch" "$co" >>"$records"
    done <"$input"
    [[ -s $records ]] || grt_die "$GRT_EXIT_USAGE" 'batch file has no operations'
    [[ $(cut -f2 "$records" | sort | uniq -d | head -1) == '' ]] || grt_die "$GRT_EXIT_USAGE" 'batch file selects a commit more than once'
    grt_write_plan_header "$plan" batch "$(grt_object_format)"
    LC_ALL=C sort -t $'\t' -k2,2 "$records" >>"$plan"
    grt_append_plan_refs "$plan" "$refs_file"
}

grt_save_or_print_plan() {
    local plan=$1
    if [[ -n $GRT_SAVE_PLAN ]]; then
        cp -- "$plan" "$GRT_SAVE_PLAN"
        printf 'Saved plan to %s\n' "$GRT_SAVE_PLAN"
    fi
    if (( GRT_DRY_RUN )); then cat "$plan"; fi
}

grt_execute_plan() {
    local plan=$1
    local refs_file="$GRT_TEMP_DIR/refs.tsv" targets_file="$GRT_TEMP_DIR/targets" universe_file="$GRT_TEMP_DIR/universe"
    local metadata_file="$GRT_TEMP_DIR/metadata.tsv" closure_file="$GRT_TEMP_DIR/closure" solved_file="$GRT_TEMP_DIR/solved.tsv" map_file="$GRT_TEMP_DIR/map.tsv"
    grt_validate_plan "$plan"
    grt_plan_to_scope_files "$plan" "$refs_file" "$targets_file" "$universe_file" "$metadata_file"
    grt_calculate_closure "$universe_file" "$targets_file" "$metadata_file" "$closure_file"
    grt_check_repository_safety "$refs_file" "$closure_file"
    grt_solve_plan "$plan" "$universe_file" "$metadata_file" "$solved_file"
    if (( GRT_DRY_RUN )); then cat "$plan"; return; fi
    grt_rewrite_graph "$universe_file" "$metadata_file" "$solved_file" "$map_file" "$closure_file"
    grt_apply_rewrite "$plan" "$refs_file" "$map_file"
}

grt_command_mutate() {
    local operation=$1
    local refs_file="$GRT_TEMP_DIR/refs.tsv" targets_file="$GRT_TEMP_DIR/targets" universe_file="$GRT_TEMP_DIR/universe" metadata_file="$GRT_TEMP_DIR/metadata.tsv" plan="$GRT_TEMP_DIR/plan"
    grt_collect_scope "$refs_file" "$universe_file" "$targets_file"
    grt_build_metadata "$universe_file" "$metadata_file"
    if [[ $operation == batch ]]; then
        [[ -n $GRT_FILE ]] || grt_die "$GRT_EXIT_USAGE" 'batch requires --file'
        grt_generate_batch_plan "$refs_file" "$universe_file" "$GRT_FILE" "$plan"
    else
        grt_generate_operation_plan "$operation" "$refs_file" "$targets_file" "$metadata_file" "$plan"
    fi
    grt_save_or_print_plan "$plan"
    (( GRT_DRY_RUN )) || grt_execute_plan "$plan"
}

grt_command_show() {
    local refs_file="$GRT_TEMP_DIR/refs.tsv" targets_file="$GRT_TEMP_DIR/targets" universe_file="$GRT_TEMP_DIR/universe" metadata_file="$GRT_TEMP_DIR/metadata.tsv"
    GRT_ALLOW_DETACHED=1
    grt_collect_scope "$refs_file" "$universe_file" "$targets_file"
    grt_build_metadata "$universe_file" "$metadata_file"
    declare -A selected=(); local oid parents at ai ct ci
    while IFS= read -r oid; do selected[$oid]=1; done <"$targets_file"
    printf 'OID\tAUTHOR\tCOMMITTER\tSUBJECT\n'
    while IFS=$'\t' read -r oid parents at ai ct ci; do
        parents=${parents#-}
        [[ -n ${selected[$oid]+x} ]] || continue
        printf '%s\t%s\t%s\t%s\n' "$oid" "$(grt_format_iso "$at" "${ai: -5}")" "$(grt_format_iso "$ct" "${ci: -5}")" "$(git show -s --format=%s "$oid")"
    done <"$metadata_file"
}

grt_command_audit() {
    local refs_file="$GRT_TEMP_DIR/refs.tsv" targets_file="$GRT_TEMP_DIR/targets" universe_file="$GRT_TEMP_DIR/universe" metadata_file="$GRT_TEMP_DIR/metadata.tsv"
    GRT_ALLOW_DETACHED=1
    grt_collect_scope "$refs_file" "$universe_file" "$targets_file"
    grt_build_metadata "$universe_file" "$metadata_file"
    declare -A author=() committer=(); local oid parents at ai ct ci parent violations=0
    while IFS=$'\t' read -r oid parents at ai ct ci; do
        parents=${parents#-}
        for parent in $parents; do
            if (( at < author[$parent] + GRT_MINIMUM_GAP )); then printf 'author\t%s\t%s\t%s\t%s\n' "$parent" "$oid" "${author[$parent]}" "$at"; violations=$((violations + 1)); fi
            if (( ct < committer[$parent] + GRT_MINIMUM_GAP )); then printf 'committer\t%s\t%s\t%s\t%s\n' "$parent" "$oid" "${committer[$parent]}" "$ct"; violations=$((violations + 1)); fi
        done
        author[$oid]=$at; committer[$oid]=$ct
    done <"$metadata_file"
    printf 'Audited %s commits. Found %s chronology violations.\n' "$(wc -l <"$universe_file")" "$violations"
}

grt_command_edit() {
    local refs_file="$GRT_TEMP_DIR/refs.tsv" targets_file="$GRT_TEMP_DIR/targets" universe_file="$GRT_TEMP_DIR/universe" metadata_file="$GRT_TEMP_DIR/metadata.tsv" edit_file="$GRT_TEMP_DIR/edit.tsv"
    grt_collect_scope "$refs_file" "$universe_file" "$targets_file"
    grt_build_metadata "$universe_file" "$metadata_file"
    { printf '# revision\tauthor-date\tcommitter-date\n'; while IFS= read -r oid; do printf '%s\t-\t-\n' "$oid"; done <"$targets_file"; } >"$edit_file"
    "${GIT_EDITOR:-${VISUAL:-vi}}" "$edit_file"
    GRT_FILE=$edit_file
    grt_command_mutate batch
}

grt_command_operations() {
    local dir manifest
    dir="$(grt_git_common_dir)/git-retime/operations"
    printf 'ID\tSTATE\tCREATED\n'
    [[ -d $dir ]] || return 0
    for manifest in "$dir"/*.manifest; do
        [[ -f $manifest ]] || continue
        printf '%s\t%s\t%s\n' "$(grt_plan_header_value "$manifest" id)" "$(grt_plan_header_value "$manifest" state)" "$(grt_plan_header_value "$manifest" created)"
    done
}

grt_command_prune() {
    local dir manifest created cutoff id backup oid
    dir="$(grt_git_common_dir)/git-retime/operations"
    cutoff=$(($(date -u +%s) - GRT_OLDER_THAN * 86400))
    [[ -d $dir ]] || { printf 'No backups were pruned.\n'; return; }
    for manifest in "$dir"/*.manifest; do
        [[ -f $manifest ]] || continue
        created=$(grt_plan_header_value "$manifest" created)
        [[ $created =~ ^[0-9]+$ ]] || continue
        (( created <= cutoff )) || continue
        while IFS=$'\t' read -r _ ref old new backup; do
            oid=$(git rev-parse --verify "$backup" 2>/dev/null || true)
            [[ -z $oid ]] || git update-ref -d "$backup" "$oid" || grt_die "$GRT_EXIT_TRANSACTION" "cannot delete backup ref: $backup"
        done < <(awk -F '\t' '$1 == "ref"' "$manifest")
        grt_set_manifest_state "$manifest" pruned
        printf 'Pruned backups for %s\n' "$(grt_plan_header_value "$manifest" id)"
    done
}

grt_command_completion() {
    local shell=${GRT_POSITIONAL[0]:-}
    case "$shell" in
        bash)
            cat <<'EOF'
_git_retime_complete() {
    local commands='show audit set shift backdate schedule normalize edit batch operations undo redo recover prune-backups apply-plan completion'
    COMPREPLY=( $(compgen -W "$commands" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _git_retime_complete git-retime
EOF
            ;;
        powershell)
            cat <<'EOF'
Register-ArgumentCompleter -Native -CommandName git-retime -ScriptBlock {
    param($wordToComplete)
    'show','audit','set','shift','backdate','schedule','normalize','edit','batch','operations','undo','redo','recover','prune-backups','apply-plan','completion' |
        Where-Object { $_ -like "$wordToComplete*" }
}
EOF
            ;;
        *) grt_die "$GRT_EXIT_USAGE" 'completion requires bash or powershell' ;;
    esac
}

git_retime_main() {
    grt_require_command git
    grt_require_command perl
    grt_require_git_version
    export GIT_NO_REPLACE_OBJECTS=1
    local command=${1:-}
    if [[ -z $command || $command == --help || $command == -h ]]; then grt_usage; return 0; fi
    if [[ $command == --version ]]; then printf 'git-retime 0.1.0\n'; return 0; fi
    shift
    grt_initialize_options
    grt_parse_options "$@"
    if [[ $command == completion ]]; then grt_command_completion; return; fi
    grt_require_git_repository
    GRT_TEMP_DIR=$(grt_make_temp_dir)
    trap grt_cleanup_temp_dir EXIT HUP INT TERM

    case "$command" in
        show) grt_command_show ;;
        audit) grt_command_audit ;;
        set|shift|backdate|schedule|normalize|batch) grt_command_mutate "$command" ;;
        edit) grt_command_edit ;;
        operations) grt_command_operations ;;
        undo|redo) grt_replay_manifest "$command" "${GRT_POSITIONAL[0]:-}" ;;
        recover) grt_recover_operations ;;
        prune-backups) grt_command_prune ;;
        apply-plan)
            [[ -n ${GRT_POSITIONAL[0]:-} ]] || grt_die "$GRT_EXIT_USAGE" 'apply-plan requires a plan path'
            grt_execute_plan "${GRT_POSITIONAL[0]}"
            ;;
        *) grt_die "$GRT_EXIT_USAGE" "unknown command: $command" ;;
    esac
}
