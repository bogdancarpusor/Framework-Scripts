﻿param (
    [Parameter(Mandatory=$true)] [string] $script
)

$o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
$pw=convertto-securestring -AsPlainText -force -string 'P@$$w0rd!'
$cred=new-object -typename system.management.automation.pscredential -argumentlist "MSTest",$pw

$s=New-PSSession -ComputerName 169.254.241.55 -Authentication Basic -Credential $cred  -Port 443 -UseSSL -SessionOption $o

$scriptBlockString = 
{ 
   param($args) 
   $sp = $args[0].ToString()
   write-host "------------->> Full args:  $args[0].ToString()"
   Write-Host "---------------------->> Script is $sp"
   $code = Start-Process powershell.exe $sp -NoNewWindow -Wait
   $code.ExitCode
}

$scriptBlock = [scriptblock]::Create($scriptBlockString)

write-host "Calling invoke-command with argument $script"
$result = Invoke-Command -Session $s -ScriptBlock $scriptBlock -ArgumentList $script

if($result -ne 0) {
    exit 1
} else {
    exit 0
}

# invoke-command -session $s -FilePath $script
# $remote_status = invoke-command -Session $s -ScriptBlock { $? } -ErrorAction SilentlyContinue

# if ($? -eq $false -or $remote_status -ne 0) {
    # exit 1
# } else {
    # exit 0
# }