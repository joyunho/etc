# test_bisect.ps1
#
# Drives the mod bisect in patch/templates/tools/patch.ps1 against a simulated
# server: a fake Klei folder, a fake modoverrides.lua, and a rule that decides
# whether a given set of enabled mods "boots". Each round we read the set the
# bisect proposed, apply the rule, and write the log a real server would have
# written -- so the search is exercised exactly as it runs on a player's
# machine, without needing a machine that runs Don't Starve Together.
#
#   pwsh tests/test_bisect.ps1

$ErrorActionPreference = 'Stop'

$repo    = Split-Path -Parent $PSScriptRoot
$package = Join-Path (Join-Path $repo 'build') 'NPC_HOF_Patch'
$script  = Join-Path (Join-Path $package 'tools') 'patch.ps1'

if (-not (Test-Path -LiteralPath $script)) {
	throw "build the package first: python3 patch/build.py  (missing $script)"
}

$failures = 0
function Check($label, $ok, $detail) {
	if ($ok) {
		Write-Host ("  PASS  " + $label)
	} else {
		$script:failures = $script:failures + 1
		Write-Host ("  FAIL  " + $label + $(if ($detail) { "  -- " + $detail } else { "" }))
	}
}

$env:NPCHOF_DOTSOURCE_ONLY = '1'
. $script

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bisect_' + [Guid]::NewGuid().ToString('N'))
$klei    = Join-Path $sandbox 'Klei/DoNotStarveTogether'
$cluster = Join-Path $klei 'Cluster_1'
New-Item -ItemType Directory -Force -Path (Join-Path $cluster 'Master') | Out-Null

function Get-KleiRoots { @($klei) }

$overrides = Join-Path $cluster 'modoverrides.lua'
$serverLog = Join-Path $cluster 'Master/server_log.txt'

function Reset-World($ids) {
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.AppendLine('return {')
	foreach ($id in $ids) {
		[void]$sb.AppendLine('  ["workshop-' + $id + '"] = { enabled = true, configuration_options = { keep = "me" } },')
	}
	[void]$sb.AppendLine('}')
	[IO.File]::WriteAllText($overrides, $sb.ToString())

	$p = Get-BisectPaths
	if (Test-Path -LiteralPath $p.State)  { Remove-Item -LiteralPath $p.State -Force }
	if (Test-Path -LiteralPath $p.Backup) { Remove-Item -LiteralPath $p.Backup -Recurse -Force }
	if (Test-Path -LiteralPath $serverLog) { Remove-Item -LiteralPath $serverLog -Force }
}

# The simulated server: it fails only when every mod of $culprits is enabled.
function Write-BootLog($enabled, $culprits) {
	$broken = $true
	foreach ($c in $culprits) { if ($enabled -notcontains $c) { $broken = $false } }

	$lines = New-Object System.Collections.Generic.List[string]
	$lines.Add('[00:00:00]: Starting Up')
	foreach ($id in $enabled) { $lines.Add('[00:00:03]: Loading mod: workshop-' + $id + ' (Mod ' + $id + ') Version:1.0') }

	if ($broken) {
		$lines.Add('[00:00:05]: MOD ERROR: workshop-' + $culprits[0] + ' (Mod ' + $culprits[0] + ')')
		$lines.Add('[00:00:05]: DoLuaFile Error: (null)')
		$lines.Add('[00:00:05]: Failed mSimulation->Reset()')
	} else {
		$lines.Add('[00:00:09]: Sim paused')
	}

	[IO.File]::WriteAllLines($serverLog, $lines)
	# the bisect only trusts a log written after it wrote modoverrides
	(Get-Item -LiteralPath $serverLog).LastWriteTime = (Get-Date).AddSeconds(5)
}

# Runs the bisect to completion against the simulated server.
# Returns the set it named, and how many server starts that took.
function Invoke-Simulation($ids, $culprits, $maxRounds) {
	Reset-World $ids

	$rounds = 0
	$answer = $null

	for ($i = 0; $i -lt $maxRounds; $i++) {
		$script:reportLines = New-Object System.Collections.Generic.List[string]
		Invoke-Bisect '' | Out-Null
		$text = ($script:reportLines -join "`n")

		if ($text -match '━━ 찾았습니다 ━━') {
			$answer = @([regex]::Matches($text, '(?m)^\s*workshop-(\d+)') | ForEach-Object { $_.Groups[1].Value })
			break
		}

		$state = Read-BisectState
		if ($state -eq $null) { break }

		$rounds++
		Write-BootLog @($state.Pending) $culprits
	}

	return [pscustomobject]@{ Answer = $answer; Rounds = $rounds }
}

