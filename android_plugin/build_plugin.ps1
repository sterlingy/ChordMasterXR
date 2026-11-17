# Builds the ChordMasterMidi Android plugin and copies the AARs into
# addons/chordmaster_midi/bin. Run from anywhere:
#   powershell -File android_plugin\build_plugin.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ver = "4.7.2.stable"
$aar = Join-Path $here "midi\libs\godot-lib.aar"
if (-not (Test-Path $aar)) {
    # godot-lib comes from the Android build template inside Godot's export templates.
    $zip = Join-Path $env:APPDATA "Godot\export_templates\$ver\android_source.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $z.Entries | Where-Object FullName -eq "libs/release/godot-lib.template_release.aar"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $aar, $true)
    } finally { $z.Dispose() }
}
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = Join-Path $env:LOCALAPPDATA "Android\jdk-21.0.9" }
Push-Location $here
try { & .\gradlew.bat --no-daemon copyToGodot } finally { Pop-Location }
