# test_patcher.ps1
#
# Exercises install / restore / report / collect in
# patch/templates/tools/patch.ps1 against a real copy of NPC Friends.
#
#   pwsh tests/test_patcher.ps1 -ModRoot <a pristine NPC Friends 3684000581 folder>
#
# Checks that installing adds exactly one hook, that installing twice is a
# no-op, that restoring gives back a byte-identical file both from the backup
# and by stripping the markers, that the "is this file stock?" report tells the
# three cases apart, and that collect produces a zip with what we asked for.

param(
	[Parameter(Mandatory = $true)][string]$ModRoot,
	[string]$Luac = 'luac5.1'
)

$ErrorActionPreference = 'Stop'

$repo    = Split-Path -Parent $PSScriptRoot
$package = Join-Path (Join-Path $repo 'build') 'NPC_HOF_Patch'
$script  = Join-Path (Join-Path $package 'tools') 'patch.ps1'

if (-not (Test-Path -LiteralPath $script)) {
	throw "build the package first: python3 patch/build.py  (missing $script)"
}

$Planner = Join-Path $ModRoot 'scripts/npc/npc_cooking_planner.lua'
if (-not (Test-Path -LiteralPath $Planner)) {
	throw "not an NPC Friends folder (no scripts/npc/npc_cooking_planner.lua): $ModRoot"
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

# ── a throwaway copy of the whole mod tree ──────────────────────────────────
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("npchof_test_" + [Guid]::NewGuid().ToString("N"))
$modDir  = Join-Path $sandbox '3684000581'
New-Item -ItemType Directory -Path $modDir -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $ModRoot 'scripts') -Destination $modDir -Recurse -Force
foreach ($extra in @('modinfo.lua')) {
	$src = Join-Path $ModRoot $extra
	if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $modDir -Force }
}

$npcDir      = Join-Path (Join-Path $modDir 'scripts') 'npc'
$plannerCopy = Join-Path $npcDir 'npc_cooking_planner.lua'
$added       = Join-Path $npcDir 'npc_hof_cooking.lua'
$pristine    = [IO.File]::ReadAllBytes($plannerCopy)

# Dot-source with the sandbox as the target folder, so nothing touches a real install.
$env:NPCHOF_DOTSOURCE_ONLY = '1'
. $script -ModFolder $modDir
$env:NPCHOF_DOTSOURCE_ONLY = $null

Write-Host ''
Write-Host '=== 1. install ==='
$ok = Install-One $modDir
Check 'install reports success' $ok
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
Write-Host '=== 3. the report tells stock from patched ==='
# Regression guard: PowerShell variable names are case-insensitive, so writing
# `$stock = $STOCK[$rel]` inside the loop silently destroys the lookup table
# and every file after the first reads as modified.
$reportText = (Build-Report) -join "`n"

Check 'planner reads as "stock + our one line"' `
	($reportText -match 'npc_cooking_planner\.lua\s+\d+ bytes\s+원본 \+ 우리 한 줄')
Check 'our file and hook are both reported present' `
	($reportText.Contains('npc_hof_cooking.lua 있음') -and $reportText.Contains('npc_cooking_planner.lua 안에 있음'))

