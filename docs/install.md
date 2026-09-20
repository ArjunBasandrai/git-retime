# Installation

## Windows

Extract the Windows ZIP. Run:

```powershell
pwsh -NoProfile -File ./install.ps1
```

The default destination is `%LOCALAPPDATA%\Programs\git-retime`. Add that
directory to `PATH`. Git then finds the extensionless `git-retime` launcher
when you run `git retime`.

To select another destination:

```powershell
./install.ps1 -Destination C:\Tools\git-retime
```

To uninstall:

```powershell
./uninstall.ps1 -Destination C:\Tools\git-retime
```

## UNIX

Extract the UNIX TAR.GZ. Run:

```bash
./install.sh --prefix "$HOME/.local"
```

Make sure `$HOME/.local/bin` is on `PATH`. To uninstall:

```bash
./uninstall.sh --prefix "$HOME/.local"
```

## Archive verification

Run this command in the release directory:

```bash
sha256sum -c SHA256SUMS
```
