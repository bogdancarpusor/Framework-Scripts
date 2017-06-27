﻿#
#  Azure information
param (
    [Parameter(Mandatory=$false)] [string] $sourceStorageAccountName="azuresmokestorageaccount",
    [Parameter(Mandatory=$false)] [string[]] $sourceURI="Unset",
    [Parameter(Mandatory=$false)] [string] $destinationStorageAccountName="azuresmokestorageaccount",
    [Parameter(Mandatory=$false)] [string] $destinationContainerName="working-vhds",
    [Parameter(Mandatory=$false)] [string] $resourceGroupName="azuresmokeresourcegroup",
    [Parameter(Mandatory=$false)] [string] $location="westus"
)

$storageAccountName=$sourceStorageAccountName
$destAccountName=$destinationStorageAccountName
$destContainerName=$destinationContainerName
$nm=$storageAccountName
$rg=$resourceGroupName
$URI=$sourceURI

$useSourceURI=[string]::IsNullOrEmpty($URI)

$neededVms_array=@()
$neededVms = {$neededVms_array}.Invoke()
$copyblobs_array=@()
$copyblobs = {$copyblobs_array}.Invoke()


$global:completed=0
$global:elapsed=0
#
#  Interval in msec.
#
$global:interval=500
$global:boot_timeout_minutes=20
$global:boot_timeout_intervals_per_minute=(60*(1000/$global:interval))
$global:boot_timeout_intervals= ($global:interval * $global:boot_timeout_intervals_per_minute) * $global:boot_timeout_minutes

#
#  Machine counts and status
#
$global:num_expected=0
$global:num_remaining=0
$global:failed=0
$global:booted_version="Unknown"



class MonitoredMachine {
    [string] $name="unknown"
    [string] $status="Unitialized"
    [string] $ipAddress="Unitialized"
    $session
}
[System.Collections.ArrayList]$global:monitoredMachines = @()

$timer=New-Object System.Timers.Timer

class MachineLogs {
    [string] $name="unknown"
    [string] $job_log
    [string] $job_name
}
[System.Collections.ArrayList]$global:machineLogs = @()

function copy_azure_machines {
    if ($useSourceURI -eq $false)
    {
        Write-Host "Getting the list of machines and disks..."  -ForegroundColor green
        $smoke_machines=Get-AzureRmVm -ResourceGroupName $rg
        $smoke_machines | Stop-AzureRmVM -Force
        $smoke_disks=Get-AzureRmDisk -ResourceGroupName $rg

        Write-Host "Launching jobs for validation of individual machines..." -ForegroundColor Yellow

        foreach ($machine in $smoke_machines) {
            $vhd_name = $machine.Name + ".vhd"
            $vmName = $machine.Name

            $neededVMs.Add($vmName)

            $newRGName=$vmName + "-SmokeRG"
            $groupExists=$false
            $existingRG=Get-AzureRmResourceGroup -Name $newRGName -ErrorAction SilentlyContinue   
            if ($? -eq $true) {
                Write-Host "There is an existing resource group with the VM named $vmName.  This resource group must be deleted to free any locks on the VHD." -ForegroundColor Red
                Remove-AzureRmResourceGroup -Name $newRGName -Force
            }

            $uri=$machine.StorageProfile.OsDisk.Vhd.Uri

            $key=Get-AzureRmStorageAccountKey -ResourceGroupName $newRGName -Name $nm
            $context=New-AzureStorageContext -StorageAccountName $destAccountName -StorageAccountKey $key[0].Value
    
            Write-Host "Initiating job to copy VHD $vhd_name from cache to working directory..." -ForegroundColor Yellow
            $blob = Start-AzureStorageBlobCopy -AbsoluteUri $uri -destblob $vhd_name -DestContainer $destContainerName -DestContext $context -Force

            $copyblobs.Add($vhd_name)
        }
    } else {
        foreach ($singleURI in $URI) {
            Write-Host "Preparing to copy disk by URI.  Source URI is $singleURI"  -ForegroundColor green

            $splitUri=$singleURI.split("/")
            $lastPart=$splitUri[$splitUri.Length - 1]

            $vhd_name = $lastPart
            $vmName = $lastPart.Replace(".vhd","")

            $neededVMs.Add($vmName)

            $newRGName=$vmName + "-SmokeRG"
            $groupExists=$false
            $existingRG=Get-AzureRmResourceGroup -Name $newRGName -ErrorAction SilentlyContinue   
            if ($? -eq $true) {
                Write-Host "There is an existing resource group with the VM named $vmName.  This resource group must be deleted to free any locks on the VHD." -ForegroundColor Red
                Remove-AzureRmResourceGroup -Name $newRGName -Force
            }

            Write-Host "Initiating job to copy VHD $vhd_name from cache to working directory..." -ForegroundColor Yellow
            $blob = Start-AzureStorageBlobCopy -AbsoluteUri $singleURI -destblob $vhd_name -DestContainer $destContainerName -DestContext $context -Force

            $copyblobs.Add($vhd_name)
        }
    }

    Write-Host "All jobs have been launched.  Initial check is:" -ForegroundColor Yellow
    $allDone = $true
    foreach ($blob in $copyblobs) {
        $status = Get-AzureStorageBlobCopyState -Blob $blob -Container $destContainerName -WaitForComplete

        $status
    }
}


