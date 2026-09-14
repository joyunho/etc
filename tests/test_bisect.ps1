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


Write-Host ''
Write-Host '=== 10. a log that dies with no Lua error names the heaviest mods ==='

$wRoot = Join-Path $sandbox 'weight/Klei/DoNotStarveTogether/Cluster_9/Master'
New-Item -ItemType Directory -Force -Path $wRoot | Out-Null
function Get-KleiRoots { @((Join-Path $sandbox 'weight/Klei/DoNotStarveTogether')) }

# A load that dies partway through registering content: no Lua error at all,
# which is what a hard crash during preload actually looks like.
$heavy = New-Object System.Collections.Generic.List[string]
$heavy.Add('[00:00:01]: DoLuaFile scripts/main.lua')
$heavy.Add('[00:00:03]: Loading mod: workshop-3383047161 (The Winterlands) Version:1.4.10')
$heavy.Add('[00:00:03]: Loading mod: workshop-2334209327 (Heap of Foods) Version:7.3-b')
$heavy.Add('[00:00:03]: Loading mod: workshop-501385076 (Quick Pick) Version:1.4.0')
foreach ($i in 1..400) { $heavy.Add('[00:00:58]: Mod: workshop-3383047161 (The Winterlands)	    chesspiece_' + $i + '_dryice') }
foreach ($i in 1..120) { $heavy.Add('[00:00:59]: Mod: workshop-2334209327 (Heap of Foods)	    kyno_dish_' + $i) }
foreach ($i in 1..5)   { $heavy.Add('[00:01:00]: Mod: workshop-501385076 (Quick Pick)	    qp_' + $i) }
foreach ($i in 1..30)  { $heavy.Add('[00:01:10]: Could not preload undefined prefab (ghost_' + $i + ')') }
[IO.File]::WriteAllLines((Join-Path $wRoot 'client_log.txt'), $heavy)

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rw = ($script:reportLines -join "`n")

Check 'no Lua error is invented' (-not ($rw -match '걸린 줄'))
Check 'the abrupt ending is reported' ($rw -match '갑자기 끊겼')
Check 'the heaviest mod is listed first' `
	($rw -match '400 줄[^\n]*workshop-3383047161[^\n]*The Winterlands') $rw
Check 'a light mod is not blamed by weight' `
	($rw -match '5 줄[^\n]*workshop-501385076')
Check 'the share of the total is shown' ($rw -match '76%|75%|74%')
Check 'it says what to switch off' ($rw -match '위에서부터 몇 개를 꺼')

# The same file, but ending cleanly: the weight table still helps, the
# "switch some off" advice does not apply.
$heavy.Add('[00:01:20]: Shutting down')
[IO.File]::WriteAllLines((Join-Path $wRoot 'client_log.txt'), $heavy)
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rw2 = ($script:reportLines -join "`n")

Check 'a clean ending is still reported as clean' ($rw2 -match '정상적으로 종료')
Check 'and it does not tell you to switch mods off' (-not ($rw2 -match '위에서부터 몇 개를 꺼'))
Check 'but the weight table is still there' ($rw2 -match 'workshop-3383047161')

# Two shards write server_log.txt under the same name; the folder tells them apart.
$caves = Join-Path $sandbox 'weight/Klei/DoNotStarveTogether/Cluster_9/Caves'
New-Item -ItemType Directory -Force -Path $caves | Out-Null
[IO.File]::WriteAllLines((Join-Path $wRoot 'server_log.txt'), @('[00:00:01]: master', '[00:00:02]: Shutting down'))
[IO.File]::WriteAllLines((Join-Path $caves 'server_log.txt'), @('[00:00:01]: caves side', '[00:00:02]: Shutting down'))

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-LastError | Out-Null
$rw3 = ($script:reportLines -join "`n")

Check 'the master log is labelled by its folder' ($rw3 -match 'Master\\server_log\.txt')
Check 'the caves log is labelled by its folder' ($rw3 -match 'Caves\\server_log\.txt')

Remove-Item -LiteralPath (Join-Path $sandbox 'weight') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($stray in @('서버오류.txt')) {
	$f = Join-Path $package $stray
	if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}


