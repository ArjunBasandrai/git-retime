#!/usr/bin/env bash

grt_write_plan_header() {
    local output=$1 operation=$2 object_format=$3
    {
        printf 'git-retime-plan\t1\n'
        printf 'object-format\t%s\n' "$object_format"
        printf 'operation\t%s\n' "$operation"
        printf 'seed\t%s\n' "$GRT_SEED"
        printf 'minimum-gap\t%s\n' "$GRT_MINIMUM_GAP"
        printf 'chronology\t%s\n' "$GRT_CHRONOLOGY"
        printf 'field-mode\t%s\n' "$GRT_FIELD_MODE"
    } >"$output"
}

grt_append_plan_refs() {
    local output=$1 refs_file=$2 ref oid
    while IFS=$'\t' read -r ref oid; do printf 'ref\t%s\t%s\n' "$ref" "$oid"; done < <(LC_ALL=C sort "$refs_file") >>"$output"
}

grt_validate_plan() {
    local plan=$1 format='' version='' operation='' gap='' chronology='' mode='' line_no=0 kind
    [[ -f $plan ]] || grt_die "$GRT_EXIT_USAGE" "plan file does not exist: $plan"
    while IFS=$'\t' read -r kind a b c d e f g extra || [[ -n ${kind:-} ]]; do
        line_no=$((line_no + 1))
        case "$kind" in
            git-retime-plan) [[ $a == 1 && -z ${b:-} ]] || grt_die "$GRT_EXIT_USAGE" "invalid plan version at line $line_no"; version=$a ;;
            object-format) [[ $a == sha1 || $a == sha256 ]] || grt_die "$GRT_EXIT_USAGE" "invalid object format at line $line_no"; format=$a ;;
            operation) [[ -n $a && -z ${b:-} ]] || grt_die "$GRT_EXIT_USAGE" "invalid operation record at line $line_no"; operation=$a ;;
            seed) [[ -z ${b:-} ]] || grt_die "$GRT_EXIT_USAGE" "invalid seed record at line $line_no" ;;
            minimum-gap) [[ $a =~ ^[0-9]+$ && -z ${b:-} ]] || grt_die "$GRT_EXIT_USAGE" "invalid minimum gap at line $line_no"; gap=$a ;;
            chronology) [[ $a == strict || $a == off ]] || grt_die "$GRT_EXIT_USAGE" "invalid chronology mode at line $line_no"; chronology=$a ;;
            field-mode) [[ $a == author || $a == committer || $a == both ]] || grt_die "$GRT_EXIT_USAGE" "invalid field mode at line $line_no"; mode=$a ;;
            target)
                grt_oid_is_valid "$format" "$a" || grt_die "$GRT_EXIT_USAGE" "invalid target object ID at line $line_no"
                if [[ $b != - || $c != - || $d != - ]]; then
                    [[ $b =~ ^-?[0-9]+$ && $c =~ ^-?[0-9]+$ && $d =~ ^[+-][0-9]{4}$ ]] || grt_die "$GRT_EXIT_USAGE" "invalid author interval at line $line_no"
                    (( b <= c )) || grt_die "$GRT_EXIT_USAGE" "reversed author interval at line $line_no"
                fi
                if [[ $e != - || $f != - || $g != - ]]; then
                    [[ $e =~ ^-?[0-9]+$ && $f =~ ^-?[0-9]+$ && $g =~ ^[+-][0-9]{4}$ ]] || grt_die "$GRT_EXIT_USAGE" "invalid committer interval at line $line_no"
                    (( e <= f )) || grt_die "$GRT_EXIT_USAGE" "reversed committer interval at line $line_no"
                fi
                [[ -z ${extra:-} ]] || grt_die "$GRT_EXIT_USAGE" "extra target field at line $line_no"
                ;;
            ref)
                git check-ref-format "$a" >/dev/null 2>&1 || [[ $a == HEAD ]] || grt_die "$GRT_EXIT_USAGE" "invalid ref at line $line_no"
                grt_oid_is_valid "$format" "$b" || grt_die "$GRT_EXIT_USAGE" "invalid ref object ID at line $line_no"
                [[ -z ${c:-} ]] || grt_die "$GRT_EXIT_USAGE" "extra ref field at line $line_no"
                ;;
            '') ;;
            *) grt_die "$GRT_EXIT_USAGE" "unknown plan record at line $line_no: $kind" ;;
        esac
    done <"$plan"
    [[ -n $version && -n $format && -n $operation && -n $gap && -n $chronology && -n $mode ]] || grt_die "$GRT_EXIT_USAGE" 'plan header is incomplete'
    [[ $format == "$(grt_object_format)" ]] || grt_die "$GRT_EXIT_USAGE" "plan object format does not match the repository"
    grep -q $'^target\t' "$plan" || grt_die "$GRT_EXIT_USAGE" 'plan has no targets'
    grep -q $'^ref\t' "$plan" || grt_die "$GRT_EXIT_USAGE" 'plan has no refs'
}

