#Test if localhost is an active controller, return active controller FQDN
Function Get-ActiveController { 
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]]
        $Controllers
    )
    
    $Output = @()
    ###Telemetry###    
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem
    #Try to get broker site info from localhost, if that fails the broker service is down
    if ($Controllers) {
        $Controllers = $Controllers | Where-Object { $_ -ne $env:COMPUTERNAME }
        # $Controllers = @($env:COMPUTERNAME) + $Controllers
    }
    else { $Controllers = $env:COMPUTERNAME }
    
    foreach ($Controller in $Controllers) {
        $dt = New-TDep -Command 'Get-BrokerSite' -Type 'CitrixSDK' -Target $Controller -ParentName $F
        #the first server in $Controllers to successfully respond becomes our AdminAddress for the rest of the script
        try {
            $activeController = Get-BrokerSite -AdminAddress $Controller -EA 1
            if ($activeController) {                
                $Output += ($Controller)                
            }
            else { continue }
        }
        catch { 
            $dt.Telemetry.ResultCode = 1
            $dt.Telemetry.Success = $false
            $TelemetryClient.TrackException($_.Exception)
        }
        finally {
            $TItem.StopOperationDT($dt)
        }
    }  
    if ($Output.Count -gt 0) {
        return $Output
    }      
} 
function Get-ActiveScaler {
    param (
        [parameter(Mandatory)]
        [string[]]$ScalingServers,
        [parameter(Mandatory)]
        [string]$ComputerName
    )
    ###Telemetry###
    $local = ($ENV:COMPUTERNAME).ToLower()
    $dt = New-TDep -Command 'Get-CimInstance' -Type 'PSremote' -Target $local -ParentName $F
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem
    # $ParentID = $T.GetActiveScaler.Request.Telemetry.Id
    # $TItem = $T.TelemetryItem
    # $dt = $TItem.StartOperationDT("Get-CimInstance",$null,$ParentID)
    # $dt.Telemetry.Type = 'PSRemote'
    # $dt.Telemetry.Target = $ENV:COMPUTERNAME

    ###Telemetry###

    $ScalingServers = $ScalingServers | Where-Object { $_ -ne $ComputerName }
    #Check localhost
    try {
        $Process = Get-CimInstance win32_process -Filter "name='powershell.exe'" | Where-Object { $_.CommandLine -match "VMScaler.ps1" }
        if ($null -ne $Process) {
            return $Process.CSName.toLower()
        }
    }
    catch {
        $dt.Telemetry.ResultCode = 1
        $dt.Telemetry.Success = $false
        $TelemetryClient.TrackException($_.Exception)
    }
    finally {
        $TItem.StopOperationDT($dt)
        Remove-Variable dt
    }
    #If not running on localhost, check if running on any other delivery controller.
    for ($i = 0; $i -ne ($ScalingServers.Length); $i++) {   
        $dt = New-TDep -Command 'Get-CimInstance' -Type 'PSremote' -Target $local -ParentName $F
        try {
            $DeliveryController = $ScalingServers[($i)] 
            $dt.Telemetry.Target = $DeliveryController.ToLower()
            $Process = Get-CimInstance win32_process -ComputerName $DeliveryController -Filter "name='powershell.exe'" | Where-Object { $_.CommandLine -match "VMScaler.ps1" }
            if ($Process) {
                return $Process.PSComputerName
            }
        }
        catch {
            $dt.Telemetry.ResultCode = 1
            $dt.Telemetry.Success = $false
            $TelemetryClient.TrackException($_.Exception)
        }
        finally {
            $TItem.StopOperationDT($dt)
            Remove-Variable dt
        }
    }    
}
function Get-ScalableGroups {
    param(
        [parameter(Mandatory)]
        [hashtable]$AdminAddress,
        [parameter()]
        [string]$FeatureTest
    )
    $Output = @{
        Data     = @() 
        Messages = @()
    }
    $dt = New-TDep -Command 'Get-BrokerDesktopGroup' -Type 'CitrixSDK' -Target $AdminAddress.AdminAddress -ParentName $F
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem
    try {
        if (!$FeatureTest) {
            #Get Desktop groups that have a tag matching sch_ that do not have the sch_DoNotScale tag
            $Groups = (Get-BrokerDesktopGroup @AdminAddress -Filter { tags -contains "sch_*" -and tags -notcontains "sch_DoNotScale" })
        }
        else {
            $Groups = Get-BrokerDesktopGroup @AdminAddress -Filter { name -eq $FeatureTest }
        }
    }
    catch {
        $dt.Telemetry.ResultCode = 1
        $dt.Telemetry.Success = $false
        $TelemetryClient.TrackException($_.Exception)
    }
    finally {
        $TItem.StopOperationDT($dt)
        Remove-Variable dt
    }
    if ($Groups) {
        #Filter one more time to make sure the sch_ tag matches sch_UID of delivery group
        $Groups = $Groups | Where-Object { $_.Tags -contains "sch_$($_.Uid)" }
        
        #Create object for each group with contents of matching sch_ tag
        $DesktopScaleGroup = $Groups | foreach {
            $DSGName = "sch_$($_.Uid)"
            [pscustomObject]@{
                Name    = $_.Name   
                Uid     = $_.Uid 
                Tag     = (Get-BrokerTag @AdminAddress -Name $DSGName)
                AllTags = $_.Tags
            }    
        }
    
        $DesktopScaleGroup | foreach {
            $name = $_.Name 
            #Convert tag description (json) to object
            try {
                $tag = Convert-SchTag -tagObject $_.Tag -ErrorAction Stop
            }
            catch {
                
                $tag = $false
            }
            finally {
                if ($tag) {
                    $_.Tag = $tag
                }
                else { $_.Tag = $null }
            }
            #Use IsItTime() to get a scale state from the schedule
            if ($tag) {
                try {
                    $ScaleState = isItTime -Schedule $_.Tag -ErrorAction Stop
                }
                catch {
                    
                }
                finally {
                    if ($ScaleState) {
                        $_ | Add-Member NoteProperty ScaleState $ScaleState
                    }
                }
            }
        }
        $Output.Data = ($DesktopScaleGroup | Where-Object { $null -ne $_.ScaleState })    
    }
    else {
        
        return $Output
    }
    
    return $Output
}
#Check if we are in a patch window
function Test-PatchDay {
    #Takes input from Get-ScalableGroups, and checks if we are currently in a patch window 
    param(
        [parameter(Mandatory)]
        [hashtable]$AdminAddress,
        [parameter(Mandatory)]
        [Alias('DSG')]
        $DesktopScaleGroup
    )
    $DSG = $DesktopScaleGroup
    $TzId = 'Eastern Standard Time'
    #Convert current UTC time to EST, which is FNF patch sunday tzid
    $tz = resourceTz -tzid $TzId
    $LocalTime = patchTzCurrentTime -resourceTz $tz
    #Check if we are 12 days after patch tuesday
    $patch = itsPatchDay -LocalTime $LocalTime
    $MTag = "sch_maint_$($DSG.UID)"
    if (($patch) -and ($patch.Hour -ge 0) -and ($patch.Hour -lt 14)) {
        #If it is 12AM, create or update maintenance tag for the DG
        if ($patch.Hour -eq 0) {
            if ($DSG.AllTags -notcontains $MTag) {
                $Start = ($patch.AddMinutes(-$patch.Minute))
                $End = $Start.AddHours(14).DateTime     
                $Start = $Start.DateTime            
                #Create or update maintenance tag to follow 14 hour maintenance window
                try {
                    $MaintenanceTag = Get-MaintenanceTag -DSG $DSG -AdminAddress $AdminAddress
                    if (!$MaintenanceTag) {
                        New-MaintenanceTag -DSG $DSG -Start $Start -End $End -TzId $TzId -AdminAddress $AdminAddress -EA 1 | Out-Null
                    }
                    else {
                        Set-MaintenanceTag -DSG $DSG -MaintenanceTag $MaintenanceTag -Start $Start -End $End -TzId $TzId -AdminAddress $AdminAddress -EA 1 | Out-Null
                    }
                    
                }
                catch {
                    
                }
            }                
        }
        return $true
    }
    #If it is 2pm, remove the maintenance tag and start scaling again
    elseif (($patch) -and ($patch.Hour -eq 14)) {
        if ($DSG.AllTags -contains $MTag) {
            try { 
                $DG = Get-BrokerDesktopGroup @AdminAddress -Uid $DSG.Uid -EA 1
                Remove-BrokerTag @AdminAddress -Name $MTag -DesktopGroup $DG -EA 1
                
            }
            catch {
                
            }
        }
        return $false
    }    
    else {
        return $false
    }
}
#Decide how many servers to spin up based on current load
function Get-Burden {
    param (
        [parameter(Mandatory)]
        [Alias('DSG')]
        $DesktopScaleGroup,
        [parameter(Mandatory)]
        [Alias('DSGM')]
        [object]$DesktopScaleGroupMachines
    )
    $Output = @{
        Data     = 0
        Messages = @()
    }
    $DSG = $DesktopScaleGroup
    $DSGM = $DesktopScaleGroupMachines
    
    #Get session counts, servers, and session averages
    #Skipping servers with 0 sessions... If the server is broken, we don't want to include it in these calculations. If it's not broken, we will end up scaling up more than we need to, which is acceptable.
    $Sessions = ($DSGM | Where-Object { $_.SessionCount -gt 0 })

    $SessionAverage = ($Sessions.SessionCount | Measure-Object -Average -Sum)
    $Overburdened = [math]::Round([math]::Ceiling(($SessionAverage.Average / $DSG.Tag.Load.USR) * 100))
    
    #Over or Underburdened, get the number of servers it would take to bring the average session count per server below the specified limit in $DSG.Tag.Load.USR
    $numServers = [math]::Round([math]::Ceiling(($SessionAverage.Sum - ($DSG.Tag.Load.USR * $SessionAverage.Count)) / $DSG.Tag.Load.USR))
    $logData = @{
        SessionCount = ($Sessions | % {'{0}:{1}' -f ($_.MachineName -split "\\")[-1],($_.SessionCount)})
        SessionAvg   = ($SessionAverage|select count,average,sum)
        Overburdened = $Overburdened
        numServer    = $numServers
    }    
    $Output.Data = $numServers
    if ($Overburdened -gt 100) {  
        
    }
    elseif (($Overburdened -lt 100) -and ($numServers -ne 0)) {        
        
    }
    #Current burden pct is between 100 and the limit, nothing to do yet
    else {
        
        $Output.Data = 0
    }
    return $Output 
}
#Find servers in maintenance mode that can be used to cover a burden
function Scale-UpMaintenanceMode {
    param(
        [ref]$Output,
        [array]$Registered,
        [psobject]$DSG,
        [int]$UnresolvedBurden
    )
    #For all registered servers in maintenance mode, get the number of sessions left before hitting the average and add them up
    #If we have more sessions available than required to cover, stop looping 
    $SessionsToCover = ($DSG.Tag.Load.USR * $UnresolvedBurden)
    $AvailableSessions = 0
    #Only loop over servers in maintenance mode that have less active sessions than the defined average user load
    $MMArray = @()
    :SessionLoop foreach ($MM in ($Registered | Where-Object { $_.SessionCount -lt $DSG.Tag.Load.USR })) {
        $MMArray += $MM
        $AvailableSessions = $AvailableSessions + ($DSG.Tag.Load.USR - $MM.SessionCount)
        if ($AvailableSessions -ge $SessionsToCover) { break :SessionLoop } 
    }
    #Update the reference Output from parent function
    $Output.Value.Data.ExitMaintenanceMode += $MMArray
    #Found enough sessions available in maintenance servers to cover the burden
    if ($AvailableSessions -ge $SessionsToCover) {
        
        $UnresolvedBurden = 0
    }    
    #We need more to cover the burden. Get number of servers needed by sessions average, and round up.
    else {
        $UnresolvedBurden = [math]::Round([math]::Ceiling(($SessionsToCover - $AvailableSessions) / $DSG.Tag.Load.USR))
        
    }
    return $UnresolvedBurden
}
function Get-AzVMPowerState {
    #Get the names of unregistered servers, compare them to azure vm computernames, power on the first one that matches
    param(                
        [psobject]$DSG,
        [psobject]$DSGM
    )
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem

    [array]$VMs = $null
    #If an array of desktop scale group machines have been provided, try to get each VM status individually
    if ($DSGM){
        foreach ($VM in $DSGM) {
            try {        
                    $dt = New-TDep -Command 'Get-AzVM' -Type AzAPI -Target ($DSG.Tag.ResourceGroupName) -ParentName $F    
                    $name = ($vm.MachineName -split "\\")[1]
                    $VM =  Get-AzVM -ResourceGroupName $DSG.Tag.ResourceGroupName -Name $Name -Status -ErrorAction Stop 
                    if ($VM) {                
                        $VMs+=$VM | Select-Object @{N='PowerState';E={($_.Statuses | where-object {$_.Code -Match "PowerState"}).DisplayStatus  }}, Name, @{N = 'MachineName'; E = { $_.Name } } 
                    }
                    $dt.Telemetry.ResultCode=0
                    $dt.Telemetry.Success=$true            
                }
                catch {
                    tex $_.Exception
                    $failed=$true
                }
                finally {
                    Stop-OpDT $dt
                }
            }
    }
    #If Get-AzVM above fails, or an array of desktop scale group machines were not provided, try to get the status of ALL vms in the associated resource group
    if (($failed) -or (-not $DSGM)){
        try {
            $dt = New-TDep -Command 'Get-AzVM' -Type AzAPI -Target ($DSG.Tag.ResourceGroupName) -ParentName $F 
            $rg = $DSG.Tag.ResourceGroupName
            
            $VMs = Start-Retry -Command { Get-AzVM -ResourceGroupName $rg -Status -ErrorAction Stop | Select-Object Powerstate, Name, @{N = 'MachineName'; E = { $_.osprofile.computername } } -EA 1 } -EA 1
            $dt.Telemetry.ResultCode=0
            $dt.Telemetry.Success=$true
        }
        catch {
            
            tex $_.Exception
            $dt.Telemetry.Success=$false
            $return=$true
        }
        finally {
            Stop-OpDT $dt
        }
    } 
    if ($return) {
        return
    } else {
        return $VMs
    }
}
function Get-AzVMInDG {
    param(
        [psobject]$DeliveryGroupMachines,
        [object]$AzVMs
    )
    #Get AzureVMs that are in the list of unregistered delivery group machines
    #The deliverygroupmachines.machinename includes DOMAIN\MachineName, so we split there and select Machinename only
    $DGMachines = ($DeliveryGroupMachines.MachineName | foreach { ($_ -split '\\')[1] })
    foreach ($AzVM in $AzVMs) {
        if (($AzVM.MachineName -in $DGMachines) -or ($AzVM.Name -in $DGMachines)) {
            $AzVM
        }
    } 
}
function Scale-UpAzVMStarting {
    param(
        [ref]$Output,
        [object]$VMsInDG,
        [psobject]$Unregistered,
        [psobject]$DSG,
        [int]$UnresolvedBurden
    )
    [array]$VmStarting = ($VMsInDG | Where-Object { $_.Powerstate -eq "Starting" })
    [array]$StartingVMs = ($Unregistered | Where-Object { ($_.MachineName -split '\\')[1] -in $VmStarting.MachineName })
    #If the number of "Starting" VMs covers the number of machines that need to be turned on, select that number and exit
    if ($StartingVMs.Count -ge $UnresolvedBurden) {
        $StartingVMs = $StartingVMs | select -First $UnresolvedBurden
        $Output.Value.Data.ExitMaintenanceMode += $StartingVMs
        
    } 
    #All available "Starting" VMs will be used to cover the burden
    else {
        $Output.Value.Data.ExitMaintenanceMode += $StartingVMs
        
    }
    #Subtract the number of "Starting" VMs from the burden
    $UnresolvedBurden = $UnresolvedBurden - $StartingVMs.Count
    return $UnresolvedBurden
}     
function Scale-UpAzVMDeallocated {
    param(
        [ref]$Output,
        [object]$VMsInDG,
        [psobject]$Unregistered,
        [psobject]$DSG,
        [int]$UnresolvedBurden
    )
    [array]$VmDeallocated = $VMsInDG | Where-Object { $_.Powerstate -eq 'VM Deallocated' } 
    #Do we have enough deallocated VMs to cover the burden? Y - Power on number we need. N - Power on what we can.
    if ($VmDeallocated.Count -ge $UnresolvedBurden) {
        $VmDeallocated = $VmDeallocated | select -First $UnresolvedBurden
        
    } 
    else {
        
    }
    #Subtract the number of Deallocated VMs from the burden
    $UnresolvedBurden = $UnresolvedBurden - $VmDeallocated.Count
    #Add AzureVMNames to output, will be sent to start-azvm            
    $Output.Value.Data.Add('AzureVMNames', @($VMDeallocated.Name)) 
    $Output.Value.Data.ExitMaintenanceMode += @(($Unregistered | Where-Object { ($_.MachineName -split '\\')[1] -in $VmDeallocated.MachineName }))   
    return $UnresolvedBurden
}
#Find Azure VMs that can be powered on. Subtract VMs in the "Starting" state from the $UnresolvedBurden count, then try to power on deallocated VMs if $UnresolvedBurden is still gt 0
function Scale-Up {
    param (
        [parameter(Mandatory)]
        [Alias('DSG')]
        $DesktopScaleGroup,
        [parameter(Mandatory)]
        [Alias('DSGM')]
        [object]$DesktopScaleGroupMachines,
        [parameter(Mandatory)]
        [Alias('B')]
        [int]$UnresolvedBurden
    )
    $DSG = $DesktopScaleGroup
    $DSGM = $DesktopScaleGroupMachines

    $Output = @{
        Data     = @{
            ExitMaintenanceMode = @()
        }
        Messages = @()
    }
    if ($Burden -eq 0) {
        return $Output
    }
    [array]$DrainingServers = $DSGM | Where-Object { ($_.Tags -contains 'sch_Scale') -and ($_.Tags -notcontains 'sch_alwaysOn') -and ($_.InMaintenanceMode -eq $true) } 
    #Sort by session count to get the servers in maintenance mode with the least connected sessions
    [array]$Registered = $DrainingServers | Where-Object { ($_.RegistrationState -eq 'Registered') } | Sort-Object SessionCount            
    [array]$Unregistered = $DSGM | Where-Object { ($_.Tags -contains 'sch_Scale') -and ($_.Tags -notcontains 'sch_alwaysOn') -and ($_.Tags -notcontains 'sch_AzAutoJobStart') -and ($_.RegistrationState -eq 'Unregistered') }

    #Do we have enough registered servers in maintenance mode to cover the burden?
    if ($Registered.Count -gt 0) {     
        #Recalculate the burden including servers in maintenance mode   
        $AllRegistered = ($DSGM | Where-Object { ($_.Tags -contains 'sch_Scale') -or ($_.Tags -contains 'sch_alwaysOn') -and ($_.RegistrationState -eq 'Registered') })
        $UpdateBurden = (Get-Burden -DesktopScaleGroup $DSG -DesktopScaleGroupMachines $AllRegistered).Data
        #If the updated burden is less than the original burden, then we can scale up by exiting maintenance mode        
        if ($UpdateBurden -le $UnresolvedBurden) { 
            $UnresolvedBurden = Scale-UpMaintenanceMode -Output ([ref]$Output) -Registered $Registered -DSG $DSG -UnresolvedBurden $UnresolvedBurden
        }                          
    }
    #Check status of VMs in azure if we have more burden to resolve
    if ($UnresolvedBurden -gt 0) { 
        #Do we have any unregistered/offline servers we could try to power on?
        if ($Unregistered.Count -gt 0) {
            #Get the names of unregistered servers, compare them to azure vm computernames, power on the first one that matches 
            
            $AzVMs = Get-AzVMPowerstate -DSG $DSG -DSGM $Unregistered
            $VMsInDG = Get-AzVMInDG -DeliveryGroupMachines $Unregistered -AzVMs $AzVMs
            if ($VMsInDG) {
                #Find any VMs that are "Starting". Add DesktopScaleGroupMachines to output
                if ("Starting" -in $VMsInDG.PowerState) {         
                    $UnresolvedBurden = Scale-UpAzVMStarting -Output ([ref]$Output) -VMsInDG $VMsInDG -DSG $DSG -Unregistered $Unregistered -UnresolvedBurden $UnresolvedBurden
                }
                if ($UnresolvedBurden -gt 0) {
                    #If there are no deallocated VMs, nothing we can do
                    if ("VM Deallocated" -notin $VMsInDG.Powerstate) {
                        
                    }
                    #Add deallocated VMnames and machinenames to output
                    else {
                        $UnresolvedBurden = Scale-UpAzVMDeallocated -Output ([ref]$Output) -VMsInDG $VMsInDG -Unregistered $Unregistered -DSG $DSG -UnresolvedBurden $UnresolvedBurden
                    }
                }
            }
            else { }
        }
        
    }
    #Write an error if there are not enough servers to cover the burden
    if ($UnresolvedBurden -ne 0) {
        
    }
    return $Output
}
function Scale-DownMaintenanceMode {
    param(
        [ref]$Output,
        [array]$NotDrainingServers,
        [int]$UnresolvedBurden,
        [psobject]$DSG
    )
    #Find $UnresolvedBurden servers that have the least active sessions
    #Enter maintenance mode for $UnresolvedBurden machines
    if ($NotDrainingServers.Count -ge $UnresolvedBurden) {
        $NotDrainingServers = $NotDrainingServers | select -First $UnresolvedBurden
        
        $Output.Value.Data.EnterMaintenanceMode += $NotDrainingServers
    }
    elseif (($NotDrainingServers.Count -lt $UnresolvedBurden) -and ($NotDrainingServers.Count -ne 0)) {
        
        $Output.Value.Data.EnterMaintenanceMode += $NotDrainingServers
    }
    else {
        
    }
}
function Scale-DownIdleSessions {
    param(
        [ref]$Output,
        [psobject]$DSG,
        [array]$DrainingServers,
        [hashtable]$AdminAddress
    )
    $IdleSince = (Get-Date).AddMinutes( - ($DSG.Tag.Limit))
    $IdleMax = (Get-Date).AddMinutes( - ($DSG.Tag.Limit) + 10)
    [array]$MachineNameFilter = ($DrainingServers | Where-Object {($_.Tags -notcontains 'sch_alwaysOn') -and ($_.Tags -notcontains 'sch_AzAutoJobStop')}).MachineName
    #Get the broker sessions for all of the sch_scale servers in maintenance mode and group them by machine
    try {
        $AllSessions = Get-BrokerSession @AdminAddress -DesktopGroupUid $DSG.Uid -MaxRecordCount 9999 -Filter { MachineName -in $MachineNameFilter } -ErrorAction Stop
        #look for machines that have only idle sessions remaining that are gt double the $DSG.Tag.Limit this indicates Stop-BrokerSession cannot kill these sessions, and the server will remain online all night because we can't remove it.
        $AllSessions | group MachineName | foreach {
            $CurrentMachineName = $_.Name
            $AllMachineSessions = $_.Group
            #If the machine has any active sessions, or sessions that have not met the idle limit, move on to the next machine
            $ActiveSessions = $AllMachineSessions | Where-Object { ($null -eq $_.IdleSince) -or ($_.IdleSince -gt $IdleSince) }
            If ($Null -ne $ActiveSessions) {
                return
            } 
            #Get the most recent idle session on this machine. If it has been idle longer than $DSG.Tag.Limit*2, add the machine to the list of servers to power off
            else {
                $YoungestSession = ($AllMachineSessions | Measure-Object -Property IdleSince -Maximum).Maximum
                if ($YoungestSession -lt $IdleMax) {
                    
                    $Output.Value.Data.MaxIdleSession += ($DrainingServers | Where-Object {$_.MachineName -eq $CurrentMachineName})
                    #Remove these sessions from $AllSessions so we don't double our workload below
                    $AllSessions = $AllSessions | Where-Object {$_.Uid -notin $AllMachineSessions.Uid}
                }
            }
        }
        $IdleSessions = $AllSessions | Where-Object {($_.Idlesince -lt $IdleSince) -and ($null -ne $_.IdleSince)}
        if ($IdleSessions.Count -gt 50) {
            $IdleSessions = $IdleSessions | select -first 50
        }
        $Output.Value.Data.IdleSessions += $IdleSessions
    }
    catch {
        
        return
    }
    
}