Write-Host ''
Write-Host '=== 1. modoverrides is edited without losing anything else ==='

$ids = @('101', '102', '103', '104')
Reset-World $ids

$before = [IO.File]::ReadAllText($overrides)
Set-EnabledMods @($overrides) @('102')
$after = [IO.File]::ReadAllText($overrides)

Check 'the chosen mod stays on'  ($after -match '"workshop-102"\] = \{ enabled = true')
Check 'the others are switched off' `
	(($after -match '"workshop-101"\] = \{ enabled = false') -and ($after -match '"workshop-104"\] = \{ enabled = false'))
Check 'configuration_options survive' `
	((@([regex]::Matches($after, 'keep = "me"'))).Count -eq 4)
Check 'no mod entry was lost' `
	((@([regex]::Matches($after, '\["workshop-'))).Count -eq 4)

$readBack = Get-EnabledFromFiles @($overrides)
Check 'reading it back agrees' (($readBack -join ',') -eq '102')

Set-EnabledMods @($overrides) $ids
Check 'switching everything back on restores the original text' `
	([IO.File]::ReadAllText($overrides) -eq $before)

Write-Host ''
Write-Host '=== 2. a mod with no enabled key still gets one ==='
[IO.File]::WriteAllText($overrides, "return {`n  [`"workshop-301`"] = { },`n  [`"workshop-302`"] = { },`n}`n")
Set-EnabledMods @($overrides) @('301')
$t2 = [IO.File]::ReadAllText($overrides)
Check 'a missing enabled key is inserted as true'  ($t2 -match '"workshop-301"\] = \{ enabled = true,') $t2
Check 'and as false for the other one'             ($t2 -match '"workshop-302"\] = \{ enabled = false,')

Write-Host ''
Write-Host '=== 3. one broken mod among 48 ==='

$many = @(1..48 | ForEach-Object { (1000 + $_).ToString() })
$run  = Invoke-Simulation $many @('1029') 40

Check 'it names the broken mod'      (($run.Answer -join ',') -eq '1029') ("got: " + ($run.Answer -join ','))
Check 'it took far fewer tries than 48' ($run.Rounds -le 16) ("took " + $run.Rounds)
Write-Host ("  (48 mods, " + $run.Rounds + " server starts)")

Write-Host ''
Write-Host '=== 4. two mods that only break together ==='

$pair = Invoke-Simulation $many @('1003', '1041') 60
$got  = @($pair.Answer | Sort-Object)
Check 'it names both halves of the conflict' (($got -join ',') -eq '1003,1041') ("got: " + ($got -join ','))
Write-Host ("  (48 mods, " + $pair.Rounds + " server starts)")

Write-Host ''
Write-Host '=== 5. nothing is broken ==='

$fine = Invoke-Simulation $many @('9999') 40
Check 'it says there is nothing to find' ($fine.Answer -eq $null -or $fine.Answer.Count -eq 0) `
	("got: " + ($fine.Answer -join ','))

Write-Host ''
Write-Host '=== 6. the original mod settings come back ==='

Reset-World $ids
$pristine = [IO.File]::ReadAllText($overrides)

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Bisect '' | Out-Null                       # takes the backup
Write-BootLog $ids @('101')
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Bisect '' | Out-Null                       # first real split, file is now edited

Check 'modoverrides really was changed mid-search' `
	([IO.File]::ReadAllText($overrides) -ne $pristine)

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Bisect 'stop' | Out-Null

Check 'stop puts the file back byte for byte' `
	([IO.File]::ReadAllText($overrides) -eq $pristine)

$p = Get-BisectPaths
Check 'stop clears the saved search' (-not (Test-Path -LiteralPath $p.State))
Check 'stop clears the backup folder' (-not (Test-Path -LiteralPath $p.Backup))

Write-Host ''
Write-Host '=== 7. only real log files are read, and each one only once ==='

# What a Klei folder actually holds next to a log.
$master = Join-Path $cluster 'Master'
foreach ($junk in @('server.ini', 'modconfiguration_workshop-3383047161', 'adjectives.txt')) {
	[IO.File]::WriteAllText((Join-Path $master $junk), 'not a log')
}
[IO.File]::WriteAllText((Join-Path $master 'server_log.txt'), 'DoLuaFile Error')
[IO.File]::WriteAllText((Join-Path $master 'server_log_2026-09-15-00-19-33.txt'), 'DoLuaFile Error')
[IO.File]::WriteAllText((Join-Path $cluster 'caves_server_log.txt'), 'DoLuaFile Error -- a caves log of its own length')
[IO.File]::WriteAllText((Join-Path $cluster 'client_log.txt'), 'Sim paused')

$found    = @(Get-DstLogs)
$logNames = @($found | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object)

Check 'server.ini is not treated as a log' ($logNames -notcontains 'server.ini')
Check 'a mod config file is not treated as a log' `
	((@($logNames | Where-Object { $_ -like 'modconfiguration*' })).Count -eq 0)
Check 'a plain .txt with no "log" in the name is left alone' ($logNames -notcontains 'adjectives.txt')
Check 'server_log.txt is found'       ($logNames -contains 'server_log.txt')
Check 'a rotated backup is found'     ($logNames -contains 'server_log_2026-09-15-00-19-33.txt')
Check 'caves_server_log.txt is found' ($logNames -contains 'caves_server_log.txt')
Check 'client_log.txt is found'       ($logNames -contains 'client_log.txt')

# Documents and OneDrive\Documents can mirror the same folder, so the same log
# arrives twice under two different paths. It must still be read once.
$mirror = Join-Path $sandbox 'OneDrive/Documents/Klei/DoNotStarveTogether/Cluster_1/Master'
New-Item -ItemType Directory -Force -Path $mirror | Out-Null
Copy-Item -LiteralPath (Join-Path $master 'server_log.txt') -Destination $mirror -Force
(Get-Item -LiteralPath (Join-Path $mirror 'server_log.txt')).LastWriteTimeUtc =
	(Get-Item -LiteralPath (Join-Path $master 'server_log.txt')).LastWriteTimeUtc

$both = @(Get-ChildItem -LiteralPath @((Join-Path $master 'server_log.txt'), (Join-Path $mirror 'server_log.txt')))
Check 'the same log under two paths is read once' `
	((@(Select-DistinctLogs $both)).Count -eq 1) ("got " + (@(Select-DistinctLogs $both)).Count)

$different = @(Get-ChildItem -LiteralPath @((Join-Path $master 'server_log.txt'), (Join-Path $cluster 'caves_server_log.txt')))
Check 'two genuinely different logs both survive' `
	((@(Select-DistinctLogs $different)).Count -eq 2)

foreach ($junk in @('server.ini', 'modconfiguration_workshop-3383047161', 'adjectives.txt',
                    'server_log_2026-09-15-00-19-33.txt')) {
	Remove-Item -LiteralPath (Join-Path $master $junk) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $cluster 'caves_server_log.txt') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $cluster 'client_log.txt') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $sandbox 'OneDrive') -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '=== 8. it refuses to guess without a fresh log ==='

