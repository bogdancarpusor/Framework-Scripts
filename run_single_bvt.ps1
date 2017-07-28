param (
    [Parameter(Mandatory=$true)] [string] $sourceName="Unknown",
    [Parameter(Mandatory=$true)] [string] $configFileName="Unknown",
    [Parameter(Mandatory=$true)] [string] $distro="Smoke-BVT",
    [Parameter(Mandatory=$true)] [string] $testCycle="BVT",
    [Parameter(Mandatory=$false)] [string] $platform="azure"
)

. "C:\Framework-Scripts\secrets.ps1"
$azure_platform = 'azure'
$hyperv_platform = 'hyperv'

#
#  Launch the automation
echo "Starting execution of test $testCycle on machine $sourceName" 

if ($platform -eq $azure_platform) {
    Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'
    Select-AzureRmSubscription -SubscriptionId "$AZURE_SUBSCRIPTION_ID"
    $automation_path = "C:\azure-linux-automation"
    $automation_cmd = "$automation_path\AzureAutomationManager.ps1 -xmlConfigFile $configFileName -runtests -email –Distro $distro -cycleName $testCycle -UseAzureResourceManager -EconomyMode"
}
elseif ($platform -eq $hyperv_platform) {
    $automation_path = "C:\lis-test\WS2012R2\lisa"
    $automation_cmd = "$automation_path\lisa.ps1 run $configFileName -vmName $distro"
}
else {
    echo "Invalid platform name. Supported values: $azure_platform, $hyperv_platform."
    exit 1
}

cd $automation_path
try {
    Invoke-Expression $automation_cmd
    exit 0
} catch {
    exit 1
}