grt_plan_header_value() {
    local plan=$1 key=$2
    awk -F '\t' -v key="$key" '$1 == key { print $2; exit }' "$plan"
}

grt_plan_to_scope_files() {
    local plan=$1 refs_file=$2 targets_file=$3 universe_file=$4 metadata_file=$5
    awk -F '\t' '$1 == "ref" { print $2 "\t" $3 }' "$plan" | LC_ALL=C sort -u >"$refs_file"
    awk -F '\t' '$1 == "target" { print $2 }' "$plan" | LC_ALL=C sort -u >"$targets_file"
    local -a tips=()
    local ref oid current
    while IFS=$'\t' read -r ref oid; do
        current=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null || true)
        [[ $current == "$oid" ]] || grt_die "$GRT_EXIT_TRANSACTION" "ref changed after plan creation: $ref"
        tips+=("$oid")
    done <"$refs_file"
    git rev-list --topo-order --reverse "${tips[@]}" >"$universe_file" || grt_die "$GRT_EXIT_OBJECT" 'cannot enumerate plan commits'
    local outside
    outside=$(comm -23 <(LC_ALL=C sort -u "$targets_file") <(LC_ALL=C sort -u "$universe_file") | head -1)
    [[ -z $outside ]] || grt_die "$GRT_EXIT_USAGE" "plan target is outside plan refs: $outside"
    grt_build_metadata "$universe_file" "$metadata_file"
}

