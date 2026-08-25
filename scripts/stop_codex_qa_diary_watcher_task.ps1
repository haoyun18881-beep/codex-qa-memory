param(
    [switch]$Unregister,
    [string]$TaskName = "Codex QA Diary Watcher",
    [string]$TaskPath = "\Codex\",
    [string]$HealthTaskName = "Codex QA Diary Health"
)

$ErrorActionPreference = "SilentlyContinue"

Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
Stop-ScheduledTask -TaskName $HealthTaskName -TaskPath $TaskPath

Get-CimInstance Win32_Process |
    Where-Object {
        ($_.Name -eq "pwsh.exe" -or $_.Name -eq "powershell.exe") -and
        $_.CommandLine -and
        ($_.CommandLine -like "*codex_qa_diary_supervisor.ps1*" -or $_.CommandLine -like "*codex_qa_diary_watcher.ps1*")
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
    }

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    Unregister-ScheduledTask -TaskName $HealthTaskName -TaskPath $TaskPath -Confirm:$false
}

Get-ScheduledTask -TaskName @($TaskName, $HealthTaskName) -TaskPath $TaskPath |
    Select-Object TaskName,TaskPath,State
