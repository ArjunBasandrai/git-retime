@echo off
powershell.exe -NoLogo -NoProfile -Command "$p='%~1';$t=[IO.File]::ReadAllText($p);$t=$t.Replace([char]9+'-'+[char]9+'-',([char]9+'2035-04-05T06:07:08Z'+[char]9+'-'));[IO.File]::WriteAllText($p,$t,[Text.UTF8Encoding]::new($false))"
exit /b %errorlevel%
