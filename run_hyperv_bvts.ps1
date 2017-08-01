param (
    [Parameter(Mandatory=$true)] [string] $lisaPath="C:\lis-test\WS2012R2\lisa",
    [Parameter(Mandatory=$true)] [string] $vmNames="Unknown",
    [Parameter(Mandatory=$true)] [string] $testXml="bvt_tests.xml",
    [Parameter(Mandatory=$true)] [string] $logDir="TestResults"
)

write-host "Starting execution of test $testXml"

if (-not (Test-Path $lisaPath)) {
    write-host "Invalid path ${lisaPath} for lisa folder." -ForegroundColor Red
    exit 1
} 

if (-not (Test-Path $vmNames)) {
    $vm_names_separator = ' '
    $vm_names = $vmNames.split($vm_names_separator)
} else {
    $vm_names = Get-Content $vmNames
}

$job_names = New-Object System.Collections.ArrayList
foreach ($vm_name in $vm_names) {
    if (-not (Get-VM -Name $vm_name)) {
        write-host "Unable to find VM $vm_name" -ForegroundColor Red
    } else {
        $job_name = $vm_name + "_bvt_runner"
        Get-Job -Name $job_name | Stop-Job -erroraction 'silentlycontinue'
        Get-Job -Name $job_name | Remove-Job -erroraction 'silentlycontinue'
        write-host "Running LISA on $vm_name with $testXml"
        $date = Get-Date -Format yyy-MM-dd
        $log_dir = $logDir + "\" + $date + "\" + $vm_name
        write-host "Logs stored at $log_dir"
        [xml]$xml_file = Get-Content $testXml
        $xml_file.config.Vms.vm.vmName = "${vm_name}"
        $xml_file_path = "${lisaPath}\${vm_name}.xml" 
        $xml_file.save($xml_file_path)
        $lisa_cmd = "cd $lisaPath; .\lisa.ps1 run ${xml_file_path} -cliLogDir ${log_dir}"
        write-host "Running command as background job."
        write-host  ${lisa_cmd} 
        $lisa_script = [scriptblock]::Create($lisa_cmd)
        Start-Job -Name  $job_name -ScriptBlock $lisa_script
        
        if ($? -ne $true) {
            Write-Host "Error launching job $job_name. Skipping BVT." -ForegroundColor Red
        } else {
            $test_runs += 1
            Write-Host "Job $job_name started for $vm_name as BVT $test_runs at $date" -ForegroundColor Green
            $job_names.Add($job_name)
        }
    }  
}


if ($job_names.count -eq 0) {
    Write-Host "No BVT Job was successfully started. Exiting with failure" -ForegroundColor Red
    exit 1
}

$exit_status = $true
$sleep_interval = 30
$failed_jobs = New-Object System.Collections.ArrayList
$completeted_jobs = New-Object System.Collections.ArrayList
$other_job_states = New-Object System.Collections.ArrayList
$bvt_max_duration = 14400 # 4 hours
$bvt_duration = 0
while ($job_names.count -gt 0) {
    $remove_jobs = New-Object System.Collections.ArrayList
    foreach ($job_name in $job_names) {
        $job = Get-Job -Name $job_name
        if ($job.State -eq "Failed") {
            $remove_jobs.Add($job_name)
            $failed_jobs.Add($job_name)
            write-host "BVT job $job_name exited with failed state." -ForegroundColor Red
        } elseif ($job.State -eq "Completed") {
            $completeted_jobs.Add($job_name)
            $remove_jobs.Add($job_name)
            write-host "BVT job $job_name completed successfully." -ForegroundColor Green
        } elseif ($job.State -eq "Running") {
            write-host "BVT job $job_name is still running"
        } else {
            write-host "BVT job $job_name is in state ${job.State}" -ForegroundColor Yellow
            $other_job_states = $other_job_states.Add($job_name) | select -uniq

            if ($other_job_states.count -eq $job_names.count) {
                write-host "All remaining jobs are in uknown states" -ForegroundColor Yellow
                $remove_jobs = $job_names
                $exit_status = $false
                break
            }
        }
    }

    foreach ($job in $remove_jobs) {
        $job_names.Remove($job)
    }

    sleep($sleep_interval)
    $bvt_duration += $sleep_interval
    write-host "BVT duration ${bvt_duration}"
    if ($bvt_duration -ge $bvt_max_duration) {
        write-host "BVT run exceeded time limit" -ForegroundColor Red
    }
}

if ($completeted_jobs.count -eq 0) {
    write-host "No successfull BVT run." -ForegroundColor Red
    $exit_status = $false
} else {
    write-host "There were ${completed_jobs.count} that run successfully" -ForegroundColor Green
    write-host $completeted_jobs -ForegroundColor Green
}

if ($failed_jobs.count -gt 0) {
    write-host "There were ${failed_jobs.Length} failed jobs." -ForegroundColor Red
    write-host $failed_jobs -ForegroundColor Red
    $exit_status = $false
}

if ($other_job_states.count -gt 0) {
    write-host "Following jobs are in uknown states."
    foreach($job_name in $other_job_states) {
        $job = Get-Job -Name $job_names
        write-host "Job ${job.Name} - State ${$job.State}" -ForegroundColor Yellow
    }
}

if ($exit_status) {
    exit 0
} else {
    exit 1
}