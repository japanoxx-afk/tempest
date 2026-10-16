param([Parameter(Mandatory=$true)][string]$GameExecutable,
      [Parameter(Mandatory=$true)][string]$Data,
      [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$Session)
$ErrorActionPreference='Stop'
# Only a newly launched replay process, and only after its confirmed exit command.
# Never infer an exit request from inactivity, loss of focus, or a hidden window.
$launched=Get-Date
$target=$null
while (((Get-Date)-$launched).TotalSeconds -lt 120) {
    $target=Get-Process -Name 'Tempest-Win64-Shipping' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $GameExecutable -and $_.StartTime -ge $launched.AddSeconds(-2) } |
        Select-Object -First 1
    if($target){break}
    Start-Sleep -Milliseconds 500
}
if(-not $target){return}
$identity=$target.StartTime
$signal=Join-Path $Data 'shutdown.txt'
$deadline=(Get-Date).AddHours(24)
while ((Get-Date) -lt $deadline) {
    $target.Refresh()
    if($target.HasExited){return}
    if((Test-Path -LiteralPath $signal) -and [IO.File]::ReadAllText($signal).Trim() -eq $Session){
        if($target.WaitForExit(8000)){return}
        $target.Refresh()
        if(-not $target.HasExited -and $target.StartTime -eq $identity -and
           $target.Path -eq $GameExecutable -and $target.MainWindowHandle -eq [IntPtr]::Zero){
            $target.Kill()
            [IO.File]::WriteAllText((Join-Path $Data 'exit-cleanup.txt'),$Session+"`nClosed lingering replay process after confirmed exit.`n")
        }
        return
    }
    Start-Sleep -Seconds 1
}
