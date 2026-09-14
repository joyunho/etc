# patch.ps1
#
#   NPC Friends x Heap of Foods - 요리 연동 패치
#
#   install.bat / restore.bat 이 이 파일을 부릅니다. 직접 실행할 필요는 없습니다.
#
#   하는 일은 두 가지뿐입니다.
#     1. files\npc_hof_cooking.lua 를 NPC Friends 의 scripts\npc\ 에 복사
#     2. scripts\npc\npc_cooking_planner.lua 의 마지막 return 바로 앞에
#        그 파일을 부르는 한 줄을 추가
#
#   기존 파일은 이 한 줄 말고는 전혀 바뀌지 않고, 원본은 _backup 에 보관됩니다.
#
#   Windows PowerShell 5.1 (윈도우 기본 내장) 에서 동작하도록 작성했습니다.

param(
	[ValidateSet('install', 'restore', 'diagnose', 'collect', 'collectmods')]
	[string]$Action = 'install',

	# 자동 탐색이 실패할 때 폴더를 직접 지정할 수 있습니다.
	#   collect.bat "D:\Steam\steamapps\workshop\content\322330\3684000581"
	[string]$ModFolder = ''
)

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ══════════════════════════════════════════════════════════════════════════════
#  상수
# ══════════════════════════════════════════════════════════════════════════════

$MODID    = '3684000581'
$LUA_NAME = 'npc_hof_cooking.lua'
$PLANNER  = 'npc_cooking_planner.lua'

$MARK_BEGIN = '-- [NPC_HOF_PATCH_BEGIN] NPC Friends x Heap of Foods'
$MARK_END   = '-- [NPC_HOF_PATCH_END]'
$HOOK_LINE  = 'pcall(function() require("npc/npc_hof_cooking").Install(CookingPlanner) end)'

$PackageRoot = Split-Path -Parent $PSScriptRoot
$SourceLua   = Join-Path (Join-Path $PackageRoot 'files') $LUA_NAME
$BackupRoot  = Join-Path $PackageRoot '_backup'

# ══════════════════════════════════════════════════════════════════════════════
#  출력
# ══════════════════════════════════════════════════════════════════════════════

function Write-Head($text) {
	Write-Host ''
	Write-Host '=========================================================='
	Write-Host ("  " + $text)
	Write-Host '=========================================================='
	Write-Host ''
}

function Write-Ok   ($t) { Write-Host ("    [완료] " + $t) -ForegroundColor Green }
function Write-Info ($t) { Write-Host ("    [확인] " + $t) -ForegroundColor Gray  }
function Write-Warn ($t) { Write-Host ("    [주의] " + $t) -ForegroundColor Yellow }
function Write-Fail ($t) { Write-Host ("    [실패] " + $t) -ForegroundColor Red   }

# ══════════════════════════════════════════════════════════════════════════════
#  Steam / 모드 폴더 찾기
# ══════════════════════════════════════════════════════════════════════════════