function launch_azure_vms {
    get-job | Stop-Job
    get-job | remove-job
    foreach ($vmName in $neededVms) {
        $machine = new-Object MonitoredMachine
        $machine.name = $vmName
        $machine.status = "Booting" # $status
        $global:monitoredMachines.Add($machine)

        $global:num_remaining++
        $jobname=$vmName + "-VMStart"
        # launch_single_vm($vmName)

        $machine_log = New-Object MachineLogs
        $machine_log.name = $vmName
        $machine_log.job_name = $jobname
        $global:machineLogs.Add($machine_log)        

        Start-Job -Name $jobname -ScriptBlock { c:\Framework-Scripts\launch_single_azure_vm.ps1 -vmName $args[0] } -ArgumentList @($vmName)
    }

    foreach ($machineLog in $global:machineLogs) {
            [MachineLogs]$singleLog=$machineLog
    
        $jobname=$singleLog.job_name
        $jobStatus=get-job -Name $jobName
        $jobState = $jobStatus.State
        
        if ($jobState -eq "Failed") {
            Write-Host "----> Azure boot Job $jobName failed to lanch.  Error information is $jobStatus.Error" -ForegroundColor yellow
            $global:failed = 1
            $global:num_remaining--
            Write-Host "Any log information provided follows:"
            receive-job $jobname
        }
        elseif ($jobState -eq "Completed")
        {
            Write-Host "----> Azure boot job $jobName completed while we were waiting.  We will check results later." -ForegroundColor green
            Write-Host "Any log information provided follows:"
            receive-job $jobname
        }
        else
        {
            Write-Host "      Azure boot job $jobName launched successfully." -ForegroundColor green
        }    
    }
}

