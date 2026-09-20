#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
retime="$project_root/bin/git-retime"
test_root=$(mktemp -d /tmp/git-retime-unix-tests.XXXXXXXX)
tests=0

cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

pass() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_equal() { [[ $1 == "$2" ]] || fail "$3: expected [$1], got [$2]"; }
assert_not_equal() { [[ $1 != "$2" ]] || fail "$3: values are equal"; }

run_expect() {
    local expected=$1
    shift
    set +e
    "$@" >"$test_root/stdout" 2>"$test_root/stderr"
    local actual=$?
    set -e
    [[ $actual -eq $expected ]] || { cat "$test_root/stdout" "$test_root/stderr" >&2; fail "expected exit $expected, got $actual: $*"; }
}

init_repo() {
    local repo=$1
    git init -q -b main "$repo"
    git -C "$repo" config user.name Test
    git -C "$repo" config user.email test@example.com
}

make_linear() {
    local repo=$1 count=$2 start=${3:-1704067200} index epoch
    init_repo "$repo"
    for ((index=0; index<count; index++)); do
        epoch=$((start + index * 100))
        printf '%s\n' "$index" >>"$repo/data.txt"
        git -C "$repo" add data.txt
        GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" git -C "$repo" commit -q -m "commit $index"
    done
}

test_version_and_help() {
    [[ $($retime --version) == 'git-retime 0.1.0' ]] || fail version
    $retime -h | grep -q 'usage: git retime'
    $retime -h | grep -q -- '--commit REVISION'
    pass 'version and help'
}

test_linear_and_transactions() {
    local repo="$test_root/linear" old new operation author committer
    make_linear "$repo" 4
    old=$(git -C "$repo" rev-parse HEAD)
    (cd "$repo" && "$retime" set --date 2025 --last 1 --seed smoke --dry-run --save-plan "$test_root/linear.plan") >/dev/null
    grep -q $'^target\t' "$test_root/linear.plan"
    (cd "$repo" && "$retime" apply-plan "$test_root/linear.plan") >/dev/null
    new=$(git -C "$repo" rev-parse HEAD)
    assert_not_equal "$old" "$new" 'set must rewrite HEAD'
    author=$(git -C "$repo" show -s --format=%at HEAD)
    committer=$(git -C "$repo" show -s --format=%ct HEAD)
    (( author >= 1735689600 && author <= 1767225599 )) || fail 'partial year range'
    (( committer >= 1735689600 && committer <= 1767225599 )) || fail 'partial year committer range'
    operation=$(cd "$repo" && "$retime" operations | awk 'NR==2 {print $1}')
    (cd "$repo" && "$retime" undo "$operation") >/dev/null
    assert_equal "$old" "$(git -C "$repo" rev-parse HEAD)" 'undo'
    (cd "$repo" && "$retime" redo "$operation") >/dev/null
    assert_equal "$new" "$(git -C "$repo" rev-parse HEAD)" 'redo'
    pass 'set, partial date, plan, backup, undo, and redo'
}

test_field_modes_and_operations() {
    local repo="$test_root/fields" before_author before_committer after_author after_committer batch_oid
    make_linear "$repo" 5
    before_author=$(git -C "$repo" show -s --format=%at HEAD)
    before_committer=$(git -C "$repo" show -s --format=%ct HEAD)
    (cd "$repo" && "$retime" shift --by 2h --author --chronology off) >/dev/null
    after_author=$(git -C "$repo" show -s --format=%at HEAD)
    after_committer=$(git -C "$repo" show -s --format=%ct HEAD)
    assert_equal "$((before_author + 7200))" "$after_author" 'author shift'
    assert_equal "$before_committer" "$after_committer" 'committer preservation'
    (cd "$repo" && "$retime" schedule --start 2027-01-01 --end 2027-01-03 --last 3 --chronology strict) >/dev/null
    (cd "$repo" && "$retime" backdate --before 2020 --root --chronology off) >/dev/null
    batch_oid=$(git -C "$repo" rev-parse HEAD)
    printf '%s\t%s\t%s\n' "$batch_oid" '2028-03-04T05:06:07Z' '-' >"$test_root/batch.tsv"
    (cd "$repo" && "$retime" batch --file "$test_root/batch.tsv") >/dev/null
    assert_equal 1835759167 "$(git -C "$repo" show -s --format=%at HEAD)" 'batch author timestamp'
    pass 'field modes, shift, schedule, backdate, and batch'
}

