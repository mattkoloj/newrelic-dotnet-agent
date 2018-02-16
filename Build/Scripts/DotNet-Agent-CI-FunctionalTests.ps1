$ErrorActionPreference = "Stop"

if([string]::IsNullOrWhiteSpace($env:TestServers)){
    Write-Host "Server name not provided, exiting."
    exit 1
}

# take existing var and reassign to a better name while keeping jenkins unchanged.
$testServer = $env:TestServers

# Prep key variables for later use
. .\windows\agent\powershell\agentInstallActions.ps1
$install = Get-ChildItem $env:WORKSPACE\Agent\_build\x86-Release\Installer\NewRelicAgent_x86_*.msi -Name
$version = $install.TrimStart('NewRelicAgent_x').TrimStart('{64,86}').TrimStart('_').TrimEnd('.msi')
Write-Host "Version: $version"

# Update the function test config file with servers, version, and other data
$appConfigPath = "$env:WORKSPACE\FunctionalTests\bin\Release\FunctionalTests.dll.config"
[Xml]$appConfig = Get-Content $appConfigPath
$appConfig.SelectSingleNode("/configuration/appSettings/add[@key='Environment']").Value = "Remote"
$appConfig.SelectSingleNode("/configuration/appSettings/add[@key='RemoteServers']").Value = $testServer
$appConfig.SelectSingleNode("/configuration/appSettings/add[@key='AgentVersion']").Value = $version
$appConfig.SelectSingleNode("/configuration/appSettings/add[@key='TestApplicationsPath']").Value = "C:\TestApplications"
$appConfig.SelectSingleNode("/configuration/system.serviceModel/client/endpoint/@address").Value = "http://$($testServer)/DotNet-Functional-4_5-WCF-IIS-Hosted/DotNetFunctionalWcfIisHosted.svc"
$appConfig.Save($appConfigPath)

# Attempt to lock the server for setup
$lockPath = "\\$testServer\c$\LOCK.txt"
Write-Host "Attempting to lock '$testServer'."

if (Test-Path $lockPath)
{
    Write-Host "-- '$testServer' is in use."
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    while (Test-Path $lockPath)
    {
        $lastModified = (Get-Item -Path $lockPath).LastWriteTime
        if ([DateTime]::Now -gt $lastModified.AddMinutes(5.0))
        {
            Write-Host '-- Lock is over 5 minutes old, proceeding with new lock.'
            break
        }
        else
        {
            Write-Host "-- Waiting for lock to expire, elapsed time '$($timer.Elapsed)'."
            Start-Sleep -Seconds 10
        }
    }
}

if ((Test-Path $lockPath) -eq $false)
{
    New-Item $lockPath -type file
}
Write-Host "-- '$testServer' locked."

# Attempt to unintall any previous version of the agent on the server
uninstallAgentOnRemoteServer $testServer $install

Write-Host "Removing previous msi files from the test VM, excluding '2.1.3.494' and leaving most recent '3'."
net use \\$testServer\c$ !4maline! /user:Administrator
$installers = Get-Item -Path "\\$testServer\c$\NewRelicAgent_x86_*" -Exclude "NewRelicAgent_x86_2.1.3.494.msi"
if ($installers.Count -gt 3)
{
    Remove-Item ($installers | Sort-Object Name -Descending | Select-Object -Last ($($installers.Count) - 3))
}

# Clean up the event logs
Clear-EventLog -LogName Application -ComputerName $testServer

# Copy the new agent install to the server and remove the temp share afterward.
Write-Host "Copying new version of the .NET Agent out to the test VM"
Copy-Item $env:WORKSPACE\Agent\_build\x86-Release\Installer\$install \\$testServer\c$
net use \\$testServer\c$ /delete

# Install the Agent
installAgentOnRemoteServer $testServer $install

# Check that the W3SVC service is running and start it if not.
$W3SVC = Get-Service -Name W3SVC -ComputerName $testServer
if ($W3SVC.Status -ne "Running")
{
    Write-Host "W3SVC service is not running; starting."
    $W3SVC.Start()
}

Write-Host "Removing lock"
Remove-Item -Path \\$testServer\c$\LOCK.txt

# check we shuold only configure servers or also run tests.
if ($env:ConfigureServersOnly -eq $true)
{
    exit 0
}

# Test Run Section
Write-Host 'Executing the functional regression tests'

# $nUnitPath = "$env:WORKSPACE\FunctionalTests\packages\NUnit.Console.3.0.0\tools\nunit3-console.exe"
$nUnitPath = "C:\Program Files (x86)\NUnit.org\nunit-console\nunit3-console.exe"

# Used to set the params based on the "Override" checkbox
if ($env:Override -eq $true)
{
    $message = "Override enabled. Executing partial run: '$env:TestParams'"
    $testParams = $env:TestParams
}
else
{
    $message = 'Executing full test run'
    $testParams = "--where=cat != NuGet && cat != Install"
}

# Run the test using Nunit
Write-Host $message
& "$nUnitPath" "$env:WORKSPACE\FunctionalTests\bin\Release\FunctionalTests.dll" "$testParams" "--result=TestResult_NUnit2.xml;format=nunit2" "--result=TestResult_NUnit3.xml;format=nunit3"
$testsResult = $LastExitCode
exit $testsResult