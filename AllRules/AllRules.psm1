# Import Localized Data
# Explicit culture needed for culture that do not match when using PowerShell Core: https://github.com/PowerShell/PowerShell/issues/8219
if ([System.Threading.Thread]::CurrentThread.CurrentUICulture.Name -ne 'en-US') {
    Import-LocalizedData -BindingVariable Messages -UICulture 'en-US'
}
else {
    Import-LocalizedData -BindingVariable Messages
}

#Helper functions
function Get-AstHash {
    param
    (
        [Parameter(Mandatory)]
        [ScriptBlock]
        $Code
    )
    # build a hashtable for parents
    $hierarchy = @{}

    $code.Ast.FindAll( { $true }, $true) |
    ForEach-Object {
        # take unique object hash as key
        
        #skip the first object, which has no parent
        if ($null -eq $_.Extent.Parent) { continue }
        $id = $_.Parent.GetHashCode()
        if ($hierarchy.ContainsKey($id) -eq $false) {
            $hierarchy[$id] = [System.Collections.ArrayList]@()
        }
        $null = $hierarchy[$id].Add($_)
        # add ast object to parent 
    }
    $hierarchy
}
function Get-AstParent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, HelpMessage = "Ast object to search from")]
        [System.Management.Automation.Language.Ast]
        $Ast,
        [Parameter(Mandatory, HelpMessage = "Clone of `$Ast to Reference")]
        [System.Management.Automation.Language.Ast]
        $Reference,
        [Parameter(HelpMessage = "Ast typename of parent to search for")]
        [ValidateScript({$_ -notmatch "\[|\]"})]
        [string]
        $Type,
        [Parameter(Mandatory, HelpMessage = "Recurse parameters")]
        [ValidateSet('AboveReference', 'WithinType','LineNumber')]
        [string]
        $SearchDirection,
        [Parameter( HelpMessage = "Recurse parameters")]        
        [string]
        $LineNumber

    )
    if ($Type -notlike "System.Management.Automation.Language.*") {
        $Type = "System.Management.Automation.Language.$Type"
    }

    switch ($SearchDirection) {
        #! Can this be used for all Ast blocks that include {}?
        'WithinType' {
            # If the current AST object is a [$Type] statement, and the extent of the try statement surrounds the $Ast we are providing, then we have found our command in a try statement
            if (($ast.Extent.StartOffset -lt $Reference.Extent.StartOffset) -and ($ast.Extent.EndOffset -gt $reference.Extent.EndOffset) -and ($Ast.GetType().ToString() -eq $Type)) { 
                return $Ast 
            }
            # If the endOffset of the current AST object is less than the $Ast we are providing, then there is no try statement in the tree wrapping this command
            # OR if we reach the top of the tree and there are no more Parents, there is no try statement between the $Ast we are providing and the top of the tree
            elseif (($reference.extent.endoffset -gt $ast.Extent.endOffset) -or ($null -eq $Ast.Parent) ) {        
                write-verbose "Offset exceeded bounds of reference for $Type"
                return
            }
            #Recurse up the tree
            else {
                Get-AstParent $Ast.Parent $Reference $Type $SearchDirection
            }
        }
        'AboveReference' { 
            #Finds any type above Reference without Extent restrictions
            if ($ast.GetType().ToString() -eq $Type) {
                return $Ast
            }
            elseif ($null -eq $Ast.Parent) {
                write-verbose "Reached top of tree without finding $Type"
            }
            else {
                Get-AstParent $Ast.Parent $Reference $Type $SearchDirection
            }
        }
        'LineNumber' {
            #Finds the previous line number, use if you need to find the capital P Parent Ast object on the current line
            if ($Ast.Parent.Extent.StartLineNumber -lt $Reference.Extent.StartLineNumber) { 
                return $Ast
            } 
            else {
                Get-AstParent -Ast $Ast.Parent -Reference $Reference -SearchDirection LineNumber -LineNumber 119
            }
        }
    }
}
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
#End helper functions region


