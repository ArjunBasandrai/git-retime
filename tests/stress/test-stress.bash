#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
generator="$project_root/tests/stress/generate-repository.bash"
retime="$project_root/bin/git-retime"
root=$(mktemp -d /tmp/git-retime-stress.XXXXXXXX)
start_time=$(date +%s)
tests=0
cleanup() {
    if [[ -d "$root/mixed-linked" ]]; then git -C "$root/mixed" worktree remove -f "$root/mixed-linked" >/dev/null 2>&1 || true; fi
    rm -rf -- "$root"
}
trap cleanup EXIT
pass(){ tests=$((tests+1)); printf 'ok %d - %s\n' "$tests" "$1"; }

bash "$generator" linear "$root/linear" 104729 10000
[[ $(git -C "$root/linear" rev-list --count main) -eq 10000 ]]
(cd "$root/linear" && "$retime" audit --repo >/dev/null)
linear_old=$(git -C "$root/linear" rev-parse HEAD)
(cd "$root/linear" && "$retime" shift --by 1s --root --chronology off >/dev/null)
[[ $(git -C "$root/linear" rev-list --count main) -eq 10000 ]]
[[ $(git -C "$root/linear" rev-parse HEAD) != "$linear_old" ]]
(cd "$root/linear" && "$retime" set --date 2031 --last 10 --seed stress-linear >/dev/null)
pass '10,000-commit linear repository and full closure rewrite'

bash "$generator" branches "$root/branches" 130363 300
[[ $(git -C "$root/branches" for-each-ref --format='%(refname)' refs/heads | wc -l) -ge 301 ]]
(cd "$root/branches" && "$retime" set --date 2032 --all-local-branches --seed stress-branches --chronology off >/dev/null)
(cd "$root/branches" && "$retime" show --branch topic/001 >/dev/null)
pass '300-branch repository with varied lengths and shared ancestry'

bash "$generator" merge "$root/merge" 155921 120
[[ $(git -C "$root/merge" for-each-ref --format='%(refname)' refs/heads/topic | wc -l) -eq 120 ]]
[[ $(git -C "$root/merge" rev-list --min-parents=3 --count main) -ge 20 ]]
(cd "$root/merge" && "$retime" schedule --start 2033-01-01 --end 2033-12-31 --all-local-branches --seed stress-merge --chronology off >/dev/null)
(cd "$root/merge" && "$retime" audit --repo >/dev/null)
pass '120-topic merge DAG with octopus merges'

bash "$generator" mixed "$root/mixed" 196613 3000
[[ $(git -C "$root/mixed" rev-list --count main) -eq 3000 ]]
[[ -n $(git -C "$root/mixed" for-each-ref --format='%(refname)' refs/tags | head -1) ]]
[[ -n $(git -C "$root/mixed" for-each-ref --format='%(refname)' refs/notes | head -1) ]]
(cd "$root/mixed" && "$retime" audit --repo >/dev/null)
(cd "$root/mixed" && "$retime" normalize --repo --allow-linked-worktrees --allow-tag-divergence --allow-note-divergence >/dev/null)
(cd "$root/mixed" && "$retime" backdate --before 2010 --root --chronology off --allow-linked-worktrees --allow-tag-divergence --allow-note-divergence >/dev/null)
mixed_head=$(git -C "$root/mixed" rev-parse HEAD)
printf '%s\t%s\t%s\n' "$mixed_head" 2034-05 2034-06 >"$root/mixed-batch.tsv"
(cd "$root/mixed" && "$retime" batch --file "$root/mixed-batch.tsv" --allow-linked-worktrees --allow-tag-divergence --allow-note-divergence >/dev/null)
pass '3,000-commit mixed repository with metadata hazards and chronology repair'

printf '1..%d\n' "$tests"
printf 'stress_elapsed_seconds=%s\n' "$(( $(date +%s) - start_time ))"