function Get-SteamLibraries {
	$libs  = New-Object System.Collections.Generic.List[string]
	$roots = New-Object System.Collections.Generic.List[string]

	foreach ($probe in @(
		@{ Path = 'HKCU:\Software\Valve\Steam';                Name = 'SteamPath'   },
		@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam';    Name = 'InstallPath' },
		@{ Path = 'HKLM:\SOFTWARE\Valve\Steam';                Name = 'InstallPath' }
	)) {
		try {
			$value = (Get-ItemProperty -Path $probe.Path -Name $probe.Name -ErrorAction Stop).($probe.Name)
			if ($value) { $roots.Add(($value -replace '/', '\')) }
		} catch { }
	}

	$roots.Add('C:\Program Files (x86)\Steam')
	$roots.Add('C:\Program Files\Steam')

	foreach ($root in $roots) {
		# 존재하지 않는 드라이브나 이상한 경로 하나 때문에 전체가 멈추면 안 됩니다.
		try {
			if ([string]::IsNullOrWhiteSpace($root)) { continue }

			$root = $root.TrimEnd('\')
			if (-not $libs.Contains($root)) { $libs.Add($root) }

			$vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
			if (Test-Path -LiteralPath $vdf) {
				$text = Get-Content -Raw -LiteralPath $vdf
				foreach ($m in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
					$lib = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
					if ($lib -and -not $libs.Contains($lib)) { $libs.Add($lib) }
				}
			}
		} catch { }
	}

	return $libs
}

function Test-ModFolder($path) {
	try {
		if ([string]::IsNullOrWhiteSpace($path)) { return $false }
		return (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $path 'scripts') 'npc') $PLANNER))
	} catch { return $false }
}

function Get-ModFolders {
	$found = New-Object System.Collections.Generic.List[string]

	if (-not [string]::IsNullOrWhiteSpace($ModFolder)) {
		if (Test-ModFolder $ModFolder) {
			$found.Add($ModFolder.TrimEnd('\'))
			return $found
		}
		Write-Fail ('직접 지정하신 폴더에 scripts\npc\' + $PLANNER + ' 이 없습니다: ' + $ModFolder)
		return $found
	}

	$relative = @(
		('steamapps\workshop\content\322330\' + $MODID),
		("steamapps\common\Don't Starve Together\mods\workshop-" + $MODID),
		("steamapps\common\Don't Starve Together Dedicated Server\mods\workshop-" + $MODID)
	)

	foreach ($lib in (Get-SteamLibraries)) {
		foreach ($rel in $relative) {
			try {
				$candidate = Join-Path $lib $rel
				if ((Test-ModFolder $candidate) -and -not $found.Contains($candidate)) {
					$found.Add($candidate)
				}
			} catch { }
		}

		# 이름을 바꿔 넣은 로컬 설치본까지 훑어봅니다.
		$modsDirs = @()
		try {
			$modsDirs = @(
				(Join-Path $lib "steamapps\common\Don't Starve Together\mods"),
				(Join-Path $lib "steamapps\common\Don't Starve Together Dedicated Server\mods")
			)
		} catch { $modsDirs = @() }

		foreach ($modsDir in $modsDirs) {
			try {
				if (-not (Test-Path -LiteralPath $modsDir)) { continue }
				foreach ($sub in (Get-ChildItem -LiteralPath $modsDir -Directory -ErrorAction Stop)) {
					if ((Test-ModFolder $sub.FullName) -and -not $found.Contains($sub.FullName)) {
						$found.Add($sub.FullName)
					}
				}
			} catch { }
		}
	}

	return $found
}

# ══════════════════════════════════════════════════════════════════════════════
#  파일 읽기 / 쓰기 (원본 인코딩과 줄바꿈을 그대로 보존)
# ══════════════════════════════════════════════════════════════════════════════

function Read-LuaFile($path) {
	$bytes  = [System.IO.File]::ReadAllBytes($path)
	$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
	$offset = if ($hasBom) { 3 } else { 0 }

	$encoding = New-Object System.Text.UTF8Encoding($hasBom)
	$text     = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)

	return [pscustomobject]@{
		Text     = $text
		Encoding = $encoding
		HasBom   = $hasBom
		NewLine  = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
	}
}

function Write-LuaFile($path, $file, $text) {
	$out = New-Object System.Collections.Generic.List[byte]
	if ($file.HasBom) { $out.AddRange($file.Encoding.GetPreamble()) }
	$out.AddRange($file.Encoding.GetBytes($text))
	[System.IO.File]::WriteAllBytes($path, $out.ToArray())
}

function Get-BackupPath($modFolder) {
	$key = ($modFolder -replace '[^A-Za-z0-9]', '_')
	if ($key.Length -gt 80) { $key = $key.Substring($key.Length - 80) }
	return (Join-Path $BackupRoot ($key + '__' + $PLANNER + '.bak'))
}

# ══════════════════════════════════════════════════════════════════════════════
#  설치
# ══════════════════════════════════════════════════════════════════════════════

function Install-One($modFolder) {
	Write-Host ('  대상: ' + $modFolder)

	$npcDir      = Join-Path (Join-Path $modFolder 'scripts') 'npc'
	$plannerPath = Join-Path $npcDir $PLANNER
	$targetLua   = Join-Path $npcDir $LUA_NAME

	# 1) 원본 백업 (최초 1회만, 이미 패치된 파일은 백업하지 않습니다)
	$backupPath = Get-BackupPath $modFolder
	if (-not (Test-Path -LiteralPath $backupPath)) {
		$current = Read-LuaFile $plannerPath
		if ($current.Text.Contains($MARK_BEGIN)) {
			Write-Info '이미 패치된 파일이라 백업을 새로 만들지 않습니다'
		} else {
			if (-not (Test-Path -LiteralPath $BackupRoot)) {
				New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
			}
			Copy-Item -LiteralPath $plannerPath -Destination $backupPath -Force
			Write-Ok ('원본 백업 -> _backup\' + (Split-Path -Leaf $backupPath))
		}
	} else {
		Write-Info '백업이 이미 있습니다'
	}

	# 2) 새 파일 복사
	Copy-Item -LiteralPath $SourceLua -Destination $targetLua -Force
	Write-Ok ('scripts\npc\' + $LUA_NAME + ' 복사')

	# 3) planner 에 연결 한 줄 추가
	$file = Read-LuaFile $plannerPath

	if ($file.Text.Contains($MARK_BEGIN)) {
		Write-Info '연결 코드가 이미 들어 있습니다'
		return $true
	}

	$hits = [regex]::Matches($file.Text, '(?m)^[ \t]*return[ \t]+CookingPlanner[ \t]*\r?$')
	if ($hits.Count -eq 0) {
		Write-Fail ($PLANNER + ' 의 형식이 예상과 다릅니다 (return CookingPlanner 를 찾지 못함)')
		Write-Fail 'NPC Friends 가 업데이트된 것 같습니다. 알려 주시면 맞춰 드릴게요.'
		return $false
	}

	$last = $hits[$hits.Count - 1]
	$nl   = $file.NewLine

	# 삽입하는 줄바꿈 수와 restore 의 정규식이 정확히 대칭이어야
	# 백업 없이 되돌려도 원본과 바이트 단위로 같아집니다.
	$block = $nl + $MARK_BEGIN + $nl + $HOOK_LINE + $nl + $MARK_END + $nl
	$text  = $file.Text.Substring(0, $last.Index) + $block + $file.Text.Substring($last.Index)

	Write-LuaFile $plannerPath $file $text
	Write-Ok ($PLANNER + ' 에 한 줄 추가')

	return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  되돌리기
# ══════════════════════════════════════════════════════════════════════════════

function Restore-One($modFolder) {
	Write-Host ('  대상: ' + $modFolder)

	$npcDir      = Join-Path (Join-Path $modFolder 'scripts') 'npc'
	$plannerPath = Join-Path $npcDir $PLANNER
	$targetLua   = Join-Path $npcDir $LUA_NAME

	# 1) 추가했던 파일 삭제
	if (Test-Path -LiteralPath $targetLua) {
		Remove-Item -LiteralPath $targetLua -Force
		Write-Ok ($LUA_NAME + ' 삭제')
	} else {
		Write-Info ($LUA_NAME + ' 이 이미 없습니다')
	}

	# 2) planner 원복 - 백업이 있으면 백업으로, 없으면 추가한 줄만 지웁니다
	$backupPath = Get-BackupPath $modFolder

	if (Test-Path -LiteralPath $backupPath) {
		Copy-Item -LiteralPath $backupPath -Destination $plannerPath -Force
		Write-Ok ($PLANNER + ' 을 백업본으로 되돌림')
		return $true
	}

	$file = Read-LuaFile $plannerPath
	if (-not $file.Text.Contains($MARK_BEGIN)) {
		Write-Info ($PLANNER + ' 은 이미 원래 상태입니다')
		return $true
	}

	$pattern = '(?s)\r?\n?' + [regex]::Escape($MARK_BEGIN) + '.*?' + [regex]::Escape($MARK_END) + '\r?\n?'
	$text    = [regex]::Replace($file.Text, $pattern, '')

	Write-LuaFile $plannerPath $file $text
	Write-Ok ($PLANNER + ' 에서 추가한 줄 제거')

	return $true
}

# ══════════════════════════════════════════════════════════════════════════════
#  진입점
# ══════════════════════════════════════════════════════════════════════════════


# ══════════════════════════════════════════════════════════════════════════════
#  진단 - 지금 설치된 상태를 통째로 뽑아서 텍스트 파일로 저장
# ══════════════════════════════════════════════════════════════════════════════

# NPC Friends v0.3.5 창작마당 원본의 지문. 파일이 손대지 않은 원본인지 판별합니다.
$STOCK = @{
	'scripts\npc\npc_cooking_planner.lua'           = @{ Size = 10570;  Hash = 'BD25B09A39AB8C82' }
	'scripts\npc\npc_cooking_recipe_scorer.lua'     = @{ Size = 7845;   Hash = 'C64646CEAF5FC6F4' }
	'scripts\npc\npc_cooking_recipes.lua'           = @{ Size = 34935;  Hash = 'B1D20F4FAF9AE031' }
	'scripts\npc\npc_cooking_ingredient_finder.lua' = @{ Size = 26362;  Hash = '1278CBE4CB271A7F' }
	'scripts\npc_tuning.lua'                        = @{ Size = 113904; Hash = '28B79D5B45A3B438' }
	'scripts\npc_commands.lua'                      = @{ Size = 55752;  Hash = '23B7C3B08393CABD' }
	'scripts\npc\npc_utils.lua'                     = @{ Size = 7980;   Hash = 'F70921D71E14F1FD' }
	'scripts\npc\npc_item_config.lua'               = @{ Size = 24328;  Hash = 'E3A166C72462D3A6' }
}

$script:reportLines = New-Object System.Collections.Generic.List[string]

function Add-Line($text) { $script:reportLines.Add([string]$text); Write-Host $text }

function Get-ShortHash($bytes) {
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try {
		return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)
	} finally { $sha.Dispose() }
}

# 우리가 넣은 블록을 뺀 상태의 지문. "원본 + 우리 한 줄" 과 "다른 패치" 를 구분합니다.
function Get-HashWithoutOurBlock($path) {
	$file = Read-LuaFile $path
	$pattern = '(?s)\r?\n?' + [regex]::Escape($MARK_BEGIN) + '.*?' + [regex]::Escape($MARK_END) + '\r?\n?'
	$clean = [regex]::Replace($file.Text, $pattern, '')
	return (Get-ShortHash ([System.Text.Encoding]::UTF8.GetBytes($clean))), $clean.Length
}

# DST 가 로그와 세이브를 두는 곳. OneDrive 로 옮겨진 문서 폴더까지 봅니다.
function Get-KleiRoots {
	$roots = New-Object System.Collections.Generic.List[string]

	$candidates = @()
	try { $candidates += [Environment]::GetFolderPath('MyDocuments') } catch { }
	if ($env:USERPROFILE) {
		$candidates += (Join-Path $env:USERPROFILE 'Documents')
		$candidates += (Join-Path $env:USERPROFILE 'OneDrive\Documents')
		$candidates += (Join-Path $env:USERPROFILE '문서')
	}

	foreach ($c in $candidates) {
		try {
			if ([string]::IsNullOrWhiteSpace($c)) { continue }
			$root = Join-Path $c 'Klei\DoNotStarveTogether'
			if ((Test-Path -LiteralPath $root) -and -not $roots.Contains($root)) { $roots.Add($root) }
		} catch { }
	}

	return $roots
}

function Get-DstLogs {
	$logs = New-Object System.Collections.Generic.List[string]

	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Include 'client_log.txt', 'server_log.txt' -ErrorAction SilentlyContinue)) {
				if (-not $logs.Contains($f.FullName)) { $logs.Add($f.FullName) }
			}
		} catch { }
	}

	return $logs
}

function Build-Report {
	$script:reportLines = New-Object System.Collections.Generic.List[string]
	Add-Line ''
	Add-Line '=========================================================='
	Add-Line '  NPC Friends 요리 상태 진단'
	Add-Line ("  " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
	Add-Line '=========================================================='

	$folders = Get-ModFolders
	Add-Line ''
	Add-Line ("[모드 폴더]  " + $folders.Count + " 곳")

	if ($folders.Count -eq 0) {
		Add-Line '  NPC Friends 를 찾지 못했습니다. 구독 후 DST 를 한 번 실행했는지 확인해 주세요.'
	}

	foreach ($folder in $folders) {
		Add-Line ''
		Add-Line ("  " + $folder)

		$npcDir = Join-Path (Join-Path $folder 'scripts') 'npc'

		# 우리 패치가 들어가 있는가
		$added = Join-Path $npcDir $LUA_NAME
		if (Test-Path -LiteralPath $added) {
			Add-Line '    [우리 패치] npc_hof_cooking.lua 있음'
			try {
				$text = [IO.File]::ReadAllText($added)
				foreach ($key in @('enabled', 'variety', 'budget', 'same_dish_max', 'allow_negative', 'explain', 'debug')) {
					$m = [regex]::Match($text, ('(?m)^\s*' + $key + '\s*=\s*([^,\r\n]+)'))
					if ($m.Success) { Add-Line ('      ' + $key.PadRight(15) + '= ' + $m.Groups[1].Value.Trim()) }
				}
			} catch { Add-Line ('      설정을 읽지 못했습니다: ' + $_.Exception.Message) }
		} else {
			Add-Line '    [우리 패치] npc_hof_cooking.lua 없음  <- 설치가 안 되어 있습니다'
		}

		$plannerPath = Join-Path $npcDir $PLANNER
		if (Test-Path -LiteralPath $plannerPath) {
			$hasHook = ([IO.File]::ReadAllText($plannerPath)).Contains($MARK_BEGIN)
			Add-Line ('    [연결 코드] npc_cooking_planner.lua 안에 ' + $(if ($hasHook) { '있음' } else { '없음  <- 연결이 안 되어 있습니다' }))
		}

		# 파일별로 원본인지 아닌지
		Add-Line '    [파일 상태]'
		foreach ($rel in ($STOCK.Keys | Sort-Object)) {
			$full = Join-Path $folder $rel
			$name = Split-Path -Leaf $rel

			if (-not (Test-Path -LiteralPath $full)) {
				Add-Line ('      ' + $name.PadRight(38) + '없음')
				continue
			}

			$bytes = [IO.File]::ReadAllBytes($full)
			$hash  = Get-ShortHash $bytes
			$size  = $bytes.Length
			# 주의: PowerShell 은 변수 이름의 대소문자를 구분하지 않습니다.
			# 여기서 $stock 을 쓰면 $STOCK 해시 테이블 자체를 덮어써 버립니다.
			$expected = $STOCK[$rel]
			$verdict = '다른 패치가 고침'

			if ($hash -eq $expected.Hash) {
				$verdict = '원본 그대로'
			} elseif ($rel -like '*npc_cooking_planner.lua') {
				$clean, $cleanLen = Get-HashWithoutOurBlock $full
				if ($clean -eq $expected.Hash) { $verdict = '원본 + 우리 한 줄' }
			}

			Add-Line ('      ' + $name.PadRight(38) + $size.ToString().PadLeft(7) + ' bytes  ' + $verdict)
		}
	}

	# ── 로그에서 요리 관련 줄만 뽑기 ────────────────────────────────────────
	Add-Line ''
	Add-Line '[로그에서 뽑은 요리 관련 줄]'

	$logs = Get-DstLogs

	if ($logs.Count -eq 0) {
		Add-Line '  로그 파일을 찾지 못했습니다.'
	}

	$wanted = '\[NPCF-HOF\]|\[Cooking\]|\[CookingPlanner\]|烹饪|NPCCookingBehavior|npc_hof_cooking'

	foreach ($log in $logs) {
		try {
			$hits = Select-String -LiteralPath $log -Pattern $wanted -Encoding UTF8 -ErrorAction Stop |
				Select-Object -Last 120
		} catch { continue }

		Add-Line ''
		Add-Line ('  --- ' + $log + '  (' + $hits.Count + ' 줄) ---')
		if ($hits.Count -eq 0) {
			Add-Line '    (요리 관련 줄이 없습니다. USER_SETTINGS 의 debug 를 true 로 바꾸고 다시 해보세요)'
		}
		foreach ($h in $hits) { Add-Line ('    ' + $h.Line.Trim()) }
	}

	return $script:reportLines
}

# ══════════════════════════════════════════════════════════════════════════════
#  개인정보 가리기 - 로그와 경로에 계정 이름이나 아이디가 섞여 나갑니다
# ══════════════════════════════════════════════════════════════════════════════

function Protect-Text($text) {
	if ([string]::IsNullOrEmpty($text)) { return $text }
	$t = $text

	foreach ($name in @($env:USERNAME, $env:USERDOMAIN)) {
		if (-not [string]::IsNullOrWhiteSpace($name) -and $name.Length -ge 3) {
			$t = $t -replace [regex]::Escape($name), '<USER>'
		}
	}

	$t = $t -replace 'KU_[A-Za-z0-9_\-]{4,}', 'KU_<가림>'
	$t = $t -replace '(?i)(token|password|passwd|session|secret|api[_-]?key)(\s*[=:]\s*)\S+', '$1$2<가림>'
	$t = $t -replace '\b\d{17}\b', '<스팀ID>'

	return $t
}

function Invoke-Diagnose {
	$lines = Build-Report

	$out = Join-Path $PackageRoot '진단결과.txt'
	$saved = $false
	try {
		[IO.File]::WriteAllText($out, (Protect-Text ($lines -join "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
		$saved = $true
	} catch {
		Write-Host ('파일로 저장하지 못했습니다: ' + $_.Exception.Message) -ForegroundColor Red
	}

	if ($saved) {
		Write-Host ''
		Write-Host ('저장했습니다: ' + $out) -ForegroundColor Green
		Write-Host '이 파일을 그대로 보내 주시면 됩니다.' -ForegroundColor Green
		# 메모장이 안 열려도 파일은 이미 저장되어 있습니다.
		try { Start-Process notepad.exe $out } catch { }
	}
}

# ══════════════════════════════════════════════════════════════════════════════
#  수집 - 필요한 파일만 골라 담아 zip 하나로 만듭니다
# ══════════════════════════════════════════════════════════════════════════════

# 요리 문제를 보려면 이 파일들이면 충분합니다. 나머지는 담지 않습니다.
$COLLECT_FILES = @(
	'modinfo.lua',
	'scripts\npc_tuning.lua',
	'scripts\npc_commands.lua',
	'scripts\npc\npc_cooking_planner.lua',
	'scripts\npc\npc_cooking_recipe_scorer.lua',
	'scripts\npc\npc_cooking_ingredient_finder.lua',
	'scripts\npc\npc_cooking_recipes.lua',
	'scripts\npc\npc_hof_cooking.lua',
	'scripts\npc\npc_utils.lua',
	'scripts\npc\characters\warly.lua'
)

function Invoke-Collect {
	Write-Head '요리 문제 자료 모으기'

	$stamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
	$staging = Join-Path ([IO.Path]::GetTempPath()) ('npchof_collect_' + $stamp)

	New-Item -ItemType Directory -Path $staging -Force | Out-Null

	# 1) 상태 보고서
	Write-Host '상태를 살펴보는 중...'
	Write-Host ''
	$lines = Build-Report
	[IO.File]::WriteAllText((Join-Path $staging '진단결과.txt'),
		(Protect-Text ($lines -join "`r`n")), (New-Object System.Text.UTF8Encoding($true)))

	# 2) 모드 파일
	$folders = Get-ModFolders
	$copied  = 0
	$index   = 0

	foreach ($folder in $folders) {
		$index = $index + 1
		$dest  = Join-Path $staging ('mod' + $index)

		[IO.File]::WriteAllText((Join-Path $staging ('mod' + $index + '_경로.txt')),
			(Protect-Text $folder), (New-Object System.Text.UTF8Encoding($true)))

		foreach ($rel in $COLLECT_FILES) {
			$src = Join-Path $folder $rel
			if (-not (Test-Path -LiteralPath $src)) { continue }
			try {
				$target = Join-Path $dest $rel
				$dir    = Split-Path -Parent $target
				if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
				Copy-Item -LiteralPath $src -Destination $target -Force
				$copied = $copied + 1
				Write-Ok $rel
			} catch {
				Write-Fail ($rel + ' : ' + $_.Exception.Message)
			}
		}
	}

	# 3) 로그에서 요리 관련 줄만
	$logDir = Join-Path $staging 'logs'
	New-Item -ItemType Directory -Path $logDir -Force | Out-Null

	$wanted = '\[NPCF-HOF\]|\[Cooking\]|\[CookingPlanner\]|烹饪|npc_hof_cooking|NPCCookingBehavior|\[string "\.\.\./npc'
	$logCount = 0

	foreach ($log in (Get-DstLogs)) {
		try {
			$hits = Select-String -LiteralPath $log -Pattern $wanted -Encoding UTF8 -ErrorAction Stop |
				Select-Object -Last 400
		} catch { continue }
		if ($hits.Count -eq 0) { continue }

		$logCount = $logCount + 1
		$name = 'log' + $logCount + '_' + (Split-Path -Leaf $log)
		$body = (Protect-Text $log) + "`r`n" + ('-' * 60) + "`r`n" +
			(Protect-Text (($hits | ForEach-Object { $_.Line.Trim() }) -join "`r`n"))
		[IO.File]::WriteAllText((Join-Path $logDir $name), $body, (New-Object System.Text.UTF8Encoding($true)))
		Write-Ok ('로그 ' + $name + ' (' + $hits.Count + ' 줄)')
	}

	# 4) 어떤 모드를 켜고 있는지
	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Include 'modoverrides.lua' -ErrorAction SilentlyContinue |
					Select-Object -First 4)) {
				$rel = 'mods_' + ($f.FullName -replace '[^A-Za-z0-9]', '_')
				if ($rel.Length -gt 60) { $rel = $rel.Substring($rel.Length - 60) }
				Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $staging ($rel + '.lua')) -Force
				Write-Ok ('켜져 있는 모드 목록: ' + $f.Name)
			}
		} catch { }
	}

	# 5) 압축
	$zip = Join-Path $PackageRoot ('NPC_HOF_수집_' + $stamp + '.zip')

	try {
		if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
		# Compress-Archive writes backslashes as the entry separator, which the
		# zip format does not allow and many extractors turn into one long file
		# name. CreateFromDirectory writes '/' the way it should.
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
	} catch {
		Write-Fail ('압축에 실패했습니다: ' + $_.Exception.Message)
		Write-Host ('모아 둔 폴더를 직접 압축해 주세요: ' + $staging)
		return
	}

	try { Remove-Item -LiteralPath $staging -Recurse -Force } catch { }

	$size = 0
	try { $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB) } catch { }

	Write-Head '다 모았습니다'
	Write-Host ('  파일 ' + $copied + '개 + 로그 ' + $logCount + '개')
	Write-Host ''
	Write-Host ('  ' + $zip) -ForegroundColor Green
	Write-Host ('  (' + $size + ' KB)')
	Write-Host ''
	Write-Host '  이 zip 파일 하나만 그대로 보내 주시면 됩니다.'
	Write-Host '  계정 이름과 스팀 ID 같은 것은 <가림> 으로 바꿔서 담았습니다.'
	Write-Host ''

	try { Start-Process explorer.exe ('/select,"' + $zip + '"') } catch { }
}


