# test_patcher.ps1
#
# Exercises the install / restore logic in patch/templates/tools/patch.ps1
# against a real copy of NPC Friends' npc_cooking_planner.lua.
#
#   pwsh tests/test_patcher.ps1 -Planner <path to a pristine npc_cooking_planner.lua>
#
# Checks that installing adds exactly one hook, that installing twice is a
# no-op, that restoring from the backup gives back a byte-identical file, and
# that restoring by marker-stripping does too when the backup is gone.

param(
	[Parameter(Mandatory = $true)][string]$Planner,
	[string]$Luac = 'luac5.1'
)

$ErrorActionPreference = 'Stop'

$repo    = Split-Path -Parent $PSScriptRoot
$package = Join-Path (Join-Path $repo 'build') 'NPC_HOF_Patch'
$script  = Join-Path (Join-Path $package 'tools') 'patch.ps1'

if (-not (Test-Path -LiteralPath $script)) {
	throw "build the package first: python3 patch/build.py  (missing $script)"
}
if (-not (Test-Path -LiteralPath $Planner)) {
	throw "no such planner file: $Planner"
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

# ── a throwaway copy of the mod tree ────────────────────────────────────────
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("npchof_test_" + [Guid]::NewGuid().ToString("N"))
$modDir  = Join-Path $sandbox '3684000581'
$npcDir  = Join-Path (Join-Path $modDir 'scripts') 'npc'
New-Item -ItemType Directory -Path $npcDir -Force | Out-Null

$plannerCopy = Join-Path $npcDir 'npc_cooking_planner.lua'
Copy-Item -LiteralPath $Planner -Destination $plannerCopy -Force

$pristine = [IO.File]::ReadAllBytes($plannerCopy)

$env:NPCHOF_DOTSOURCE_ONLY = '1'
. $script
$env:NPCHOF_DOTSOURCE_ONLY = $null

# The dot-sourced script computed its paths from its own location, which is
# exactly what we want: it reads files/npc_hof_cooking.lua out of the package.
Write-Host ''
Write-Host '=== 1. install ==='
$ok = Install-One $modDir
Check 'install reports success' $ok

$added = Join-Path $npcDir 'npc_hof_cooking.lua'
Check 'npc_hof_cooking.lua was copied in' (Test-Path -LiteralPath $added)

$patched = [IO.File]::ReadAllText($plannerCopy)
Check 'hook line was inserted' ($patched -match [regex]::Escape('require("npc/npc_hof_cooking")'))
Check 'begin marker present' ($patched.Contains('[NPC_HOF_PATCH_BEGIN]'))
Check 'end marker present'   ($patched.Contains('[NPC_HOF_PATCH_END]'))

$hookCount = ([regex]::Matches($patched, [regex]::Escape('require("npc/npc_hof_cooking")'))).Count
Check 'exactly one hook' ($hookCount -eq 1) "count=$hookCount"

$returnIdx = $patched.LastIndexOf('return CookingPlanner')
$hookIdx   = $patched.IndexOf('require("npc/npc_hof_cooking")')
Check 'hook sits before the final return' ($hookIdx -lt $returnIdx) "hook=$hookIdx return=$returnIdx"

Check 'no BOM was introduced' (([IO.File]::ReadAllBytes($plannerCopy))[0] -ne 0xEF)

# ── both files must still be valid Lua 5.1 ──────────────────────────────────
foreach ($f in @($plannerCopy, $added)) {
	$out = & $Luac -p $f 2>&1
	Check ("still parses as Lua 5.1: " + (Split-Path -Leaf $f)) ($LASTEXITCODE -eq 0) ($out -join ' ')
}

Write-Host ''
Write-Host '=== 2. install twice is a no-op ==='
$before = [IO.File]::ReadAllBytes($plannerCopy)
Install-One $modDir | Out-Null
$after = [IO.File]::ReadAllBytes($plannerCopy)
Check 'second install leaves the file untouched' (-not (Compare-Object $before $after -SyncWindow 0))

Write-Host ''
Write-Host '=== 3. restore from backup ==='
$ok = Restore-One $modDir
Check 'restore reports success' $ok
Check 'added file was removed' (-not (Test-Path -LiteralPath $added))
Check 'planner is byte-identical to the original' `
	(-not (Compare-Object $pristine ([IO.File]::ReadAllBytes($plannerCopy)) -SyncWindow 0))

Write-Host ''
Write-Host '=== 4. restore with no backup (marker stripping) ==='
Install-One $modDir | Out-Null
Get-ChildItem -LiteralPath (Join-Path $package '_backup') -File | Remove-Item -Force
$ok = Restore-One $modDir
Check 'restore reports success without a backup' $ok
Check 'planner is byte-identical after stripping markers' `
	(-not (Compare-Object $pristine ([IO.File]::ReadAllBytes($plannerCopy)) -SyncWindow 0))

Write-Host ''
Write-Host '=== 5. a planner without the expected return is refused ==='
$broken = Join-Path $npcDir 'npc_cooking_planner.lua'
[IO.File]::WriteAllText($broken, "local X = {}`nreturn X`n")
$ok = Install-One $modDir
Check 'refuses to guess when the file shape is unknown' (-not $ok)

# ── cleanup ─────────────────────────────────────────────────────────────────
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
$bk = Join-Path $package '_backup'
if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse -Force }

Write-Host ''
if ($failures -eq 0) {
	Write-Host 'ALL CHECKS PASSED'
	exit 0
} else {
	Write-Host ("{0} CHECK(S) FAILED" -f $failures)
	exit 1
}
