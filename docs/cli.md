# Command line guide

This document is the main reference for `git-retime`. It explains command
behavior, date selection, scope, safety checks, plans, and recovery.

## Help and version

```text
git retime -h
git retime --version
```

Use `-h` for the command summary. Git reserves `git retime --help` for an
installed manual page. This release has one top-level help screen. It does not
have separate help screens for individual commands.

## Quick start

Run all commands inside the repository that you want to inspect or change.

Show the five newest commits on the current branch:

```text
git retime show --last 5
```

Create a deterministic plan that moves those commits into September 2026:

```text
git retime set --date 2026-09 --last 5 --seed example \
  --dry-run --save-plan retime.plan
```

Review `retime.plan`. Apply the same plan without recalculating its dates:

```text
git retime apply-plan retime.plan
```

Inspect the recorded operation:

```text
git retime operations
```

Undo the newest committed operation if necessary:

```text
git retime undo
```

## How a rewrite works

A command has three related sets:

- **Refs** are the local branches or detached `HEAD` that the command can
  update.
- **Targets** are the commits whose timestamps the command selects.
- **Rewrite closure** contains each target and every reachable descendant that
  needs a new parent object ID.

A descendant in the rewrite closure keeps its original timestamps unless the
command also selects that descendant. Its object ID still changes when a
parent object ID changes.

Every mutating command creates replacement commit objects and then updates all
selected refs in one checked Git transaction. It does not run rebase, amend,
or `git filter-branch`.

## Command summary

```text
git retime show [scope]
git retime audit [ref scope] [--minimum-gap SECONDS]
git retime set --date DATE [scope] [field options]
git retime shift --by DURATION [scope] [field options]
git retime backdate --before DATE [scope] [field options]
git retime schedule --start DATE --end DATE [scope] [field options]
git retime normalize [ref scope] [field options]
git retime edit [scope]
git retime batch --file PATH [ref scope]
git retime operations
git retime undo [OPERATION-ID]
git retime redo [OPERATION-ID]
git retime recover
git retime prune-backups [--older-than DAYS]
git retime apply-plan PLAN
git retime completion bash|powershell
```

## Scope selection

Scope has two parts. Ref options select the refs that can move. Commit options
select timestamp targets within the history of those refs.

### Ref options

- `--branch NAME` selects one local branch. Repeat the option to select more
  branches. A short name such as `main` and a full name such as
  `refs/heads/main` are valid.
- `--all-local-branches` selects all local branch refs.
- `--repo` selects all local branch refs. In this release, it is a convenience
  form of `--all-local-branches`.
- With no ref option, the current branch is selected.
- A detached `HEAD` requires `--allow-detached`. In that case, `HEAD` is the
  ref that the command updates.

Do not combine `--branch` with `--repo` or `--all-local-branches`.

### Commit options

- `--last N` selects at most the newest `N` commits across the selected refs.
- `--commit REVISION` selects one exact commit. A full object ID, an
  unambiguous short object ID, a tag that points to a commit, or a revision
  expression such as `HEAD~3` is valid. Repeat the option to select more
  commits. The result must be inside the selected ref history.
- `--range REVISION-RANGE` passes one revision expression to `git rev-list`.
  The result must be inside the selected ref history.
- `--root` selects each root commit in the selected ref history.
- `--first-parent` applies first-parent traversal to `--last`, `--range`, or
  `--root` target selection.
- With no commit option, the selected branch tips are the targets.

Do not combine `--commit` with `--last`, `--range`, `--root`, or
`--first-parent`. If two `--commit` values resolve to the same commit, the
command stops with a usage error.

`--commit` changes the timestamp of the selected commit only. Descendants must
still get new object IDs because their parent object IDs change. Those
descendants keep their existing timestamps unless another `--commit` option
selects them.

Examples:

```text
git retime show --last 10
git retime show --commit HEAD~3
git retime show --range HEAD~5..HEAD
git retime show --branch main --branch release --last 20
git retime set --date 2026-09-19 --root
git retime shift --by 2h --repo --range feature~3..feature
git retime shift --by 2h --commit HEAD~3
git retime set --date 2026-09-19T23 --commit a1b2c3d --commit release-candidate
```