$action={
    function checkMachine ([MonitoredMachine]$machine) {
        $machineName=$machine.name
        $machineStatus=$machine.status
        $machineIP=$machine.ipAddress

        if ($machineStatus -eq "Completed" -or $global:num_remaining -eq 0) {
            Write-Host "Machine $machineName is in state $machineStatus" -ForegroundColor green
            return 0
        }

        if ($machineStatus -ne "Booting") {
            Write-Host "??? Machine $machineName was not in state Booting.  Cannot process" -ForegroundColor red
            return 1
        }

        $expected_ver=Get-Content C:\temp\expected_version

        $failed=0
        $newRGName=$machineName + "-SmokeRG"

        #
        #  Attempt to create the PowerShell PSRP session
        #
        $machineIsUp = $false
        foreach ($localMachine in $global:monitoredMachines) {
            [MonitoredMachine]$monitoredMachine=$localMachine

            if ($localMachine.Name -eq $machineName) {
                $ip=Get-AzureRmPublicIpAddress -ResourceGroupName $newRGName
                $ipAddress=$ip.IpAddress
                $localMachine.ipAddress = $ipAddress

                # Write-Host "Creating PowerShell Remoting session to machine at IP $ipAddress"  -ForegroundColor green
                $o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
                $pw=convertto-securestring -AsPlainText -force -string 'P@$$w0rd!'
                $cred=new-object -typename system.management.automation.pscredential -argumentlist "mstest",$pw
                $localMachine.session=new-PSSession -computername $ipAddress -credential $cred -authentication Basic -UseSSL -Port 443 -SessionOption $o
                if ($?) {
                    $machineIsUp = $true
                } else {
                    return 0
                }
                break
            }
        }

        
        try {            
            $installed_vers=invoke-command -session $localMachine.session -ScriptBlock {/bin/uname -r}
            # Write-Host "$machineName installed version retrieved as $installed_vers" -ForegroundColor Cyan
        }
        Catch
        {
            Write-Host "Caught exception attempting to verify Azure installed kernel version.  Aborting..." -ForegroundColor red
        }

        #
        #  Now, check for success
        #
        if ($expected_ver.CompareTo($installed_vers) -ne 0) {
            if (($global:elapsed % $global:boot_timeout_intervals_per_minute) -eq 0) {
                Write-Host "Machine $machineName is up, but the kernel version is $installed_vers when we expected $expected_ver.  Waiting to see if it reboots." -ForegroundColor Cyan
            }
            # Write-Host "(let's see if there is anything running with the name Kernel on the remote machine)"
            # invoke-command -session $localMachine.session -ScriptBlock {ps -efa | grep -i linux}

        } else {
            Write-Host "Machine $machineName came back up as expected.  kernel version is $installed_vers" -ForegroundColor green
            $localMachine.Status = "Completed"
            $global:num_remaining--
        }
    }

    $global:elapsed=$global:elapsed+$global:interval
    # Write-Host "Checking elapsed = $global:elapsed against interval limit of $global:boot_timeout_intervals" -ForegroundColor Yellow

    if ($global:elapsed -ge $global:boot_timeout_intervals) {
        Write-Host "Elapsed is $global:elapsed"
        Write-Host "Intervals is $global:boot_timeout_intervals"
        Write-Host "Timer has timed out." -ForegroundColor red
        $global:completed=1
    }

    #
    #  Check for Hyper-V completion
    #
    foreach ($localMachine in $global:monitoredMachines) {
        [MonitoredMachine]$monitoredMachine=$localMachine
        $monitoredMachineName=$monitoredMachine.name
        $monitoredMachineStatus=$monitoredMachine.status

        foreach ($localLog in $global:machineLogs) {
            [MachineLogs]$singleLog=$localLog

            #
            #  Don't even try if the new-vm hasn't completed...
            #
            if ($singleLog.name -eq $monitoredMachineName) {
                $jobStatus = get-job $singleLog.job_name
                $jobStatus = $jobStatus.State
               
                if ($jobStatus -ne $null -and ($jobStatus -eq "Completed" -or $jobStatus -eq "Failed")) {
                    if ($jobStatus -eq "Completed") {
                        # write-host "Checking machine $monitoredMachineMane in status $jobStatus"
                        if ($monitoredMachineStatus -ne "Completed") {
                            checkMachine $monitoredMachine
                        }
                    }
                } elseif ($jobStatus -eq $null -and $monitoredMachineStatus -ne "Completed") {
                    checkMachine $monitoredMachine
                }
            }
        }
    }

    if ($global:num_remaining -eq 0) {
        Write-Host "***** All machines have reported in."  -ForegroundColor magenta
        if ($global:failed -eq $true) {
            Write-Host "One or more machines have failed to boot.  This job has failed." -ForegroundColor Red
        }
        Write-Host "Stopping the timer" -ForegroundColor green
        $global:completed=1
    }

    if (($global:elapsed % 10000) -eq 0) {
        Write-Host "Waiting for remote machines to complete all testing.  There are $global:num_remaining machines left.." -ForegroundColor green

        foreach ($localMachine in $global:monitoredMachines) {
            [MonitoredMachine]$monitoredMachine=$localMachine

            $monitoredMachineName=$monitoredMachine.name
            $monitoredMachineStatus=$monitoredMachine.status

            $calledIt = $false
            foreach ($localLog in $global:machineLogs) {
                [MachineLogs]$singleLog=$localLog

                $singleLogName = $singleLog.name
                $singleLogJobName = $singleLog.job_name

                if ($singleLogName -eq $monitoredMachineName) {
                    $jobStatusObj = get-job $singleLogJobName
                    $jobStatus = $jobStatusObj.State
               
                    if ($jobStatusObj -ne $null -and ($jobStatus -eq "Completed" -or $jobStatus -eq "Failed")) {
                        if ($jobStatus -eq "Completed") {
                           if ($monitoredMachineStatus -eq "Completed") {
                                Write-Host "--- Machine $monitoredMachineName has completed..." -ForegroundColor green
                            } else {
                                Write-Host "--- Testing of machine $monitoredMachineName is in progress..." -ForegroundColor Yellow
                            }                          
                        } elseif ($jobStatus -eq "Failed") {
                            Write-Host "--- Job $singleLogName failed to start." -ForegroundColor Red
                            Write-Host "Log information, if any, follows:" -ForegroundColor Red
                            receive-job $singleLogJobName
                        }
                        
                        #  Make sure we don't come back here again...
                        remove-job $singleLog.job_name
                    } elseif ($jobStatusObj -ne $null) {
                        $message="--- The job starting VM $monitoredMachineName has not completed yet.  The current state is " + $jobStatus
                        Write-Host $message -ForegroundColor Yellow
                    }
                    $calledIt = $true
                    break
                }
            }

            if ($calledIt -eq $false -and $monitoredMachineStatus -ne "Completed") {
                Write-Host "--- Machine $monitoredMachineName has not completed yet" -ForegroundColor yellow
            }
                        
            if ($calledIt -eq $false -and $monitoredMachine.session -ne $null) {
                Write-Host "Last three lines of the log file for machine $monitoredMachineName ..." -ForegroundColor Magenta                
                $last_lines=invoke-command -session $monitoredMachine.session -ScriptBlock { get-content /opt/microsoft/borg_progress.log  | Select-Object -last 3 }
                if ($?) {
                    $last_lines | write-host -ForegroundColor Magenta
                } else {
                    Write-Host "Error when attempting to retrieve the log file from the remote host.  It may be rebootind..."
                }
            }
        }
    }
    [Console]::Out.Flush() 
}

