Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Show-Usage {
    @'
Usage: .\az-register-fireworks-pre-relase-feature.ps1 [subscription-id]

Checks Microsoft.CognitiveServices provider registration first, requests the
Fireworks.EnableDeploy feature registration, and reports its current state.
'@
}

function Invoke-AzureCli {
    param(
        [string[]]$Arguments,
        [switch]$IgnoreErrors
    )

    # Handle native exit codes explicitly, including in Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    if ($IgnoreErrors) {
        & az @Arguments 2>$null
    }
    else {
        & az @Arguments
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
}

if ($args.Count -gt 1 -or ($args.Count -eq 1 -and ($args[0] -ceq '-h' -or $args[0] -ceq '--help'))) {
    Show-Usage
    if ($args.Count -eq 1) {
        exit 0
    }
    exit 2
}

if ($args.Count -eq 1) {
    $subscriptionId = [string]$args[0]
}
else {
    try {
        $subscriptionId = Read-Host 'Enter the subscription ID where Fireworks on Foundry should be enabled'
    }
    catch {
        [Console]::Error.WriteLine('Error: could not read a subscription ID.')
        exit 2
    }
}

if ([string]::IsNullOrEmpty($subscriptionId)) {
    [Console]::Error.WriteLine('Error: subscription ID cannot be empty.')
    exit 2
}

if ($subscriptionId -notmatch '^[0-9a-fA-F-]{36}$') {
    [Console]::Error.WriteLine('Error: subscription ID must be a UUID.')
    exit 2
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('Error: Azure CLI (az) is required.')
    exit 1
}

Invoke-AzureCli -Arguments @(
    'account', 'show',
    '--subscription', $subscriptionId,
    '--output', 'none'
)

$providerState = Invoke-AzureCli -Arguments @(
    'provider', 'show',
    '--namespace', 'Microsoft.CognitiveServices',
    '--subscription', $subscriptionId,
    '--query', 'registrationState',
    '--output', 'tsv'
)

if ($providerState -ceq 'Registered' -or $providerState -ceq 'Registering') {
    Write-Output "Resource provider Microsoft.CognitiveServices state is $providerState; skipping another registration request."
}
else {
    $providerStateDisplay = if ($providerState) { $providerState } else { 'unknown' }
    Write-Output "Registering resource provider Microsoft.CognitiveServices (current state: $providerStateDisplay)..."
    Invoke-AzureCli -Arguments @(
        'provider', 'register',
        '--namespace', 'Microsoft.CognitiveServices',
        '--subscription', $subscriptionId,
        '--output', 'none'
    )
}

$featureStateArguments = @(
    'feature', 'registration', 'show',
    '--provider-namespace', 'Microsoft.CognitiveServices',
    '--name', 'Fireworks.EnableDeploy',
    '--subscription', $subscriptionId,
    '--query', 'properties.state',
    '--output', 'tsv'
)

$state = Invoke-AzureCli -Arguments $featureStateArguments -IgnoreErrors

if ($state -cne 'Registered' -and $state -cne 'Registering') {
    Write-Output "Registering Fireworks.EnableDeploy in subscription $subscriptionId..."
    Invoke-AzureCli -Arguments @(
        'feature', 'registration', 'create',
        '--namespace', 'Microsoft.CognitiveServices',
        '--name', 'Fireworks.EnableDeploy',
        '--subscription', $subscriptionId,
        '--output', 'none'
    )
}

$state = Invoke-AzureCli -Arguments $featureStateArguments -IgnoreErrors

if ($state -ceq 'Registered') {
    Write-Output "Fireworks.EnableDeploy is Registered in subscription $subscriptionId."
}
else {
    $stateDisplay = if ($state) { $state } else { 'unknown' }
    Write-Output "Feature registration was requested. Current state: $stateDisplay. Check again before planning the Foundry deployment."
}

exit 0
