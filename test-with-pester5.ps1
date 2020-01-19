Get-Module Pester, Axiom | Remove-Module
$root = "C:\projects\pester_main"
Import-Module "$root\Pester.psd1"

$tests = Get-ChildItem C:\Projects\powershell_nohwnd\test -Recurse *.Tests.ps1 | 
    where { $c = Get-Content $_ -ReadCount 10; [bool]($c -match "# Pester5") } | 
    Select -ExpandProperty FullName


Invoke-Pester $tests | Out-Null