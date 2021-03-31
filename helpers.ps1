function copysource ($source, $name) { 
    $item = Get-ChildItem -path $source "*$name*"
    Copy-Item $item (split-path $source) -Force -Verbose 
}
function deletecopy ($source, $name) {
    $item = Get-ChildItem -path (split-path $source) "*$name*"
    Remove-Item $item -Force -Verbose
}
#Recursive search up the AST for parent of a specific type
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
# $CommandElements | foreach {
#     $Reference = $_.Copy()
#     Get-AstParent -Ast $_ -Reference $Reference -Type [System.Management.Automation.Language.TryStatementAst]
# }

function Get-AstHash {
    param
    (
        [Parameter(Mandatory)]
        $Code
    )
    # build a hashtable for parents
    $hierarchy = @{}

    $code.FindAll( { $true }, $true) |
    ForEach-Object {
        # take unique object hash as key
        
        #skip the first object, which has no parent
        if ($null -ne $_.Parent) { 
        
            $id = $_.Parent.GetHashCode()
            if ($hierarchy.ContainsKey($id) -eq $false) {
                $hierarchy[$id] = [System.Collections.ArrayList]@()
            }
            $null = $hierarchy[$id].Add($_)
            # add ast object to parent 
        }
        
    }
    $hierarchy
}
# $AstHash = Get-AstHash $ModuleScriptBlock


# $OffsetLine = $Ast.Extent.EndLineNumber
# $x=$ScriptBlockAst.Find({
#     param($ast)
#     $ast.extent.StartLineNumber -gt $OffsetLine
# },$true)