Write-Host ''
Write-Host '=== 11. collecttext picks out text and skips what is already Korean ==='

$tRoot = Join-Path $sandbox 'text'
$tKlei = Join-Path $sandbox 'textklei/Klei/DoNotStarveTogether/Cluster_1'
New-Item -ItemType Directory -Force -Path $tKlei | Out-Null
function Get-KleiRoots { @((Join-Path $sandbox 'textklei/Klei/DoNotStarveTogether')) }

function New-TextMod($id, $info) {
	$d = Join-Path $tRoot ('workshop-' + $id)
	New-Item -ItemType Directory -Force -Path $d | Out-Null
	[IO.File]::WriteAllText((Join-Path $d 'modinfo.lua'), $info, (New-Object Text.UTF8Encoding($false)))
	return $d
}

# A Chinese mod that ships proper .po files -- the safe case.
$m1 = New-TextMod '700000001' "name = `"主线拓展`"`nversion = `"1.0`"`napi_version = 10"
New-Item -ItemType Directory -Force -Path (Join-Path $m1 'languages') | Out-Null
[IO.File]::WriteAllText((Join-Path $m1 'languages/chinese.po'),
	"msgid `"STRINGS.NAMES.CE_WHEAT`"`nmsgstr `"小麦`"`n`nmsgid `"STRINGS.NAMES.CE_BREAD`"`nmsgstr `"面包`"`n",
	(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $m1 'languages/english.po'),
	"msgid `"STRINGS.NAMES.CE_WHEAT`"`nmsgstr `"Wheat`"`n`nmsgid `"STRINGS.NAMES.CE_BREAD`"`nmsgstr `"Bread`"`n",
	(New-Object Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path (Join-Path $m1 'anim') | Out-Null
[IO.File]::WriteAllText((Join-Path (Join-Path $m1 'anim') 'ignored.txt'), 'x')

# An English mod with its text hardcoded in lua -- the risky case.
$m2 = New-TextMod '700000002' "name = `"Large Chest`"`nversion = `"1.1.1`"`napi_version = 10"
[IO.File]::WriteAllText((Join-Path $m2 'modmain.lua'),
	"GLOBAL.STRINGS.NAMES.LARGECHEST = `"Large Chest`"`nGLOBAL.STRINGS.RECIPE_DESC.LARGECHEST = `"Holds more stuff.`"`n",
	(New-Object Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path (Join-Path $m2 'scripts') | Out-Null
[IO.File]::WriteAllText((Join-Path (Join-Path $m2 'scripts') 'nothing.lua'), 'local x = 1')

# Already Korean -- must be left alone.
$m3 = New-TextMod '700000003' "name = `"한글화 모드`"`nversion = `"1.0`"`napi_version = 10"
New-Item -ItemType Directory -Force -Path (Join-Path $m3 'languages') | Out-Null
[IO.File]::WriteAllText((Join-Path $m3 'languages/korean.po'),
	"msgid `"STRINGS.NAMES.THING`"`nmsgstr `"물건입니다. 한국어로 적혀 있습니다.`"`n",
	(New-Object Text.UTF8Encoding($false)))

# Switched off -- must be reported separately, not queued for translation.
$m4 = New-TextMod '700000004' "name = `"Disabled Mod`"`nversion = `"1.0`"`napi_version = 10"
[IO.File]::WriteAllText((Join-Path $m4 'modmain.lua'), "GLOBAL.STRINGS.NAMES.X = `"Something`"", (New-Object Text.UTF8Encoding($false)))

[IO.File]::WriteAllText((Join-Path $tKlei 'modoverrides.lua'), @'
return {
  ["workshop-700000001"] = { enabled = true },
  ["workshop-700000002"] = { enabled = true },
  ["workshop-700000003"] = { enabled = true },
  ["workshop-700000004"] = { enabled = false },
}
'@)

$score = Measure-TextScript '안녕하세요 반갑습니다'
Check 'Korean text is recognised as Korean' ((Get-DominantScript $score) -eq '한국어')
Check 'Chinese text is recognised as Chinese' `
	((Get-DominantScript (Measure-TextScript '小麦面包主线拓展')) -eq '중국어/일본어')
Check 'English text is recognised as English' `
	((Get-DominantScript (Measure-TextScript 'Large Chest holds more stuff')) -eq '영어')

$t1 = Measure-ModText $m1
Check 'po files are collected'          ((@($t1.Files | Where-Object { $_.Kind -eq 'po' })).Count -eq 2)
Check 'msgid entries are counted'       ($t1.Msgids -eq 4) ("got " + $t1.Msgids)
Check 'the po languages are listed'     ((($t1.PoLangs | Sort-Object) -join ',') -eq 'chinese,english') `
	(($t1.PoLangs | Sort-Object) -join ',')
Check 'a Chinese mod is not marked Korean' (-not $t1.HasKorean)

$t2 = Measure-ModText $m2
Check 'a lua file holding STRINGS is collected' `
	((@($t2.Files | Where-Object { $_.Relative -eq 'modmain.lua' })).Count -eq 1)
Check 'a lua file with no text is skipped' `
	((@($t2.Files | Where-Object { $_.Relative -like '*nothing.lua' })).Count -eq 0)
Check 'modinfo.lua is always collected' `
	((@($t2.Files | Where-Object { $_.Relative -eq 'modinfo.lua' })).Count -eq 1)

$t3 = Measure-ModText $m3
Check 'a korean.po marks the mod as done' ($t3.HasKorean)

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-CollectText $tRoot | Out-Null
$rt = ($script:reportLines -join "`n")

Check 'the Chinese mod is queued for translation' `
	($rt -match '(?s)번역이 필요한 모드.*700000001')
Check 'the English mod is queued too' `
	($rt -match '(?s)번역이 필요한 모드.*700000002')
Check 'the Korean mod is listed as done' `
	($rt -match '(?s)손댈 필요 없는 모드.*700000003')
Check 'the switched-off mod is set aside' `
	($rt -match '(?s)꺼져 있어서 뺀 모드.*700000004')
Check 'the report says how many need work' ($rt -match '번역이 필요한 것\s*:\s*2 개')

$zips = @(Get-ChildItem -LiteralPath $package -Filter 'DST_번역대상_*.zip' -ErrorAction SilentlyContinue)
Check 'a zip was produced' ($zips.Count -ge 1)
if ($zips.Count -ge 1) {
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$z = [IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
	try {
		$entries = @($z.Entries | ForEach-Object { $_.FullName })
		Check 'the zip carries the report'    (($entries | Where-Object { $_ -like '*번역대상.txt' }).Count -eq 1)
		Check 'the zip carries the po files'  (($entries | Where-Object { $_ -like '*chinese.po' }).Count -eq 1)
		Check 'the zip carries the lua text'  (($entries | Where-Object { $_ -like '*mod_700000002/modmain.lua' }).Count -eq 1)
		Check 'the zip leaves plain code out' (($entries | Where-Object { $_ -like '*nothing.lua' }).Count -eq 0)
		Check 'zip entries use forward slashes' ((@($entries | Where-Object { $_ -like '*\*' })).Count -eq 0) `
		($entries -join ' ')
	Check 'the zip really has folders, not flattened names' `
		((@($entries | Where-Object { $_ -like 'mod_*/*' })).Count -ge 3)
	} finally { $z.Dispose() }
	foreach ($zz in $zips) { Remove-Item -LiteralPath $zz.FullName -Force }
}

Remove-Item -LiteralPath $tRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $sandbox 'textklei') -Recurse -Force -ErrorAction SilentlyContinue


Write-Host ''
Write-Host '=== 12. korean: switch on the Korean that mods already ship ==='

$kRoot = Join-Path $sandbox 'ko'
$kKlei = Join-Path $sandbox 'koklei/Klei/DoNotStarveTogether/Cluster_1'
New-Item -ItemType Directory -Force -Path $kKlei | Out-Null
function Get-KleiRoots { @((Join-Path $sandbox 'koklei/Klei/DoNotStarveTogether')) }

function New-KoMod($id, $info, $extra) {
	$d = Join-Path $kRoot ('workshop-' + $id)
	New-Item -ItemType Directory -Force -Path $d | Out-Null
	$null = $d
	[IO.File]::WriteAllText((Join-Path $d 'modinfo.lua'), $info, (New-Object Text.UTF8Encoding($false)))
	if ($extra) { [IO.File]::WriteAllText((Join-Path $d 'strings_kr.lua'), $extra, (New-Object Text.UTF8Encoding($false))) }
	return $d
}

# The Heap of Foods shape: the option table is named, and the Korean entry is
# recognisable only by its data value because the description is a code lookup.
New-KoMod '800000001' @'
name = "Foods"
version = "1.0"
api_version = 10
local LANGUAGE_OPTIONS =
{
	{ description = STRINGS.SETTINGS.LANGUAGE.OPTS.en, data = false },
	{ description = STRINGS.SETTINGS.LANGUAGE.OPTS.zh, data = "zh" },
	{ description = STRINGS.SETTINGS.LANGUAGE.OPTS.kr, data = "kr" },
}
configuration_options =
{
	{ name = "LANGUAGE", label = LANGUAGE_LABEL, options = LANGUAGE_OPTIONS, default = false },
}
'@ $null

# The Show Me shape: options table written inline, starting on the next line.
New-KoMod '800000002' @'
name = "Show Me"
version = "1.0"
api_version = 10
configuration_options = {
 {
  name = "lang",
  label = "Language",
  options =
  {
   {description = "Auto", data = "auto"},
   {description = "kr", data = "kr", hover = "Korean"},
  },
  default = "auto",
 },
}
'@ $null

# Korean text on disk but no option to select it: the game language decides.
New-KoMod '800000003' "name = `"Manual`"`nversion = `"1.0`"`napi_version = 10" `
	"STRINGS.NAMES.X = `"한국어 문자열이 여기 잔뜩 들어 있습니다. 여든 자가 넘어야 세어집니다. 한국어 한국어 한국어 한국어 한국어 한국어 한국어 한국어 한국어 한국어 한국어 한국어 한국어`""

# Nothing Korean anywhere: this is the one that actually needs translating.
New-KoMod '800000004' "name = `"English Only`"`nversion = `"1.0`"`napi_version = 10" $null

[IO.File]::WriteAllText((Join-Path $kKlei 'modoverrides.lua'), @'
return {
  ["workshop-800000001"] = { enabled = true, configuration_options = { OTHER = 5 } },
  ["workshop-800000002"] = { enabled = true },
  ["workshop-800000003"] = { enabled = true },
  ["workshop-800000004"] = { enabled = true },
}
'@)

$o1 = Find-KoreanOption (Join-Path $kRoot 'workshop-800000001')
Check 'a named option table is resolved'     ($o1.Option -eq 'LANGUAGE' -and $o1.Value -eq 'kr') ($o1.Option + '=' + $o1.Value)
$o2 = Find-KoreanOption (Join-Path $kRoot 'workshop-800000002')
Check 'an inline option table is resolved'   ($o2.Option -eq 'lang' -and $o2.Value -eq 'kr') ($o2.Option + '=' + $o2.Value)
$o3 = Find-KoreanOption (Join-Path $kRoot 'workshop-800000003')
Check 'a mod with no language option is left alone' ($o3.Value -eq $null)

$ovr = Join-Path $kKlei 'modoverrides.lua'
$before = [IO.File]::ReadAllText($ovr)

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-SetKorean '' $kRoot | Out-Null
$rk = ($script:reportLines -join "`n")
$after = [IO.File]::ReadAllText($ovr)

Check 'the option is written into an existing config block' `
	($after -match 'LANGUAGE = "kr"') $after
Check 'the config it already had survives'  ($after -match 'OTHER = 5')
Check 'a config block is created when there was none' `
	($after -match '"workshop-800000002"\] = \{ configuration_options = \{ lang = "kr" \}')
Check 'enabled is never touched' `
	((@([regex]::Matches($after, 'enabled = true'))).Count -eq 4)
Check 'the mod with no option is not given one' (-not ($after -match '800000003"\] = \{ configuration_options'))

Check 'the report lists what was switched'   ($rk -match '(?s)한국어로 바꿨습니다.*800000001')
Check 'the manual ones are listed apart'     ($rk -match '(?s)설정으로는 못 켜는.*800000003')
Check 'the untranslated ones are listed apart' ($rk -match '(?s)한국어가 아예 없는.*800000004')

# Running twice must not double up.
Invoke-SetKorean '' $kRoot | Out-Null
$twice = [IO.File]::ReadAllText($ovr)
Check 'running it again changes nothing more' `
	((@([regex]::Matches($twice, 'LANGUAGE = "kr"'))).Count -eq 1) `
	("found " + (@([regex]::Matches($twice, 'LANGUAGE = "kr"'))).Count)

Invoke-SetKorean 'stop' $kRoot | Out-Null
Check 'stop restores the original file byte for byte' ([IO.File]::ReadAllText($ovr) -eq $before)

Remove-Item -LiteralPath $kRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $sandbox 'koklei') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($stray in @('한국어켜기.txt')) {
	$f = Join-Path $package $stray
	if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}
$kb = Join-Path $package '_korean_backup'
if (Test-Path -LiteralPath $kb) { Remove-Item -LiteralPath $kb -Recurse -Force }


Write-Host ''
Write-Host '=== 12b. korean check: report the settings without writing anything ==='

$cRoot = Join-Path $sandbox 'koc'
$cKlei = Join-Path $sandbox 'kocklei/Klei/DoNotStarveTogether/Cluster_1'
New-Item -ItemType Directory -Force -Path $cKlei | Out-Null
function Get-KleiRoots { @((Join-Path $sandbox 'kocklei/Klei/DoNotStarveTogether')) }

function New-CoMod($id, $info) {
	$d = Join-Path $cRoot ('workshop-' + $id)
	New-Item -ItemType Directory -Force -Path $d | Out-Null
	[IO.File]::WriteAllText((Join-Path $d 'modinfo.lua'), $info, (New-Object Text.UTF8Encoding($false)))
	return $d
}

# The Achievement & Level shape, down to the helpers it uses: every label is a
# lookup into a `language` table, the option table is inline, and the Korean
# entry is spelled out in English. It is `all_clients_require_mod`, which is the
# whole point -- the server decides this one for everybody.
New-CoMod '900000001' @'
local multilingual = {
	en = {
		["A"] = "Achievement & Level",
		["Language"] = "Language",
	},
	kr = {
		["A"] = "업적과 레벨",
		["Language"] = "언어",
	},
}
local language = ChooseTranslationTable and ChooseTranslationTable(multilingual) or multilingual.en
local function title(t) return { name = t, options = {{description = "", data = 0}}, default = 0 } end
name = language["A"]
version = "7.3.6"
api_version = 10
dst_compatible = true
all_clients_require_mod = true
configuration_options =
{
	title(language["GENERAL SETTINGS"]),
	{
		name = "LANGUAGE",
		label = language["Language"],
		options = {
			{description ="English", data = "en"},
			{description ="简体", data = "chs"},
			{description ="Korean", data = "kr"},
		},
		default = "en",
		hover = language["LanguageInfo"],
	},
}
'@

# A client-only mod: the server has no say, the player picks it in the menu.
New-CoMod '900000002' @'
name = "Client Thing"
version = "1.0"
api_version = 10
client_only_mod = true
configuration_options = {
	{ name = "language", label = "Language",
	  options = { {description = "English", data = "en"}, {description = "한국어", data = "kr"} },
	  default = "en" },
}
'@

[IO.File]::WriteAllText((Join-Path $cKlei 'modoverrides.lua'), @'
return {
  ["workshop-900000001"] = { enabled = true, configuration_options = { LANGUAGE = "en", REFUND = 0.85 } },
  ["workshop-900000002"] = { enabled = true, configuration_options = { language = "kr" } },
}
'@)

$cOvr    = Join-Path $cKlei 'modoverrides.lua'
$cBefore = [IO.File]::ReadAllText($cOvr)
$cFiles  = @(Get-ModoverrideFiles)

# The name of such a mod is not written out either: it is looked up in a table
# further up the same file. Reading it as "A" tells the player nothing.
Check 'a name looked up in a table is resolved' `
	((Read-ModInfo (Join-Path $cRoot 'workshop-900000001')).Name -eq 'Achievement & Level') `
	((Read-ModInfo (Join-Path $cRoot 'workshop-900000001')).Name)
Check 'a plain quoted name still wins' `
	((Read-ModInfo (Join-Path $cRoot 'workshop-900000002')).Name -eq 'Client Thing')

# The real modinfo shape must still give up its Korean option.
$c1 = Find-KoreanOption (Join-Path $cRoot 'workshop-900000001')
Check 'the Achievement & Level shape yields LANGUAGE = kr' `
	($c1.Option -eq 'LANGUAGE' -and $c1.Value -eq 'kr') ([string]$c1.Option + '=' + [string]$c1.Value)

# Who decides the value.
Check 'all_clients_require_mod reads as server-decided' `
	((Get-ModConfigOwner (Join-Path $cRoot 'workshop-900000001')) -eq 'shared')
Check 'client_only_mod reads as client-decided' `
	((Get-ModConfigOwner (Join-Path $cRoot 'workshop-900000002')) -eq 'client')

# Reading what is set right now.
Check 'the current value is read back'        ((Get-ModConfigOption $cFiles '900000001' 'LANGUAGE') -eq 'en')
Check 'a value that is already Korean is seen' ((Get-ModConfigOption $cFiles '900000002' 'language') -eq 'kr')
Check 'a missing option reads as nothing'      ((Get-ModConfigOption $cFiles '900000001' 'NOPE') -eq $null)
Check 'a non-string value is read too'         ((Get-ModConfigOption $cFiles '900000001' 'REFUND') -eq '0.85')

# check must not touch the file.
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-SetKorean 'check' $cRoot | Out-Null
$rc = ($script:reportLines -join "`n")

Check 'check leaves modoverrides.lua byte for byte' ([IO.File]::ReadAllText($cOvr) -eq $cBefore)
Check 'check makes no backup folder' (-not (Test-Path -LiteralPath (Join-Path $package '_korean_backup')))
Check 'check shows the value it would replace'  ($rc -match 'LANGUAGE : "en" -> "kr"') $rc
Check 'check marks the server-decided mod'      ($rc -match '서버 설정이 접속자에게도 내려감')
Check 'check lists the one already in Korean'   ($rc -match '(?s)이미 한국어로 되어 있는 모드.*900000002')
Check 'check names the file it looked at'       ($rc -match 'modoverrides\.lua')

# ...and then the real run does change it, from en to kr.
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-SetKorean '' $cRoot | Out-Null
$ra = ($script:reportLines -join "`n")
$cAfter = [IO.File]::ReadAllText($cOvr)

Check 'the run flips en to kr'            ($cAfter -match 'LANGUAGE = "kr"') $cAfter
Check 'the other settings survive'        ($cAfter -match 'REFUND = 0\.85')
Check 'the one already Korean is untouched' ((@([regex]::Matches($cAfter, 'language = "kr"'))).Count -eq 1)
Check 'the report says what it came from' ($ra -match 'LANGUAGE : "en" -> "kr"') $ra

# A mod that has no block in this cluster is reported, not silently skipped.
New-CoMod '900000003' @'
name = "Not On This Server"
version = "1.0"
api_version = 10
all_clients_require_mod = true
configuration_options = {
	{ name = "LANGUAGE", label = "Language",
	  options = { {description = "English", data = "en"}, {description = "Korean", data = "kr"} },
	  default = "en" },
}
'@
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-SetKorean '' $cRoot | Out-Null
$rb = ($script:reportLines -join "`n")
Check 'a mod missing from modoverrides.lua is listed' `
	($rb -match '(?s)modoverrides\.lua 에 블록이 없는 모드.*900000003') $rb

Invoke-SetKorean 'stop' $cRoot | Out-Null
Check 'stop puts the whole file back' ([IO.File]::ReadAllText($cOvr) -eq $cBefore)

Remove-Item -LiteralPath $cRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $sandbox 'kocklei') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($stray in @('한국어켜기.txt', '한국어상태.txt')) {
	$f = Join-Path $package $stray
	if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}
$cb = Join-Path $package '_korean_backup'
if (Test-Path -LiteralPath $cb) { Remove-Item -LiteralPath $cb -Recurse -Force }


Write-Host ''
Write-Host '=== 13. hangul: install the Korean patch into the game folder ==='

$steam = Join-Path $sandbox "steam"
$gameMods = Join-Path $steam "steamapps/common/Don't Starve Together/mods"
$srvMods  = Join-Path $steam "steamapps/common/Don't Starve Together Dedicated Server/mods"
New-Item -ItemType Directory -Force -Path $gameMods | Out-Null
New-Item -ItemType Directory -Force -Path $srvMods  | Out-Null

# A modsettings.lua the player already edited: it must survive untouched.
$theirs = "-- 내가 직접 적은 줄`r`nForceEnableMod(`"workshop-1234567890`")`r`n"
[IO.File]::WriteAllText((Join-Path $gameMods 'modsettings.lua'), $theirs)

function Get-SteamLibraries { @($steam) }

$folders = @(Get-DstModFolders)
Check 'only the game mods folder is used, not the server one' `
	($folders.Count -eq 1 -and $folders[0] -eq $gameMods) (($folders -join ' | '))

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Hangul '' | Out-Null

$dest = Join-Path $gameMods 'mod_korean_patch'
Check 'the mod folder was created'   (Test-Path -LiteralPath $dest)
Check 'modinfo.lua was copied'       (Test-Path -LiteralPath (Join-Path $dest 'modinfo.lua'))
Check 'modmain.lua was copied'       (Test-Path -LiteralPath (Join-Path $dest 'modmain.lua'))
Check 'a client-only mod is kept out of the server folder' `
	(-not (Test-Path -LiteralPath (Join-Path $srvMods 'mod_korean_patch')))

$ms = [IO.File]::ReadAllText((Join-Path $gameMods 'modsettings.lua'))
Check 'ForceEnableMod was written'   ($ms -match 'ForceEnableMod\("mod_korean_patch"\)')
Check "the player's own lines survive" ($ms -match 'workshop-1234567890' -and $ms -match '내가 직접 적은 줄')

# Running it twice must not stack the block up.
Invoke-Hangul '' | Out-Null
$ms2 = [IO.File]::ReadAllText((Join-Path $gameMods 'modsettings.lua'))
Check 'installing twice writes one entry, not two' `
	((@([regex]::Matches($ms2, 'ForceEnableMod\("mod_korean_patch"\)'))).Count -eq 1) `
	("found " + (@([regex]::Matches($ms2, 'ForceEnableMod\("mod_korean_patch"\)'))).Count)

# And the copied file must still be valid Lua after the round trip.
$copied = [IO.File]::ReadAllText((Join-Path $dest 'modmain.lua'))
Check 'the copied strings file is not empty' ($copied.Length -gt 10000) ([string]$copied.Length)
Check 'and it still carries Korean'          ($copied -match '[가-힣]')

Write-Host ''
Write-Host '--- and taking it back out ---'

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-Hangul 'stop' | Out-Null

Check 'the mod folder is gone'        (-not (Test-Path -LiteralPath $dest))
Check 'the server folder is still clean' (-not (Test-Path -LiteralPath (Join-Path $srvMods 'mod_korean_patch')))

$ms3 = [IO.File]::ReadAllText((Join-Path $gameMods 'modsettings.lua'))
Check 'ForceEnableMod was taken out'  (-not ($ms3 -match 'mod_korean_patch'))
Check "the player's own lines are still there" `
	($ms3 -match 'workshop-1234567890' -and $ms3 -match '내가 직접 적은 줄')

# Removing when nothing is installed must not fail or damage the file.
Invoke-Hangul 'stop' | Out-Null
Check 'removing twice is harmless' `
	([IO.File]::ReadAllText((Join-Path $gameMods 'modsettings.lua')) -match 'workshop-1234567890')

Remove-Item -LiteralPath $steam -Recurse -Force -ErrorAction SilentlyContinue

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
