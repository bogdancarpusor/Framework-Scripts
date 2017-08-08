##### Install PowerShell 5 using https://github.com/DarwinJS/ChocoPackages/blob/master/PowerShell/v5.1/tools/ChocolateyInstall.ps1#L107-L173
##### For 2008 R2, run the .ps1 from: https://download.microsoft.com/download/6/F/5/6F5FF66C-6775-42B0-86C4-47D41F2DA187/Win7AndW2K8R2-KB3191566-x64.zip


class Instance {
    [Backend] $Backend
    [String] $Name
    [String] $LogPath = "C:\temp\transcripts\launch_single_azure_vm_{0}.log"
    [String] $DefaultUsername
    [String] $DefaultPassword

    Instance ($Backend, $Name) {
        $transcriptPath = $this.LogPath -f @($Name)
        Start-Transcript -Path $transcriptPath -Force -ErrorAction SilentlyContinue -Append
        $this.Backend = $Backend
        $this.Name = $Name
        Write-Host ("Initialized instance wrapper" + $this.Name) -ForegroundColor Blue
    }

    [void] Cleanup () {
        $this.Backend.CleanupInstance($this.Name)
    }

    [void] Create () {
        $this.Backend.CreateInstance($this.Name)
    }

    [String] GetPublicIP () {
        return $this.Backend.GetPublicIP($this.Name)
    }
}

class AzureInstance : Instance {
    AzureInstance ($Backend, $Name) : base ($Backend, $Name) {}
}

class HypervInstance : Instance {
    HypervInstance ($Params) : base ($Params) {}
}


class Backend {
    [String] $Name="BaseBackend"

    Backend ($Params) {
        Write-Host ("Initialized backend " + $this.Name) -ForegroundColor Blue
    }

    [Instance] GetInstanceWrapper ($InstanceName) {
        Write-Host ("Initializing instance on backend " + $this.Name) -ForegroundColor Green
        return $null
    }

    [void] CreateInstance ($InstanceName) {
    }

    [void] CleanupInstance ($InstanceName) {
        Write-Host ("Cleaning instance and associated resources on backend " + $this.Name) `
            -ForegroundColor Red
    }

    [void] RebootInstance ($InstanceName) {
        Write-Host ("Rebooting instance on backend " + $this.Name) -ForegroundColor Green
    }

    [String] GetPublicIP ($InstanceName) {
        Write-Host ("Getting instance public IP a on backend " + $this.Name) -ForegroundColor Green
        return $null
    }

    [Object] GetPSSession ($InstanceName) {
        Write-Host ("Getting new Powershell Session on backend " + $this.Name) -ForegroundColor Green
        return $null
    }
}

class AzureBackend : Backend {
    [String] $Name = "AzureBackend"
    [String] $SecretsPath = "C:\Framework-Scripts\secrets.ps1"
    [String] $ProfilePath = "C:\Azure\ProfileContext.ctx"
    [String] $ResourceGroupName = "smoke_working_resource_group"
    [String] $StorageAccountName = "smokeworkingstorageacct"
    [String] $ContainerName = "vhds-under-test"
    [String] $Location = "westus"
    [String] $VMFlavor = "Standard_D2"
    [String] $NetworkName = "SmokeVNet"
    [String] $SubnetName = "SmokeSubnet-1"
    [String] $NetworkSecGroupName = "SmokeNSG"

    AzureBackend ($Params) : base ($Params) {
        if (Test-Path $this.SecretsPath) {
            . $this.SecretsPath
        } else {
            throw "Secrets file does not exist."
        }

        login_azure $this.ResourceGroupName $this.StorageAccountName
    }

    [Instance] GetInstanceWrapper ($InstanceName) {
        if ($this.ResourceGroupName -and $this.StorageAccountName) {
            Set-AzureRmCurrentStorageAccount -ResourceGroupName $this.ResourceGroupName `
                -StorageAccountName $this.StorageAccountName | Out-Null
        }