function Measure-WriteLog {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]
        $ScriptBlockAst,
        [switch]$Testing
    )

    Process {
        if (($null -ne $ScriptBlockAst.Parent) -or ($Testing)) {
            $results = @()
            try {
                #! Move this out
                $FunctionFilter = funcfilter -ScriptBlockAst $ScriptBlockAst -AdditionalFunctions @('flush', 'New-Op', 'New-TClient', 'New-TDep', 'New-TItem', 'New-TReq', 'Send-JobMetrics', 'Stop-OpDT', 'Stop-OpRT', 'tdep', 'tevent', 'tex', 'tmetric', 'ttrace','start-retry')
                
                #region Define predicates to find ASTs.
                # Finds cmdlet calls
                #! I might be doing this backwards. This is returning each command that exists in a try block. I either need to return every try block that contains a cmdast here, or further down I need to select the... no that's not right.
                #! Each commandast needs its own write-log in the try block. The catch block needs one write-log. This predicate is returning every commandast in the try block, so when we want to update the catch block, it wants to do it as many number of commandast instances exist in the try
                #! build a dict of commandast objects as we are creating suggestedcorrections for catch. if the cmdast doesn't exist, create the catch correction. if it does, continue
                [ScriptBlock]$predicate1 = {
                    param ([System.Management.Automation.Language.Ast]$Ast)
                    [bool]$returnValue = $false
                    if ($Ast -is [System.Management.Automation.Language.CommandAst]) {
                        if ($Ast.Commandelements[0].Value -in $FunctionFilter) {
                            [System.Management.Automation.Language.CommandAst]$cmdAst = $Ast
                            
                            $ReferenceAst = $cmdAst.Copy()
                            $ParentIsTry = Get-AstParent -Ast $cmdAst -Reference $ReferenceAst -Type "System.Management.Automation.Language.TryStatementAst" -SearchDirection WithinType
                            if ($ParentIsTry) {                                
                                $returnValue = $true
                            }
                        } 
                    }                
                    return $returnValue
                }
                #region Finds ASTs that match the predicates.

                [System.Management.Automation.Language.Ast[]]$commandAst = $ScriptBlockAst.FindAll($predicate1, $true)          
                       
                [hashtable]$ParentTryHash=@{}
                $commandAst | ForEach-Object {
                    $currentCommandAst = $_

                    #Get TryStatementAst block, we are assuming it exists because of predicate1 
                    $ParentTry = Get-AstParent -Ast $currentCommandAst -Reference $currentCommandAst.copy() -Type "System.Management.Automation.Language.TryStatementAst" -SearchDirection WithinType
                    #Do we already have a Write-Log?
                    $TryContainsWriteLog = $ParentTry.Body.Extent.Text -match "Write-Log"
#                     if (-not $TryContainsWriteLog) {
#                         $ParentOfLine = Get-AstParent -Ast $currentCommandAst -Reference $currentCommandAst.Copy() -SearchDirection LineNumber -LineNumber $currentCommandAst.Extent.StartLineNumber
#                         #Add Write-Log Success
#                         [int]$startLineNumber = $ParentOfLine.Extent.StartLineNumber
#                         [int]$endLineNumber = $ParentOfLine.Extent.EndLineNumber
#                         [int]$startColumnNumber = $ParentOfLine.Extent.StartColumnNumber
#                         [int]$endColumnNumber = $ParentOfLine.Extent.EndColumnNumber
#                         [string]$correction = @'
# {0}
# {1}
# '@ -f $ParentOfLine.Extent.Text, 'Write-Log -Message "Success"'
#                         [string]$file = $MyInvocation.MyCommand.Definition
#                         [string]$optionalDescription = ''
                        
#                         $correctionExtent = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent' $startLineNumber, $endLineNumber, $startColumnNumber, $endColumnNumber, $correction, $description
#                         $suggestedCorrections = New-Object System.Collections.ObjectModel.Collection['Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent']
#                         $suggestedCorrections.add($correctionExtent) | out-null

#                         $result = [Microsoft.Windows.Powershell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
#                             "Message"              = "This is a rule with a suggested correction"
#                             "Extent"               = $currentCommandAst.Extent
#                             "RuleName"             = $PSCmdlet.MyInvocation.InvocationName
#                             "Severity"             = "Warning"
#                             "RuleSuppressionID"    = "MyRuleSuppressionID"
#                             "SuggestedCorrections" = $suggestedCorrections
#                         }
#                         $results += $result
#                     }
                    #Add Write-Log Faiure   
                    #Check if we have already created a correction for a commandast in this try block 
                    if ($ParentTryHash.ContainsKey($ParentTry.GetHashCode())) {
                        return
                    } 
                    else {$ParentTryHash.Add($ParentTry.GetHashCode(),@{})} 

                    $CatchClause = $ParentTry.CatchClauses.Body
                    if ($CatchClause.Count -gt 1) {
                        $CatchClause = $CatchClause[-1]
                    }
                    #Do we already have a Write-Log?
                    $CatchContainsWriteLog = $CatchClause.Extent.Text -match "Write-Log"
                    if (-not $CatchContainsWriteLog) {
                        if ($CatchClause.Statements.Count -gt 0) {
                            $LastStatementInCatchClause = $CatchClause.Statements[-1]
                        }
                        else {
                            $emptyCatch=$true
                            $LastStatementInCatchClause = $CatchClause
                        }
                        
                        [int]$startLineNumber = $LastStatementInCatchClause.Extent.StartLineNumber
                        [int]$endLineNumber = $LastStatementInCatchClause.Extent.EndLineNumber
                        [int]$startColumnNumber = $LastStatementInCatchClause.Extent.StartColumnNumber
                        [int]$endColumnNumber = $LastStatementInCatchClause.Extent.EndColumnNumber
                        if (!$emptyCatch) {
                            [string]$correction = @'
{0}
{1}
{2}
'@ -f '', 'Write-Log -Message "Failure"', ($LastStatementInCatchClause.Extent.Text)

                        }
                        else {
                            [string]$correction = '{Write-Log}'                            
                        }
                        Write-host $correction
                        [string]$file = $MyInvocation.MyCommand.Definition
                        [string]$optionalDescription = ''
                        $correctionExtent = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent' $startLineNumber, $endLineNumber, $startColumnNumber, $endColumnNumber, $correction, $description
                        $suggestedCorrections = New-Object System.Collections.ObjectModel.Collection['Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent']
                        $suggestedCorrections.add($correctionExtent) | out-null

                        $result = [Microsoft.Windows.Powershell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
                            "Message"              = "This is a rule with a suggested correction"
                            "Extent"               = $LastStatementInCatchClause.Extent
                            "RuleName"             = $PSCmdlet.MyInvocation.InvocationName
                            "Severity"             = "Warning"
                            "RuleSuppressionID"    = "MyRuleSuppressionID"
                            "SuggestedCorrections" = $suggestedCorrections
                        }
                        $results += $result
                    }
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

Export-ModuleMember Measure-WriteLog

function Measure-PSCallStack {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]
        $ScriptBlockAst
    )

    Process {
        # $AstHash = Get-AstHash -Code $ScriptBlockAst
        if ($null -ne $ScriptBlockAst.Parent) {
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
Export-ModuleMember Measure-PSStack