unregister-event AzureBootTimer -ErrorAction SilentlyContinue

Write-Host "    " -ForegroundColor green
Write-Host "                 **********************************************" -ForegroundColor yellow
Write-Host "                 *                                            *" -ForegroundColor yellow
Write-Host "                 *            Microsoft Linux Kernel          *" -ForegroundColor yellow
Write-Host "                 *     Basic Operational Readiness Gateway    *" -ForegroundColor yellow
Write-Host "                 * Host Infrastructure Validation Environment *" -ForegroundColor yellow
Write-Host "                 *                                            *" -ForegroundColor yellow
Write-Host "                 *           Welcome to the BORG HIVE         *" -ForegroundColor yellow
Write-Host "                 **********************************************" -ForegroundColor yellow
Write-Host "    "
Write-Host "          Initializing the CUBE (Customizable Universal Base of Execution)" -ForegroundColor yellow
Write-Host "    "

#
#  Clean up the sentinel files
#
Write-Host "   "
Write-Host "                                BORG CUBE is initialized"                   -ForegroundColor Yellow
Write-Host "              Starting the Dedicated Remote Nodes of Execution (DRONES)" -ForegroundColor yellow
Write-Host "    "

Write-Host "Importing the context...." -ForegroundColor Green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'

Write-Host "Selecting the Azure subscription..." -ForegroundColor Green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4"
Set-AzureRmCurrentStorageAccount –ResourceGroupName $rg –StorageAccountName $nm

#
#  Copy the virtual machines to the staging container
#                
copy_azure_machines

#
#  Launch the virtual machines
#                
launch_azure_vms
write-host "$global:num_left machines have been launched.  Waiting for completion..."

#
#  Wait for the machines to report back
#               
Write-Host "                          Initiating temporal evaluation loop (Starting the timer)" -ForegroundColor yellow
Register-ObjectEvent -InputObject $timer -EventName elapsed –SourceIdentifier AzureBootTimer -Action $action
$timer.Interval = 500
$timer.Enabled = $true
$timer.start()

Write-Host "Finished launching the VMs.  Completed is $global:completed" -ForegroundColor Yellow
while ($global:completed -eq 0) {
    start-sleep -s 1
}

Write-Host "                         Exiting Temporal Evaluation Loop (Unregistering the timer)" -ForegroundColor yellow
$timer.stop()
unregister-event AzureBootTimer

Write-Host "     Checking results" -ForegroundColor green

if ($global:num_remaining -eq 0) {
    Write-Host "All machines have come back up.  Checking results." -ForegroundColor green
    
    if ($global:failed -eq $true) {
        Write-Host "Failures were detected in reboot and/or reporting of kernel version.  See log above for details." -ForegroundColor red
        Write-Host "             BORG TESTS HAVE FAILED!!" -ForegroundColor red
    } else {
        Write-Host "All machines rebooted successfully to kernel version $global:booted_version" -ForegroundColor green
        Write-Host "             BORG has been passed successfully!" -ForegroundColor yellow
    }
} else {
        Write-Host "Not all machines booted in the allocated time!" -ForegroundColor red
        Write-Host " Machines states are:" -ForegroundColor red
        foreach ($localMachine in $global:monitoredMachines) {
            [MonitoredMachine]$monitoredMachine=$localMachine
            $monitoredMachineName=$monitoredMachine.name
            $monitoredMachineState=$monitoredMachine.status
            if ($monitoredMachineState -ne "Completed") {
                Write-Host Machine "$monitoredMachineName is in state $monitoredMachineState.  This is the log, if any:" -ForegroundColor red
                $log_lines=invoke-command -session $monitoredMachine.session -ScriptBlock { get-content /opt/microsoft/borg_progress.log }
                $log_lines | write-host -ForegroundColor Magenta
            } else {
                Write-Host Machine "$monitoredMachineName is in state $monitoredMachineState" -ForegroundColor green
            }
            $global:failed = 1
        }
    }

if ($global:failed -eq 0) {    
    Write-Host "     BORG is   Exiting with success.  Thanks for Playing" -ForegroundColor green
    exit 0
} else {
    Write-Host "     BORG is Exiting with failure.  Thanks for Playing" -ForegroundColor red
    exit 1
}