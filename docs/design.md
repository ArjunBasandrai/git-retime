# Design

## Object rewrite

`git-retime` reads commit objects with `git cat-file` and writes replacement
objects with `git hash-object -t commit -w`. It changes only these tokens:

- a selected `author` timestamp and offset;
- a selected `committer` timestamp and offset;
- a `parent` object ID when the parent was rewritten.

The object writer keeps the tree, message, identities, encoding, unknown
headers, header order, and line endings. A descendant that is in the rewrite
closure keeps its timestamps unless the operation selects that descendant.

## Timestamp constraints

For each enabled timestamp field, every constrained edge must satisfy:

```text
child >= parent + minimum_gap
```

The default minimum gap is one second. The strict solver gives each selected
commit a closed interval. An exact timestamp has an interval of one second.
An unchanged commit is a fixed point. A forward pass calculates lower bounds.
A reverse pass calculates upper bounds. The operation stops when an interval
is empty. The solver then selects a deterministic second in each remaining
interval in topological order.

Existing invalid edges between two unchanged commits do not block an unrelated
operation. `audit` reports those edges. `normalize` selects the commits that it
must move to repair the requested history.

## Deterministic selection

The random algorithm is `sha256-mod-v1`:

1. Encode this record as UTF-8. Use a line-feed between fields.

   ```text
   git-retime-random-v1
   <seed>
   <operation>
   <old-commit-oid>
   <author-or-committer>
   <interval-low>
   <interval-high>
   ```

2. Calculate SHA-256.
3. Interpret the first 13 hexadecimal digits as an unsigned integer.
4. Calculate `value modulo interval-size`.
5. Add the result to the inclusive lower bound.

Thirteen hexadecimal digits are 52 bits. Bash and PowerShell can represent
this value exactly as an integer. The same input record gives the same result
on both platforms.

## Plans

Plans use UTF-8 and line-feed line endings. Each record is tab-delimited. A
field cannot contain a tab or a line-feed.

```text
git-retime-plan\t1
object-format\tsha1
operation\tset
seed\texample
minimum-gap\t1
chronology\tstrict
field-mode\tboth
target\t<oid>\t<author-low>\t<author-high>\t<author-offset>\t<committer-low>\t<committer-high>\t<committer-offset>
ref\t<full-ref-name>\t<expected-old-oid>
```

A dash (`-`) in all four values for one timestamp field means that the plan
does not select that field. Target and ref records are sorted by byte order.
Unknown records are errors. A plan does not contain creation time or a host
path. Thus, saved plans are stable and portable.

## Transactions and recovery

Before a ref transaction, the program creates backup refs below
`refs/git-retime/backups/<operation-id>/`. It writes an operation manifest in
the common Git directory. The manifest has these states:

```text
prepared -> committed
prepared -> rolled-back
committed -> undone -> redone
```

Ref updates use expected old object IDs. A concurrent ref update makes the
transaction fail. Recovery examines `prepared` manifests. It either records a
completed transaction or restores refs that match the planned new values.

## Object formats

The implementation gets the object format from Git. It accepts SHA-1 and
SHA-256 object IDs. No code assumes a fixed object ID length.
