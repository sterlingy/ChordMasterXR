# Runs the app with a dev script, saves a screenshot, never hangs.
#   powershell -File tools\shot.ps1 -Name settings -Out C:\tmp\shot.png
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$TimeoutSec = 45
)
$godot = 'C:\Users\sterl\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$log = [System.IO.Path]::ChangeExtension($Out, '.log')
$args = @('--path', $root, '--resolution', '1600x900', '--quit-after', '200000', '--', "--screenshot=$Out", "--script=$Name")
$p = Start-Process -FilePath $godot -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Write-Output "TIMEOUT"
    Get-CimInstance Win32_Process -Filter "Name like 'Godot%'" | Where-Object { $_.CommandLine -like "*$Out*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}
Get-Content $log, "$log.err" -ErrorAction SilentlyContinue | Select-String 'SCRIPT ERROR|Parse Error|^ERROR|SCREENSHOT|DEV ' | Select-Object -First 15 | ForEach-Object { $_.Line }