function Scale-DownAzVMNoSessions {
    param (
        [ref]$Output,
        [array]$NoSessions,
        [psobject]$DSG
    )
    
    
    try {                       
        $VMs = Get-AzVMPowerState -DSG $DSG -DSGM $NoSessions -EA 1
    }
    catch {  
        return        
    } 
    #Filter Azure vm list by computernames that exist in the farm
    [array]$VMsInDG = Get-AzVMInDG -DeliveryGroupMachines $NoSessions -AzVMs $VMs    
    if ($VMsInDG.Count -eq $NoSessions.Count) {
        
    }
    elseif ($VMSInDG) {
        
    }
    else { 
    #Adding this last check, because adding $null to an array will result in a count of 1, which will break things or cause issues upstream
    if ($null -ne $VMsInDG) {
        $Output.Value.Data.AzureVMNames += $VMsInDG.Name                    
    }
}
}

#Find VDA servers that can be powered off
function Scale-Down {
    <#
    .SYNOPSIS
    Given a number of servers a delivery group is underburdened by, resolve the burden by entering maintenance mode and powering off VMs with 0 sessions.
    .NOTES
    #If we are here, then the burden on registered,active servers is negative, so we can enter maintenance mode
    Enter maintenance mode
    #>
    param(
        [parameter(Mandatory)]
        [Alias('DSG')]
        $DesktopScaleGroup,
        [parameter(Mandatory)]
        [Alias('DSGM')]
        [object]$DesktopScaleGroupMachines,
        [parameter(Mandatory)]
        [hashtable]$AdminAddress,
        [parameter(Mandatory)]
        [Alias('B')]
        [int]$UnresolvedBurden,
        [parameter(HelpMessage = "Power off VMs")]
        [switch]$DrainVMs,
        [parameter(HelpMessage = "Allows scale-downidlesessions and scale-downazvmnosessions to collect data for logging/troubleshooting")]
        [switch]$Audit
    )
    $DSG = $DesktopScaleGroup
    $DSGM = $DesktopScaleGroupMachines
    $Output = @{
        Data     = @{
            EnterMaintenanceMode = @()
            IdleSessions         = @()
            MaxIdleSession       = @()
            AzureVMNames         = @()
        }
        Messages = @()
    }
    [array]$AllServers = $DSGM | Where-Object { ($_.Tags -contains 'sch_Scale') -and ($_.Tags -notcontains 'sch_alwaysOn') -and ($_.RegistrationState -eq 'Registered') }
    [array]$IdleSessionServers = $DSGM | Where-Object { (($_.Tags -contains 'sch_Scale') -or ($_.Tags -contains 'sch_alwaysOn')) -and ($_.RegistrationState -eq 'Registered') }
    [array]$DrainingServers = $AllServers | Where-Object { ($_.InMaintenanceMode -eq $true) } | Sort-Object SessionCount
    [array]$NotDrainingServers = $AllServers | Where-Object { ($_.InMaintenanceMode -eq $false) } | Sort-Object SessionCount
    $UnresolvedBurden = [math]::Abs($UnresolvedBurden)
    if (($NotDrainingServers.Count -gt 0) -and ($UnresolvedBurden -ne 0)) {
        Scale-DownMaintenanceMode -Output ([ref]$Output) -NotDrainingServers $NotDrainingServers -UnresolvedBurden $UnresolvedBurden -DSG $DSG
    }
    if (($DrainVMs -and ($DrainingServers.Count -gt 0)) -or $Audit) {
        #If there is an idle duration Limit set, check for sessions over the limit and log them off
        if ($DSG.Tag.Limit) {    
            if (-not $Audit) {        
                Scale-DownIdleSessions -Output ([ref]$Output) -DSG $DSG -DrainingServers $IdleSessionServers -AdminAddress $AdminAddress
            }
            else {
                Scale-DownIdleSessions -Output ([ref]$Output) -DSG $DSG -DrainingServers $AllServers -AdminAddress $AdminAddress
            }
        }
        #Power off servers with 0 sessions
        if ($Audit) {
            [array]$NoSessions = $AllServers | Where-Object { ($_.SessionCount -eq 0) -and ($_.Tags -notcontains 'sch_AzAutoJobStop') } 
        }
        else {
            [array]$NoSessions = $DrainingServers | Where-Object { ($_.SessionCount -eq 0) -and ($_.Tags -notcontains 'sch_AzAutoJobStop') } 
            #Do we have servers that only contain maxidle sessions? i.e. sessions vmscaler cannot remove
            if ($Output.Data.MaxIdleSession) {
                if ($NoSessions) {
                    $NoSessions+=$Output.Data.MaxIdleSession
                }
                else {
                    $NoSessions = $Output.Data.MaxIdleSession
                }
            }
        }
        if ($NoSessions.Count -gt 0) {
            Scale-DownAzVMNoSessions -Output ([ref]$Output) -NoSessions $NoSessions -DSG $DSG
        }
        else {
            
        }
    }
    return $Output
}
function Get-PeggedVDA {
    #If there are pegged servers in the sch_AlwaysOn group, we will remove them from the pool as they can skew results of Get-Burden
    param (
        [psobject]$DSGM,
        [psobject]$DSG
    )
    $Output = @{
        Data = @{
            MaxLoad = $false
            DSGM    = @()
        }
    }
    $AlwaysOn = $DSGM | Where-Object { $_.Tags -contains 'sch_AlwaysOn' }
    $AlwaysOn | foreach {
        $OnServer = $_
        if ((($OnServer.LoadIndex -eq 10000) -or ($OnServer.LoadIndex -eq 20000)) -and ($OnServer.SessionCount -lt $DSG.Tag.Load.USR)) {
            $Output.Data.MaxLoad = $true
            $DSGM = $DSGM | Where-Object { $_.MachineName -ne $OnServer.MachineName }
            
        }
    }
    $Output.Data.DSGM = $DSGM
    return $Output
}
function Start-Runbook {
    param(
        [psobject]$DSG,
        [bool]$Start,
        [bool]$Stop,
        [string[]]$VMNames,
        [string]$AutomationAccountName = 'fnf-aa-monitoring-pr-use2-02',
        [string]$ResourceGroupName = 'fnf-rg-monitoring-prod',
        [string]$RunbookName = 'fnf-vmautomation'
    )
    ###Telemetry###    
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem
    
    $param = @{
        runbook        = 'fnf-scheduledstartstop_parent'
        connectionName = "$AutomationAccountName-connection"
        vmlist         = @($VMNames)
        schedule       = [pscustomobject]@{empty = 'object' }
        webhookdata    = @{
            requestBody = [pscustomobject]@{
                Start = $Start
                Stop  = $Stop
            }
        }
    }
    try {
        $dt = New-TDep -Command 'Start-AzAutomationRunbook' -Type 'AzAPI' -Target $AutomationAccountName -ParentName $F
        $Run = Start-Retry -Command { Start-AzAutomationRunbook -Name $RunbookName -Parameters $param -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -EA 1 } -EA 1
        
        $dt.Telemetry.Success = $true
        $dt.Telemetry.ResultCode = 200
    }
    catch {
        
        tex $_.Exception
        $dt.Telemetry.Success=$false
        $dt.Telemetry.ResultCode=1
        throw
    }
    finally {
        Stop-OpDT $dt
    }
}
function Get-AzAutoTaggedState {
    param(
        [psobject]$DSGM,
        [int]$Burden,
        [int]$nPlus
    )
    #Add server that have the tag and are registered to removetag, so we can remove the tag in scale-vda
    $Output = @{
        Data = @{
            RemoveTag = @($DSGM | Where-Object { ($_.RegistrationState -eq 'Registered') -and ($_.Tags -contains 'sch_AzAutoJobStart') })
            Burden    = $Burden
        } 
    }

    #Get Unregistered servers that have been tagged
    #If the number of unregistered servers is less than the current burden, increase the burden by one so we can get ahead of the loa11d
    #If the number of registered servers is greater than or equal to the current burden, set the burden to 0 so we can wait for these starting servers to register
    [array]$AzAutoTagged = $DSGM | Where-Object { ($_.RegistrationState -ne 'Registered') -and ($_.Tags -contains 'sch_AzAutoJobStart') }
    if ($AzAutoTagged.Count -gt 0) {            
        if ($AzAutoTagged.Count -lt $Burden) {
            #overburdened by alltags+1, scale up again by n+(n*.5)
            $nPlusF = [math]::round([math]::ceiling($nPlus * .5))            
            
            $Output.Data.Burden = ($Burden - ($AzAutoTagged.Count)) + $nPlusF
        }
        elseif ($AzAutoTagged.Count -ge $Burden) {
            
            $Output.Data.Burden = 0
        }
    }
    return $Output
} 
function Set-MTM {
    param(
        [string]$URI = 'https://nocrest.fnf.com/ScomAPI_prod/api',
        [psobject]$DSGM,
        [switch]$Enter,
        [switch]$Exit
    )
    $Output = @{
        Data = @()
    }
    ###Telemetry###    
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem
    foreach ($vm in $DSGM) {
        $ServerName = $vm.MachineName.split('\\') 
        $ServerName = $ServerName[1] + "." + $ServerName[0] + ".local"
        if ($Exit) {            
            $Output.Data += $URI + "/Maintenance/StopWindowsMaintenance?computerName=$ServerName"            
        }
        if ($Enter) {
            $Output.Data += $URI + "/Maintenance/ScheduleWindowsMaintenance?computerName=$ServerName&maintenanceComment=VMScaler&timeMaintenanceDurationInMinutes=43800"   
        }
    }
    
        $Output.Data | foreach {
            try {
                $URI = $_
                $dt = New-TDep -Command 'Invoke-RestMethod' -Type 'ScomAPI' -Target ($URI -split "\?")[0] -ParentName $F
                $Request = Invoke-RestMethod -Method Post -URI $URI -EA 1
                if (($Request.HasError) -or ($Request.Message -eq "Computer name not found")) {
                    
                    $dt.Telemetry.ResultCode = 404
                }
                else {
                    
                    $dt.Telemetry.ResultCode = 200
                    $dt.Telemetry.Success = $true
                }

            }
            catch {
                
                tex $_.Exception
                $dt.Telemetry.ResultCode = 1
                $dt.Telemetry.Success = $false
            }
            finally {
                Stop-OpDT $dt
            }
        }    
}      
function New-SNOW {
    param (
        [parameter(Mandatory)]
        [psobject]$DSGM,
        [parameter(Mandatory)]
        [validateset('Server On', 'Server Off')]
        [string]$OnOff
    )
    $Output = @{
        Data = @()
    }   
    ###Telemetry###    
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem 
    #Get stored snow credential
    try {
        $snowcred = Get-CredMan -EA 1
    }
    catch {
        
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $URI = 'https://fnf.service-now.com/api/now/table/u_event'
    $user = $snowcred.UserName
    $pass = $snowcred.GetNetworkCredential().Password
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $user, $pass)))
    $type = 'application/json'
    $Headers = @{
        Authorization  = 'Basic {0}' -f $auth
        Accept         = $type
        'Content-Type' = $type
    }

    foreach ($vm in $DSGM) {

        $ServerName = $vm.MachineName.split('\\') 
        $ServerName = $ServerName[1] + "." + $ServerName[0] + ".local"
        $Description = "$OnOff - $ServerName"

$BODY = @'
{{
    "u_event_type":"{0}",
    "u_action":"{1}",
    "u_event_timestamp":"{2}",
    "u_server_name":"{3}",
    "short_description":"{4}",
    "u_guid":"{5}"
}}
'@ -f 'VMScaler', $OnOff, [datetime]::Now.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss"), $ServerName, $Description, (New-Guid)

        $Request = Invoke-RestMethod -Headers $Headers -Method POST -ContentType $type -Body $Body -Uri $URI -EA 1
}
}
Function Get-CredMan {
    param(
        [string]$Resource="SNOWEvents"
    )
    
    $ErrorActionPreference = 'Stop' 
    $retryCount=3   
    do {        
        try {
            [Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime] | Out-Null
            $Vault = new-object Windows.Security.Credentials.PasswordVault
            $AllSavedCredentials = $Vault.RetrieveAll()
            $StoredCredential = $AllSavedCredentials.where({$_.Resource -eq $Resource})
            $StoredCredential.RetrievePassword()
            $ReturnedCredential = New-Object System.Management.Automation.PSCredential -ArgumentList ($StoredCredential.UserName, (ConvertTo-SecureString $StoredCredential.Password -AsPlainText -Force))
            $ReturnedCredential 
            $RetryCount = -1      
        }
        catch {
            if ($RetryCount -eq 0) {
                $RetryCount--                
            }
            else {
                $WaitSeconds = Get-Random -Maximum 5 -Minimum 1                
                Start-Sleep -Seconds $WaitSeconds
                $RetryCount--
            }             
        }        
    } while ($retryCount -ne -1)
}
function Scale-VDA {
    param(
        [parameter(Mandatory)]
        [hashtable]$AdminAddress,
        [parameter(Mandatory)]
        [alias('DSG')]
        [pscustomobject]$DesktopScaleGroup
    )
    $Output = @{
        Data     = @{ } 
        Messages = @()
    }
    $DSG = $DesktopScaleGroup

    #Create Telemetry Objects and store in Global variable $T
    if (($DSG.ScaleState -eq 'init') -or ($DSG.ScaleState -eq 'scale')) { $OpName = 'ScaleOut' }
    else { $OpName = 'ScaleIn' }    
    $MetricDefs=@(
    'SessionCount,DeliveryGroup,ServerName',
    'LoadIndexesCPU,DeliveryGroup,ServerName'
    )
    New-Variable -Scope Global -Name T -Value (New-Op -OperationName "$OpName $($DSG.Name)" -Metrics $MetricDefs)
    $MetricHash = @{
        SessionCount   = @()
        LoadIndexesCPU = @()
    }
    $TClient = $T.TelemetryClient    
    $TItem = $T.TelemetryItem

    if ($DSG.AllTags -Contains 'sch_OnlyLog') {
        $Audit = $true
    }
    else {
        $Audit = $false
    }
    #If the delivery group tag contains AppInsightsKey property, add it as a default parameter to Write-Log
    if ($DSG.Tag.AppInsightsKey) {
        $PSDefaultParameterValues = @{
            "Write-Log:AppInsightsKey"    = $DSG.Tag.AppInsightsKey
            "Write-Log:DeliveryGroupName" = $DSG.Name
        }        
    }
    else {
        $PSDefaultParameterValues = @{
            "Write-Log:DeliveryGroupName" = $DSG.Name
        }
    }
    #All the servers in the scale set
    try {
        $rq0 = New-TReq -Name 'Get-BrokerMachine'
        $rq0dp0 = New-TDep -Command 'Get-BrokerMachine' -Type CitrixSDK -Target $AdminAddress.AdminAddress -ParentName 'Get-BrokerMachine' 
        $DSGM = Get-BrokerMachine @AdminAddress -DesktopGroupUid $DSG.Uid | Where-Object { ($_.Tags -contains 'sch_Scale') -or ($_.Tags -Contains 'sch_AlwaysOn') } -EA 1
        #Send CPU and Session count metrics to App Insights
        # $TClient.TrackTrace("Tracking CPU and SessionCount Metrics")
        $DSGM | % {
            $Server = $_.MachineName.split('\')[1]
            $SessionCount = $_.SessionCount
            if ($_.LoadIndexes[0] -match "CPU\:") {
                $CPU = ($_.LoadIndexes[0] -replace "CPU\:" -as [int])
                $MetricHash.LoadIndexesCPU += @{CPU=$CPU;DSG=$DSG.Name;SRV=$Server}
            }
            if ($SessionCount) {
                $MetricHash.SessionCount += @{SCT=$SessionCount;DSG=$DSG.Name;SRV=$Server}
            }
        }        
        $rq0.Telemetry.Success=$true
        $rq0dp0.Telemetry.Success=$true
    }
    catch {
        
        tex $_.Exception
        $rq0.Telemetry.Success=$false
        $rq0dp0.Telemetry.Success=$false
        $return = $true
    }
    finally {
        Stop-OpDT $rq0dp0
        Stop-OpRT $rq0
    }
    if ($return) { flush;return }
    $CTXFunction = 'Set-BrokerMachineMaintenanceMode'

    if (($DSG.ScaleState -eq 'init') -or ($DSG.ScaleState -eq 'scale')) {
        $DrainVMs = $false
        if ($DSG.AllTags -contains 'sch_Drain') {
            try {
                $rq1 = New-TReq -Name "Set-SchTag"
                Set-SchTag -AdminAddress $AdminAddress -TagName sch_Drain -Action Remove -DesktopScaleGroup $DSG
                $rq1.Telemetry.Success = $true
            }
            catch {
                $rq1.Telemetry.Success = $false
                tex $_.Exception
            }
            finally {
                Stop-OpRT $rq1
            }
            #Remove sch_AzAutoJobStop tag from all machines that were powered off during Drain, and any AutoJobStart tags that were never removed
            [array]$AzAutoTagged = $DSGM | Where-Object { ($_.Tags -contains 'sch_AzAutoJobStop') -or ($_.Tags -contains 'sch_AzAutoJobStart') }
            if ($AzAutoTagged.Count -gt 0) {    
            try {
                $rq2 = New-TReq -Name 'Reset-Tags'
                Reset-Tags -DSGM $AzAutoTagged -AdminAddress $AdminAddress
                $rq2.Telemetry.Success = $true
                }
                catch {
                    $rq2.Telemetry.Success = $false
                    tex $_.Exception
                }
                finally {
                    Stop-OpRT $rq2
                }      
            }
            #Exit out of this job, setting tags for all of the scaling servers can take some time
            flush 
            return $MetricHash
        }
    }
    #Add sch_Drain tag to Desktop Group, put all scalable servers into maintenance mode
    if (($DSG.ScaleState -eq 'drain') -or ($DSG.ScaleState -eq 'shouldBeDraining')) {
        #switch parameter that tells Scale-Down to start powering off VMs
        $DrainVMs = $true
        if ($DSG.AllTags -notcontains 'sch_Drain') {
            try {
                $rq1 = New-TReq -Name "Set-SchTag"                    
                Set-SchTag -AdminAddress $AdminAddress -TagName sch_Drain -Action Add -DesktopScaleGroup $DSG -EA 1                             
                $rq1.Telemetry.Success = $true
            }
            catch {
                $rq1.Telemetry.Success = $false
                tex $_.Exception
            }
            finally {
                Stop-OpRT $rq1
            }                         
            [array]$ServersNoMaintenance = $DSGM | Where-Object { ($_.InMaintenanceMode -eq $false) -and ($_.Tags -notcontains 'sch_AlwaysOn') }                
            if ($ServersNoMaintenance.Count -gt 0) {  
                try {
                    if (-not $Audit) {
                        $rq2 = New-TReq -Name 'Set-BrokerMachineMaintenanceMode'
                        $rq2dp0 = New-TDep -Type CitrixSDK -Command 'Set-BrokerMachineMaintenanceMode' -Target $AdminAddress.AdminAddress -ParentName 'Set-BrokerMachineMaintenanceMode'

                        $ServersNoMaintenance | Set-BrokerMachineMaintenanceMode @AdminAddress -MaintenanceMode $true -ErrorAction Stop

                        $rq2dp0.Telemetry.Success = $true
                        $rq2.Telemetry.Success = $true
                    }
                    
                }
                catch {
                    
                    $rq2dp0.Telemetry.Success = $false
                    $rq2.Telemetry.Success = $false
                    tex $_.Exception
                }
                finally {
                    Stop-OpDT $rq2dp0
                    Stop-OpRT $rq2
                }
                #Exit out of this job, entering maintenance mode for all of the scaling servers can take some time
                flush
                return $MetricHash
            }
            else { 
        }
    }

    #If there are pegged servers in the sch_AlwaysOn group, we will remove them from the pool as they can skew results of Get-Burden  
    try {
        $rq3 = New-TReq -Name 'Get-PeggedVDA'
        $maxLoad = Get-PeggedVDA -DSGM $DSGM -DSG $DSG
        $rq3.Telemetry.Success = $true
        if ($maxLoad.Data.MaxLoad) { 
            $DSGM = $maxLoad.Data.DSGM
        }        
    }
    catch {
        $rq3.Telemetry.Success = $false
        tex $_.Exception
    }  
    finally {
        Stop-OpRT $rq3
    }

    #Servers that are actively being used in the scale set, this is what we use to determine the current load
    $ActiveServers = $DSGM | Where-Object { ($_.RegistrationState -eq 'Registered') -and ($_.InMaintenanceMode -eq $false) }
    try {
        $rq4 = New-TReq -Name "Get-Burden"
        #Get how many servers need to be added or removed from the scale set to even the load
        $Burden = (Get-Burden -DesktopScaleGroup $DSG -DesktopScaleGroupMachines $ActiveServers).Data 
        $rq4.Telemetry.Success = $true
    }
    catch {
        $rq4.Telemetry.Success = $false
        tex $_.Exception
    }
    finally {
        Stop-OpRT $rq4
    }
    #If we just scaled out, we want to keep the nplus servers online
    if ($DSG.Tag.Load.nPlus) { $ScaleInBurden = -$DSG.Tag.Load.nPlus-1 }
    else {$ScaleInBurden=-1}
    #Must scale up
    if ($Burden -gt 0) {  

        #ADD N+N TO BURDEN
        if ($DSG.Tag.Load.nPlus) { $Burden = $Burden + $DSG.Tag.Load.nPlus }   

        try {
            $rq5 = New-TReq -Name "Get-AzAutoTaggedState"
            
            $AzAutoTagged = (Get-AzAutoTaggedState -DSGM $DSGM -Burden $Burden -nPlus $DSG.Tag.Load.nPlus).Data
            $Burden = $AzAutoTagged.Burden  

            $rq5.Telemetry.Success = $true
        }
        catch {
            $rq5.Telemetry.Success = $false
            tex $_.Exception
        }
        finally {
            Stop-OpRT $rq5
        }
        #Check for AutoTagged servers that are starting and remove the tag. Remove AutoTagged count from burden  
        #Servers in $AzAutoTagged.RemoveTag are both 'Running' in azure and 'Registered' in Citrix, remove the starting tag and exit MTM
        If ($AzAutoTagged.RemoveTag.Count -gt 0) { 
            try {
                $rq6 = New-TReq -Name 'Set-SchTag'  
                $AzAutoTagged.RemoveTag | foreach {
                    Set-SchTag -DesktopScaleGroupMachine $_ -AdminAddress $AdminAddress -Action Remove -TagName sch_AzAutoJobStart                
                }
                $rq6.Telemetry.Success = $true
            }
            catch {
                $rq6.Telemetry.Success = $false
                tex $_.Exception
            }
            finally {
                Stop-OpRT $rq6
            }

            try {
                if (-not $Audit) {
                    $rq7 = New-TReq -Name 'Set-MTM'           
                    Set-MTM -DSGM $AzAutoTagged.RemoveTag -Exit
                    $rq7.Telemetry.Success = $true
                }   
            }
            catch {
                $rq7.telemetry.Success = $false
                tex $_.Exception
            }
            finally {
                Stop-OpRT $rq7
            }

        }

        #FIND OUT WHO CAN SCALE
        try {
            $rq8 = New-TReq -Name 'Scale-Up'
            $ScaleUp = (Scale-Up -DSG $DSG -DSGM $DSGM -UnresolvedBurden $Burden).Data            
            $rq8.telemetry.Success = $true
        }
        catch {
            $rq8.telemetry.Success = $false
            tex $_.Exception
        }
        finally {
            Stop-OpRT $rq8
        }     
        
        #Power On Azure VMs, add Starting tag, Enter SCOM MTM, Add record to SNOW Event Table
        if ($ScaleUp.ContainsKey('AzureVMNames')) {            
            
            try {
                $rq9 = New-TReq -Name 'Scale-Actions'
                Scale-Actions -DSG $DSG -DSGM $DSGM -ScaleOut $ScaleUp -Audit:$Audit -AdminAddress $AdminAddress 
                $rq9.Telemetry.Success = $true
            }
            catch {
                $rq9.telemetry.Success = $false
                tex $_.Exception
            }
            finally {
                Stop-OpRT $rq9
            } 
        }
        
        #EXIT MAINTENANCE MODE
        if ($ScaleUp.ExitMaintenanceMode.Count -gt 0) {
            try {
                if (-not $Audit) {
                    $rq10 = New-TReq -Name 'Set-BrokerMachineMaintenanceMode'
                    $rq10dp0 = New-TDep -Type 'CitrixSDK' -Command 'Set-BrokerMachineMaintenanceMode' -Target $AdminAddress.AdminAddress -ParentName 'Set-BrokerMachineMaintenanceMode'
                    $ScaleUp.ExitMaintenanceMode | Set-BrokerMachineMaintenanceMode @AdminAddress -MaintenanceMode $false -EA 1
                    $rq10.Telemetry.Success = $true
                    $rq10dp0.Telemetry.Success = $true
                }
                
            }
            catch {
                
                $rq10.Telemetry.Success = $false
                $rq10dp0.Telemetry.Success = $false
                tex $_.Exception
            }
            Finally {
                Stop-OpDT $rq10dp0
                Stop-OpRT $rq10
            }
        }

        
    }
    #Must scale down, only look for servers to deallocate if we are in drain or shouldBeDraining scalestate
    elseif ((($Burden -lt 0) -and ($DrainVMs)) -or (($Burden -lt $ScaleInBurden) -and (-not $DrainVMs)) -or ($DrainVMs)) {
        #Remove sch_AzAutoJobStop tag from VMs that have successfully powered down
        $RemoveStopTag = $DSGM | Where-Object {($_.RegistrationState -eq 'Unregistered') -and ($_.Tags -contains 'sch_AzAutoJobStop')}
        if ($RemoveStopTag) {
            try {
                $rq5 = New-TReq -Name 'Set-SchTag'            
                $RemoveStopTag | foreach {
                    Set-SchTag -DesktopScaleGroupMachine $_ -Action Remove -TagName 'sch_AzAutoJobStop' -AdminAddress $AdminAddress
                }
                $rq5.Telemetry.Success = $true
                }
                catch {
                    $rq5.telemetry.Success = $false
                    tex $_.Exception
                }
                finally {
                    Stop-OpRT $rq5
                }
        }

        try {
            $rq6 = New-TReq -Name 'Scale-Down'
            $ScaleDown = (Scale-Down -AdminAddress $AdminAddress -DSG $DSG -DSGM $DSGM -UnresolvedBurden $Burden -DrainVMs:$DrainVMs -Audit:$Audit).Data
            $rq6.Telemetry.Success = $true
        }
        catch {
            $rq6.telemetry.Success = $false
            tex $_.Exception
        }
        finally {
            Stop-OpRT $rq6
        }

        #Power Off Azure VMs, Enter SCOM MTM, Add record to SNOW Event Table
        if ($ScaleDown.AzureVMNames.Count -gt 0) {   
            try {
                $rq7 = New-TReq -Name 'Scale-Actions'
                Scale-Actions -DSG $DSG -DSGM $DSGM -ScaleIn $ScaleDown -Audit:$Audit -AdminAddress $AdminAddress 
                $rq7.Telemetry.Success = $true
            }
            catch {
                $rq7.telemetry.Success = $false
                tex $_.Exception
            }
            finally {
                Stop-OpRT $rq7
            }         
            
        }

        #ENTER MAINTENANCE MODE
        if ($ScaleDown.EnterMaintenanceMode.Count -gt 0) {
            try {
                if (-not $Audit) {
                    $rq8 = New-TReq -Name 'Set-BrokerMachineMaintenanceMode'
                    $rq8dp0 = New-TDep -Type 'CitrixSDK' -Command 'Set-BrokerMachineMaintenanceMode' -Target $AdminAddress.AdminAddress -ParentName 'Set-BrokerMachineMaintenanceMode'
                    $ScaleDown.EnterMaintenanceMode | Set-BrokerMachineMaintenanceMode @AdminAddress -MaintenanceMode $true -EA 1
                    $rq8.Telemetry.Success = $true
                    $rq8dp0.Telemetry.Success = $true
                }
                
            }
            catch {
                
                $rq8.Telemetry.Success = $false
                $rq8dp0.Telemetry.Success = $false
                tex $_.Exception
            }
            Finally {
                Stop-OpDT $rq8dp0
                Stop-OpRT $rq8
            }
        }

        #STOP IDLE SESSIONS
        if ($ScaleDown.IdleSessions.Count -gt 0) {
            try {
                if (-not $Audit) {
                    $rq9 = New-TReq -Name 'Stop-BrokerSession'
                    $rq9dp0 = New-TDep -Command 'Stop-BrokerSession' -Type 'CitrixSDK' -Target $AdminAddress.AdminAddress -ParentName 'Stop-BrokerSession'
                    $ScaleDown.IdleSessions | Stop-BrokerSession @AdminAddress -EA 1
                    $rq9.Telemetry.Success = $true
                    $rq9dp0.Telemetry.Success = $true
                }
                
            }
            catch {
                
                $rq9.Telemetry.Success = $false
                $rq9dp0.Telemetry.Success = $false
                tex $_.Exception
            }
            Finally {
                Stop-OpDT $rq9dp0
                Stop-OpRT $rq9
            }
        }

    }
    #Burden is 0, nothing to scale
    else {}
        
    }
    flush
    return $MetricHash
}
function Scale-Actions {
    param(
        [psobject]$DSG,
        [psobject]$DSGM,
        [psobject]$ScaleOut,
        [psobject]$ScaleIn,
        [switch]$Audit,
        [hashtable]$AdminAddress
    )
    #Set function parameter values for scale out or scale in
    if ($ScaleOut) {
        $Servers = $ScaleOut
        $TagName='sch_AzAutoJobStart'
        $Runbook = @{Start=$True}
        $MTM = @{Exit=$true}
        $SNOW = @{OnOff='Server On'}
    }
    Elseif ($ScaleIn) {
        $Servers = $ScaleIn
        $TagName='sch_AzAutoJobStop'
        $Runbook = @{Stop=$true}
        $MTM = @{Enter=$true}
        $SNOW = @{OnOff='Server Off'}
    } 
    if (-not $Audit) {  
        #Start-Runbook
        try {
            Start-Runbook -DSG $DSG @Runbook -VMNames $Servers.AzureVMNames -EA 1 
        }
        catch {
            
            return
        }
        #Filter Citrix DSGMs
        $DSGM = $DSGM | Where-Object { ($_.MachineName -split '\\')[-1] -in $Servers.AzureVMNames } 

        #Set Tags
        $DSGM | foreach {
            Set-SchTag -DesktopScaleGroupMachine $_ -AdminAddress $AdminAddress -Action Add -TagName $TagName
        }

        #Set MTM (scale in only, servers exit mtm when they are registered to the citrix farm)
        if ($ScaleIn){
            Set-MTM -DSGM $DSGM @MTM  
        }
        #Update SNOW
        New-Snow -DSGM $DSGM @SNOW
        
    }
    else {
        
    }
}
#Convert schedule tag description to json
function Convert-SchTag ($tagObject) {    
    try {        
        $ScaleSettings = $tagObject.Description | ConvertFrom-Json -EA Stop
        $Schedule = $ScaleSettings
    }
    catch [Citrix.Broker.Admin.SDK.SdkOperationException] {        
        throw "Could not find tag for: $($tagObject.Name)"
    }
    catch [System.ArgumentException], [Microsoft.PowerShell.Commands.ConvertFromJsonCommand] {
        throw "Something is wrong with the json syntax for: $($tagObject.Name)"
    }
    catch {
        throw $PSItem
    }    
    if ($Schedule) {
        return $Schedule
    }
    else {
        return $null
    }
}
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter()]
        [alias('T')]
        [string]$TimeStamp = (Get-Date -f yyyMMdd-HHmmss),

        [Parameter()]
        [alias('G')]
        [string]$DeliveryGroupName,

        [Parameter()]
        [alias('M')]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [alias('D')]
        [object]$Data,

        [Parameter()]        
        [alias('F')]
        [ValidateNotNullOrEmpty()]
        [string]$Function,

        [Parameter()]
        [alias('S')]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Severity = 'Information',

        [Parameter()]
        [alias('E')]
        [object]$ErrorMessage,

        [Parameter()]
        [alias('P')]
        [object]$PSStack,

        [parameter()]
        [alias('L')]
        [ValidateNotNullOrEmpty()]
        [string]$logsPath = "VMScaler",

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Source = 'VMScaler',

        [parameter()]
        [string]$AppInsightsKey
    )
    $EventIDs = @{
        #All functions until 60 do not WRITE, they only collect/filter/collate informaiton
        'VMSCaler'                         = 00
        'StartScale'                       = 10
        'Get-ActiveScaler'                 = 11
        'Start-Process'                    = 12
        'Wait-RSJob'                       = 13
        'Get-ActiveController'             = 20
        'Test-PatchDay'                    = 21
        'Get-ScalableGroups'               = 22
        'Scale-Vda'                        = 30
        'Get-Burden'                       = 31
        'Get-PeggedVDA'                    = 32
        'Get-AzAutoTaggedState'            = 33
        'Scale-Up'                         = 40
        'Scale-UpMaintenanceMode'          = 41
        'Get-AzVMPowerState'               = 42
        'Scale-UpAzVMStarting'             = 43
        'Scale-UpAzVMDeallocated'          = 44
        'Scale-Down'                       = 50
        'Scale-DownMaintenanceMode'        = 51
        'Scale-DownIdleSessions'           = 52
        'Scale-DownAzVMNoSessions'         = 53
        'Get-CredMan'                      = 54
        #Functions starting at 60 all WRITE in some form. 
        'Set-SchTag'                       = 60
        'Reset-Tags'                       = 61    
        'Set-BrokerMachineMaintenanceMode' = 62
        'Stop-BrokerSession'               = 63
        'Scale-Actions'                    = 64   
        'Start-Runbook'                    = 65
        'New-SNOW'                         = 66    
        'Set-MTM'                          = 67
        'Get-MaintenanceTag'               = 70
        'New-MaintenanceTag'               = 71
        'Set-MaintenanceTag'               = 72
        'Update-VDA'                       = 73
        'isItPatch'                        = 74
    }
    if ($EventIDs.ContainsKey($Function)) {
        $Base = $EventIDs[$Function]
        $Index = @('Information', 'Warning', 'Error').IndexOf($Severity)
        $EventID = "$Base$Index"
    }
    else { $EventID = 0 }
    $log = [pscustomobject]@{
        Time          = $TimeStamp
        DeliveryGroup = $DeliveryGroupName
        Severity      = $Severity
        Message       = $Message 
        Data          = $Data   
        Function      = $Function
        ErrorMessage  = $ErrorMessage 
        PSStack       = $PSStack
    } 
    $evtLog = $log | ConvertTo-Json
    Write-EventLog -LogName $logsPath -Message $evtLog -Source $Source -EventId $EventId -EntryType $Severity
    if ($AppInsightsKey) {
        $dictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $dictionary.add('Message', $evtLog)
        Log-ApplicationInsightsEvent -InstrumentationKey $AppInsightsKey -EventName "VMScaler" -EventDictionary $dictionary
    }
    Write-Verbose $evtLog
} 