# ══════════════════════════════════════════════════════════════════════════════
#  전체 모드 수집 - 설치된 모드의 "코드"만 골라 담습니다
# ══════════════════════════════════════════════════════════════════════════════
#
#  모드 폴더를 통째로 담으면 수 GB 입니다. 대부분은 애니메이션(.zip), 텍스처(.tex),
#  사운드(.fsb/.fev) 같은 에셋이고, 문제를 보는 데는 쓸모가 없습니다.
#  그래서 lua 같은 코드 파일만 담고, 나머지는 목록으로만 정리합니다.

$CODE_EXTENSIONS = @('.lua', '.json', '.xml', '.txt', '.md', '.po', '.ini', '.cfg')

# 통째로 건너뛸 폴더 (에셋 전용)
$SKIP_DIRS = @('anim', 'sound', 'bigportraits', 'images', 'exported', 'minimap',
               'levels\textures', 'levels\tiles', '.git')

# 한 파일이 이보다 크면 코드라도 건너뜁니다 (보통 자동 생성된 데이터).
$MAX_FILE_BYTES = 3MB

# 담은 코드 전체가 이보다 커지면 거기서 멈추고, 남은 모드는 목록으로만 남깁니다.
$MAX_TOTAL_BYTES = 120MB

function Get-AllModFolders($override) {
	$found = New-Object System.Collections.Generic.List[object]

	if ([string]::IsNullOrWhiteSpace($override)) { $override = $ModFolder }

	# 직접 지정한 경우: 모드 폴더 하나이거나, 모드 폴더들이 들어 있는 폴더.
	#   collectmods.bat "D:\Steam\steamapps\workshop\content\322330"
	if (-not [string]::IsNullOrWhiteSpace($override)) {
		try {
			$root = $override.TrimEnd('\', '/')

			if (Test-Path -LiteralPath (Join-Path $root 'modinfo.lua')) {
				$found.Add([pscustomobject]@{ Path = $root; Id = (Split-Path -Leaf $root); Root = (Split-Path -Parent $root) })
				return $found
			}

			foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
				if (Test-Path -LiteralPath (Join-Path $dir.FullName 'modinfo.lua')) {
					$found.Add([pscustomobject]@{ Path = $dir.FullName; Id = $dir.Name; Root = $root })
				}
			}
		} catch {
			Write-Fail ('직접 지정하신 폴더를 읽지 못했습니다: ' + $override)
		}

		return $found
	}

	foreach ($lib in (Get-SteamLibraries)) {
		$roots = @()
		try {
			$roots = @(
				(Join-Path $lib 'steamapps\workshop\content\322330'),
				(Join-Path $lib "steamapps\common\Don't Starve Together\mods"),
				(Join-Path $lib "steamapps\common\Don't Starve Together Dedicated Server\mods")
			)
		} catch { continue }

		foreach ($root in $roots) {
			try {
				if (-not (Test-Path -LiteralPath $root)) { continue }

				foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
					# modinfo.lua 가 있어야 모드입니다.
					if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'modinfo.lua'))) { continue }
					if ($found | Where-Object { $_.Path -eq $dir.FullName }) { continue }

					$found.Add([pscustomobject]@{
						Path = $dir.FullName
						Id   = $dir.Name
						Root = $root
					})
				}
			} catch { }
		}
	}

	return $found
}

