$ErrorActionPreference='Stop'
$ProjectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ProjectFile=Join-Path $ProjectRoot 'td_project/camera_to_dsi_display.al'
$ProjectDirectory=(Split-Path -Parent $ProjectFile).Replace('\','/')
$Text=[System.IO.File]::ReadAllText($ProjectFile)
$Text=[regex]::Replace($Text,'(<Project\b[^>]*\bPath=")[^"]*(")',{
    param($match)
    $match.Groups[1].Value+$ProjectDirectory+$match.Groups[2].Value
},1)
[System.IO.File]::WriteAllText($ProjectFile,$Text,(New-Object System.Text.UTF8Encoding($false)))
Write-Output "Project ready: $ProjectFile"