Reset-World $ids
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Bisect '' | Out-Null
$stateA = Read-BisectState

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Bisect '' | Out-Null                       # no server start in between
$stateB = Read-BisectState

Check 'the search does not advance on its own' ($stateA.Round -eq $stateB.Round)
Invoke-Bisect 'stop' | Out-Null


Write-Host ''
Write-Host '=== 9. lasterror tells a real error from ordinary startup noise ==='

$lastRoot = Join-Path $sandbox 'last/Klei/DoNotStarveTogether/Cluster_9/Master'
New-Item -ItemType Directory -Force -Path $lastRoot | Out-Null

function Get-KleiRoots { @((Join-Path $sandbox 'last/Klei/DoNotStarveTogether')) }

# A healthy startup. Every line here appears in a log that booted fine --
# including "DoLuaFile scripts/main.lua", which the first version of this tool
# matched as an error and then centred its report on.
$healthy = @(
	'[00:00:01]: LOADING LUA',
	'[00:00:01]: DoLuaFile scripts/main.lua',
	'[00:00:01]: DoLuaFile loading buffer scripts/main.lua',
	'[00:00:58]: Mod: workshop-3383047161 (The Winterlands)	  Registering prefab file: prefabs/emperor_egg',
	'[00:00:58]: Mod: workshop-3383047161 (The Winterlands)	    chesspiece_moon_dryice',
	'[00:01:20]: Could not preload undefined prefab (paint_fx)',
	'[00:01:20]: Could not preload undefined prefab (paint_fx)',
	'[00:02:31]: anim/quagmire_pot.zip - 10',
	'[00:02:31]: CurlRequestManager::ClientThread::Main() complete',
	'[00:02:32]: Shutting down'
)
[IO.File]::WriteAllLines((Join-Path $lastRoot 'server_log.txt'), $healthy)

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rep = ($script:reportLines -join "`n")