# modinfo.lua 에서 이름과 버전만 살짝 긁어옵니다 (lua 를 실행하지는 않습니다).
function Read-ModInfo($modPath) {
	$info = [pscustomobject]@{ Name = ''; Version = ''; Api = ''; ClientOnly = '' }

	try {
		$text = [IO.File]::ReadAllText((Join-Path $modPath 'modinfo.lua'))

		# 반드시 줄 맨 앞(들여쓰기 없음)에서 찾습니다. 들여쓴 name= 은
		# configuration_options 안의 설정 이름이라 모드 이름이 아닙니다.
		foreach ($pair in @(
			@{ Key = 'Version';    Pattern = '(?m)^version\s*=\s*"([^"]{1,40})"' },
			@{ Key = 'Api';        Pattern = '(?m)^api_version\s*=\s*(\d+)' },
			@{ Key = 'ClientOnly'; Pattern = '(?m)^client_only_mod\s*=\s*(\w+)' }
		)) {
			$m = [regex]::Match($text, $pair.Pattern)
			if ($m.Success) { $info.($pair.Key) = $m.Groups[1].Value }
		}

		# 이름은 여러 모양으로 쓰입니다:
		#   name = "My Mod"
		#   name = is_chinese and "중국어" or "English"      <- 마지막 것을 씁니다
		#   name = ChooseTranslationTable(STRINGS.NAME)      <- 글자가 없으니 비워 둡니다
		$line = [regex]::Match($text, '(?m)^name\s*=\s*(.+)$')
		if ($line.Success) {
			$quoted = [regex]::Matches($line.Groups[1].Value, '"([^"]{1,120})"')
			if ($quoted.Count -gt 0) {
				$info.Name = $quoted[$quoted.Count - 1].Groups[1].Value
			}
		}
	} catch { }

	return $info
}