        $instance = [AzureInstance]::new($this, $InstanceName)
        return $instance
    }

    [void] CleanupInstance ($InstanceName) {
        ([Backend]$this).CleanupInstance($InstanceName)
        $vm = Get-AzureRmVm -ResourceGroupName $this.ResourceGroupName -Status | `
            Where-Object -Property Name -eq $InstanceName
        if (!$vm) {
            Write-Host ("VM $InstanceName does not exist") -ForegroundColor Yellow
            return
        }
        Get-AzureRmVm -ResourceGroupName $this.ResourceGroupName -Status | `
            Where-Object -Property Name -eq $InstanceName | `
            Remove-AzureRmVM -Force
    }

    [void] CreateInstance ($InstanceName) {
        ([Backend]$this).CreateInstance($InstanceName)
        Write-Host "Creating a new VM config..." -ForegroundColor Yellow
        $vm = New-AzureRmVMConfig -VMName $InstanceName -VMSize $this.VMFlavor
        Write-Host "Assigning network and subnet config to new machine" `
            -ForegroundColor Yellow
            
        #
        #  JWF -- TODO:  Add VNET and Subnet detection and creation just like we have for NIC and IP Address
        $VMVNETObject = Get-AzureRmVirtualNetwork -Name $this.NetworkName -ResourceGroupName $this.ResourceGroupName
        $VMSubnetObject = Get-AzureRmVirtualNetworkSubnetConfig -Name $this.SubnetName -VirtualNetwork $VMVNETObject

        Write-Host "Assigning the public IP address" -ForegroundColor Yellow
        $ipName = $InstanceName + "PublicIP"
        $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $this.ResourceGroupName -Name $ipName `
            -ErrorAction SilentlyContinue
        if (!$pip) {
            Write-Host "Creating new IP address..." -ForegroundColor Yellow
            New-AzureRmPublicIpAddress -ResourceGroupName $this.ResourceGroupName -Location $this.Location `
                -Name $ipName -AllocationMethod Dynamic -IdleTimeoutInMinutes 4
            $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $this.ResourceGroupName -Name $ipName
        }

        Write-Host "Assigning the network interface" -ForegroundColor Yellow
        $nicName = $InstanceName + "VMNic"
        $VNIC = Get-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue
        if (!$VNIC) {
            Write-Host "Creating new network interface" -ForegroundColor Yellow
            New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $this.ResourceGroupName `
                -Location $this.Location -SubnetId $VMSubnetObject.Id -publicipaddressid $pip.Id
            $VNIC = Get-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $this.ResourceGroupName
        }

        #
        #  JWF -- TODO -- Can we make sure port 443 is enabled here?
        $sg = Get-AzureRmNetworkSecurityGroup -Name $this.NetworkSecGroupName -ResourceGroupName $this.ResourceGroupName
        $VNIC.NetworkSecurityGroup = $sg
        Set-AzureRmNetworkInterface -NetworkInterface $VNIC

        Write-Host "Adding the network interface" -ForegroundColor Yellow
        Add-AzureRmVMNetworkInterface -VM $vm -Id $VNIC.Id

        $blobURIRaw = ("https://{0}.blob.core.windows.net/{1}/{2}.vhd" -f `
                       @($this.StorageAccountName, $this.ContainerName, $InstanceName))

        $vm = Set-AzureRmVMOSDisk -VM $vm -Name $InstanceName -VhdUri $blobURIRaw -CreateOption Attach -Linux
        try {
            Write-Host "Starting the VM" -ForegroundColor Yellow
            $NEWVM = New-AzureRmVM -ResourceGroupName $this.ResourceGroupName -Location $this.Location -VM $vm
            if (!$NEWVM) {
                Write-Host "Failed to create VM" -ForegroundColor Red
            } else {
                Write-Host "VM $InstanceName started successfully..." -ForegroundColor Green
            }
        } catch {
            Write-Host "Caught exception attempting to start the new VM.  Aborting..."
            Stop-Transcript
            return
        }
    }

    [String] GetPublicIP ($InstanceName) {
        ([Backend]$this).GetPublicIP($InstanceName)
        $ip = Get-AzureRmPublicIpAddress -ResourceGroupName $this.ResourceGroupName `
            -Name ($InstanceName + "-pip")
        if ($ip) {
            return $ip.IPAddress
        } else {
            return $null
        }
    }

    [Object] GetPSSession ($InstanceName) {
        return ([Backend]$this).GetPSSession()
    }
}

class HypervBackend : Backend {
    [String] $Name="HypervBackend"
    [String] $ServerName="localhost"


    HypervBackend ($Params) : base ($Params) {}

    [boolean] CreateVM ($vmName, $vhdPath, $memSize, $generation, $switchName) {
        New-VM -Name $vmName -ComputerName $this.ServerName -VHDPath $vhdPath -MemoryStartupBytes $memSize -SwitchName $switchName -Generation $generation
        if (-not $?) {
           Write-Host "Unable to create VM ${vmName} on server ${this.ServerName}" -ForegroundColor Red
           return $false
        }
        return $true
    }

    [boolean] GetVM ($vmName) {
        Get-VM -Name $vmName -ComputerName $this.ServerName
        if (-not $?) {
           Write-Host "Unable to get VM ${vmName} on server ${this.ServerName}" -ForegroundColor Red
           return $false
        }
        return $true
    }

    [boolean] StopVM ($vmName) {
        Stop-VM -Name $vmName -ComputerName $this.ServerName -force
        if (-not $?) {
           Write-Host "Unable to get VM ${vmName} on server ${this.ServerName}" -ForegroundColor Red
           return $false
        }
        return $true
    }

    [boolean] RemoveVM ($vmName) {
        Remove-VM -Name $vmName -ComputerName $this.ServerName -force
        if (-not $?) {
           Write-Host "Unable to get VM ${vmName} on server ${this.ServerName}" -ForegroundColor Red
           return $false
        }
        return $true
    }

    [boolean] StartVM ($vmName) {
        Start-VM -Name $vhdFileName -ComputerName $this.ServerName
        if (-not $?) {
           Write-Host "Unable to start VM ${vmName} on server ${this.ServerName}" -ForegroundColor Red
           return $false
        }
        return $true
    }
}


class BackendFactory {
    [Backend] GetBackend([String] $Type, $Params) {
        return (New-Object -TypeName $Type -ArgumentList $Params)
    }
}