test_normalize_and_audit() {
    local repo="$test_root/normalize" output
    make_linear "$repo" 3
    (cd "$repo" && "$retime" set --date 2010-01-01T00:00:00Z --chronology off) >/dev/null
    output=$(cd "$repo" && "$retime" audit --repo)
    grep -q 'chronology violations' <<<"$output"
    (cd "$repo" && "$retime" normalize --repo) >/dev/null
    output=$(cd "$repo" && "$retime" audit --repo)
    grep -q 'Found 0 chronology violations' <<<"$output"
    pass 'audit and DAG normalization'
}

test_merge_and_branch_scope() {
    local repo="$test_root/merge" base main_before topic_before main_after topic_after head_dates
    make_linear "$repo" 2
    git -C "$repo" branch topic HEAD
    printf 'main\n' >>"$repo/data.txt"; git -C "$repo" add data.txt; git -C "$repo" commit -q -m main
    git -C "$repo" switch -q topic
    printf 'topic\n' >"$repo/topic.txt"; git -C "$repo" add topic.txt; git -C "$repo" commit -q -m topic
    git -C "$repo" switch -q main
    git -C "$repo" merge -q --no-ff topic -m merge
    main_before=$(git -C "$repo" rev-parse main); topic_before=$(git -C "$repo" rev-parse topic); head_dates=$(git -C "$repo" show -s --format='%at %ct' main)
    (cd "$repo" && "$retime" shift --by 1d --branch main --root --chronology off --allow-tag-divergence) >/dev/null
    main_after=$(git -C "$repo" rev-parse main); topic_after=$(git -C "$repo" rev-parse topic)
    assert_not_equal "$main_before" "$main_after" 'merge branch closure'
    assert_equal "$topic_before" "$topic_after" 'out-of-scope branch'
    assert_equal "$head_dates" "$(git -C "$repo" show -s --format='%at %ct' main)" 'closure-only timestamp preservation'
    [[ $(git -C "$repo" show -s --format=%P main | wc -w) -eq 2 ]] || fail 'merge parents'
    pass 'branch scope and merge closure'
}

test_exact_commit_selection() {
    local repo="$test_root/exact-commit" full short tagged plan targets outside before_target before_head
    make_linear "$repo" 5
    full=$(git -C "$repo" rev-parse HEAD~3); short=${full:0:8}
    tagged=$(git -C "$repo" rev-parse HEAD~2); git -C "$repo" tag selected HEAD~2
    plan="$test_root/exact-commit.plan"
    (cd "$repo" && "$retime" shift --by 1h --commit "$short" --commit selected --dry-run --save-plan "$plan") >/dev/null
    targets=$(grep -c $'^target\t' "$plan")
    assert_equal 2 "$targets" 'exact commit target count'
    grep -q $'^target\t'"$full"$'\t' "$plan" || fail 'short commit resolution'
    grep -q $'^target\t'"$tagged"$'\t' "$plan" || fail 'tag commit resolution'
    run_expect 2 bash -c "cd '$repo' && '$retime' shift --by 1h --commit '$full' --commit '$short'"
    run_expect 2 bash -c "cd '$repo' && '$retime' shift --by 1h --commit missing-revision"
    run_expect 2 bash -c "cd '$repo' && '$retime' shift --by 1h --commit HEAD --last 1"
    git -C "$repo" switch -q --orphan outside
    printf 'outside\n' >"$repo/outside.txt"; git -C "$repo" add outside.txt; git -C "$repo" commit -q -m outside
    outside=$(git -C "$repo" rev-parse HEAD); git -C "$repo" switch -q main
    run_expect 2 bash -c "cd '$repo' && '$retime' shift --by 1h --commit '$outside'"
    git -C "$repo" tag -d selected >/dev/null
    before_target=$(git -C "$repo" show -s --format=%at HEAD~3); before_head=$(git -C "$repo" show -s --format='%at %ct' HEAD)
    (cd "$repo" && "$retime" shift --by 2h --commit HEAD~3 --chronology off) >/dev/null
    assert_equal "$((before_target + 7200))" "$(git -C "$repo" show -s --format=%at HEAD~3)" 'exact commit timestamp'
    assert_equal "$before_head" "$(git -C "$repo" show -s --format='%at %ct' HEAD)" 'exact commit descendant timestamps'
    pass 'exact commit selection and descendant closure'
}