function Test-SkippedPath($relative) {
	foreach ($skip in $SKIP_DIRS) {
		if ($relative -eq $skip -or $relative.StartsWith($skip + '\')) { return $true }
	}
	return $false
}

function Invoke-CollectMods($root) {
	Write-Head '설치된 모드의 코드 모으기'

	Write-Host '모드를 찾는 중...'
	$mods = Get-AllModFolders $root

	if ($mods.Count -eq 0) {
		Write-Fail '설치된 DST 모드를 하나도 찾지 못했습니다.'
		Write-Host '  Steam 이 기본 위치가 아니면, 모드가 들어 있는 폴더를 이 파일 위로 드래그해 주세요.'
		Write-Host ''
		return
	}

	Write-Host ("모드 " + $mods.Count + " 개를 찾았습니다.")
	Write-Host ''

	$stamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
	$staging = Join-Path ([IO.Path]::GetTempPath()) ('npchof_mods_' + $stamp)
	New-Item -ItemType Directory -Path $staging -Force | Out-Null

	$listing = New-Object System.Collections.Generic.List[string]
	$listing.Add('설치된 DST 모드 목록')
	$listing.Add((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
	$listing.Add('')
	$listing.Add('코드 파일(.lua 등)만 담았습니다. 애니메이션/텍스처/사운드는 제외했습니다.')
	$listing.Add('')

	$totalCopied = 0
	$totalFiles  = 0
	$omitted     = New-Object System.Collections.Generic.List[string]
	$index       = 0

	foreach ($mod in ($mods | Sort-Object Id)) {
		$index = $index + 1
		$info  = Read-ModInfo $mod.Path

		# 에셋까지 포함한 전체 크기 (참고용)
		$allBytes = 0
		$allFiles = 0
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $mod.Path -Recurse -File -ErrorAction SilentlyContinue)) {
				$allBytes = $allBytes + $f.Length
				$allFiles = $allFiles + 1
			}
		} catch { }

		$label = $mod.Id
		if ($info.Name) { $label = $mod.Id + '  ' + $info.Name }

		$listing.Add(('[' + $index + '] ' + $label))
		$listing.Add(('     버전 ' + $(if ($info.Version) { $info.Version } else { '?' }) +
			'   api ' + $(if ($info.Api) { $info.Api } else { '?' }) +
			'   client_only ' + $(if ($info.ClientOnly) { $info.ClientOnly } else { '?' })))
		$listing.Add(('     전체 ' + $allFiles + ' 파일 / ' + [math]::Round($allBytes / 1MB, 1) + ' MB'))
		$listing.Add(('     ' + (Protect-Text $mod.Path)))

		if ($totalCopied -ge $MAX_TOTAL_BYTES) {
			$listing.Add('     -> 용량 한계로 코드는 담지 않았습니다 (목록만)')
			$listing.Add('')
			$omitted.Add($label)
			continue
		}

		$dest    = Join-Path $staging ('mod_' + $mod.Id)
		$copied  = 0
		$bytes   = 0

		try {
			foreach ($file in (Get-ChildItem -LiteralPath $mod.Path -Recurse -File -ErrorAction SilentlyContinue)) {
				if ($CODE_EXTENSIONS -notcontains $file.Extension.ToLower()) { continue }
				if ($file.Length -gt $MAX_FILE_BYTES) { continue }

				$relative = $file.FullName.Substring($mod.Path.Length).TrimStart('\', '/').Replace('/', '\')
				$dir      = Split-Path -Parent $relative
				if ($dir -and (Test-SkippedPath $dir)) { continue }

				$target    = Join-Path $dest $relative
				$targetDir = Split-Path -Parent $target
				if (-not (Test-Path -LiteralPath $targetDir)) {
					New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
				}

				Copy-Item -LiteralPath $file.FullName -Destination $target -Force
				$copied = $copied + 1
				$bytes  = $bytes + $file.Length
			}
		} catch {
			$listing.Add(('     -> 읽는 중 오류: ' + $_.Exception.Message))
		}

		$totalCopied = $totalCopied + $bytes
		$totalFiles  = $totalFiles + $copied

		$listing.Add(('     -> 코드 ' + $copied + ' 파일 / ' + [math]::Round($bytes / 1MB, 2) + ' MB 담음'))
		$listing.Add('')

		Write-Host ("  [" + $index + "/" + $mods.Count + "] " + $label + "  (코드 " + $copied + " 파일)")
	}

	# 어떤 모드를 켜고 있는지 + 그 설정
	$overrides = 0
	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Filter 'modoverrides.lua' -ErrorAction SilentlyContinue |
					Select-Object -First 6)) {
				$overrides = $overrides + 1
				Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $staging ('modoverrides_' + $overrides + '.lua')) -Force
			}
		} catch { }
	}
	$listing.Add(('켜져 있는 모드 설정 파일(modoverrides.lua): ' + $overrides + ' 개'))

	[IO.File]::WriteAllText((Join-Path $staging '모드목록.txt'),
		(Protect-Text ($listing -join "`r`n")), (New-Object System.Text.UTF8Encoding($true)))

	# ── 압축 ───────────────────────────────────────────────────────────────
	$zip = Join-Path $PackageRoot ('DST_모드코드_' + $stamp + '.zip')

	try {
		if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
	} catch {
		Write-Fail ('압축에 실패했습니다: ' + $_.Exception.Message)
		Write-Host ('모아 둔 폴더를 직접 압축해 주세요: ' + $staging)
		return
	}

	try { Remove-Item -LiteralPath $staging -Recurse -Force } catch { }

	$size = 0
	try { $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1) } catch { }

	Write-Head '다 모았습니다'
	Write-Host ('  모드 ' + $mods.Count + ' 개 / 코드 ' + $totalFiles + ' 파일')
	Write-Host ''
	Write-Host ('  ' + $zip) -ForegroundColor Green
	Write-Host ('  ' + $size + ' MB')
	Write-Host ''

	if ($omitted.Count -gt 0) {
		Write-Warn ('용량 한계로 ' + $omitted.Count + ' 개 모드는 목록만 담았습니다:')
		foreach ($name in ($omitted | Select-Object -First 8)) { Write-Host ('    - ' + $name) }
		Write-Host ''
	}

	if ($size -gt 45) {
		Write-Warn '파일이 큽니다. 한 번에 못 보내시면 알려 주세요 - 모드를 나눠 담는 방법을 드리겠습니다.'
		Write-Host ''
	}

	Write-Host '  이 zip 파일 하나만 보내 주시면 됩니다.'
	Write-Host '  애니메이션/텍스처/사운드는 빼고 코드만 담았고,'
	Write-Host '  계정 이름과 스팀 ID 는 <가림> 으로 바꿨습니다.'
	Write-Host ''

	try { Start-Process explorer.exe ('/select,"' + $zip + '"') } catch { }
}