foreach ($name in @('npc_tuning.lua', 'npc_commands.lua', 'npc_cooking_recipes.lua',
                    'npc_cooking_recipe_scorer.lua', 'npc_cooking_ingredient_finder.lua',
                    'npc_utils.lua', 'npc_item_config.lua')) {
	Check ("untouched file reads as stock: " + $name) `
		($reportText -match ([regex]::Escape($name) + '\s+\d+ bytes\s+원본 그대로'))
}

Write-Host ''
Write-Host '=== 4. a third-party edit is reported as such ==='
$tuning = Join-Path (Join-Path $modDir 'scripts') 'npc_tuning.lua'
Add-Content -LiteralPath $tuning -Value "`n-- pretend another patch edited this file`n"
$reportText2 = (Build-Report) -join "`n"
Check 'edited file reads as "modified by another patch"' `
	($reportText2 -match 'npc_tuning\.lua\s+\d+ bytes\s+다른 패치가 고침')

Write-Host ''
Write-Host '=== 5. collect produces a zip with what we asked for ==='
Invoke-Collect | Out-Null

$zips = @(Get-ChildItem -LiteralPath $package -Filter 'NPC_HOF_수집_*.zip' -ErrorAction SilentlyContinue)
Check 'a zip was produced' ($zips.Count -ge 1) ("count=" + $zips.Count)

if ($zips.Count -ge 1) {
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$zip = [IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
	try {
		$names = $zip.Entries | ForEach-Object { $_.FullName }
		Check 'zip carries the report' (($names -join '|').Contains('진단결과.txt'))
		foreach ($want in @('npc_cooking_planner.lua', 'npc_hof_cooking.lua', 'npc_tuning.lua', 'warly.lua')) {
			Check ("zip carries " + $want) (($names -join '|').Contains($want))
		}
	} finally { $zip.Dispose() }

	foreach ($z in $zips) { Remove-Item -LiteralPath $z.FullName -Force }
}

Write-Host ''
Write-Host '=== 6. collectmods keeps code and leaves the assets behind ==='
# A mod folder is mostly animation, texture and sound data. Sending all of it is
# gigabytes and answers nothing, so only code may travel -- and every mod has to
# appear in the listing either way.
$modsRoot = Join-Path $sandbox 'allmods'
foreach ($m in @('1111111111', '2222222222')) {
	$dir = Join-Path $modsRoot $m
	New-Item -ItemType Directory -Path (Join-Path $dir 'scripts') -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $dir 'anim') -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $dir 'images') -Force | Out-Null

	[IO.File]::WriteAllText((Join-Path $dir 'modinfo.lua'),
		"name = `"Test Mod $m`"`nversion = `"1.2.3`"`napi_version = 10`nclient_only_mod = false`n" +
		"configuration_options =`n{`n`t{ name = `"not_the_mod_name`" },`n}`n")
	[IO.File]::WriteAllText((Join-Path $dir 'modmain.lua'), "-- code $m`n")
	[IO.File]::WriteAllText((Join-Path (Join-Path $dir 'scripts') 'thing.lua'), "return {}`n")

	# the bulk: assets that must not travel
	[IO.File]::WriteAllBytes((Join-Path (Join-Path $dir 'anim') 'big.zip'), (New-Object byte[] 400000))
	[IO.File]::WriteAllBytes((Join-Path (Join-Path $dir 'images') 'atlas.tex'), (New-Object byte[] 400000))
	[IO.File]::WriteAllText((Join-Path (Join-Path $dir 'images') 'atlas.xml'), "<Atlas/>`n")
}

Invoke-CollectMods $modsRoot | Out-Null

$modZips = @(Get-ChildItem -LiteralPath $package -Filter 'DST_모드코드_*.zip' -ErrorAction SilentlyContinue)
Check 'a mod-code zip was produced' ($modZips.Count -ge 1) ("count=" + $modZips.Count)

if ($modZips.Count -ge 1) {
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$z = [IO.Compression.ZipFile]::OpenRead($modZips[0].FullName)
	try {
		$names = @($z.Entries | ForEach-Object { $_.FullName })
		$all   = $names -join '|'

		Check 'both mods contributed code' `
			($all.Contains('mod_1111111111/modmain.lua') -and $all.Contains('mod_2222222222/scripts/thing.lua'))
		Check 'the listing is there' ($all.Contains('모드목록.txt'))
		Check 'animation data stayed behind' (-not ($all -match '\.zip\||anim/'))
		Check 'textures stayed behind' (-not $all.Contains('.tex'))
		Check 'the images folder stayed behind, xml and all' (-not $all.Contains('images/'))
		Check 'zip entries use forward slashes' (-not $all.Contains('\'))

		$listing = ''
		$entry = $z.Entries | Where-Object { $_.FullName -eq '모드목록.txt' }
		if ($entry) {
			$reader = New-Object IO.StreamReader($entry.Open(), (New-Object Text.UTF8Encoding($true)))
			try { $listing = $reader.ReadToEnd() } finally { $reader.Dispose() }
		}
		Check 'the listing names the mod, not a config option' `
			($listing.Contains('Test Mod 1111111111') -and -not $listing.Contains('not_the_mod_name'))
		Check 'the listing reports the real on-disk size' ($listing -match '전체 \d+ 파일 / 0\.[0-9] MB')
	} finally { $z.Dispose() }

	foreach ($zz in $modZips) { Remove-Item -LiteralPath $zz.FullName -Force }
}

Write-Host ''
Write-Host '=== 7. restore from backup ==='
$ok = Restore-One $modDir
Check 'restore reports success' $ok
Check 'added file was removed' (-not (Test-Path -LiteralPath $added))
Check 'planner is byte-identical to the original' `
	(-not (Compare-Object $pristine ([IO.File]::ReadAllBytes($plannerCopy)) -SyncWindow 0))

Write-Host ''
Write-Host '=== 8. restore with no backup (marker stripping) ==='
Install-One $modDir | Out-Null
Get-ChildItem -LiteralPath (Join-Path $package '_backup') -File | Remove-Item -Force
$ok = Restore-One $modDir
Check 'restore reports success without a backup' $ok
Check 'planner is byte-identical after stripping markers' `
	(-not (Compare-Object $pristine ([IO.File]::ReadAllBytes($plannerCopy)) -SyncWindow 0))

Write-Host ''
Write-Host '=== 9. a planner without the expected return is refused ==='
[IO.File]::WriteAllText($plannerCopy, "local X = {}`nreturn X`n")
$ok = Install-One $modDir
Check 'refuses to guess when the file shape is unknown' (-not $ok)

Write-Host ''
Write-Host '=== 10. modcheck: which mod is the problem ==='

# A miniature mod library that contains every collision modcheck looks for.
$mcRoot = Join-Path $sandbox 'mods'
$klei   = Join-Path $sandbox 'Klei/DoNotStarveTogether'
New-Item -ItemType Directory -Force -Path (Join-Path $klei 'Cluster_1/Master') | Out-Null

function New-FakeMod($id, $info, $code) {
	$dir = Join-Path $mcRoot ('workshop-' + $id)
	New-Item -ItemType Directory -Force -Path $dir | Out-Null
	[IO.File]::WriteAllText((Join-Path $dir 'modinfo.lua'), $info)
	[IO.File]::WriteAllText((Join-Path $dir 'modmain.lua'), $code)
}

$wxHeavy = (1..25 | ForEach-Object { "defs.AddNewModuleDefinition(M$_)" }) -join "`n"
$wxSmall = (1..20 | ForEach-Object { "defs.AddNewModuleDefinition(E$_)" }) -join "`n"

New-FakeMod '900000001' "name = `"WX Heavy`"`nversion = `"1.0`"`napi_version = 10" $wxHeavy
New-FakeMod '900000002' "name = `"WX Small`"`nversion = `"1.0`"`napi_version = 10" $wxSmall
New-FakeMod '900000003' "name = `"Error Hijacker`"`nversion = `"1.0`"`napi_version = 10" 'SetGlobalErrorWidget(msg)'
New-FakeMod '900000004' "name = `"Chesty`"`nversion = `"1.0`"`napi_version = 10" @'
AddComponentPostInit("container", function(self) end)
AddPrefabPostInit("treasurechest", function(inst) end)
AddCookerRecipe("cookpot", { name = "stew_a", test = function() end })
'@
New-FakeMod '900000005' "name = `"Foody`"`nversion = `"1.0`"`napi_version = 10" @'
AddCookerRecipe("cookpot", { name = "stew_a", test = function() end })
AddCookerRecipe("cookpot", { name = "stew_b", test = function() end })
AddRecipe("oldstyle", {})
'@
New-FakeMod '900000006' "name = `"Clientside`"`nversion = `"1.0`"`napi_version = 6`nclient_only_mod = true" 'print("hi")'

[IO.File]::WriteAllText((Join-Path $klei 'Cluster_1/modoverrides.lua'), @'
return {
  ["workshop-900000001"] = { enabled = true },
  ["workshop-900000002"] = { enabled = false },
  ["workshop-900000003"] = { enabled = true },
  ["workshop-900000004"] = { enabled = true },
  ["workshop-900000005"] = { enabled = true },
  ["workshop-900000007"] = { enabled = true },
}
'@)

[IO.File]::WriteAllText((Join-Path $klei 'Cluster_1/Master/server_log.txt'), @'
[00:00:04]: Loading mod: workshop-900000001 (WX Heavy) Version:1.0
[00:00:05]: MOD ERROR: workshop-900000005 (Foody)
    ../mods/workshop-900000003/gemscripts/tools/dynamictilemanager.lua(188,1) in function 'error'
'@)

# Get-KleiRoots builds Windows-shaped paths; point it at the sandbox instead.
function Get-KleiRoots { @($klei) }

$state = Get-EnabledMods
Check 'modoverrides: enabled mod is read as on'  ($state['900000001'] -eq $true)
Check 'modoverrides: disabled mod is read as off' ($state['900000002'] -eq $false)
Check 'modoverrides: a mod with no folder is still listed' ($state.ContainsKey('900000007'))

$blamed = Get-ModBlameFromLogs
Check 'logs: MOD ERROR names the mod'            ($blamed.ContainsKey('900000005'))
Check 'logs: a stack frame names the mod'        ($blamed.ContainsKey('900000003'))
Check 'logs: an innocent mod is not blamed'      (-not $blamed.ContainsKey('900000001'))

$code = Measure-ModCode (Join-Path $mcRoot 'workshop-900000001')
Check 'code: WX-78 registrations are counted'    ($code.Hits['wx78'] -eq 25) ("got " + $code.Hits['wx78'])

$code4 = Measure-ModCode (Join-Path $mcRoot 'workshop-900000004')
Check 'code: container hook is seen'             ($code4.Hits['container'] -ge 1)
Check 'code: chest prefab hook is seen'          ($code4.Hits['chest'] -ge 1)
Check 'code: crock pot dish name is captured'    ($code4.CookRecipes -contains 'stew_a')

$code5 = Measure-ModCode (Join-Path $mcRoot 'workshop-900000005')
Check 'code: deprecated AddRecipe is seen'       ($code5.Hits['oldapi'] -ge 1)
Check 'code: AddRecipe2 is not counted as old'   ($code5.Hits['oldapi'] -eq 1) ("got " + $code5.Hits['oldapi'])

# The whole report. 45 WX modules are installed but only 25 are switched on,
# so the budget must come out under the limit, not over it.
$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-ModCheck $mcRoot | Out-Null
$text = ($script:reportLines -join "`n")

Check 'report: counts only the mods that are switched on' `
	($text -match '개수: 약 25 개') 'expected 25, not 45'
Check 'report: says the budget is fine when it is' `
	($text -match '자리 남았습니다')
Check 'report: names the mod the log blamed' `
	($text -match 'workshop-900000005[\s\S]{0,200}MOD ERROR')
Check 'report: flags the error-handler hijacker' `
	($text -match 'workshop-900000003')
Check 'report: reports the duplicated dish name' `
	($text -match 'stew_a')
Check 'report: reports a mod enabled but not installed' `
	($text -match 'workshop-900000007')
Check 'report: marks the switched-off mod as off' `
	($text -match 'workshop-900000002\s+10\s+-')
Check 'report: does not blame the disabled WX mod' `
	(-not ($text -match 'workshop-900000002\s+약'))

# ...and with that mod switched on, the same library must trip the limit.
[IO.File]::WriteAllText((Join-Path $klei 'Cluster_1/modoverrides.lua'),
	((Get-Content -LiteralPath (Join-Path $klei 'Cluster_1/modoverrides.lua') -Raw) `
		-replace '"workshop-900000002"\] = \{ enabled = false', '"workshop-900000002"] = { enabled = true'))

$script:reportLines = New-Object System.Collections.Generic.List[string]
Invoke-ModCheck $mcRoot | Out-Null
$text2 = ($script:reportLines -join "`n")
Check 'report: over the WX-78 limit is reported as a startup failure' `
	($text2 -match '개수: 약 45 개' -and $text2 -match '모자랍니다')

foreach ($stray in @('모드점검.txt')) {
	$f = Join-Path $package $stray
	if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

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