test_byte_preservation() {
    local repo="$test_root/bytes" tree parent old new
    make_linear "$repo" 1
    tree=$(git -C "$repo" show -s --format=%T HEAD); parent=$(git -C "$repo" rev-parse HEAD)
    {
        printf 'tree %s\nparent %s\nauthor Tést <test@example.com> 1704067300 +0530\ncommitter Test <test@example.com> 1704067301 -0400\nencoding ISO-8859-1\nx-extra value\n continuation\n\nmessage with trailing spaces  \r\nsecond line\r\n' "$tree" "$parent"
    } >"$test_root/raw.commit"
    old=$(git -C "$repo" hash-object -t commit -w "$test_root/raw.commit")
    git -C "$repo" update-ref refs/heads/main "$old" "$parent"
    perl -0777 -pe 's/(?<=author T\x{c3}\x{a9}st <test\@example\.com> )1704067300 \+0530/1800000000 +0000/; s/(?<=committer Test <test\@example\.com> )1704067301 -0400/1800000000 +0000/' "$test_root/raw.commit" >"$test_root/expected.commit"
    (cd "$repo" && "$retime" set --date 2027-01-15T08:00:00Z --chronology off) >/dev/null
    new=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" cat-file commit "$new" >"$test_root/actual.commit"
    # Build the exact expected epoch with GNU date to avoid a constant error.
    local epoch; epoch=$(date --date='2027-01-15T08:00:00Z' +%s)
    perl -0777 -pe "s/1800000000 \+0000/$epoch +0000/g" "$test_root/expected.commit" >"$test_root/expected-final.commit"
    cmp "$test_root/expected-final.commit" "$test_root/actual.commit" || fail 'raw commit byte preservation'
    pass 'byte preservation for Unicode, CRLF message data, and unknown headers'
}

test_safety_and_concurrency() {
    local repo="$test_root/safety" old
    make_linear "$repo" 2
    printf 'dirty\n' >>"$repo/data.txt"
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h"
    git -C "$repo" restore data.txt
    git -C "$repo" tag -a -m keep keep HEAD
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h"
    (cd "$repo" && "$retime" shift --by 1h --allow-tag-divergence) >/dev/null
    git -C "$repo" notes add -m note HEAD
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h --allow-tag-divergence"
    old=$(git -C "$repo" rev-parse HEAD)
    (cd "$repo" && "$retime" set --date 2030 --dry-run --save-plan "$test_root/stale.plan" --allow-tag-divergence --allow-note-divergence) >/dev/null
    printf 'next\n' >"$repo/next.txt"; git -C "$repo" add next.txt; git -C "$repo" commit -q -m next
    run_expect 6 bash -c "cd '$repo' && '$retime' apply-plan '$test_root/stale.plan' --allow-tag-divergence --allow-note-divergence"
    pass 'dirty, tag, note, and concurrent-ref safety'
}

test_recovery() {
    local repo old changed stage
    for stage in after-manifest after-backups before-refs after-refs; do
        repo="$test_root/recovery-$stage"
        make_linear "$repo" 2
        old=$(git -C "$repo" rev-parse HEAD)
        run_expect 6 bash -c "cd '$repo' && GIT_RETIME_FAIL_STAGE=$stage '$retime' shift --by 1h"
        changed=$(git -C "$repo" rev-parse HEAD)
        if [[ $stage == after-refs ]]; then assert_not_equal "$old" "$changed" 'injected transaction must update ref'; else assert_equal "$old" "$changed" 'pre-transaction failure'; fi
        (cd "$repo" && "$retime" recover) >/dev/null
        assert_equal "$old" "$(git -C "$repo" rev-parse HEAD)" 'recovery rollback'
    done
    pass 'four-stage failure injection and crash recovery'
}