Check 'a clean startup is not reported as an error' ($rep -match '오류 없음')
Check 'and it says the log ended normally'          ($rep -match '정상적으로 종료')
Check 'DoLuaFile scripts/main.lua is not an error'  (-not ($rep -match '걸린 줄'))
Check 'repeated warnings are counted, not dumped'   ($rep -match '2 번  Could not preload')

# The same log, cut off mid-write: no Lua error, but the process died.
[IO.File]::WriteAllLines((Join-Path $lastRoot 'server_log.txt'), $healthy[0..7])
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rep2 = ($script:reportLines -join "`n")

Check 'a log that just stops is called out as a hard crash' ($rep2 -match '갑자기 끊겼')
Check 'and it says this is not a mod error'                 ($rep2 -match '모드 오류가 아니')

# A real one, taken from the crash this tool was written for.
$crash = @(
	'[00:00:03]: Loading mod: workshop-818739975 (Adshovel) Version:1.6',
	'[00:00:03]: Loading mod: workshop-1289779251 (Cherry Forest) Version:1.6.107',
	'[00:00:03]: DoLuaFile scripts/main.lua',
	'[00:03:52]: [string "../mods/workshop-818739975/modmain.lua"]:98: attempt to call global ''Point'' (a nil value)',
	'LUA ERROR stack traceback:',
	'    ../mods/workshop-818739975/modmain.lua:98 in (field) onfinish (Lua) <97-169>',
	'    ../mods/workshop-1289779251/postinit/components/workable.lua:51 in (method) WorkedBy (Lua) <29-52>',
	'    scripts/gamelogic.lua:636 in (upvalue) PopulateWorld (Lua) <368-664>',
	'[00:04:24]: Shutting down'
)
[IO.File]::WriteAllLines((Join-Path $lastRoot 'server_log.txt'), $crash)
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rep3 = ($script:reportLines -join "`n")

Check 'the real error line is the one reported' `
	($rep3 -match "attempt to call global 'Point'") $rep3
Check 'the mod that broke is named'        ($rep3 -match 'workshop-818739975\s+Adshovel')
Check 'the mod in the stack is named too'  ($rep3 -match 'workshop-1289779251\s+Cherry Forest')
Check 'the failing line is marked in the context' ($rep3 -match '>> \[00:03:52\]')

# DST writes the same content as server_log.txt and master_server_log.txt.
$twin = Join-Path $lastRoot 'master_server_log.txt'
Copy-Item -LiteralPath (Join-Path $lastRoot 'server_log.txt') -Destination $twin -Force
(Get-Item -LiteralPath $twin).LastWriteTimeUtc =
	(Get-Item -LiteralPath (Join-Path $lastRoot 'server_log.txt')).LastWriteTimeUtc

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rep4 = ($script:reportLines -join "`n")

# One reported log means one "걸린 줄" heading. The error text itself appears
# twice per log -- once as the heading, once inside the context block.
$reported = (@([regex]::Matches($rep4, '걸린 줄'))).Count
Check 'the same log under two names is reported once' ($reported -eq 1) ("reported " + $reported + " times")

Remove-Item -LiteralPath (Join-Path $sandbox 'last') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($stray in @('서버오류.txt')) {
	$f = Join-Path $package $stray
	if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

# ── cleanup ─────────────────────────────────────────────────────────────────
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
foreach ($stray in @('범인모드.txt', 'bisect_state.json')) {
	$f = Join-Path $package $stray
	if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}
$bk = Join-Path $package '_bisect_backup'
if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse -Force }

Write-Host ''
if ($failures -eq 0) {
	Write-Host 'ALL CHECKS PASSED'
	exit 0
} else {
	Write-Host ("{0} CHECK(S) FAILED" -f $failures)
	exit 1
}
