<#
Requests - all functions should be built as requests
Dependencies - cmdlets that call external data sources should be piped to invoke-telemetrydependency
Traces - all write-log, write-host, write-verbose messages should be duplicated as traces
All of this will be done with find/replace and find/insert
#>
#######################################################################
<#
REQUESTS - this assumes try/catch blocks
Find line after parameter definition
 if lines doesnt equal
        ###Telemetry###
        $PSStack = Get-PSCallStack | Select-Object Command, Location
        $F = $PSStack[0].Command
        $PSDefaultParameterValues = $Global:PSDefaultParameterValues
        $RT = New-TelemetryRequest -Name $F 
        $RS = $true 
        ###Telemetry###
    Insert these lines above
 foreach try/catch block 
  if the catch block does not set rs to false and track the exception
    Insert rs=false and ntx $_.exception
 end foreach
 if last catch block is not followed by a call to stop the request
    insert the stop
#>
#######################################################################
<#
DEPENDENCIES
look inside try blocks for cmdlets that are definded as dependencies
if cmdlet is not wrapped in squigglies and piped to invoke-telemetrydependency
 wrap and pipe it
#>
#######################################################################
<#
TRACES
look for cmdlets or functions that have a message parameter
if line below is not New-TelemetryTrace
 insert New-TelemetryTrace
#>


<#
start
 get ps1 files in directory, foreach
  
#>