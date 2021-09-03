$root = "$home\source\PSSAFixers"
. (Join-Path -Path $root -ChildPath "helpers.ps1")
$source = Join-Path $root -ChildPath "TestModules\source"
$fixers = Join-Path $root 'AllRules'
$modulepath = Join-Path $source -ChildPath "testmod\iwrfunction.ps1"
$ModuleString = Get-Content -Path $ModulePAth -Raw 
$ModuleScriptBlock = [scriptblock]::Create($ModuleString)
# $fixedmodulepath = Join-Path $root 'TestModules\iwrfunction.ps1'
# $FixedModuleScriptBlock = [scriptblock]::Create((Get-Content $fixedmodulepath -Raw))
# show-ast $ModuleScriptBlock -ExtentDetailLevel Detailed
function funcfilter ($ScriptBlockAst, $AdditionalFunctions, $Modules) {
    #Create a command filter to remove commands we don't want to write logs for
    $UtilityFunctionsFilter = (get-command -module Microsoft.Powershell.Utility | Where-Object { $_.Name -notmatch "^Convert|^Set|^Add|^Invoke|^Set|^Start|^Update" }).Name
    $UtilityFunctionsFilter += (get-command -module Microsoft.Powershell.Core).Name
    if ($Modules) {
        $modules | foreach {
            $UtilityFunctionsFilter += (get-command -module $_).Name
        } 
    }
    $Token = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($ScriptBlockAst, [ref]$Token, [ref]$null)
    $Functions = ($Token | Where-Object { $_.TokenFlags -eq 'CommandName' }).Value | Select -Unique | Where-Object { ($_ -notin $UtilityFunctionsFilter) -and ($_ -notin $AdditionalFunctions) }
    $Functions
}
ipmo $fixers\AllRules.psm1 -force -verbose
#Find the substring where we can insert all our telemetry request init stuff for a cmdlet
Measure-PSCallStack -ScriptBlockAst $ModuleScriptBlock.Ast -Testing -OutVariable foo
#Insert
$TelemetryInit = $ModuleString.Insert($foo.extent.EndOffset,$foo.SuggestedCorrections.Text)
#Test if our new insertaion broker any ps syntax
if ($TelemetryInit | Test-Syntax) {
    #Write to file? Or maybe create a scriptblock from this string and move on to the next rule
}
else {#Syntax error
}
break
Invoke-Scriptanalyzer -Path $modulepath -CustomRulePath $fixers -IncludeRule 'Measure-WriteLog' -ReportSummary -OutVariable Measured -Verbose
copysource $source vmscaler
Invoke-Scriptanalyzer -Path $fixedmodulepath -CustomRulePath $fixers -IncludeRule 'Measure-WriteLog' -Fix -ReportSummary -OutVariable Fixed -Verbose


















function Measure-PSCallStack {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]
        $ScriptBlockAst,
        [Parameter()]
        [switch]$Testing
    )

    Process {
        # $AstHash = Get-AstHash -Code $ScriptBlockAst
        if (($null -ne $ScriptBlockAst.Parent) -or $Testing) {
            $results = @()
            try {
                #region Define predicates to find ASTs.            
                #Checks if the first object below the ParamBlockAst in the tree is $PSStack = 
                [ScriptBlock]$predicate1 = {
                    param ([System.Management.Automation.Language.Ast]$Ast)
                    [bool]$returnValue = $false
          
                    if ($Ast -is [System.Management.Automation.Language.ParamBlockAst]) {
                        [System.Management.Automation.Language.ParamBlockAst]$paramAst = $Ast

                        $FirstChildAst = $ScriptBlockAst.Find( {
                                param($ParentAst)
                                $ParentAst.extent.StartLineNumber -gt $paramAst.Extent.EndLineNumber
                            }, $true)
                        if (($FirstChildAst -isnot [System.Management.Automation.Language.AssignmentStatementAst]) -or ($FirstChildAst.left.VariablePath.userpath -ne 'PSStack')) {
                            $returnValue = $true
                        }                    
                    } 
                    return $returnValue
                }
                #region Finds ASTs that match the predicates.

                [System.Management.Automation.Language.Ast[]]$paramblockAst = $ScriptBlockAst.FindAll($predicate1, $true)
            
                $paramblockAst | ForEach-Object {
                    $currentParamBlockAst = $_
                    [int]$startLineNumber = $currentParamBlockAst.Extent.StartLineNumber
                    [int]$endLineNumber = $currentParamBlockAst.Extent.EndLineNumber
                    [int]$startColumnNumber = $currentParamBlockAst.Extent.StartColumnNumber
                    [int]$endColumnNumber = $currentParamBlockAst.Extent.EndColumnNumber
                    [string]$correction = @'
{0}
{1}
{2}
'@ -f $currentParamBlockAst.Extent.Text, '$PSStack = Get-PSCallStack', '$F = $PSStack[0].Command'
                    [string]$file = $MyInvocation.MyCommand.Definition
                    [string]$optionalDescription = ''
                    $correctionExtent = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent' $startLineNumber, $endLineNumber, $startColumnNumber, $endColumnNumber, $correction, $description
                    $suggestedCorrections = New-Object System.Collections.ObjectModel.Collection['Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent']
                    $suggestedCorrections.add($correctionExtent) | out-null

                    $result = [Microsoft.Windows.Powershell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
                        "Message"              = "This is a rule with a suggested correction"
                        "Extent"               = $currentParamBlockAst.Extent
                        "RuleName"             = $PSCmdlet.MyInvocation.InvocationName
                        "Severity"             = "Warning"
                        "RuleSuppressionID"    = "MyRuleSuppressionID"
                        "SuggestedCorrections" = $suggestedCorrections
                    }
                    $results += $result
                }
                return $results
                #endregion
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($PSItem)
            }
        }
    }
}
Measure-PSCallStack -ScriptBlockAst $ModuleScriptBlock.Ast -Testing -OutVariable bar

Invoke-Scriptanalyzer -Path $modulepath -CustomRulePath $fixers -IncludeRule 'Measure-PSStack' -ReportSummary -OutVariable Measured -Verbose
# Invoke-Scriptanalyzer -Path $fixedmodulepath -CustomRulePath $fixers -IncludeRule 'Measure-PSStack' -Fix -ReportSummary -OutVariable Fixed 




break
$UtilityFunctionsFilter = (get-command -module Microsoft.Powershell.Utility | Where-Object { $_.Name -notmatch "^Convert|^Set|^Add|^Invoke|^Set|^Start|^Update" }).Name
$UtilityFunctionsFilter += (get-command -module Microsoft.Powershell.Core).Name
$Token = $null
# $null = [System.Management.Automation.Language.Parser]::ParseFile($ModulePAth, [ref]$Token, [ref]$null)
$null = [System.Management.Automation.Language.Parser]::ParseInput($ModuleScriptBlock, [ref]$Token, [ref]$null)
$Functions = ($Token | Where-Object { $_.TokenFlags -eq 'CommandName' }).Value | Select -Unique | Where-Object { $_ -notin $UtilityFunctionsFilter }
$CommandElements = $ModuleScriptBlock.Ast.findall( { param($ast)
        $ast -is [System.Management.Automation.Language.CommandAst] <#-and 
        $ast.CommandElements.Value -in $Functions     #>

    }, $true)

($commandelements | where-object { $_.CommandElements.Value[0] -in $Functions })