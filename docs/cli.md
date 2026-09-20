# Command line

## Commands

```text
git retime show [scope]
git retime audit [scope]
git retime set --date DATE [scope] [field options]
git retime shift --by DURATION [scope] [field options]
git retime backdate --before DATE [scope] [field options]
git retime schedule --start DATE --end DATE [scope] [field options]
git retime normalize [scope] [field options]
git retime edit [scope]
git retime batch --file PATH [scope]
git retime operations
git retime undo [OPERATION-ID]
git retime redo [OPERATION-ID]
git retime recover
git retime prune-backups [--older-than DAYS]
git retime apply-plan PLAN
git retime completion bash|powershell
```

## Scope options

- `--branch NAME`: use one local branch. Repeat the option for more branches.
- `--all-local-branches`: use all local branches.
- `--repo`: use all local branches and an attached current branch.
- `--last N`: select the last N commits in the scope.
- `--range REVISION-RANGE`: select commits from a Git revision range.
- `--root`: select root commits in the scope.
- `--first-parent`: use only the first-parent path for target selection.

With no scope option, the scope is the current branch. The default target is
`HEAD`.

## Field options

- `--author`: change author timestamps only.
- `--committer`: change committer timestamps only.
- `--both`: change both timestamp fields. This is the default.

## Date input

The program accepts these date forms:

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

A partial value specifies an interval. The program selects an integer second
from that interval. A value without an offset uses UTC unless `--timezone`
supplies `Z` or a fixed offset such as `-04:00`. Calendar operations use the
specified fixed offset. They do not infer daylight-saving transitions.

Durations use an optional sign and a sequence of units. Valid units are `w`,
`d`, `h`, `m`, and `s`. Example: `-2d4h30m`.

## Chronology options

- `--minimum-gap SECONDS`: set the parent-to-child gap. The default is `1`.
- `--chronology strict`: solve selected intervals and stop on conflict. This is
  the default.
- `--chronology off`: do not apply chronology constraints.

## Safety overrides

The command has no general force option. Each risk has a separate override:

- `--allow-dirty`
- `--allow-active-operation`
- `--allow-shallow`
- `--allow-replace-refs`
- `--allow-linked-worktrees`
- `--allow-detached`
- `--allow-published`
- `--allow-invalid-signatures`
- `--allow-tag-divergence`
- `--allow-note-divergence`

Use `--dry-run` to print the plan without object or ref writes. Use
`--save-plan PATH` to save the plan. Use `--seed TEXT` to make partial-date
selection repeatable. Without this option, each new plan uses a unique seed.

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
