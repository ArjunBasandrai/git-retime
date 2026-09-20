# Safety model

`git-retime` treats history replacement as a ref transaction. It does not
change the index or worktree files.

Before a rewrite, the program checks the worktree, index, active Git operation,
repository depth, replace refs, linked worktrees, upstream configuration,
commit signatures, tags, and notes. Each refusal identifies one override. The
program does not have a general force option.

An annotated or lightweight tag is not moved. A note is not copied to a new
commit object ID. An override accepts this divergence. A commit signature stays
in the raw commit, but any changed byte makes that signature invalid. The
signature override accepts the invalid signature. The program never removes a
signature header.

The program disables replace-object substitution in all object reads. Thus,
`--allow-replace-refs` accepts the presence of replace refs but still rewrites
the stored history.

Each updated ref has an expected old object ID. Git locks and verifies all
affected refs before it commits the transaction. A concurrent change stops the
transaction.

Backup refs use this namespace:

```text
refs/git-retime/backups/<operation-id>/...
```

`undo` requires every affected ref to have the recorded new value. `redo`
requires every affected ref to have the recorded old value. These checks stop
either command from overwriting later work.

`recover` processes a manifest that stayed in the `prepared` state. If all refs
have old values, recovery records a rollback. If a ref has its planned new
value, recovery restores the old value in a checked transaction. An unrelated
value stops automatic recovery.

Use `prune-backups` only when the rewritten history no longer needs local
recovery. This command deletes backup refs for operations older than the given
age. Git can later remove the unreferenced objects.
