function Write-ErrorDump {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetDir,
    [Parameter(Mandatory = $true)]
    [string]$Phase,
    [Parameter(Mandatory = $true)]
    $ErrorRecord
  )

  try {
    if ([string]::IsNullOrWhiteSpace($TargetDir)) { return $null }
    New-DirectoryIfMissing -DirPath $TargetDir
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $dumpPath = Join-Path -Path $TargetDir -ChildPath ("isolate-error-{0}.txt" -f $ts)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("timestamp: {0:o}" -f (Get-Date)))
    $lines.Add(("phase: {0}" -f $Phase))
    $lines.Add(("script: {0}" -f $PSCommandPath))
    $lines.Add(("ps: {0}" -f $PSVersionTable.PSVersion))
    $lines.Add(("cwd: {0}" -f (Get-Location)))
    $lines.Add("")
    $lines.Add("=== parameters ===")
    $lines.Add(("GameModsDir={0}" -f $GameModsDir))
    $lines.Add(("StorageModsDir={0}" -f $StorageModsDir))
    $lines.Add(("LogPath={0}" -f $LogPath))
    $lines.Add(("LauncherExePath={0}" -f $LauncherExePath))
    $lines.Add(("LauncherWindowTitlePattern={0}" -f $LauncherWindowTitlePattern))
    $lines.Add(("PlayClickOffsetX={0}" -f $PlayClickOffsetX))
    $lines.Add(("PlayClickOffsetY={0}" -f $PlayClickOffsetY))
    $lines.Add(("CrashCloseClickOffsetX={0}" -f $CrashCloseClickOffsetX))
    $lines.Add(("CrashCloseClickOffsetY={0}" -f $CrashCloseClickOffsetY))
    $lines.Add(("WaitForGameExitSeconds={0}" -f $WaitForGameExitSeconds))
    $lines.Add(("GameProcessNames={0}" -f ($GameProcessNames -join ",")))
    $lines.Add(("MoveRetryCount={0}" -f $MoveRetryCount))
    $lines.Add(("MoveRetryDelayMs={0}" -f $MoveRetryDelayMs))
    $lines.Add("")

    try {
      $lines.Add("=== visible windows (sample) ===")
      $windows = Get-WindowList
      $max = 40
      $count = 0
      foreach ($w in $windows) {
        $count++
        if ($count -gt $max) { break }
        $lines.Add(("[{0}] pid={1} handle=0x{2} title={3}" -f $count, $w.ProcessId, ("{0:X}" -f ([long]$w.Handle.ToInt64())), $w.Title))
      }
      if ($windows.Count -gt $max) {
        $lines.Add(("[...] total visible windows: {0}" -f $windows.Count))
      }
      $lines.Add("")
    } catch {
      $lines.Add("=== visible windows (sample) ===")
      $lines.Add("failed to enumerate windows")
      $lines.Add("")
    }

    $lines.Add("=== error record ===")
    $lines.Add(($ErrorRecord | Format-List * -Force | Out-String))
    if ($ErrorRecord.Exception) {
      $lines.Add("")
      $lines.Add("=== exception ===")
      $lines.Add(($ErrorRecord.Exception | Format-List * -Force | Out-String))
      $lines.Add("")
      $lines.Add("=== stacktrace ===")
      $lines.Add([string]$ErrorRecord.Exception.StackTrace)
    }
    if ($ErrorRecord.InvocationInfo) {
      $lines.Add("")
      $lines.Add("=== invocation ===")
      $lines.Add(($ErrorRecord.InvocationInfo | Format-List * -Force | Out-String))
      $lines.Add("")
      $lines.Add("=== position ===")
      $lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage)
    }

    $lines | Out-File -LiteralPath $dumpPath -Encoding UTF8
    return $dumpPath
  } catch {
    return $null
  }
}
