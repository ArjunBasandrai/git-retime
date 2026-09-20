#!/usr/bin/env bash

grt_rewrite_commit_object() {
    local old_oid=$1 parent_map_file=$2 author_epoch=$3 author_zone=$4 committer_epoch=$5 committer_zone=$6
    local perl_program
    read -r -d '' perl_program <<'PERL' || true
use strict;
use warnings;
binmode STDIN;
binmode STDOUT;

my %parent_map;
if (open my $map, '<:raw', $ENV{GRT_PARENT_MAP}) {
    while (my $line = <$map>) {
        $line =~ s/\r?\n\z//;
        my ($old, $new) = split /\t/, $line, 2;
        $parent_map{$old} = $new if defined $new;
    }
    close $map;
}

local $/;
my $raw = <STDIN>;
defined $raw or die "empty commit object\n";
my $lf = index($raw, "\n\n");
my $crlf = index($raw, "\r\n\r\n");
my ($header_end, $separator_length);
if ($crlf >= 0 && ($lf < 0 || $crlf <= $lf)) {
    $header_end = $crlf;
    $separator_length = 4;
} elsif ($lf >= 0) {
    $header_end = $lf;
    $separator_length = 2;
} else {
    die "commit object has no header separator\n";
}

my $header = substr($raw, 0, $header_end);
my $tail = substr($raw, $header_end);
my @lines = split /(?<=\n)/, $header, -1;
for my $line (@lines) {
    if ($line =~ /\Aparent ([0-9a-f]+)(\r?\n)?\z/) {
        my ($old, $ending) = ($1, defined($2) ? $2 : '');
        $line = 'parent ' . ($parent_map{$old} // $old) . $ending;
    } elsif ($ENV{GRT_CHANGE_AUTHOR} eq '1' &&
             $line =~ /\Aauthor (.*) (-?[0-9]+) ([+-][0-9]{4})(\r?\n)?\z/s) {
        my ($identity, $ending) = ($1, defined($4) ? $4 : '');
        $line = 'author ' . $identity . ' ' . $ENV{GRT_AUTHOR_EPOCH} . ' ' . $ENV{GRT_AUTHOR_ZONE} . $ending;
    } elsif ($ENV{GRT_CHANGE_COMMITTER} eq '1' &&
             $line =~ /\Acommitter (.*) (-?[0-9]+) ([+-][0-9]{4})(\r?\n)?\z/s) {
        my ($identity, $ending) = ($1, defined($4) ? $4 : '');
        $line = 'committer ' . $identity . ' ' . $ENV{GRT_COMMITTER_EPOCH} . ' ' . $ENV{GRT_COMMITTER_ZONE} . $ending;
    }
}
print @lines, $tail;
PERL

    git cat-file commit "$old_oid" | env \
        GRT_PARENT_MAP="$parent_map_file" \
        GRT_CHANGE_AUTHOR=$([[ $author_epoch == - ]] && printf 0 || printf 1) \
        GRT_AUTHOR_EPOCH="$author_epoch" GRT_AUTHOR_ZONE="$author_zone" \
        GRT_CHANGE_COMMITTER=$([[ $committer_epoch == - ]] && printf 0 || printf 1) \
        GRT_COMMITTER_EPOCH="$committer_epoch" GRT_COMMITTER_ZONE="$committer_zone" \
        perl -e "$perl_program" | git hash-object -t commit -w --stdin || \
        grt_die "$GRT_EXIT_OBJECT" "cannot rewrite commit object: $old_oid"
}

grt_rewrite_graph() {
    local universe_file=$1 metadata_file=$2 solved_file=$3 map_file=$4 closure_file=$5
    declare -A parents=() selected=() new_author_epoch=() new_author_zone=() new_committer_epoch=() new_committer_zone=()
    declare -A rewritten=()
    local oid parent_list at ai ct ci ae az ce cz parent new_parent new_oid changed parent_pairs output_path

    while IFS=$'\t' read -r oid parent_list at ai ct ci; do parents[$oid]=${parent_list#-}; done <"$metadata_file"
    while IFS=$'\t' read -r oid ae az ce cz; do
        selected[$oid]=1
        new_author_epoch[$oid]=$ae; new_author_zone[$oid]=$az
        new_committer_epoch[$oid]=$ce; new_committer_zone[$oid]=$cz
    done <"$solved_file"

    local raw_dir="$GRT_TEMP_DIR/raw" rewritten_dir="$GRT_TEMP_DIR/rewritten"
    local paths_file="$GRT_TEMP_DIR/rewritten-paths" expected_file="$GRT_TEMP_DIR/expected-oids" actual_file="$GRT_TEMP_DIR/actual-oids"
    mkdir -p -- "$raw_dir" "$rewritten_dir"
    git cat-file --batch <"$closure_file" | perl "$lib_dir/rewrite-worker.pl" extract "$raw_dir" || \
        grt_die "$GRT_EXIT_OBJECT" 'cannot read commit objects in batch'
    coproc GRT_REWRITE_WORKER { perl "$lib_dir/rewrite-worker.pl" rewrite "$raw_dir" "$rewritten_dir" "$(grt_object_format)"; }
    local worker_in=${GRT_REWRITE_WORKER[1]} worker_out=${GRT_REWRITE_WORKER[0]} worker_pid=$GRT_REWRITE_WORKER_PID
    : >"$map_file"; : >"$paths_file"; : >"$expected_file"
    while IFS= read -r oid; do
        changed=0
        parent_pairs=''
        for parent in ${parents[$oid]}; do
            new_parent=${rewritten[$parent]:-$parent}
            if [[ -n $parent_pairs ]]; then parent_pairs+=,; fi
            parent_pairs+="$parent=$new_parent"
            [[ $new_parent != "$parent" ]] && changed=1
        done
        [[ -n ${selected[$oid]+x} ]] && changed=1
        if (( changed )); then
            if [[ -n ${selected[$oid]+x} ]]; then
                ae=${new_author_epoch[$oid]}; az=${new_author_zone[$oid]}
                ce=${new_committer_epoch[$oid]}; cz=${new_committer_zone[$oid]}
            else
                ae=-; az=-; ce=-; cz=-
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$oid" "$ae" "$az" "$ce" "$cz" "$parent_pairs" >&"$worker_in"
            IFS=$'\t' read -r new_oid output_path <&"$worker_out" || grt_die "$GRT_EXIT_OBJECT" "rewrite worker stopped at commit: $oid"
            rewritten[$oid]=$new_oid
            printf '%s\n' "$output_path" >>"$paths_file"
            printf '%s\n' "$new_oid" >>"$expected_file"
        else
            rewritten[$oid]=$oid
            new_oid=$oid
        fi
        printf '%s\t%s\n' "$oid" "$new_oid" >>"$map_file"
    done <"$universe_file"
    exec {worker_in}>&-
    wait "$worker_pid" || grt_die "$GRT_EXIT_OBJECT" 'rewrite worker failed'
    git hash-object -t commit -w --stdin-paths <"$paths_file" >"$actual_file" || grt_die "$GRT_EXIT_OBJECT" 'cannot write commit objects in batch'
    cmp -s "$expected_file" "$actual_file" || grt_die "$GRT_EXIT_OBJECT" 'Git object IDs do not match calculated object IDs'
}

grt_backup_ref_name() {
    local operation_id=$1 ref=$2 suffix
    if [[ $ref == HEAD ]]; then suffix=detached-head; else suffix=${ref#refs/}; fi
    printf 'refs/git-retime/backups/%s/%s\n' "$operation_id" "$suffix"
}

grt_manifest_path() {
    local operation_id=$1
    printf '%s/git-retime/operations/%s.manifest\n' "$(grt_git_common_dir)" "$operation_id"
}

grt_set_manifest_state() {
    local manifest=$1 new_state=$2 temporary="$manifest.state.$$"
    awk -F '\t' -v OFS='\t' -v state="$new_state" '$1 == "state" { $2=state } { print }' "$manifest" >"$temporary"
    mv -f -- "$temporary" "$manifest"
}

grt_apply_ref_transaction() {
    local updates_file=$1 operation_id=${2:-} plan=${3:-} manifest='' ref old new backup zero
    local common_dir manifest_tmp repository_id plan_digest
    common_dir=$(grt_git_common_dir)
    mkdir -p -- "$common_dir/git-retime/operations"
    [[ -n $operation_id ]] || operation_id=$(grt_now_id)
    manifest=$(grt_manifest_path "$operation_id")
    [[ ! -e $manifest ]] || grt_die "$GRT_EXIT_TRANSACTION" "operation ID already exists: $operation_id"

    if [[ $(grt_object_format) == sha1 ]]; then zero=$(printf '%040d' 0); else zero=$(printf '%064d' 0); fi
    manifest_tmp="$GRT_TEMP_DIR/manifest"
    {
        printf 'git-retime-operation\t1\n'
        printf 'id\t%s\n' "$operation_id"
        printf 'state\tprepared\n'
        printf 'created\t%s\n' "$(date -u +%s)"
        printf 'object-format\t%s\n' "$(grt_object_format)"
        printf 'repository-id\t%s\n' "$(grt_repository_id "$updates_file")"
        if [[ -n $plan ]]; then printf 'plan-sha256\t%s\n' "$(grt_sha256_hex <"$plan")"; fi
        while IFS=$'\t' read -r ref old new; do
            backup=$(grt_backup_ref_name "$operation_id" "$ref")
            printf 'ref\t%s\t%s\t%s\t%s\n' "$ref" "$old" "$new" "$backup"
        done <"$updates_file"
    } >"$manifest_tmp"

    grt_write_atomic "$manifest" "$manifest_tmp"
    if [[ ${GIT_RETIME_FAIL_STAGE:-} == after-manifest ]]; then grt_die "$GRT_EXIT_TRANSACTION" 'injected failure after manifest creation'; fi
    while IFS=$'\t' read -r ref old new; do
        backup=$(grt_backup_ref_name "$operation_id" "$ref")
        git update-ref "$backup" "$old" "$zero" || grt_die "$GRT_EXIT_TRANSACTION" "cannot create backup ref: $backup"
    done <"$updates_file"
    if [[ ${GIT_RETIME_FAIL_STAGE:-} == after-backups ]]; then grt_die "$GRT_EXIT_TRANSACTION" 'injected failure after backup creation'; fi
    if [[ ${GIT_RETIME_FAIL_STAGE:-} == before-refs ]]; then grt_die "$GRT_EXIT_TRANSACTION" 'injected failure before ref transaction'; fi

    local transaction="$GRT_TEMP_DIR/ref-transaction"
    {
        printf 'start\n'
        if grep -q $'^HEAD\t' "$updates_file"; then printf 'option no-deref\n'; fi
        while IFS=$'\t' read -r ref old new; do printf 'update %s %s %s\n' "$ref" "$new" "$old"; done <"$updates_file"
        printf 'prepare\ncommit\n'
    } >"$transaction"
    if ! git update-ref --stdin <"$transaction" >/dev/null; then
        grt_die "$GRT_EXIT_TRANSACTION" 'the ref transaction failed; refs changed concurrently or Git rejected an update'
    fi
    if [[ ${GIT_RETIME_FAIL_STAGE:-} == after-refs ]]; then grt_die "$GRT_EXIT_TRANSACTION" 'injected failure after ref transaction'; fi
    grt_set_manifest_state "$manifest" committed
    printf '%s\n' "$operation_id"
}

grt_apply_rewrite() {
    local plan=$1 refs_file=$2 map_file=$3
    declare -A new_oid=()
    local old new ref expected updates_file operation_id
    while IFS=$'\t' read -r old new; do new_oid[$old]=$new; done <"$map_file"
    updates_file="$GRT_TEMP_DIR/updates.tsv"
    : >"$updates_file"
    while IFS=$'\t' read -r ref expected; do
        new=${new_oid[$expected]:-$expected}
        [[ $new != "$expected" ]] || continue
        printf '%s\t%s\t%s\n' "$ref" "$expected" "$new" >>"$updates_file"
    done <"$refs_file"
    [[ -s $updates_file ]] || grt_die "$GRT_EXIT_USAGE" 'the operation does not change a selected ref'
    operation_id=$(grt_apply_ref_transaction "$updates_file" '' "$plan")
    printf 'Applied operation %s\n' "$operation_id"
}

grt_select_manifest() {
    local requested=${1:-} wanted_state=${2:-} operations_dir manifest state
    operations_dir="$(grt_git_common_dir)/git-retime/operations"
    if [[ -n $requested ]]; then
        manifest="$operations_dir/$requested.manifest"
        [[ -f $manifest ]] || grt_die "$GRT_EXIT_USAGE" "operation does not exist: $requested"
        printf '%s\n' "$manifest"
        return
    fi
    [[ -d $operations_dir ]] || grt_die "$GRT_EXIT_USAGE" 'there are no recorded operations'
    while IFS= read -r manifest; do
        state=$(grt_plan_header_value "$manifest" state)
        if [[ -z $wanted_state || $state == "$wanted_state" ]]; then printf '%s\n' "$manifest"; return; fi
    done < <(find "$operations_dir" -maxdepth 1 -type f -name '*.manifest' -print | LC_ALL=C sort -r)
    grt_die "$GRT_EXIT_USAGE" "there is no operation in state ${wanted_state:-any}"
}

grt_replay_manifest() {
    local action=$1 requested=${2:-} wanted new_state manifest transaction ref old new backup current
    if [[ $action == undo ]]; then wanted=committed; new_state=undone; else wanted=undone; new_state=committed; fi
    manifest=$(grt_select_manifest "$requested" "$wanted")
    transaction="$GRT_TEMP_DIR/ref-transaction"
    {
        printf 'start\n'
        if awk -F '\t' '$1 == "ref" && $2 == "HEAD" { found=1 } END { exit !found }' "$manifest"; then printf 'option no-deref\n'; fi
        while IFS=$'\t' read -r _ ref old new backup; do
            if [[ $action == undo ]]; then printf 'update %s %s %s\n' "$ref" "$old" "$new"; else printf 'update %s %s %s\n' "$ref" "$new" "$old"; fi
        done < <(awk -F '\t' '$1 == "ref"' "$manifest")
        printf 'prepare\ncommit\n'
    } >"$transaction"
    git update-ref --stdin <"$transaction" >/dev/null || grt_die "$GRT_EXIT_TRANSACTION" "$action failed because a ref does not have the expected value"
    grt_set_manifest_state "$manifest" "$new_state"
    printf '%s operation %s\n' "${action^}" "$(grt_plan_header_value "$manifest" id)"
}

grt_recover_operations() {
    local operations_dir manifest state transaction ref old new backup current changed operation_id
    operations_dir="$(grt_git_common_dir)/git-retime/operations"
    [[ -d $operations_dir ]] || { printf 'No recovery work is required.\n'; return; }
    for manifest in "$operations_dir"/*.manifest; do
        [[ -f $manifest ]] || continue
        state=$(grt_plan_header_value "$manifest" state)
        [[ $state == prepared ]] || continue
        changed=0
        transaction="$GRT_TEMP_DIR/recovery-transaction"
        { printf 'start\n'; if awk -F '\t' '$1 == "ref" && $2 == "HEAD" { found=1 } END { exit !found }' "$manifest"; then printf 'option no-deref\n'; fi; } >"$transaction"
        while IFS=$'\t' read -r _ ref old new backup; do
            current=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null || true)
            if [[ $current == "$new" ]]; then
                printf 'update %s %s %s\n' "$ref" "$old" "$new" >>"$transaction"
                changed=1
            elif [[ $current != "$old" ]]; then
                grt_die "$GRT_EXIT_RECOVERY" "cannot recover $ref because it has an unrelated value"
            fi
        done < <(awk -F '\t' '$1 == "ref"' "$manifest")
        if (( changed )); then
            printf 'prepare\ncommit\n' >>"$transaction"
            git update-ref --stdin <"$transaction" >/dev/null || grt_die "$GRT_EXIT_RECOVERY" "cannot roll back prepared operation $(grt_plan_header_value "$manifest" id)"
        fi
        grt_set_manifest_state "$manifest" rolled-back
        printf 'Recovered operation %s by rollback.\n' "$(grt_plan_header_value "$manifest" id)"
    done
}
