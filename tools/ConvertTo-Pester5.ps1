<#
.SYNOPSIS
    Migrates Pester test files from v4 to v5 by wrapping bare code in Describe/Context blocks.
.DESCRIPTION
    In Pester 5, code directly inside Describe/Context blocks (outside It/BeforeAll/BeforeEach/AfterAll/AfterEach/Context)
    runs during Discovery phase, not Run phase. This script detects such bare code and wraps it in:
    - BeforeDiscovery { } if the variables are used in -TestCases (Discovery-time data)
    - BeforeAll { } otherwise (Run-time setup)
#>
param(
    [Parameter(Mandatory)]
    [string]$Path,
    [switch]$WhatIf
)

$Path = (Resolve-Path $Path).Path
$content = Get-Content -Path $Path -Raw
$lines = Get-Content -Path $Path
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)

$pesterBlockCommands = @('It', 'Context', 'Describe', 'BeforeAll', 'BeforeEach', 'AfterAll', 'AfterEach', 'InModuleScope', 'BeforeDiscovery')

# Find all Describe/Context command calls
$describeContextCalls = $ast.FindAll({
    param($a)
    $a -is [System.Management.Automation.Language.CommandAst] -and
    $a.GetCommandName() -in @('Describe', 'Context')
}, $true)

# Find all variables referenced in -TestCases parameters within the file
$testCasesVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$itCalls = $ast.FindAll({
    param($a)
    $a -is [System.Management.Automation.Language.CommandAst] -and
    $a.GetCommandName() -eq 'It'
}, $true)
foreach ($itCall in $itCalls) {
    $params = $itCall.CommandElements
    for ($i = 0; $i -lt $params.Count; $i++) {
        if ($params[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
            $params[$i].ParameterName -eq 'TestCases' -and
            ($i + 1) -lt $params.Count) {
            # Find all variable references in the TestCases argument
            $tcArg = $params[$i + 1]
            $varRefs = $tcArg.FindAll({ param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
            foreach ($v in $varRefs) {
                [void]$testCasesVars.Add($v.VariablePath.UserPath)
            }
        }
    }
    # Also check for positional -TestCases (3rd argument after It "name" { } -TestCases ...)
    # Actually, TestCases is named-only in Pester, so we only need to check named params
}

# Also check for Describe/Context -ForEach which also runs during Discovery
$forEachVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($dc in $describeContextCalls) {
    $params = $dc.CommandElements
    for ($i = 0; $i -lt $params.Count; $i++) {
        if ($params[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
            $params[$i].ParameterName -eq 'ForEach' -and
            ($i + 1) -lt $params.Count) {
            $feArg = $params[$i + 1]
            $varRefs = $feArg.FindAll({ param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
            foreach ($v in $varRefs) {
                [void]$forEachVars.Add($v.VariablePath.UserPath)
            }
        }
    }
}

$discoveryVars = [System.Collections.Generic.HashSet[string]]::new($testCasesVars, [System.StringComparer]::OrdinalIgnoreCase)
$discoveryVars.UnionWith($forEachVars)

# Collect line ranges for wrapping
$wrapRanges = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($dc in $describeContextCalls) {
    $scriptBlockArg = $dc.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }
    if (-not $scriptBlockArg) { continue }
    
    $sb = $scriptBlockArg.ScriptBlock
    if (-not $sb.EndBlock) { continue }
    
    $currentGroupStart = -1
    $currentGroupEnd = -1
    $currentIndent = ""
    $currentStmts = [System.Collections.Generic.List[System.Management.Automation.Language.StatementAst]]::new()
    
    foreach ($stmt in $sb.EndBlock.Statements) {
        $isPesterCmd = $false
        if ($stmt -is [System.Management.Automation.Language.PipelineAst]) {
            $firstCmd = $stmt.PipelineElements[0]
            if ($firstCmd -is [System.Management.Automation.Language.CommandAst]) {
                $cmdName = $firstCmd.GetCommandName()
                if ($cmdName -in $pesterBlockCommands) {
                    $isPesterCmd = $true
                }
            }
        }
        
        # Check if this statement contains It/Context/Describe calls in nested scriptblocks
        # (e.g., ForEach-Object { It ... }) - these generate tests during Discovery and must NOT be wrapped
        if (-not $isPesterCmd) {
            $nestedItCalls = $stmt.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.CommandAst] -and
                $a.GetCommandName() -in @('It', 'Context', 'Describe')
            }, $true)
            if ($nestedItCalls.Count -gt 0) {
                $isPesterCmd = $true
            }
        }
        
        if (-not $isPesterCmd) {
            if ($currentGroupStart -eq -1) {
                $currentGroupStart = $stmt.Extent.StartLineNumber
                $lineText = $lines[$stmt.Extent.StartLineNumber - 1]
                $currentIndent = if ($lineText -match '^(\s+)') { $matches[1] } else { "" }
            }
            $currentGroupEnd = $stmt.Extent.EndLineNumber
            $currentStmts.Add($stmt)
        } else {
            if ($currentGroupStart -ne -1) {
                # Determine if any assigned variables are used in -TestCases
                $needsDiscovery = $false
                foreach ($s in $currentStmts) {
                    if ($s -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                        $varName = $s.Left.VariablePath.UserPath
                        if ($discoveryVars.Contains($varName)) {
                            $needsDiscovery = $true
                            break
                        }
                    }
                }
                
                $wrapRanges.Add([PSCustomObject]@{
                    StartLine = $currentGroupStart
                    EndLine = $currentGroupEnd
                    Indent = $currentIndent
                    BlockName = $dc.GetCommandName()
                    WrapperType = if ($needsDiscovery) { 'BeforeDiscovery' } else { 'BeforeAll' }
                })
                $currentGroupStart = -1
                $currentStmts.Clear()
            }
        }
    }
    if ($currentGroupStart -ne -1) {
        $needsDiscovery = $false
        foreach ($s in $currentStmts) {
            if ($s -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $varName = $s.Left.VariablePath.UserPath
                if ($discoveryVars.Contains($varName)) {
                    $needsDiscovery = $true
                    break
                }
            }
        }
        
        $wrapRanges.Add([PSCustomObject]@{
            StartLine = $currentGroupStart
            EndLine = $currentGroupEnd
            Indent = $currentIndent
            BlockName = $dc.GetCommandName()
            WrapperType = if ($needsDiscovery) { 'BeforeDiscovery' } else { 'BeforeAll' }
        })
    }
}

if ($wrapRanges.Count -eq 0) {
    Write-Host "No changes needed for: $Path"
    return
}

if ($WhatIf) {
    Write-Host "Would make $($wrapRanges.Count) insertions in: $Path"
    foreach ($r in $wrapRanges | Sort-Object StartLine) {
        Write-Host "  Lines $($r.StartLine)-$($r.EndLine) in $($r.BlockName) -> $($r.WrapperType)"
    }
    return
}

# Apply wrapping from bottom to top so line numbers don't shift
$resultLines = [System.Collections.Generic.List[string]]::new()
$resultLines.AddRange([string[]]$lines)

foreach ($range in ($wrapRanges | Sort-Object StartLine -Descending)) {
    $indent = $range.Indent
    $wrapper = $range.WrapperType
    $startIdx = $range.StartLine - 1
    $endIdx = $range.EndLine - 1
    
    $resultLines.Insert($endIdx + 1, "$indent}")
    $resultLines.Insert($startIdx, "${indent}${wrapper} {")
}

$resultContent = ($resultLines -join "`n")
if ($content.Contains("`r`n")) {
    $resultContent = $resultContent -replace "(?<!\r)\n", "`r`n"
}

Set-Content -Path $Path -Value $resultContent -NoNewline -Encoding utf8NoBOM
Write-Host "Fixed $($wrapRanges.Count) bare code group(s) in: $Path"