`audit` and `normalize` inspect the full history reachable from the selected
refs. Use their ref options to control that history. Commit options do not
reduce their inspection to a partial history.

## Timestamp fields

- `--author` changes author timestamps only.
- `--committer` changes committer timestamps only.
- `--both` changes both fields. This is the default.

The author and committer fields use separate deterministic selections. Thus,
one partial date can produce different author and committer seconds.

Examples:

```text
git retime set --date 2026-09-19T22 --last 1 --author
git retime shift --by 30m --last 3 --committer
git retime set --date 2026-09-19T22:30:00-04:00 --last 1 --both
```

## Date input

Accepted ISO date forms are:

```text
2026
2026-09
2026-09-10
2026-09-10T14
2026-09-10T14:30
2026-09-10T14:30:45
2026-09-10T14:30:45Z
2026-09-10T14:30:45-04:00
```

A complete timestamp identifies one exact second. A partial date identifies a
closed interval:

| Input | Interval |
| --- | --- |
| `2026` | The complete year |
| `2026-09` | The complete month |
| `2026-09-10` | The complete day |
| `2026-09-10T14` | The complete hour |
| `2026-09-10T14:30` | The complete minute |
| `2026-09-10T14:30:45` | One exact second |

`set`, `backdate`, `batch`, and `edit` select an integer second from each
partial-date interval. The selection is deterministic for the same seed,
operation, old commit object ID, field, and final interval bounds.

Use `--seed TEXT` to reproduce a selection:

```text
git retime set --date 2026-09-19T22 --timezone -04:00 \
  --last 4 --seed late-night
```

If `--seed` is absent, each new plan gets a unique automatic seed. A seed
cannot contain a tab or line break.

### Timezones

A date with `Z` uses UTC. A date with an explicit offset uses that offset. A
date without an offset uses the value from `--timezone`. The default is UTC.

```text
git retime set --date 2026-09-19T22 --timezone -04:00 --last 1
git retime set --date 2026-09-19T22:15:00Z --last 1
```

`--timezone` accepts `Z`, `UTC`, or a fixed offset such as `-04:00` or `-0400`.
It does not accept an IANA name such as `America/New_York`. A fixed offset does
not calculate daylight-saving changes.

## Durations

A duration has an optional sign followed by one or more number-unit pairs.

| Unit | Meaning |
| --- | --- |
| `w` | Weeks |
| `d` | Days |
| `h` | Hours |
| `m` | Minutes |
| `s` | Seconds |

Examples:

```text
2h
-30m
1w2d4h
-2d4h30m
```

## Chronology

The default rule for each enabled field is:

```text
child >= parent + minimum_gap
```

- `--minimum-gap SECONDS` sets a nonnegative gap. The default is `1`.
- `--chronology strict` applies the rule and stops if no solution exists. This
  is the default.
- `--chronology off` accepts the requested timestamps without DAG chronology
  constraints.

Strict mode narrows the selected date intervals around changed edges before it
selects timestamps. An unchanged commit is a fixed point. Existing invalid
edges between two unchanged commits do not block an unrelated change.

Use `audit` to find existing violations. Use `normalize` to repair them.

## Command reference

### `show`

```text
git retime show [scope]
```

Shows one tab-delimited row for each target. The columns are object ID, author
timestamp, committer timestamp, and subject.

```text
git retime show --last 5
git retime show --branch release --range release~10..release
```

`show` does not change the repository and permits a detached `HEAD`.

### `audit`

```text
git retime audit [ref scope] [--minimum-gap SECONDS]
```

Checks author and committer chronology for the full history of the selected
refs. Each violation identifies the field, parent, child, parent timestamp,
and child timestamp. The final line gives the commit and violation counts.

```text
git retime audit
git retime audit --repo --minimum-gap 60
```

`audit` does not change the repository and permits a detached `HEAD`.

### `set`

```text
git retime set --date DATE [scope] [field options]
```

