# git-retime

`git-retime` rewrites Git commit timestamps with raw Git object operations. It
has native PowerShell and Bash implementations with the same command line,
plan format, safety checks, and exit codes.

See [docs/design.md](docs/design.md)
for the data model and [docs/cli.md](docs/cli.md) for the command contract.

## Main properties

- Rewrites raw commit objects. It does not use rebase or amend loops.
- Changes author and committer timestamps independently or together.
- Resolves partial ISO dates to deterministic integer seconds.
- Applies parent-to-child chronology constraints to a commit DAG.
- Keeps descendant timestamps when only their parent object IDs must change.
- Updates multiple refs in one checked Git transaction.
- Creates backup refs and operation manifests for undo, redo, and recovery.
- Supports SHA-1 and SHA-256 repositories.

## Note to recruiters

This is not a serious portfolio project. It is the product of boredom, made in
one night (or not? You never know with these things!). I also had some help from an engineer's best friend. Please judge accordingly.

## Example

First, inspect the selected commits:

```bash
git retime show --last 5
git retime audit --repo
```

Create a plan without a repository change:

```bash
git retime set --date 2026-09 --last 5 --seed release-demo \
  --dry-run --save-plan retime.plan
```

Review `retime.plan`. Then apply the exact plan:

```bash
git retime apply-plan retime.plan
```

The command refuses a dirty worktree, an active Git operation, published
branches, signatures, affected tags, notes, shallow history, replace refs, and
linked worktree conflicts by default. Each risk has a separate override. See
[docs/safety.md](docs/safety.md) before a history rewrite.

## Commands

`git-retime` provides these commands:

```text
show audit set shift backdate schedule normalize edit batch
operations undo redo recover prune-backups apply-plan completion
```

Common scope options include `--branch`, `--last`, `--range`, `--root`,
`--commit`, `--first-parent`, `--repo`, and `--all-local-branches`.

Use `--commit REVISION` to select one exact commit. A full object ID, a short
object ID, a tag, or a revision such as `HEAD~3` is valid. Repeat the option to
select more commits:

```text
git retime shift --by 2h --commit HEAD~3
git retime set --date 2026-09-19T23 --commit a1b2c3d --commit release-candidate
```

## Requirements

- Windows: PowerShell 7.4 or later and Git 2.38 or later.
- UNIX: Bash 5 or later, Git 2.38 or later, Perl 5, and a SHA-256 utility.

## Installation

Install a release archive instead of cloning the repository.

### Windows

Download and extract `git-retime-windows-<version>.zip`. Open PowerShell in
the extracted directory. Then run:

```powershell
pwsh -NoProfile -File .\install.ps1
```

The default installation directory is
`%LOCALAPPDATA%\Programs\git-retime`. Add this directory to the user `PATH`,
and open a new terminal.

### Linux and UNIX

Download and extract `git-retime-unix-<version>.tar.gz`. Open a shell in the
extracted directory. Then run:

```bash
./install.sh --prefix "$HOME/.local"
```

Make sure that `$HOME/.local/bin` is on `PATH`.

### Verify the installation

```text
git retime --version
git retime -h
```

Use `-h` for the command summary. Git reserves `git retime --help` for an
installed manual page. See [docs/cli.md](docs/cli.md) for command options.

Use `sha256sum -c SHA256SUMS` on Linux to verify the downloaded archives.
On Windows, compare the output from `Get-FileHash -Algorithm SHA256` with
`SHA256SUMS`.

See [docs/install.md](docs/install.md) for custom installation directories and
uninstall instructions.

## Development entry points

```text
Windows: pwsh -NoProfile -File ./windows/git-retime.ps1 -h
UNIX:    ./bin/git-retime -h
```

All tests create disposable repositories. The test runner does not modify the
repository that contains `git-retime`.

```powershell
./tools/test-all.ps1
```

The full runner uses Windows Git and PowerShell directly. It uses Linux Git and
Bash through `wsl -d Ubuntu`. Large UNIX repositories stay in the Linux
filesystem. The runner builds release archives and tests each archive in a
clean temporary installation.

Use this command only when you intentionally want to omit the large repository
tests:

```powershell
./tools/test-all.ps1 -SkipStress
```

## License

Apache-2.0. See [LICENSE](LICENSE).