if ($env:NPCHOF_DOTSOURCE_ONLY -eq '1') { return }

if ($Action -eq 'diagnose') {
	Invoke-Diagnose
	exit 0
}

if ($Action -eq 'collect') {
	Invoke-Collect
	exit 0
}

if ($Action -eq 'collectmods') {
	Invoke-CollectMods
	exit 0
}

if ($Action -eq 'install') {
	Write-Head 'NPC Friends x Heap of Foods - 요리 연동 패치 설치'
} else {
	Write-Head 'NPC Friends x Heap of Foods - 원래대로 되돌리기'
}

if ($Action -eq 'install' -and -not (Test-Path -LiteralPath $SourceLua)) {
	Write-Fail ($LUA_NAME + ' 을 찾지 못했습니다.')
	Write-Fail 'zip 압축을 완전히 푼 뒤, 풀린 폴더 안의 install.bat 을 실행해 주세요.'
	Write-Host ''
	exit 1
}

Write-Host 'NPC Friends 모드 폴더를 찾는 중...'
Write-Host ''

$folders = Get-ModFolders

if ($folders.Count -eq 0) {
	Write-Fail 'NPC Friends 모드 폴더를 찾지 못했습니다.'
	Write-Host ''
	Write-Host '  확인해 주세요:'
	Write-Host '    1) 창작마당에서 NPC Friends (3684000581) 를 구독했는지'
	Write-Host '    2) 구독 후 DST 를 한 번 실행해서 실제로 내려받아졌는지'
	Write-Host '    3) Steam 이 기본 위치가 아닌 다른 드라이브에 설치되어 있다면,'
	Write-Host '       그 폴더의 steamapps\workshop\content\322330\3684000581 이'
	Write-Host '       존재하는지'
	Write-Host ''
	exit 1
}