Assigns each target a timestamp from `DATE`. An exact date assigns one second.
A partial date uses deterministic random selection.

```text
git retime set --date 2026-09-19T22 --timezone -04:00 --last 3
git retime set --date 2026-09-19T22:45:12-04:00 --last 1 --committer
git retime set --date 2026-09-19T23 --commit a1b2c3d
```

### `shift`

```text
git retime shift --by DURATION [scope] [field options]
```

Adds the duration to each selected timestamp. A negative duration moves time
backward. The command keeps each field's existing timezone offset.

```text
git retime shift --by 2h --last 4
git retime shift --by -1d30m --range HEAD~5..HEAD --author
git retime shift --by 2h --commit HEAD~3
```

### `backdate`

```text
git retime backdate --before DATE [scope] [field options]
```

Moves each selected field to a second in the specified interval that is also
earlier than its current timestamp. The command stops if the interval contains
no earlier second.

```text
git retime backdate --before 2025 --last 2 --seed old-commits
git retime backdate --before 2026-09-19T23 --timezone -04:00 --last 1
```

### `schedule`

```text
git retime schedule --start DATE --end DATE [scope] [field options]
```

Places the targets at evenly spaced timestamps in topological order. This
command does not use random interval selection. With more than one target, the
first target uses the start interval's first second and the last target uses
the end interval's last second. Intermediate targets use even spacing.

Use complete timestamps when you need exact schedule boundaries:

```text
git retime schedule \
  --start 2026-09-19T21:17:08-04:00 \
  --end 2026-09-20T02:11:43-04:00 \
  --last 8
```

### `normalize`

```text
git retime normalize [ref scope] [field options]
```

Moves violating child timestamps forward by the minimum amount required to
satisfy chronology. It keeps timestamps that already satisfy the rule.

```text
git retime audit --repo
git retime normalize --repo --minimum-gap 1
```

`normalize` examines the full history of the selected refs. Commit-selection
options do not restrict this repair to only part of that history.

### `edit`

```text
git retime edit [scope]
```

Creates a temporary tab-delimited batch file and opens it in an editor. Each
row contains a commit object ID, an author date, and a committer date. A dash
means that the field does not change.

Windows uses `GIT_EDITOR`, then `VISUAL`, then Notepad. UNIX uses `GIT_EDITOR`,
then `VISUAL`, then `vi`.

For every row that remains in the file, replace at least one dash with a date.
Delete rows that you do not want to change. Save the file and close the editor
to create and apply the batch plan.

```text
git retime edit --last 3
GIT_EDITOR=vim git retime edit --range HEAD~5..HEAD
```

### `batch`

```text
git retime batch --file PATH [ref scope]
```

Reads timestamp changes from a UTF-8, tab-delimited file. Blank lines and
lines that start with `#` are ignored. Each data line must have exactly three
fields:

```text
REVISION<TAB>AUTHOR-DATE-OR-DASH<TAB>COMMITTER-DATE-OR-DASH
```

`<TAB>` means one literal tab character. A dash keeps that field unchanged.
Each revision must resolve to one commit inside the selected ref history. The
file cannot select the same commit twice. Each data row must change at least
one field.

Example `batch.tsv`, shown with `<TAB>` markers:

```text
# revision<TAB>author-date<TAB>committer-date
HEAD~2<TAB>2026-09-19T22-04:00<TAB>-
HEAD~1<TAB>2026-09-20T00:30-04:00<TAB>2026-09-20T00:30-04:00
HEAD<TAB>-<TAB>2026-09-20T02-04:00
```

Run the batch with a repeatable seed:

```text
git retime batch --file batch.tsv --seed release-night
```

Partial dates in the batch use deterministic random selection. `--timezone`
supplies the offset for values that do not include one.

### `operations`

```text
git retime operations
```

Lists recorded operation IDs, states, and creation times. Operation manifests
are stored in the repository's common Git directory.

Possible states include `prepared`, `committed`, `undone`, `rolled-back`, and
`pruned`.

### `undo`

```text
git retime undo [OPERATION-ID]
```