#is it time to scale, drain, initializae, or do nothing?
function isItTime {
    param(
        #Schedule object, must contain a TimeZone property/value that will work with the FindSystemTimeZoneById Method
        [Parameter(Mandatory)]
        [ValidateScript( {
                if (  $null -ne $_.psobject.Properties["TzId"].Value ) {
                    try { [System.TimeZoneInfo]::FindSystemTimeZoneById($_.TzId) }
                    catch { throw "Timezone provided cannot be found in System.Timezone" }
                }
                else { throw "Timezone cannot be null" }
                if ($null -eq $_.psobject.Properties["Start"].Value) { throw "Start cannot be null" }
                if ($null -eq $_.psobject.Properties["End"].Value) { throw "End cannot be null" }                
                if ($null -eq $_.psobject.Properties["Limit"].Value) { throw "Limit cannot be null" }
                if ($null -eq $_.psobject.Properties["ResourceGroupName"].Value) { throw "ResourceGroupName cannot be null" }
                if ($null -ne $_.psobject.Properties["Surge"].Value) {
                    if ($null -eq $_.Surge.psobject.Properties["Start"]) { throw "Surge property Start cannot be null" }
                    if ($null -eq $_.Surge.psobject.Properties["Count"]) { throw "Surge property Count cannot be null" }
                }
            })]
        [PSCustomObject]$Schedule,
        #Used to mock pester tests        
        [Parameter(Mandatory = $false)]
        [datetime]$utcCurrentTime = [datetime]::utcNow
    )
       
    #Convert UTC time to TzId time    
    $resourceTz = [System.TimeZoneInfo]::FindSystemTimeZoneById($schedule.TzId)    
    $resourceTzCurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcCurrentTime, $resourceTz)

    #is it the workweek?
    if ($resourceTzCurrentTime.DayOfWeek -notin 'saturday', 'sunday') {
        #Are we in the first hour of the start window?
        if ($Schedule.Start -eq $resourceTzCurrentTime.Hour) {
            $state = 'init'
        }
        #Are we in the surge window?
        elseif ($Schedule.Surge.Start -eq $resourceTzCurrentTime.Hour) {
            $state = 'surge'
        }
        #Are we in the scaling window?
        elseif (($resourceTzCurrentTime.Hour -gt $schedule.Start) -and ($resourceTzCurrentTime.Hour -lt $schedule.End)) {
            $state = 'scale'
        }
        #Are we outside the scaling window?
        elseif ($Schedule.End -eq $resourceTzCurrentTime.Hour) {
            $state = 'drain'
        }
        else {
            $state = 'shouldBeDraining'
        }
    }
    #On the weekend we should continue to drain
    else { $state = 'shouldBeDraining' }
    return $state
}
#Get TimeZone object
function resourceTz ($tzid) {
    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($TzId)
    }
    catch {
        throw
    }    
}
#Convert timezone object to UTCNow
function patchTzCurrentTime ($resourceTz) {
    try {
        return [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $resourceTz) 
    }
    catch {
        throw
    }    
}
#Are we in a patch window right now
function itsPatchDay ([datetime]$LocalTime) {
    $baseDate = [datetime]::Parse("$($LocalTime.Month)/12/$($LocalTime.Year)")    
    $patchDay = $baseDate.AddDays((2 - [int]$baseDate.DayOfWeek) + 12)
    if ($LocalTime.Date -eq $patchDay.Date) {
        $LocalTime
    }
    else {
        $false
    }
}
#Used for mock testing
function lastPatchDay ([datetime]$LocalDate) {
    $baseDate = [datetime]::Parse("$($LocalDate.Month)/12/$($LocalDate.Year)")
    $lastPatchDay = $baseDate.AddDays(2 - [int]$baseDate.DayOfWeek)    
    # If we are prior to patch Day get the previous one
    if ($LocalDate -lt $lastpatchDay) {
        $baseDate = $baseDate.AddMonths(-1)
        $lastPatchDay = $baseDate.AddDays(2 - [int]$baseDate.DayOfWeek)
    }
    return $lastPatchDay
}
#Create a new tag for scaling. Does not apply tag to any resource
function New-ScaleSetting {
    param(    
        [parameter(mandatory, HelpMessage = "Uid of Delivery Group, will be used as tag name")]  
        [string]$DeliveryGroupUid, 

        [parameter(mandatory, HelpMessage = "Full Timezone Name (e.g. Eastern Standard Time)")]
        [validateScript( {
                try { [System.TimeZoneInfo]::FindSystemTimeZoneById($_) }
                catch { throw "Timezone provided cannot be found in System.Timezone" }
            })]
        [String]$TimeZone,

        [parameter(mandatory, HelpMessage = "Hour to start VMs (0-23)")]
        [validateScript( { $_ -in 0..23 })]
        [int]$Start,

        [parameter(mandatory, HelpMessage = "Hour to start draining VMs (0-23)")]
        [validateScript( { $_ -in 0..23 })]
        [int]$End,

        [parameter(Mandatory, HelpMessage = "Az Resource Group containing the VMs for this schedule")]
        [string]$ResourceGroupName,

        [parameter(HelpMessage = "Application Insights key to write logs to appinsights as well as event log for specific DG")]
        [string]$AppInsightsKey,

        [parameter(HelpMessage = "Number of minutes a session can idle before being stopped during the draining period")]
        [int]$IdleTimeout,

        [parameter(HelpMessage = "Average CPU load % to initiate scaling")]
        [validateScript( { $_ -in 0..100 })]
        [int]$CpuPercentage,

        [parameter(HelpMessage = "Average Memory load % to initiate scaling")]
        [validateScript( { $_ -in 0..100 })]
        [int]$MemPercentatge,

        [parameter(HelpMessage = "Scale by specified citrix load evaluator index")]
        [int]$LeiPercentage,
        
        [parameter(HelpMessage = "Average concurrent sessions to initiate scaling")]
        [int]$SessionCount
    )
    $tagName = "sch_" + $DeliveryGroupUid
    $tagDescription = [pscustomObject]@{
        Start             = $Start
        End               = $End
        TzId              = $TimeZone
        Limit             = $IdleTimeout
        ResourceGroupName = $ResourceGroupName
        Load              = [pscustomobject]@{
            CPU = $cpuPercentage
            MEM = $memPercentatge
            LEI = $leiPercentage
            USR = $sessionCount
        }
    }
    if ($AppInsightsKey) {
        $tagDescription | Add-Member NoteProperty "AppInsightsKey" $AppInsightsKey
    }
    try {
        New-BrokerTag -Name $tagName -Description ($tagDescription | ConvertTo-Json)
    }
    catch {
        $PSItem
    }    
}
#Apply or remove tag on/from broker desktop group
#Removing a tag that has already been removed returns no error, same with adding, only care about exceptions
function Set-SchTag {
    param (        
        [parameter(Mandatory, HelpMessage = "Add or Remove `$TagName from Desktop Group specified in `$DesktopScaleGroup")]
        [ValidateSet('Add', 'Remove')]
        [String]$Action,

        [parameter(Mandatory, HelpMessage = "Name of the tag to add or remove from Desktop Group specified in `$DesktopScaleGroup")]
        [ValidateSet('sch_Drain', 'sch_Patch', 'sch_doNotScale', 'sch_Surge', 'sch_AzAutoJobStart', 'sch_AzAutoJobStop', 'sch_AlwaysOn', 'sch_Scale')]
        [String]$TagName,

        [parameter(HelpMessage = "Name of the desktop scale group")]
        [Alias('DSG')]
        [pscustomobject]$DesktopScaleGroup,

        [parameter(HelpMessage = "Name of the desktop scale group")]
        [Alias('DSGM')]
        [pscustomobject]$DesktopScaleGroupMachine,

        [parameter(Mandatory, HelpMessage = "Hashtable key AdminAddress with value of FQDN of Delivery Controller with responding broker service")]
        [hashtable]$AdminAddress        
    )
    $Output = @{
        Data     = @()
        Messages = @()
    }
    $DSG = $DesktopScaleGroup.Name
    $DSGM = $DesktopScaleGroupMachine
    ###Telemetry###    
    $TelemetryClient = $T.TelemetryClient
    $TItem = $T.TelemetryItem 
    
    $param = @{
        Name = $TagName
        ErrorAction = 'Stop'
    }
    #Get the Desktop Group if provided
    if ($DSG) {
        $DesktopGroup = Get-BrokerDesktopGroup @AdminAddress -UID $DesktopScaleGroup.Uid
        $param.Add('DesktopGroup',$DesktopGroup) 
        $Name = $DesktopGroup.Name
    }
    elseif ($DSGM) {
        $param.Add('Machine',$DSGM)
        $Name = $DSGM.MachineName
    }
    #Try removing tag from delivery group, write to error log if failure
    if ($Action -eq 'Remove') {
        try {
            $dt1 = New-TDep -Command "Remove-BrokerTag $tagName" -Type 'CitrixSDK' -Target $ServerName -ParentName $F
            Remove-BrokerTag @AdminAddress @param  
            
            $dt1.Telemetry.ResultCode = 200
            $dt1.Telemetry.Success = $true            
        }
        catch {                    
            
            $dt1.Telemetry.ResultCode = 404
            $dt1.Telemetry.Success = $false
        }
        finally {
            Stop-OpDt $dt1
        }
    }
    #Try adding tag to delivery group, write to error log if failure
    else {
        try {
            $dt2 = New-TDep -Command "Add-BrokerTag $tagName" -Type 'CitrixSDK' -Target $ServerName -ParentName $F
            Add-Brokertag @AdminAddress @param
            
            $dt2.Telemetry.ResultCode = 200
            $dt2.Telemetry.Success = $true 
        }
        catch {                    
            
            $dt2.Telemetry.ResultCode = 404
            $dt2.Telemetry.Success = $false
        }
        finally {
            Stop-OpDt $dt2
        }
    }        
}
#Remove sch_AzAutoJobStop/Start from all VMs tagged 
Function Reset-Tags {
    param(
        [parameter(Mandatory, HelpMessage = "Array of desktop scale group machines tagged with sch_AzAutoJobStart/Stop")]
        [Array]$DSGM,
        [parameter(Mandatory, HelpMessage = "Hashtable key AdminAddress with value of FQDN of Delivery Controller with responding broker service")]
        [hashtable]$AdminAddress  
    )
    $Output = @{
        Start = @()
        Stop  = @()
    }
    try {
        $AutoStopTag = Get-BrokerTag -Name 'sch_AzAutoJobStop' -EA 1
        $AutoStartTag = Get-BrokerTag -Name 'sch_AzAutoJobStart' -EA 1
        $DSGM | foreach {
            $machine = $_
            if ($machine.Tags -contains 'sch_AzAutoJobStop') {
                Remove-BrokerTag -Name $AutoStopTag.Name -Machine $machine @AdminAddress -EA 1
                $Output.Stop += $machine.MachineName
            }
            if ($machine.Tags -contains 'sch_AzAutoJobStart') {
                Remove-BrokerTag -Name $AutoStartTag.Name -Machine $machine @AdminAddress -EA 1
                $Output.Start += $machine.MachineName
            }
        }
        
    }
    catch {
        
    }
}
#generic retry loop
function Start-Retry {
    <#
        .SYNOPSIS
        Retries a command if it throws an error
        .DESCRIPTION
        When running many commands in parallel in an Azure Automation Account, the API starts to fail to respond to requests.
        Retrying is a good way to work around the problem.
    #>
    param(
        [parameter(Mandatory, HelpMessage = "Full command to execute and retry")]
        [scriptblock]$Command,
        [parameter(HelpMessage = "Number of times to retry executing `$Command if it fails")]
        [int]$RetryCount = 3,
        [parameter(HelpMessage = "Number of seconds to wait between retries")]
        [int]$WaitSeconds = 5
    )
    $ErrorActionPreference = 'Stop'    
    do {        
        try {
            Invoke-Command -ScriptBlock $Command  
            $RetryCount = -1      
        }
        catch {
            if ($RetryCount -eq 0) {
                $RetryCount--
                throw 
            }
            elseif ($_.Exception.Message -match "ExpiredAuthenticationToken") {
                
                Disconnect-AzAccount -EA 0 | Out-Null
                Clear-AzContext -Force -EA 0| Out-Null
                $Context = Login-AzAccount -Identity
                if ($null -ne $Context) {
                    
                }
                $RetryCount--
            }
            else {
                
                Start-Sleep -Seconds $WaitSeconds
                $RetryCount--
            }             
        }        
    } while ($retryCount -ne -1)
}
function Get-MaintenanceTag {
    param (
        [parameter(Mandatory)]
        [pscustomobject]$DSG,
        [parameter(Mandatory)]
        [hashtable]$AdminAddress
    ) 
    $MTag = "sch_maint_$($DSG.Uid)"

    #If the tag doesn't exist, return null. If there is some other error, write an exception
    try {
        $MaintenanceTag = Get-BrokerTag @AdminAddress -Name $MTag -EA 1 
    } 
    catch {
        if ($_.Status -ne 'Citrix.XDPowerShell.Broker.UnknownObject') {
            
        }
    }
    if ($MaintenanceTag) {
        $MaintenanceTag
    }
}
function New-MaintenanceTag {
    <#
    Example tag:
    $tag =  [PSCustomObject]@{
        End = ((Get-Date).AddHours(3)).DateTime
        Start = (Get-Date).DateTime
        TzId = "Mountain Standard Time"
        Ticket = 123456789
    }
    #>
    param (
        [parameter(Mandatory)]
        [pscustomobject]$DSG,
        [parameter(Mandatory, helpmessage = "(get-date).DateTime")]
        [string]$Start,
        [parameter(Mandatory, helpmessage = "(get-date).DateTime")]
        [string]$End,
        [parameter(Mandatory)]
        [string]$TzId,
        [parameter()]
        [string]$Ticket,
        [parameter(Mandatory)]
        [hashtable]$AdminAddress
    )  
    try {
        $Description = @{
            Start = $Start
            End  = $End
            TzId = $TzId
        }
        if ($Ticket) { $Description.Add('Ticket', $Ticket) }
        $Description = $Description | ConvertTo-Json
        $MaintenanceTag = New-BrokerTag @AdminAddress -Name "sch_maint_$($DSG.UID)" -Description $Description -EA 1
        $DG = Get-BrokerDesktopGroup -Uid $DSG.UID -EA 1
        Add-BrokerTag -Name "sch_maint_$($DSG.UID)" -DesktopGroup $DG -EA 1
        
    }
    catch {
        
    }    
    if ($MaintenanceTag) {
        return $MaintenanceTag
    }
}
function Set-MaintenanceTag {
    param (
        [parameter(Mandatory)]
        [pscustomobject]$DSG,
        [parameter(helpmessage="Existing maintenance tag object (Get-BrokerTag)")]
        [Object]$MaintenanceTag,
        [parameter(Mandatory, helpmessage = "(get-date).DateTime")]
        [string]$Start,
        [parameter(Mandatory, helpmessage = "(get-date).DateTime")]
        [string]$End,
        [parameter(Mandatory)]
        [string]$TzId,
        [parameter()]
        [string]$Ticket,
        [parameter(Mandatory)]
        [hashtable]$AdminAddress
    ) 
    try {
        #Build new description property value
        $Description = @{
            Start = $Start
            End  = $End
            TzId = $TzId
        }
        if ($Ticket) { $Description.Add('Ticket', $Ticket) }
        $Description = $Description | ConvertTo-Json

        #Get maintenance tag if not provided
        if (!$MaintenanceTag) {
            $MaintenanceTag = Get-BrokerTag @AdminAddress -Name "sch_maint_$($DSG.UID)" -EA 1
        }

        #Update the tag, and apply it to the Desktop Group
        $MaintenanceTag | Set-BrokerTag -Description $Description  -EA 1
        $DG = Get-BrokerDesktopGroup -Uid $DSG.UID -EA 1
        Add-BrokerTag -Name "sch_maint_$($DSG.UID)" -DesktopGroup $DG -EA 1
        
    }
    catch {
        
    }    
    if ($MaintenanceTag) {
        return $MaintenanceTag
    }
}
function isItPatch {
    param (
        [parameter(Mandatory)]
        [Alias('DSG')]
        $DesktopScaleGroup,
        [parameter(Mandatory)]
        $AdminAddress,
        #Used to mock pester tests        
        [Parameter(Mandatory = $false)]
        [datetime]$utcCurrentTime = [datetime]::utcNow
    ) 
    $DSG = $DesktopScaleGroup
    #Does the DSG contain the maintenance tag?
    $MTag = "sch_maint_$($DSG.UID)"
    if ($DSG.AllTags -contains $MTag) {
        try {
           $Tag = Get-BrokerTag -Name $MTag @AdminAddress -EA 1
           $Schedule = $Tag.Description | ConvertFrom-Json -EA 1
           $Schedule.End = Get-Date $Schedule.End
           $Schedule.Start = Get-Date $Schedule.Start
        }
        catch {
            
        }
        #Convert UTC time to TzId time    
        $resourceTz = [System.TimeZoneInfo]::FindSystemTimeZoneById($schedule.TzId)    
        $resourceTzCurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcCurrentTime, $resourceTz)
        

        #If current time is lt the end of the patch window, we're in the patch window
        if ($resourceTzCurrentTime -lt $Schedule.End) {
            #If current time is greater than start, then we are in the patch window.
            if ($resourceTzCurrentTime -gt $Schedule.Start){
                #Does the tag contain a selection of VMs to put in a maintenance window? 
                if ($null -ne $Schedule.VMList) {
                    'Selective'
                }
                else {
                    
                    $true
                }
            }
            #Maintenance is coming, but not yet
            else {
                $false
            }
        }
        #If current time is ge to the end of the patch window, we're out, time to clean up
        else {
            try {
                $DG = Get-BrokerDesktopGroup -Uid $DSG.UID -EA 1
                Remove-BrokerTag -DesktopGroup $DG -Name $MTag -EA 1
                Remove-BrokerTag -DesktopGroup $DG -Name 'sch_Patch' -EA 1
                
                #Add the scaling tag back to the provided VM selection
                if ($null -ne $Schedule.VMList) {
                    $Schedule.VMList | % {
                        $Machine = Get-BrokerMachine -MachineName "*$($_)"
                        Add-BrokerTag -Name 'sch_Scale' -Machine $Machine
                        
                    }
                }
            }
            catch {
                
            }
            $false
        } 
    }
    #DSG does not contain mtag, we are not in a maintenance window
    else {
        $false
    }
}
function Update-VDA {
    param(
        $DSG,
        $AdminAddress
    )
    # $DSG = $DesktopScaleGroup
    #Create Telemetry Objects and store in Global variable $T
    $OpName = 'MaintenanceWindow'
    New-Variable -Scope Global -Name T -Value (New-Op -OperationName "$OpName $($DSG.Name)")
    $TClient = $T.TelemetryClient    
    $TItem = $T.TelemetryItem
    #Get all machines in the scaling group. If ther maintenance tag includes a list of vms, select only those VMs to work with
    $MTag = (Get-BrokerTag -Name "sch_maint_$($DSG.UID)").Description | ConvertFrom-Json
    if ($null -ne $MTag.VMList) {
        [array]$DSGM = (Get-BrokerMachine @AdminAddress -DesktopGroupUid $DSG.Uid | Where-Object { ($_.MachineName -split '\\')[1] -in $MTag.VMList })
    }
    else {
        $DSGM = Get-BrokerMachine @AdminAddress -DesktopGroupUid $DSG.Uid | Where-Object { ($_.Tags -contains 'sch_Scale') -or ($_.Tags -Contains 'sch_AlwaysOn') } -EA 1
    }
    #If this is the first run in maintenance window, reset sch_AzAutoJob[Start|Stop] tags on Desktop Scale Group Machines and exit
    if ($DSG.AllTags -notcontains 'sch_Patch') {
        try {
            Add-BrokerTag @AdminAddress -Name 'sch_Patch' -DesktopGroup (Get-BrokerDesktopGroup -Uid $DSG.UID) -EA 1
            
            Reset-Tags -DSGM $DSGM -AdminAddress $AdminAddress -EA 1   
            #Remove the scaling tag from the provided VM selection, this allows us to manage the MTag maintenance window while scaling the rest of the VMs
            if ($null -ne $MTag.VMList) {
                $DSGM | % {
                    Remove-BrokerTag -Name 'sch_Scale' -Machine $_
                    
                }
                
            }             
        }
        catch {
            
        }
        return
    }
    #Find unregistered VMs not tagged with sch_AzAutoJobStart and start them
    [array]$Unregistered = $DSGM | Where-Object {($_.RegistrationState -eq 'Unregistered') -and ($_.Tags -notcontains 'sch_AzAutoJobStart')}
    if (($null -ne $Unregistered) -and ($Unregistered.Count -gt 0)) {
        $VMs = $Unregistered.MachineName | % { $_ -split "\\" | select -last 1 }
        
        #Set Tags
        $Unregistered | foreach {
            try {
                Add-BrokerTag @AdminAddress -Machine $_ -Name 'sch_AzAutoJobStart'
                
            }
            catch {
                
            }
        }
        Start-Runbook -DSG $DSG -Start $true -VMNames $VMs -EA 1 
    }
    #Remove sch_AzAutoJobStart tags from registered VMs
    [array]$Registered = $DSGM | Where-Object {($_.RegistrationState -eq 'Registered') -and ($_.Tags -contains 'sch_AzAutoJobStart')}
    if (($null -ne $Registered) -and ($Registered.Count -gt 0)) {
        $Registered | % {
            try {
                Remove-BrokerTag -Machine $_ -Name 'sch_AzAutoJobStart'
                
            }
            catch {
                
            }
        }
    } 
}
###PESTER FUNCTIONS####
function day ($dayOfWeek, $startTime, $TzId) {
    $currentTime = [dateTime]::utcNow
    $resourceTz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TzId)
    $resourceTzMakeDay = [System.TimeZoneInfo]::ConvertTimeFromUtc($currentTime, $resourceTz)   
    $makeDay = $resourceTzMakeDay.AddDays($dayOfWeek - $resourceTzMakeDay.DayOfWeek.value__)    
    $makeDay = $makeDay.AddHours($startTime - $makeday.hour)    
    $makeDay = [System.TimeZoneInfo]::ConvertTimeToUtc($makeDay, $resourceTz)
    $makeDay   
}