grt_solve_plan() {
    local plan=$1 universe_file=$2 metadata_file=$3 solved_file=$4
    local operation seed gap chronology
    operation=$(grt_plan_header_value "$plan" operation)
    seed=$(grt_plan_header_value "$plan" seed)
    gap=$(grt_plan_header_value "$plan" minimum-gap)
    chronology=$(grt_plan_header_value "$plan" chronology)

    declare -A parents=() author_orig=() author_offset=() committer_orig=() committer_offset=()
    declare -A author_low=() author_high=() author_selected=() author_new=()
    declare -A committer_low=() committer_high=() committer_selected=() committer_new=()
    local oid parent_list at ai ct ci al ah ao cl ch co

    while IFS=$'\t' read -r oid parent_list at ai ct ci; do
        parent_list=${parent_list#-}
        parents[$oid]=$parent_list
        author_orig[$oid]=$at
        author_offset[$oid]=${ai: -5}
        committer_orig[$oid]=$ct
        committer_offset[$oid]=${ci: -5}
        author_low[$oid]=$at; author_high[$oid]=$at
        committer_low[$oid]=$ct; committer_high[$oid]=$ct
    done <"$metadata_file"

    while IFS=$'\t' read -r _ oid al ah ao cl ch co; do
        if [[ $al != - ]]; then author_selected[$oid]=1; author_low[$oid]=$al; author_high[$oid]=$ah; author_offset[$oid]=$ao; fi
        if [[ $cl != - ]]; then committer_selected[$oid]=1; committer_low[$oid]=$cl; committer_high[$oid]=$ch; committer_offset[$oid]=$co; fi
    done < <(awk -F '\t' '$1 == "target"' "$plan")

    if [[ $chronology == strict ]]; then
        grt_propagate_bounds "$universe_file" parents author_low author_high author_selected "$gap" author
        grt_propagate_bounds "$universe_file" parents committer_low committer_high committer_selected "$gap" committer
    fi

    : >"$solved_file"
    local lower upper chosen parent candidate
    while IFS= read -r oid; do
        if [[ -n ${author_selected[$oid]+x} ]]; then
            lower=${author_low[$oid]}; upper=${author_high[$oid]}
            if [[ $chronology == strict ]]; then
                for parent in ${parents[$oid]}; do
                    if [[ -n ${author_new[$parent]+x} ]]; then candidate=$((author_new[$parent] + gap)); else candidate=$((author_orig[$parent] + gap)); fi
                    (( candidate > lower )) && lower=$candidate
                done
            fi
            chosen=$(grt_random_second "$seed" "$operation" "$oid" author "$lower" "$upper")
            author_new[$oid]=$chosen
        else
            author_new[$oid]=${author_orig[$oid]}
        fi
        if [[ -n ${committer_selected[$oid]+x} ]]; then
            lower=${committer_low[$oid]}; upper=${committer_high[$oid]}
            if [[ $chronology == strict ]]; then
                for parent in ${parents[$oid]}; do
                    if [[ -n ${committer_new[$parent]+x} ]]; then candidate=$((committer_new[$parent] + gap)); else candidate=$((committer_orig[$parent] + gap)); fi
                    (( candidate > lower )) && lower=$candidate
                done
            fi
            chosen=$(grt_random_second "$seed" "$operation" "$oid" committer "$lower" "$upper")
            committer_new[$oid]=$chosen
        else
            committer_new[$oid]=${committer_orig[$oid]}
        fi
        if [[ -n ${author_selected[$oid]+x} || -n ${committer_selected[$oid]+x} ]]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$oid" "${author_new[$oid]}" "${author_offset[$oid]}" "${committer_new[$oid]}" "${committer_offset[$oid]}" >>"$solved_file"
        fi
    done <"$universe_file"
}

# Arguments 2-5 name associative arrays in the caller.
grt_propagate_bounds() {
    local universe_file=$1 parents_name=$2 low_name=$3 high_name=$4 selected_name=$5 gap=$6 field=$7
    local -n p_ref=$parents_name low_ref=$low_name high_ref=$high_name selected_ref=$selected_name
    local oid parent candidate
    while IFS= read -r oid; do
        for parent in ${p_ref[$oid]}; do
            if [[ -n ${selected_ref[$oid]+x} || -n ${selected_ref[$parent]+x} ]]; then
                candidate=$((low_ref[$parent] + gap))
                (( candidate > low_ref[$oid] )) && low_ref[$oid]=$candidate
            fi
        done
        (( low_ref[$oid] <= high_ref[$oid] )) || grt_die "$GRT_EXIT_CHRONOLOGY" "$field chronology has no solution at commit $oid"
    done <"$universe_file"

    while IFS= read -r oid; do
        for parent in ${p_ref[$oid]}; do
            if [[ -n ${selected_ref[$oid]+x} || -n ${selected_ref[$parent]+x} ]]; then
                candidate=$((high_ref[$oid] - gap))
                (( candidate < high_ref[$parent] )) && high_ref[$parent]=$candidate
                (( low_ref[$parent] <= high_ref[$parent] )) || grt_die "$GRT_EXIT_CHRONOLOGY" "$field chronology has no solution at commit $parent"
            fi
        done
    done < <(tac "$universe_file")
}