Restores each affected ref to its recorded old object ID. Without an ID, the
command selects the newest committed operation. Undo stops if an affected ref
does not have the exact recorded new value.

```text
git retime operations
git retime undo
git retime undo 20260920T061234Z-ab12cd34ef56
```

### `redo`

```text
git retime redo [OPERATION-ID]
```

Restores an undone operation. Without an ID, the command selects the newest
undone operation. Redo stops if an affected ref does not have the exact
recorded old value.

```text
git retime redo
```

### `recover`

```text
git retime recover
```

Examines operations left in the `prepared` state after an interrupted ref
transaction. It records an operation as rolled back when refs still have their
old values. It restores old values when refs have the planned new values. An
unrelated ref value stops automatic recovery.

Running `recover` when no work is necessary is safe.

### `prune-backups`

```text
git retime prune-backups [--older-than DAYS]
```

Deletes backup refs for operations at least the specified number of days old.
The default is 30 days. The manifest remains and changes to the `pruned` state.

```text
git retime prune-backups --older-than 90
```

Pruning removes the refs that make old history easy to recover. Git can later
remove the unreferenced objects. Prune only when you no longer need undo or
recovery for those operations.

### `apply-plan`

```text
git retime apply-plan PLAN
```

Applies a saved plan without recalculating target intervals. The repository
object format must match the plan. Every recorded ref must still have its
expected old object ID. These checks prevent a stale plan from overwriting
later work.

```text
git retime apply-plan retime.plan --dry-run
git retime apply-plan retime.plan
```

Safety checks still run when a plan is applied. Supply only the specific
overrides that the repository requires.

### `completion`

```text
git retime completion bash
git retime completion powershell
```

Prints a basic completion script for the direct `git-retime` executable. It
completes command names, not all command options.

Bash example:

```bash
eval "$(git retime completion bash)"
```

PowerShell example:

```powershell
git retime completion powershell | Out-String | Invoke-Expression
```

## Plan workflow

All timestamp-changing commands support these options:

- `--dry-run` prints the generated plan and does not write commit objects or
  refs.
- `--save-plan PATH` saves the generated plan.
- `--seed TEXT` controls deterministic selection from partial-date intervals.

Recommended workflow:

```text
git retime set --date 2026-09 --last 5 --seed review-1 \
  --dry-run --save-plan retime.plan
git retime apply-plan retime.plan --dry-run
git retime apply-plan retime.plan
```

A plan records the object format, operation, seed, chronology settings, target
intervals, selected refs, and expected old ref values. It uses UTF-8, line-feed
line endings, and tab-delimited records. See [design.md](design.md) for the
complete format and deterministic selection algorithm.

## Safety checks and overrides

There is no general `--force` option. A rewrite stops on each detected risk
unless its specific override is present.

| Override | Risk that it accepts |
| --- | --- |
| `--allow-dirty` | Staged, unstaged, or untracked worktree content |
| `--allow-active-operation` | Rebase, merge, cherry-pick, revert, bisect, or sequencer state |
| `--allow-shallow` | A shallow repository with incomplete history |
| `--allow-replace-refs` | Existing `refs/replace` entries |
| `--allow-linked-worktrees` | An affected branch checked out in another worktree |
| `--allow-detached` | Updating detached `HEAD` |
| `--allow-published` | A selected branch with a configured upstream |
| `--allow-invalid-signatures` | Rewriting a signed commit and invalidating its signature |
| `--allow-tag-divergence` | Leaving a tag on an old commit object ID |
| `--allow-note-divergence` | Leaving notes attached to old object IDs |

The program preserves signature headers. It does not make an invalid signature
valid. Tags and notes do not move automatically.

Before a published-history rewrite, review the plan and coordinate with other
users. A later push normally requires:

```text
git push --force-with-lease
```

See [safety.md](safety.md) for transaction, backup, undo, and recovery details.

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Success |
| 2 | Command-line or plan error |
| 3 | Repository state or safety refusal |
| 4 | Date or chronology conflict |
| 5 | Git object failure |
| 6 | Concurrent ref update or transaction failure |
| 7 | Recovery failure |
| 8 | Internal error |