test_remaining_safety_modes() {
    local repo="$test_root/safety-modes" oid tree signed linked="$test_root/linked" shallow="$test_root/shallow"
    make_linear "$repo" 3

    touch "$repo/.git/MERGE_HEAD"
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h"
    rm -- "$repo/.git/MERGE_HEAD"

    git -C "$repo" remote add origin https://example.invalid/repository.git
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
    git -C "$repo" config branch.main.remote origin
    git -C "$repo" config branch.main.merge refs/heads/main
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h"
    (cd "$repo" && "$retime" shift --by 1h --allow-published) >/dev/null
    git -C "$repo" config --unset branch.main.remote
    git -C "$repo" config --unset branch.main.merge

    git -C "$repo" branch linked HEAD
    git -C "$repo" worktree add -q "$linked" linked
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h --all-local-branches"
    git -C "$repo" worktree remove -f "$linked"

    oid=$(git -C "$repo" rev-list --max-parents=0 HEAD)
    git -C "$repo" replace "$oid" HEAD
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h"
    git -C "$repo" replace -d "$oid" >/dev/null

    git -C "$repo" switch -q --detach
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h"
    (cd "$repo" && "$retime" shift --by 1h --allow-detached) >/dev/null
    git -C "$repo" switch -q main

    tree=$(git -C "$repo" show -s --format=%T HEAD); oid=$(git -C "$repo" rev-parse HEAD)
    {
        printf 'tree %s\nparent %s\nauthor Test <test@example.com> 1704067600 +0000\ncommitter Test <test@example.com> 1704067600 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n fake\n -----END PGP SIGNATURE-----\n\nsigned\n' "$tree" "$oid"
    } >"$test_root/signed.commit"
    signed=$(git -C "$repo" hash-object -t commit -w "$test_root/signed.commit")
    git -C "$repo" update-ref refs/heads/main "$signed" "$oid"
    run_expect 3 bash -c "cd '$repo' && '$retime' shift --by 1h --chronology off"
    (cd "$repo" && "$retime" shift --by 1h --chronology off --allow-invalid-signatures) >/dev/null

    git clone -q --depth=1 "file://$repo" "$shallow"
    run_expect 3 bash -c "cd '$shallow' && '$retime' shift --by 1h"
    (cd "$shallow" && "$retime" shift --by 1h --chronology off --allow-shallow --allow-published --allow-invalid-signatures) >/dev/null
    pass 'active operation, published, worktree, replace, detached, signature, and shallow safety'
}

test_sha256() {
    local repo="$test_root/sha256"
    if ! git init -q --object-format=sha256 "$repo" 2>/dev/null; then pass 'SHA-256 unavailable (skipped)'; return; fi
    git -C "$repo" config user.name Test; git -C "$repo" config user.email test@example.com
    printf 'sha256\n' >"$repo/data"; git -C "$repo" add data; git -C "$repo" commit -q -m sha256
    (cd "$repo" && "$retime" shift --by 1h --chronology off) >/dev/null
    [[ $(git -C "$repo" rev-parse HEAD) =~ ^[0-9a-f]{64}$ ]] || fail 'SHA-256 OID length'
    pass 'SHA-256 repository'
}

test_edit_prune_and_completion() {
    local repo="$test_root/maintenance" editor="$project_root/tests/fixtures/edit-plan.bash"
    make_linear "$repo" 2
    (cd "$repo" && GIT_EDITOR="$editor" "$retime" edit --chronology off) >/dev/null
    assert_equal 2059366028 "$(git -C "$repo" show -s --format=%at HEAD)" 'edit timestamp'
    (cd "$repo" && "$retime" prune-backups --older-than 0) >/dev/null
    [[ -z $(git -C "$repo" for-each-ref --format='%(refname)' refs/git-retime/backups) ]] || fail 'prune backups'
    "$retime" completion bash | grep -q 'complete -F'
    "$retime" completion powershell | grep -q 'Register-ArgumentCompleter'
    pass 'edit, backup pruning, and completion'
}

test_version_and_help
test_linear_and_transactions
test_field_modes_and_operations
test_normalize_and_audit
test_merge_and_branch_scope
test_exact_commit_selection
test_byte_preservation
test_safety_and_concurrency
test_recovery
test_remaining_safety_modes
test_sha256
test_edit_prune_and_completion
printf '1..%d\n' "$tests"