$done = 0
foreach ($folder in $folders) {
	try {
		$ok = if ($Action -eq 'install') { Install-One $folder } else { Restore-One $folder }
		if ($ok) { $done = $done + 1 }
	} catch {
		Write-Fail $_.Exception.Message
		Write-Fail 'DST 를 완전히 종료한 뒤, install.bat 을 마우스 오른쪽 클릭 -> 관리자 권한으로 실행해 보세요.'
	}
	Write-Host ''
}

if ($Action -eq 'install') {
	Write-Head ('설치 완료 - ' + $done + ' / ' + $folders.Count + ' 곳')
	Write-Host '  다음 순서로 확인하세요:'
	Write-Host '    1. DST 를 완전히 종료했다가 다시 실행'
	Write-Host '    2. Heap of Foods 와 NPC Friends 를 둘 다 켠 채로 월드 접속'
	Write-Host '    3. 왈리 NPC 에게 냄비와 아이스박스를 지정하고 요리 시키기'
	Write-Host ''
	Write-Warn 'Steam 이 NPC Friends 를 업데이트하면 이 패치가 지워집니다.'
	Write-Warn '그때는 install.bat 을 다시 실행하면 됩니다.'
	Write-Host ''
	Write-Host '  되돌리려면 restore.bat 을 실행하세요.'
} else {
	Write-Head ('되돌리기 완료 - ' + $done + ' / ' + $folders.Count + ' 곳')
	Write-Host '  DST 를 완전히 종료했다가 다시 실행하세요.'
}

Write-Host ''
exit 0
