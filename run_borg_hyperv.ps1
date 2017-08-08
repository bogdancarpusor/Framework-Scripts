#
#  Run the Basic Operations and Readiness Gateway in Hyper-V.  This script will:
#      - Copy a VHD from the safe-templates folder to working-vhds
#      - Create a VM around the VHD and launch it.  It is assumed that the VHD has a
#        properly configured RunOnce set up
#      - Wait for the VM to tell us it's done.  The VM will use PSRP to do a live
#        update of a log file on this machine, and will write a sentinel file
#        when the install succeeds or fails.
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $skipCopy=$false
)


$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptPath\backend.ps1"

class HypervVM {
    [String] $name
    [String] $status = 'Uknown'
    [String] $memSize = '1GB'
    [String] $generation = '1'
    [String] $switchName = 'External'
    [String] $vhdPath
    [String] $testState = "Uknown"
    [Backend] $backend

    HypervVM ($name, $vhdPath) {
        $this.name = $name
        $this.vhdPath = $vhdPath
        $backendFactory = [BackendFactory]::new()
        $this.backend = $backendFactory.GetBackend("HypervBackend", @(1))
    }

    [boolean] start() {
        Write-Host "Virtual Maching ${this.name} is starting" -ForegroundColor green
        return $this.backend.StartVM($this.name)
    }

    [boolean] exists() {
        return $this.backend.GetVM($this.name)
    }

    [boolean] stop() {
        return $this.backend.StopVM($this.name)
    }

    [boolean] remove() {
        return $this.backend.RemoveVM($this.name)
    }

    [boolean] create() {
        return $this.backend.CreateVM($this.name, $this.vhdPath, $this.memSize, $this.generation, $this.switchName)
    }

    [boolean] runOnce() {
        Write-Host "      Checking boot results for machine ${this.name}" -ForegroundColor green
        if ($this.status -ne "Booting") {
            Write-Host "       Machine was not in state Booting.  Cannot process" -ForegroundColor Red
            return
        }

        if ((test-path $this.progressLogPath) -eq $false) {
            Write-Host "      Unable to locate results file $resultsFile.  Cannot process" -ForegroundColor Red
            return
        }

        $results = get-content $this.progressLogPath
        $resultsSplit = $results.split(' ')
        $resultsWord=$resultsSplit[0]
        $resustsgot=$resultsSplit[1]

        if ($resultsSplit[0] -ne "Success") {
            $resultExpected = $resultsSplit[2]
            Write-Host "       **** Machine ${this.name} rebooted, but wrong version detected.  Expected $resultExpected but got $resustsgot" -ForegroundColor red
            $this.testState = 'failed'
        } else {
            Write-Host "       **** Machine rebooted successfully to kernel version $resustsgot" -ForegroundColor green
            $this.booted_version = $resustsgot
        }

        $this.status = "test_completed"
    }
}

class Borg {
    [String] $vhdSourceFolder = 'D:\azure_images\'
    [String] $vhdDestination = "D:\working_images\"
    [String] $bootLogPath = "c:\temp\boot_results\"
    [String] $progressLogPath = "c:\temp\progress_logs\"
    [Int] $max_boot_time = 2700 # 45 mins
    [Boolean] $state = $true
    [String] $bootedVersion = "Uknown"
    [ArrayList] $vms = @()

    Borg ($Params) {
        $vhds = Get-ChildItem $this.vhdSourceFolder | foreach-Object { $_.Name }
        $this.initVMs($vhds)
    }

    [void] initVMs ($vhds) {
        foreach $vhdFile in $vhds {
            $vhdFileName = $vhdFile.Split('.')[0]
            $vm = [HypervVM]::new($vhdFileName, $this.vhdDestination + $vhdFile)
            $vm.state = 'created'
            $this.vms.Add($vm)

            if ($vm.exists()) {
                Write-Host "Stopping and cleaning any existing instances of machine ${vm.name}." -ForegroundColor green           
                $vm.stop()
                $vm.remove()
            }
        }
    }

    [boolean] copyVHDs () {
        $status = $true
        $this.status = "copying"
        [ArrayList] $copyJobs = @()
        Get-ChildItem $this.vhdSourceFolder |        
        foreach-Object {
            $vhdFile = $_.Name
            $vm.vhdPath = $this.vhdDestination + $vhdFile
            
            $destFile= $this.vhdDestination + $vhdFile
            Remove-Item -Path $destFile -Force > $null
            $jobName = $vhdFileName + "_copy_job"
            $existingJob = get-job $jobName -ErrorAction SilentlyContinue > $null
            if ($? -eq $true) {
                stop-job $jobName -ErrorAction SilentlyContinue > $null
                remove-job $jobName -ErrorAction SilentlyContinue > $null
            }
            Start-Job -Name $jobName -ScriptBlock { robocopy /njh /ndl /nc /ns /np /nfl D:\azure_images\ D:\working_images\ $args[0] } -ArgumentList @($vhdFile) > $null
            if ($? -eq $false) {
                Write-Host "Error starting copy vhd job - $jobName" -ForegroundColor red
                return $false   
            } else {
                $copyJobs.add($jobName)
            }
        }
        
        while($true) {
            Write-Host "Waiting for copying to complete..." -ForegroundColor green
            $copy_complete=$true
            foreach $jobName in $copyJobs {
                $job = get-job -Name $jobName -ErrorAction SilentlyContinue
                if ($job.state -eq "Failed") {
                    $status = $false
                    Write-Host "Copy job $jobName exited with FAILED state!" -ForegroundColor red
                    Receive-Job -Name $jobName
                } elseif ($job.state -eq "Completed") {
                    Write-Host "Copy job $jobName completed successfully." -ForegroundColor green
                    Remove-Job $jobName -ErrorAction SilentlyContinue
                } else {
                    Write-Host "Current state of job $jobName is $job.state" -ForegroundColor yellow
                    $copy_complete = $false
                }
            }

            if ($copy_complete -eq $false) {
                sleep 30
            } else {
                break
            }
        }
        return $status
    }

