#
# Example of an external module taking advantage of this event.
#

Get-Module PSTracer | Remove-Module
New-Module -Name PSTracer -ScriptBlock {
    function Trace-Script ($ScriptBlock, $Include) {

        $trace = [System.Collections.Generic.List[Object]]@()

        try {
            # set bogus BP to force the debugging mode, just because it is the easiest way to force debug mode
            $bp = Set-PSBreakpoint -Script $PSCommandPath -Line 1 -Column 1
            
            # added DebuggerSequencePointHitAction that will be hit on every debugger sequencepoint
            # we can run any code here, but it should be as quick as possible
            $ExecutionContext.InvokeCommand.DebuggerSequencePointHitAction = { 
                param($s, $e) 
                if ($e.Extent.File -notin $Include) { 
                    return
                }

                $trace.Add($e) 
            }

            # invoke our script, that is coming from another session state
            & $ScriptBlock
        }
        finally {
            # cleanup
            $ExecutionContext.InvokeCommand.DebuggerSequencePointHitAction = $null
            Remove-PSBreakpoint $bp
        }

        $trace
    }
} | Import-Module

Get-Module Pester | Remove-Module
Import-Module /Projects/Pester/bin/Pester.psd1
$trace = Trace-Script { Invoke-Pester C:\temp\f\f.tests.ps1 } -Include "C:\temp\f\f.ps1"
$trace