    [boolean] createVMs() {
        foreach $vm in $this.vms {
            if (-not $vm.create()) {
                Write-Host "Unable to create Hyper-V VM.  The BORG cannot continue." -ForegroundColor Red
                return $false
            }
        }
    }

    [boolean] testVMs() {
        #
        #  Fire them up!  When they boot, the runonce should take over and install the new kernel.
        #
        foreach $vm in $this.vms {
            if (-not $vm.start()) {
                Write-Host "Unable to start Hyper-V VM.  The BORG cannot continue." -ForegroundColor Red 
                return $false
            }
        }
        
        write-host "Initiating temporal evaluation loop (Starting the timer)" -ForegroundColor yellow
        
        while ($true) {
            foreach $vm in $this.vms {
                if (($vm.status -eq 'booting') -and ((Test-Path $vm.bootFile) -eq $true)) {
                    $vm.testRunOnce()
                }
            }

            foreach $vm in $this.vms {
                if ($vm.status -ne "test_completed") {
                    $this.status = "test_running"
                } elseif ($vm.status -eq "booting") {
                    if ((test-path $vm.progressLogFile) -eq $true) {
                        write-host "     --- Last 3 lines of results from ${vm.progressLogFile}" -ForegroundColor magenta
                        get-content $vm.progressLogFile | Select-Object -Last 3 | write-host -ForegroundColor cyan
                        write-host "" -ForegroundColor magenta
                    } else {
                        Write-Host "     --- Machine ${vm.state} has not checked in yet"
                    }
                }
            }

            if ($this.status -eq "test_completed") {
                write-host "***** All machines have reported in."  -ForegroundColor magenta
                break
            } else {
                $this.status = "test_completed"
            }

            if ($this.elapsed_time -ge $this.max_boot_time) {
                write-host "Timer has timed out." -ForegroundColor red
                break
            } else {
                start-sleep 10
                $this.timer = $this.timer + 10
            }
        }

        write-host "Checking results" -ForegroundColor green
        if ($this.status -eq 'test_completed') {
            Write-Host "All machines have come back up.  Checking results." -ForegroundColor green
            $status = $true
            foreach $vm in $this.vms {
                if ($vm.testStatus -eq "failed") {
                    $status = $false
                }
            }
            if ($status) {
                Write-Host "All machines rebooted successfully to kernel version ${this.booted_version}" -ForegroundColor green
                write-host "             BORG has been passed successfully!" -ForegroundColor yellow
                return $true
            } else {
                Write-Host "Failures were detected in reboot and/or reporting of kernel version.  See log above for details." -ForegroundColor red
                write-host "             BORG TESTS HAVE FAILED!!" -ForegroundColor red
                return $false
            }
        } else {
            write-host "Not all machines booted in the allocated time!" -ForegroundColor red
            Write-Host " Machines states are:" -ForegroundColor red
            foreach $vm in $this.vms {
                Write-Host Machine "${vm.name} is in state ${vm.status}" -ForegroundColor red
            }
            return $false
        }

    }
}


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
Write-Host "Cleaning up sentinel files..." -ForegroundColor green
remove-item -ErrorAction "silentlycontinue" C:\temp\completed_boots\*
remove-item -ErrorAction "silentlycontinue" C:\temp\boot_results\*
remove-item -ErrorAction "silentlycontinue" C:\temp\progress_logs\*

Write-Host "   "
Write-Host "                                BORG CUBE is initialized"                   -ForegroundColor Yellow
Write-Host "              Starting the Dedicated Remote Nodes of Execution (DRONES)" -ForegroundColor yellow
Write-Host "    "

Write-Host "Checking to see which VMs we need to bring up..." -ForegroundColor green
Write-Host "Errors may appear here depending on the state of the system.  They're almost all OK.  If things go bad, we'll let you know." -ForegroundColor Green
Write-Host "For now, though, please feel free to ignore the following errors..." -ForegroundColor Green
Write-Host " "
Write-Host "*************************************************************************************************************************************"
Write-Host "                      Stopping and cleaning any existing machines.  Any errors here may be ignored." -ForegroundColor green


$borg = [Borg]::new()
if (-not $skipCopy) {
    if (-not $borg.copyVHDs()) {
        Write-Host "Error while copying vhds." -ForegroundColor red
        exit 1
    }
}

if (-not $borg.createVMs()) {
    exit 1
}

Write-Host "All machines template images have been copied.  Starting the VMs in Hyper-V" -ForegroundColor green
if (-not $borg.testVMs()) {
    Write-Host "BORG is Exiting with failure." -ForegroundColor red    
    exit 1
} else {
    Write-Host "     BORG is Exiting with success." -ForegroundColor green    
    exit 0
}