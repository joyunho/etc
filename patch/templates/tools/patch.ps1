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
	[ValidateSet('install', 'restore', 'diagnose', 'collect', 'collectmods', 'lasterror', 'modcheck', 'bisect')]
	[string]$Action = 'install',

	# 자동 탐색이 실패할 때 폴더를 직접 지정할 수 있습니다.
	#   collect.bat "D:\Steam\steamapps\workshop\content\322330\3684000581"
	[string]$ModFolder = '',

	# bisect 에서만 씁니다: stop 을 주면 모드 설정을 원래대로 되돌립니다.
	[string]$Arg = ''
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

# 로그 파일 이름인지 판정합니다.
#   server_log.txt / client_log.txt / caves_server_log.txt
#   server_log_2026-09-15-00-19-33.txt (백업본)
function Test-LogName($name) {
	return ($name -match '(?i)^[a-z0-9_\-]*log[a-z0-9_\-]*\.txt$')
}

# 주의: Get-ChildItem -LiteralPath ... -Include 를 쓰면 안 됩니다.
# Windows PowerShell 5.1 에서는 -Include 가 통째로 무시되어 Klei 폴더의
# 모든 파일(server.ini, modconfiguration_* 까지)이 로그로 딸려 옵니다.
# 이름은 직접 걸러야 합니다.
function Get-DstLogs {
	$logs = New-Object System.Collections.Generic.List[string]

	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
				if (-not (Test-LogName $f.Name)) { continue }
				if (-not $logs.Contains($f.FullName)) { $logs.Add($f.FullName) }
			}
		} catch { }
	}

	return $logs
}

# 같은 로그가 여러 번 잡히는 일이 있습니다. 문서 폴더와 OneDrive\문서 폴더가
# 같은 파일을 비추고 있으면 경로가 달라서 걸러지지 않습니다.
# 이름과 크기와 수정 시각이 모두 같으면 같은 파일로 봅니다.
function Select-DistinctLogs($items) {
	$seen = @{}
	$out  = New-Object System.Collections.Generic.List[object]

	foreach ($f in $items) {
		$key = ($f.Name + '|' + $f.Length + '|' + $f.LastWriteTimeUtc.Ticks)
		if ($seen.ContainsKey($key)) { continue }
		$seen[$key] = $true
		$out.Add($f)
	}

	return $out
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
				return (Resolve-DuplicateMods $found)
			}

			foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
				if (Test-Path -LiteralPath (Join-Path $dir.FullName 'modinfo.lua')) {
					$found.Add([pscustomobject]@{ Path = $dir.FullName; Id = $dir.Name; Root = $root })
				}
			}
		} catch {
			Write-Fail ('직접 지정하신 폴더를 읽지 못했습니다: ' + $override)
		}

		return (Resolve-DuplicateMods $found)
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

					$found.Add([pscustomobject]@{
						Path = $dir.FullName
						Id   = $dir.Name
						Root = $root
					})
				}
			} catch { }
		}
	}

	return (Resolve-DuplicateMods $found)
}

# 같은 모드가 두 군데에 깔려 있는 일이 흔합니다.
#   ...\workshop\content\322330\2484725102        <- 스팀이 받아 둔 것
#   ...\Don't Starve Together\mods\workshop-2484725102  <- 서버가 쓰는 복사본
# 둘은 같은 모드이므로 번호로 묶고, 코드가 더 많이 들어 있는 쪽 하나만 씁니다.
function Resolve-DuplicateMods($list) {
	$best = @{}

	foreach ($entry in $list) {
		$id = ($entry.Id -replace '^workshop-', '')
		if ($id -notmatch '^\d+$') { $id = $entry.Id }

		$n = 0
		try {
			$n = @(Get-ChildItem -LiteralPath $entry.Path -Recurse -File -Filter *.lua -ErrorAction SilentlyContinue).Count
		} catch { }

		$entry | Add-Member -NotePropertyName 'Number'   -NotePropertyValue $id   -Force
		$entry | Add-Member -NotePropertyName 'LuaFiles' -NotePropertyValue $n    -Force

		if (-not $best.ContainsKey($id) -or $n -gt $best[$id].LuaFiles) { $best[$id] = $entry }
	}

	$out = New-Object System.Collections.Generic.List[object]
	foreach ($id in ($best.Keys | Sort-Object)) { $out.Add($best[$id]) }
	return $out
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
		# modinfo 를 한 줄에 몰아 쓴 모드가 있어서, 다음 "무엇 =" 이 나오면
		# 거기서 끊습니다. 안 그러면 icon = "preview.tex" 를 이름으로 집습니다.
		$line = [regex]::Match($text, '(?m)^name\s*=\s*(.+?)(?=\s+[A-Za-z_]\w*\s*=|$)')
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


# ══════════════════════════════════════════════════════════════════════════════
#  서버가 안 켜질 때 - 로그에서 오류만 뽑아내기
# ══════════════════════════════════════════════════════════════════════════════
#
#  "데디케이티드 서버 시작 실패" 창은 이유를 알려주지 않습니다. 이유는 로그에
#  그대로 찍혀 있고, 보통 파일 맨 아래쪽입니다.

# 오류 한 건의 시작을 알리는 표시들.
$ERROR_MARKERS = @(
	'\[string "',
	'stack traceback',
	'^\s*Error',
	'LUA ERROR',
	'attempt to (index|call|compare|perform|concatenate)',
	'Assert failure',
	'SCRIPT ERROR',
	'Mod: .*Error',
	'DoLuaFile',
	'Failed to load',
	'unexpected symbol',
	"'end' expected",
	'caused an error'
)

function Invoke-LastError {
	Write-Head '서버가 안 켜지는 이유 찾기'

	$logs = @(Get-DstLogs)

	# 백업본(server_log_2026-..-...txt)까지 같이 봅니다.
	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
					Where-Object { Test-LogName $_.Name })) {
				if ($logs -notcontains $f.FullName) { $logs += $f.FullName }
			}
		} catch { }
	}

	if ($logs.Count -eq 0) {
		Write-Fail 'DST 로그 파일을 찾지 못했습니다.'
		Write-Host ('  보통 여기 있습니다: ' + (Join-Path $env:USERPROFILE 'Documents\Klei\DoNotStarveTogether'))
		Write-Host ''
		return
	}

	# 최근에 쓰인 것부터
	$ordered = @()
	try {
		$ordered = @(Select-DistinctLogs (Get-ChildItem -LiteralPath $logs -ErrorAction SilentlyContinue |
			Sort-Object LastWriteTime -Descending) | Select-Object -First 8)
	} catch {
		$ordered = @()
	}

	if ($ordered.Count -eq 0) {
		Write-Fail '로그 파일을 읽지 못했습니다.'
		return
	}

	$out = New-Object System.Collections.Generic.List[string]
	$out.Add('DST 서버 오류 찾기')
	$out.Add((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
	$out.Add('')

	$pattern = ($ERROR_MARKERS -join '|')
	$anyFound = $false

	foreach ($log in $ordered) {
		$lines = @()
		try { $lines = [IO.File]::ReadAllLines($log.FullName) } catch { continue }
		if ($lines.Length -eq 0) { continue }

		$hits = @()
		for ($i = 0; $i -lt $lines.Length; $i++) {
			if ($lines[$i] -match $pattern) { $hits += $i }
		}

		$header = ('--- ' + $log.Name + '   (' + $log.LastWriteTime.ToString('MM-dd HH:mm') +
			', ' + $lines.Length + ' 줄)')

		if ($hits.Count -eq 0) {
			$out.Add($header + '  -> 오류 없음')
			$out.Add('')
			continue
		}

		$anyFound = $true
		$out.Add($header + '  -> 오류로 보이는 줄 ' + $hits.Count + ' 개')
		$out.Add('')

		# 마지막 오류 주변을 넉넉히. 시작 실패의 이유는 거의 항상 마지막에 있습니다.
		$start = [Math]::Max(0, $hits[$hits.Count - 1] - 25)
		$end   = [Math]::Min($lines.Length - 1, $hits[$hits.Count - 1] + 40)

		$out.Add('   ── 마지막 오류 부근 ──')
		for ($i = $start; $i -le $end; $i++) {
			$out.Add('   ' + $lines[$i])
		}
		$out.Add('')

		# 마지막 20줄도. 시작이 끊긴 지점이 여기 드러납니다.
		$out.Add('   ── 로그 마지막 20줄 ──')
		for ($i = [Math]::Max(0, $lines.Length - 20); $i -lt $lines.Length; $i++) {
			$out.Add('   ' + $lines[$i])
		}
		$out.Add('')

		Write-Host ''
		Write-Host ('  ' + $log.Name) -ForegroundColor Yellow
		foreach ($i in ($hits | Select-Object -Last 3)) {
			Write-Host ('    ' + $lines[$i].Trim()) -ForegroundColor Red
		}
	}

	if (-not $anyFound) {
		Write-Host ''
		Write-Warn '로그에서 오류 같은 줄을 찾지 못했습니다.'
		Write-Host '  서버를 한 번 더 켜 보신 뒤 이 파일을 다시 실행해 주세요.'
	}

	$file = Join-Path $PackageRoot '서버오류.txt'
	try {
		[IO.File]::WriteAllText($file, (Protect-Text ($out -join "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
		Write-Host ''
		Write-Host ('저장했습니다: ' + $file) -ForegroundColor Green
		Write-Host '이 파일을 보내 주시면 원인을 찾아 드리겠습니다.' -ForegroundColor Green
		try { Start-Process notepad.exe $file } catch { }
	} catch {
		Write-Fail ('저장하지 못했습니다: ' + $_.Exception.Message)
	}

	Write-Host ''
	Write-Host '  바로 되돌리시려면 restore.bat 을 실행하세요.'
	Write-Host ''
}

# ══════════════════════════════════════════════════════════════════════════════
#  어떤 모드가 문제인지 찾아내기
# ══════════════════════════════════════════════════════════════════════════════
#
#  설치된 모드의 lua 를 전부 훑어서, 서로 부딪칠 만한 지점을 찾아냅니다.
#  추측이 아니라 "이 모드의 이 파일에 이 코드가 있다" 만 말합니다.
#
#  가장 중요한 것은 WX-78 모듈 개수입니다. 바닐라 wx78_moduledefs.lua 에는
#      assert(module_netid < 64, "To support additional WX modules, ...")
#  가 있고, 바닐라 자신이 23 개를 먼저 씁니다. 그래서 모드 전체가 나눠 쓸 수
#  있는 자리는 40 개뿐이고, 넘기는 순간 서버가 아예 안 켜집니다.

$WX78_LIMIT     = 63   # assert(module_netid < 64)
# 바닐라 wx78_moduledefs.lua 가 먼저 등록하는 23 개. 모드가 추가한 것만 세려면
# 이 이름들은 빼야 합니다.
$WX78_STOCK = @(
	'bee', 'chess', 'cold', 'digestion', 'heat', 'light', 'light2',
	'maxhealth', 'maxhealth2', 'maxhunger', 'maxhunger1', 'maxsanity', 'maxsanity1',
	'movespeed', 'movespeed2', 'music', 'nightvision', 'radar', 'screech',
	'shielding', 'spin', 'stacksize', 'taser'
)
$WX78_VANILLA   = 23   # 바닐라가 먼저 쓰는 개수
$SCAN_MAX_BYTES = 3MB  # 이보다 큰 lua 는 건너뜁니다 (보통 번역 표)

# 모드 코드에서 찾을 흔적들.
#   Key      : 내부 이름
#   Label    : 사람이 읽을 이름
#   Pattern  : 정규식
#   Weight   : 'crash' 서버가 안 켜질 수 있음 / 'cook' 요리에 영향 / 'watch' 참고
$MOD_SIGNALS = @(
	@{ Key = 'wx78';      Label = 'WX-78 모듈 추가';        Weight = 'crash'
	   Pattern = '(?<!function\s{1,10})AddNewModuleDefinition\s*\(' },
	@{ Key = 'wx78tbl';   Label = 'WX-78 모듈 표에 넣기';    Weight = 'crash'
	   Pattern = 'table\.insert\s*\(\s*module_definitions' },
	@{ Key = 'dishes';    Label = '냄비 요리 추가';          Weight = 'watch'
	   Pattern = 'AddCookerRecipe\s*\(' },
	@{ Key = 'errorhook'; Label = '오류 처리 가로채기';      Weight = 'crash'
	   Pattern = 'SetGlobalErrorWidget|(_G|GLOBAL)\.error\s*=|(?m)^\s*(local\s+)?function\s+error\s*\(|(?m)^\s*error\s*=\s*function' },
	@{ Key = 'container'; Label = '상자 내부 손대기';        Weight = 'cook'
	   Pattern = 'AddComponentPostInit\s*\(\s*"container"|containers\.params|GetNumSlots\s*=' },
	@{ Key = 'chest';     Label = '상자 프리팹 손대기';      Weight = 'cook'
	   Pattern = 'AddPrefabPostInit\s*\(\s*"(treasurechest|icebox|saltbox|meatrack)"' },
	@{ Key = 'cookpot';   Label = '냄비 손대기';            Weight = 'cook'
	   Pattern = 'AddPrefabPostInit\s*\(\s*"(cookpot|portablecookpot|archive_cookpot)"|AddComponentPostInit\s*\(\s*"stewer"' },
	@{ Key = 'cooking';   Label = '요리 계산식 손대기';      Weight = 'cook'
	   Pattern = 'CalculateRecipe\s*=|cooking\.recipes\s*\[|IsCookingIngredient\s*=' },
	@{ Key = 'autopick';  Label = '자동으로 물건 옮기기';    Weight = 'cook'
	   Pattern = 'AddComponentPostInit\s*\(\s*"harvestable"|DoPeriodicTask[^\n]{0,120}(Harvest|Pickup|Collect|Sort)' },
	@{ Key = 'oldapi';    Label = '옛날 AddRecipe 사용';     Weight = 'watch'
	   Pattern = '(?<!AddRecipe2)AddRecipe\s*\(' }
)

# 모드 하나의 lua 를 전부 읽고 흔적을 셉니다.
function Measure-ModCode($modPath) {
	$hits = @{}
	foreach ($sig in $MOD_SIGNALS) { $hits[$sig.Key] = 0 }

	$result = [pscustomobject]@{
		Hits         = $hits
		Files        = 0
		WxNames      = New-Object System.Collections.Generic.List[string]
		CookRecipes  = New-Object System.Collections.Generic.List[string]
		CraftRecipes = New-Object System.Collections.Generic.List[string]
		Unreadable   = 0
	}

	$files = @()
	try {
		$files = @(Get-ChildItem -LiteralPath $modPath -Recurse -File -Filter *.lua -ErrorAction SilentlyContinue)
	} catch { return $result }

	foreach ($f in $files) {
		if ($f.Length -gt $SCAN_MAX_BYTES) { continue }

		$text = $null
		try { $text = [IO.File]::ReadAllText($f.FullName) } catch { $result.Unreadable++; continue }
		if ([string]::IsNullOrEmpty($text)) { continue }

		$result.Files++

		foreach ($sig in $MOD_SIGNALS) {
			$n = [regex]::Matches($text, $sig.Pattern).Count
			if ($n -gt 0) { $result.Hits[$sig.Key] = $result.Hits[$sig.Key] + $n }
		}

		# WX-78 모듈은 언제나 wx78module_<이름> 이라는 프리팹을 같이 만듭니다.
		# 그래서 이 이름을 세는 것이 AddNewModuleDefinition 호출을 세는 것보다
		# 정확합니다 (반복문 한 줄로 20 개를 등록하는 모드가 있습니다).
		foreach ($m in [regex]::Matches($text, 'wx78module_([A-Za-z0-9_]{1,40})')) {
			$nm = $m.Groups[1].Value
			if ($WX78_STOCK -notcontains $nm -and -not $result.WxNames.Contains($nm)) {
				$result.WxNames.Add($nm)
			}
		}

		# 냄비 요리 이름: 두 모드가 같은 이름을 쓰면 나중에 켜진 쪽만 남습니다.
		foreach ($m in [regex]::Matches($text,
			'AddCookerRecipe\s*\(\s*"[^"]{1,40}"\s*,\s*\{[\s\S]{0,300}?name\s*=\s*"([^"]{1,60})"')) {
			$result.CookRecipes.Add($m.Groups[1].Value)
		}

		# 제작법 이름도 마찬가지입니다.
		foreach ($m in [regex]::Matches($text, 'AddRecipe2?\s*\(\s*"([^"]{1,60})"')) {
			$result.CraftRecipes.Add($m.Groups[1].Value)
		}
	}

	return $result
}

# 최근 로그에서 "이 모드 때문"이라고 이름이 찍힌 것만 모읍니다.
#
# 중요: ../mods/workshop-123/... 은 평범한 줄에도 잔뜩 나옵니다 (그냥 파일 경로).
# 그것까지 세면 설치된 모드가 전부 범인이 되어 버립니다. 그래서 오류가 시작된
# 줄부터 아래로 몇 줄만 들여다보고, 그 안에 나온 모드만 지목합니다.
function Get-ModBlameFromLogs {
	$blame  = @{}
	$names  = @{}
	$wxHit  = $false

	# server_log.txt 뿐 아니라 백업본(server_log_2026-..-...txt)까지 봅니다.
	$paths = @(Get-DstLogs)
	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
					Where-Object { Test-LogName $_.Name })) {
				if ($paths -notcontains $f.FullName) { $paths += $f.FullName }
			}
		} catch { }
	}

	$logs = @()
	if ($paths.Count -gt 0) {
		try {
			$logs = @(Select-DistinctLogs (Get-ChildItem -LiteralPath $paths -ErrorAction SilentlyContinue |
				Sort-Object LastWriteTime -Descending) | Select-Object -First 6)
		} catch { $logs = @() }
	}

	$blockStart = '\[string "|stack traceback|LUA ERROR|SCRIPT ERROR|Assert failure|' +
		'attempt to (index|call|compare|perform|concatenate)|is not declared|DoLuaFile Error'

	function Add-Blame($table, $id, $note) {
		if (-not $table.ContainsKey($id)) {
			$table[$id] = New-Object System.Collections.Generic.List[string]
		}
		if (-not $table[$id].Contains($note)) { $table[$id].Add($note) }
	}

	foreach ($log in $logs) {
		$lines = @()
		try { $lines = [IO.File]::ReadAllLines($log.FullName) } catch { continue }
		if ($lines.Length -eq 0) { continue }

		for ($i = 0; $i -lt $lines.Length; $i++) {
			$line = $lines[$i]

			# DST 가 스스로 읽어낸 모드 이름. modinfo 를 파싱하는 것보다 정확합니다.
			$nm = [regex]::Match($line, 'Loading mod:\s*workshop-(\d+)\s*\((.*)\)\s*Version:')
			if ($nm.Success) { $names[$nm.Groups[1].Value] = $nm.Groups[2].Value.Trim() }

			# 이건 언제나 확실합니다.
			# 이 문장이 로그에 있으면 WX-78 자리가 실제로 넘친 것입니다. 추측이 아닙니다.
			if ($line -match 'To support additional WX modules') { $wxHit = $true }

			$me = [regex]::Match($line, 'MOD ERROR:\s*workshop-(\d+)')
			if ($me.Success) { Add-Blame $blame $me.Groups[1].Value '로그에 MOD ERROR 로 찍힘' }

			# 오류가 시작된 줄. 여기서부터 아래로만 모드 경로를 봅니다.
			if ($line -notmatch $blockStart) { continue }

			$stop = [Math]::Min($lines.Length - 1, $i + 40)
			for ($k = $i; $k -le $stop; $k++) {
				# 새 타임스탬프가 나오면 그 오류는 거기서 끝난 것으로 봅니다.
				if ($k -gt $i -and $lines[$k] -match '^\[\d\d:\d\d:\d\d\]' -and
					$lines[$k] -notmatch $blockStart -and $lines[$k] -notmatch '\.\./mods/') { break }

				foreach ($m in [regex]::Matches($lines[$k], '\.\./mods/workshop-(\d+)/')) {
					Add-Blame $blame $m.Groups[1].Value '오류 스택에 이 모드 파일이 나옴'
				}
			}
		}
	}

	return [pscustomobject]@{ Blame = $blame; Names = $names; WxOverflow = $wxHit }
}


function Get-EnabledMods {
	$state = @{}

	foreach ($root in (Get-KleiRoots)) {
		$files = @()
		try {
			$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'modoverrides.lua' -ErrorAction SilentlyContinue)
		} catch { continue }

		foreach ($f in $files) {
			$text = $null
			try { $text = [IO.File]::ReadAllText($f.FullName) } catch { continue }
			if ([string]::IsNullOrEmpty($text)) { continue }

			# ["workshop-123"] = { enabled = true, ... }
			foreach ($m in [regex]::Matches($text,
				'\[\s*"workshop-(\d+)"\s*\]\s*=\s*\{([\s\S]{0,400}?)(?=\n\s*\[\s*"workshop-|\z)')) {
				$id   = $m.Groups[1].Value
				$body = $m.Groups[2].Value
				$on   = $true
				$e    = [regex]::Match($body, 'enabled\s*=\s*(true|false)')
				if ($e.Success) { $on = ($e.Groups[1].Value -eq 'true') }

				# 한 번이라도 켜져 있으면 켜진 것으로 봅니다 (마스터/동굴 중 한쪽).
				if ($on -or -not $state.ContainsKey($id)) { $state[$id] = $on }
			}
		}
	}

	return $state
}

function Invoke-ModCheck($root) {
	Write-Head '어떤 모드가 문제인지 찾기'

	$script:reportLines = New-Object System.Collections.Generic.List[string]
	Add-Line 'DST 모드 점검'
	Add-Line ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

	Write-Host '모드를 찾는 중...'
	$mods = Get-AllModFolders $root

	if ($mods.Count -eq 0) {
		Write-Fail '설치된 모드를 하나도 찾지 못했습니다.'
		Write-Host '  모드가 들어 있는 폴더를 modcheck.bat 위로 드래그해 주세요.'
		Write-Host '  보통 이 경로입니다: ...\steamapps\workshop\content\322330'
		Write-Host ''
		return
	}

	Write-Ok ('모드 ' + $mods.Count + ' 개를 찾았습니다. 코드를 읽는 중입니다...')

	$fromLog = Get-ModBlameFromLogs
	$blame   = $fromLog.Blame
	$wxBlown = $fromLog.WxOverflow
	$logNames = $fromLog.Names
	$onOff   = Get-EnabledMods
	$rows    = New-Object System.Collections.Generic.List[object]
	$cookMap = @{}   # 요리 이름 -> 그 이름을 쓰는 모드들
	$done    = 0

	foreach ($entry in $mods) {
		$done++
		Write-Progress -Activity '모드 코드 읽는 중' -Status $entry.Id -PercentComplete (100 * $done / $mods.Count)

		$info = Read-ModInfo $entry.Path
		$code = Measure-ModCode $entry.Path

		foreach ($dish in ($code.CookRecipes | Sort-Object -Unique)) {
			if (-not $cookMap.ContainsKey($dish)) {
				$cookMap[$dish] = New-Object System.Collections.Generic.List[string]
			}
			$cookMap[$dish].Add($entry.Id)
		}

		$bareId = $entry.Id -replace '^workshop-', ''
		$label  = $info.Name
		if ($logNames.ContainsKey($bareId)) { $label = $logNames[$bareId] }
		if ([string]::IsNullOrWhiteSpace($label) -or $label -eq $bareId) { $label = 'workshop-' + $bareId }

		$bare = $entry.Id -replace '^workshop-', ''
		$on   = $null
		if ($onOff.ContainsKey($bare)) { $on = [bool]$onOff[$bare] }

		$rows.Add([pscustomobject]@{
			Id      = $entry.Id
			Name    = $label
			Enabled = $on
			Wx      = 0
			Version = $info.Version
			Api     = $info.Api
			Client  = $info.ClientOnly
			Code    = $code
			Blame   = $(if ($blame.ContainsKey(($entry.Id -replace '^workshop-', ''))) {
							$blame[($entry.Id -replace '^workshop-', '')]
						} elseif ($blame.ContainsKey($entry.Id)) { $blame[$entry.Id] } else { $null })
			Path    = $entry.Path
		})
	}
	Write-Progress -Activity '모드 코드 읽는 중' -Completed

	$known = @($rows | Where-Object { $_.Enabled -ne $null })
	$on    = @($rows | Where-Object { $_.Enabled -eq $true })
	$off   = @($rows | Where-Object { $_.Enabled -eq $false })

	Add-Line ''
	if ($known.Count -eq 0) {
		Add-Line ('  설치된 모드 ' + $rows.Count + ' 개. (modoverrides.lua 를 못 찾아서, 어느 것이 서버에')
		Add-Line '  켜져 있는지는 구분하지 못했습니다. 아래는 설치된 것 전부를 본 결과입니다.)'
	} else {
		Add-Line ('  설치된 모드 ' + $rows.Count + ' 개 중 서버에 켜져 있는 것 ' + $on.Count + ' 개, 꺼져 있는 것 ' + $off.Count + ' 개.')
		Add-Line '  꺼져 있는 모드는 아무 문제도 일으키지 않으므로 아래 계산에서 뺐습니다.'
	}

	# ── WX-78 모듈 자리 계산 ───────────────────────────────────────────────
	# 모드는 두 가지 방법으로 모듈을 등록합니다. 둘 다 쓰는 모드도 있으므로
	# 더하지 않고 큰 쪽을 그 모드의 개수로 봅니다.
	foreach ($r in $rows) {
		$best = $r.Code.Hits['wx78']
		foreach ($v in @($r.Code.Hits['wx78tbl'], $r.Code.WxNames.Count)) {
			if ($v -gt $best) { $best = $v }
		}
		$r.Wx = $best
	}

	# 서버에 켜져 있는 모드만 자리를 씁니다.
	$wxRows  = @($rows | Where-Object { $_.Wx -gt 0 -and $_.Enabled -ne $false } |
					Sort-Object { -$_.Wx })
	$wxTotal = 0
	foreach ($r in $wxRows) { $wxTotal += $r.Wx }
	$wxRoom  = $WX78_LIMIT - $WX78_VANILLA

	Add-Line ''
	Add-Line '━━ 1. 서버가 아예 안 켜지게 만들 수 있는 것 ━━'
	Add-Line ''
	Add-Line ('  WX-78 모듈 자리: 전체 ' + $WX78_LIMIT + ' 개 중 바닐라가 ' + $WX78_VANILLA +
		' 개를 먼저 씁니다. 모드 몫은 ' + $wxRoom + ' 개입니다.')
	Add-Line ('  지금 모드들이 쓰는 것으로 보이는 개수: 약 ' + $wxTotal + ' 개')

	if ($wxRows.Count -eq 0) {
		Add-Line '    WX-78 모듈을 추가하는 모드가 없습니다. 이 문제는 아닙니다.'
	} else {
		foreach ($r in $wxRows) {
			Add-Line ('    ' + $r.Id.PadRight(22) + ' 약 ' + ([string]$r.Wx).PadLeft(3) + ' 개   ' + $r.Name)
		}
		Add-Line ''
		if ($wxBlown) {
			Add-Line '  >> 로그에 이 문장이 있습니다:'
			Add-Line '       "To support additional WX modules, player_classified.upgrademodulebars must be updated"'
			Add-Line '     자리가 실제로 넘쳤습니다. 이것 때문에 서버가 안 켜집니다.'
			Add-Line '     위 목록에서 하나를 끄세요. 3번에서 MOD ERROR 로 찍힌 모드가 1순위입니다.'
		} elseif ($wxTotal -gt $wxRoom) {
			Add-Line ('  >> 자리가 ' + ($wxTotal - $wxRoom) + ' 개 모자랍니다. 이 상태면 서버가 안 켜집니다.')
			Add-Line '     위 목록에서 개수가 많은 모드를 하나 끄면 켜집니다.'
		} else {
			Add-Line ('  코드에서 센 것으로는 ' + ($wxRoom - $wxTotal) + ' 자리 남습니다.')
			Add-Line '     다만 이 숫자는 믿지 마세요. 모듈을 반복문 한 줄로 20 개씩 등록하는'
			Add-Line '     모드가 있어서 코드만 봐서는 제대로 셀 수 없습니다.'
			Add-Line '     넘쳤는지 아닌지는 로그가 말해 줍니다. 위 문장이 안 나왔다면'
			Add-Line '     지금은 안 넘친 것입니다.'
		}
	}

	$errHook = @($rows | Where-Object { $_.Code.Hits['errorhook'] -gt 0 -and $_.Enabled -ne $false })
	if ($errHook.Count -gt 0) {
		Add-Line ''
		Add-Line '  오류 화면을 자기 코드로 바꾸는 모드:'
		foreach ($r in $errHook) {
			Add-Line ('    ' + $r.Id.PadRight(22) + ' ' + $r.Name)
		}
		Add-Line '    이런 모드가 있으면, 다른 모드의 사소한 오류 하나가'
		Add-Line '    "서버 시작 실패" 로 커질 수 있습니다.'
	}

	# ── 요리에 끼어드는 모드 ───────────────────────────────────────────────
	Add-Line ''
	Add-Line '━━ 2. 왈리 요리에 끼어들 수 있는 모드 ━━'
	Add-Line ''

	$cookKeys = @('container', 'chest', 'cookpot', 'cooking', 'autopick')
	$cookRows = @($rows | Where-Object {
		$n = 0
		foreach ($k in $cookKeys) { $n += $_.Code.Hits[$k] }
		$n -gt 0
	})

	if ($cookRows.Count -eq 0) {
		Add-Line '  없습니다.'
	} else {
		foreach ($r in ($cookRows | Sort-Object Name)) {
			$marks = New-Object System.Collections.Generic.List[string]
			foreach ($sig in $MOD_SIGNALS) {
				if ($cookKeys -contains $sig.Key -and $r.Code.Hits[$sig.Key] -gt 0) {
					$marks.Add($sig.Label + ' x' + $r.Code.Hits[$sig.Key])
				}
			}
			Add-Line ('    ' + $r.Id.PadRight(22) + ' ' + $r.Name)
			Add-Line ('        ' + ($marks -join ' / '))
		}
		Add-Line ''
		Add-Line '  끼어든다고 해서 다 나쁜 것은 아닙니다. 상자를 추가하는 모드는 당연히'
		Add-Line '  상자를 건드립니다. 왈리가 요리를 못 할 때 먼저 의심할 목록일 뿐입니다.'
	}

	$dishRows = @($rows | Where-Object { $_.Code.CookRecipes.Count -gt 0 -and $_.Enabled -ne $false })
	if ($dishRows.Count -gt 0) {
		Add-Line ''
		Add-Line '  냄비 요리를 추가하는 모드:'
		foreach ($r in ($dishRows | Sort-Object { -$_.Code.CookRecipes.Count })) {
			Add-Line ('    ' + $r.Id.PadRight(22) + ([string](($r.Code.CookRecipes | Sort-Object -Unique).Count)).PadLeft(4) + ' 가지   ' + $r.Name)
		}
	}

	# 같은 요리 이름을 두 모드가 쓰는 경우
	$clashes = @($cookMap.Keys | Where-Object { ($cookMap[$_] | Sort-Object -Unique).Count -gt 1 })
	Add-Line ''
	if ($clashes.Count -eq 0) {
		Add-Line '  같은 요리 이름을 두 모드가 동시에 쓰는 경우: 없습니다.'
	} else {
		Add-Line ('  같은 요리 이름을 두 모드가 동시에 씁니다 (' + $clashes.Count + ' 건).')
		Add-Line '  이 경우 나중에 켜진 모드의 요리만 남습니다.'
		foreach ($dish in ($clashes | Sort-Object | Select-Object -First 20)) {
			Add-Line ('    ' + $dish.PadRight(28) + ' <- ' + (($cookMap[$dish] | Sort-Object -Unique) -join ', '))
		}
		if ($clashes.Count -gt 20) { Add-Line ('    ... 그리고 ' + ($clashes.Count - 20) + ' 건 더') }
	}

	# ── 로그가 직접 지목한 모드 ────────────────────────────────────────────
	Add-Line ''
	Add-Line '━━ 3. 로그가 직접 이름을 부른 모드 ━━'
	Add-Line ''
	Add-Line '  이게 가장 확실한 증거입니다. 여기 이름이 있으면 그 모드가 범인입니다.'
	Add-Line ''

	$blamed = @($rows | Where-Object { $_.Blame -ne $null })

	$seen = @{}
	foreach ($r in $rows) { $seen[($r.Id -replace '^workshop-', '')] = $true }
	$orphan = @($blame.Keys | Where-Object { -not $seen.ContainsKey($_) })

	if ($blamed.Count -eq 0 -and $orphan.Count -eq 0) {
		Add-Line '    없습니다. 최근 로그에서 모드 이름이 찍힌 오류가 없습니다.'
	} else {
		foreach ($r in $blamed) {
			Add-Line ('    ' + $r.Id.PadRight(22) + ' ' + $r.Name)
			foreach ($note in $r.Blame) { Add-Line ('        - ' + $note) }
		}
		foreach ($id in ($orphan | Sort-Object)) {
			Add-Line ('    workshop-' + $id.PadRight(13) + ' (설치 폴더를 못 찾았습니다)')
			foreach ($note in $blame[$id]) { Add-Line ('        - ' + $note) }
		}
	}

	# ── 나머지 참고 ────────────────────────────────────────────────────────
	Add-Line ''
	Add-Line '━━ 4. 참고 ━━'
	Add-Line ''

	$oldApi = @($rows | Where-Object { $_.Api -ne '' -and [int]$_.Api -lt 10 })
	if ($oldApi.Count -gt 0) {
		Add-Line ('  api_version 이 낡은 모드 (' + $oldApi.Count + ' 개). 지금은 돌아가지만 업데이트에 약합니다.')
		foreach ($r in ($oldApi | Sort-Object { [int]$_.Api })) {
			Add-Line ('    api ' + $r.Api.PadLeft(2) + '  ' + $r.Id.PadRight(22) + ' ' + $r.Name)
		}
		Add-Line ''
	}

	if ($onOff.Count -gt 0) {
		$have = @{}
		foreach ($r in $rows) { $have[($r.Id -replace '^workshop-', '')] = $true }
		$missing = @($onOff.Keys | Where-Object { $onOff[$_] -and -not $have.ContainsKey($_) })
		if ($missing.Count -gt 0) {
			Add-Line ('  서버에는 켜 놓았는데 설치가 안 된 모드 (' + $missing.Count + ' 개).')
			Add-Line '  이건 그 자체로 시작 실패의 원인이 됩니다. 창작마당에서 다시 구독하세요.'
			foreach ($id in ($missing | Sort-Object)) { Add-Line ('    workshop-' + $id) }
			Add-Line ''
		}
	}

	$clientOnly = @($rows | Where-Object { $_.Client -match '^(true|1)$' -and $_.Enabled -ne $false })
	if ($clientOnly.Count -gt 0) {
		Add-Line ('  client_only_mod 인 모드 (' + $clientOnly.Count + ' 개). 서버에 켜 봐야 아무 일도 하지 않습니다.')
		foreach ($r in ($clientOnly | Sort-Object Name)) {
			Add-Line ('    ' + $r.Id.PadRight(22) + ' ' + $r.Name)
		}
		Add-Line ''
	}

	$oldRecipe = @($rows | Where-Object { $_.Code.Hits['oldapi'] -gt 0 })
	if ($oldRecipe.Count -gt 0) {
		Add-Line ('  옛날 AddRecipe 를 쓰는 모드 (' + $oldRecipe.Count + ' 개). 로그에 경고만 남기고 동작은 합니다.')
		Add-Line ('    ' + (($oldRecipe | ForEach-Object { $_.Id }) -join ', '))
		Add-Line ''
	}

	# ── 전체 목록 ──────────────────────────────────────────────────────────
	Add-Line ''
	Add-Line '━━ 5. 설치된 모드 전체 ━━'
	Add-Line ''
	Add-Line ('  ' + 'ID'.PadRight(22) + 'api'.PadLeft(4) + '  켜짐  표시   이름')

	foreach ($r in ($rows | Sort-Object Name)) {
		$mark = ' ?  '
		if ($r.Enabled -eq $true)  { $mark = ' O  ' }
		if ($r.Enabled -eq $false) { $mark = ' -  ' }
		$flag = '     '
		if ($r.Blame -ne $null)                 { $flag = '[로그]' }
		elseif ($r.Code.Hits['errorhook'] -gt 0) { $flag = '[오류]' }
		elseif ($r.Wx -gt 0)                     { $flag = '[WX78]' }
		elseif ($r.Code.Hits['cooking'] -gt 0 -or $r.Code.Hits['cookpot'] -gt 0) { $flag = '[요리]' }
		elseif ($r.Code.Hits['container'] -gt 0 -or $r.Code.Hits['chest'] -gt 0) { $flag = '[상자]' }

		Add-Line ('  ' + $r.Id.PadRight(22) + $r.Api.PadLeft(4) + '  ' +
			$mark + '  ' + $flag + ' ' + $r.Name)
	}

	Add-Line ''
	Add-Line '━━ 읽는 법 ━━'
	Add-Line ''
	Add-Line '  [로그]  최근 로그가 이 모드 이름을 오류와 함께 찍었습니다. 1순위로 끄세요.'
	Add-Line '  [오류]  다른 모드의 오류를 서버 시작 실패로 키울 수 있습니다.'
	Add-Line '  [WX78]  WX-78 모듈을 추가합니다. 위 1번의 자리 계산에 들어갑니다.'
	Add-Line '  [요리]  냄비나 요리 계산식을 건드립니다.'
	Add-Line '  [상자]  상자 내부를 건드립니다. 왈리가 상자를 못 읽을 때 의심하세요.'
	Add-Line ''
	Add-Line '  켜짐 O = 서버에 켜져 있음 / - = 구독만 해 놓고 꺼 둠 / ? = 알 수 없음'
	Add-Line ''

	$file = Join-Path $PackageRoot '모드점검.txt'
	try {
		[IO.File]::WriteAllText($file, (Protect-Text (($script:reportLines) -join "`r`n")),
			(New-Object System.Text.UTF8Encoding($true)))
		Write-Host ''
		Write-Host ('저장했습니다: ' + $file) -ForegroundColor Green
		Write-Host '이 파일을 그대로 보내 주시면 됩니다.' -ForegroundColor Green
		try { Start-Process notepad.exe $file } catch { }
	} catch {
		Write-Fail ('저장하지 못했습니다: ' + $_.Exception.Message)
	}

	Write-Host ''
}

# ══════════════════════════════════════════════════════════════════════════════
#  서버가 안 켜질 때 - 범인 모드를 반씩 잘라서 찾아내기
# ══════════════════════════════════════════════════════════════════════════════
#
#  모드 48 개를 하나씩 꺼 보면 48 번을 켜 봐야 합니다. 절반씩 자르면 6 번이면
#  끝납니다. 두 모드가 "같이 있을 때만" 터지는 경우도 찾아냅니다.
#
#  방식:
#    지금 "반드시 켜 두는 묶음"(Required)과 "범인이 이 안에 있는 묶음"(Pool)을
#    들고 다닙니다. 둘을 합치면 언제나 안 켜지는 조합입니다.
#      - Pool 을 반으로 잘라 앞쪽만 켜 본다. 안 켜지면 뒤쪽은 버린다.
#      - 뒤쪽만 켜 본다. 안 켜지면 앞쪽을 버린다.
#      - 둘 다 켜지면 두 모드가 "같이 있을 때만" 터지는 경우다.
#        앞쪽을 Required 로 옮기고 뒤쪽을 계속 좁힌다.
#    Pool 이 하나로 줄면 그 모드는 범인 중 하나가 확정입니다. 그러면 Required 와
#    Pool 을 맞바꿔서, 이번에는 나머지 쪽을 같은 방법으로 좁힙니다. 더 줄지 않으면
#    끝입니다. 모드 48 개면 한 개짜리 원인은 열 번 안쪽, 두 개가 얽힌 경우도
#    스물몇 번이면 나옵니다.
#
#  건드리는 파일은 modoverrides.lua 뿐이고, 시작할 때 원본을 백업해 두었다가
#  끝나거나 중단하면 그대로 되돌립니다.

# 시작이 실패했다는 표시. 하나라도 있으면 실패로 봅니다.
$BOOT_FAIL = @(
	'Failed mSimulation->Reset\(\)',
	'Error during game initialization',
	'DoLuaFile Error',
	'Error loading main\.lua',
	'MOD ERROR'
)

# 시뮬레이션이 실제로 돌기 시작했다는 표시.
$BOOT_OK = @(
	'Sim paused',
	'Starting master server',
	'Starting up',
	'Reconstructing topology',
	'\[Shard\].*Ready'
)

function Get-ModoverrideFiles {
	$files = New-Object System.Collections.Generic.List[string]

	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'modoverrides.lua' -ErrorAction SilentlyContinue)) {
				if (-not $files.Contains($f.FullName)) { $files.Add($f.FullName) }
			}
		} catch { }
	}

	return $files
}

# 한 모드 블록의 범위: ["workshop-123"] = { 부터 다음 ["workshop- 직전까지.
function Split-ModBlocks($text) {
	$blocks = New-Object System.Collections.Generic.List[object]

	$starts = [regex]::Matches($text, '\[\s*"workshop-(\d+)"\s*\]\s*=\s*\{')
	for ($i = 0; $i -lt $starts.Count; $i++) {
		$from = $starts[$i].Index
		$to   = $(if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Index } else { $text.Length })
		$blocks.Add([pscustomobject]@{
			Id     = $starts[$i].Groups[1].Value
			Start  = $from
			Length = $to - $from
			Open   = $starts[$i].Index + $starts[$i].Length
		})
	}

	return $blocks
}

function Get-EnabledFromFiles($files) {
	$ids = New-Object System.Collections.Generic.List[string]

	foreach ($file in $files) {
		$text = $null
		try { $text = [IO.File]::ReadAllText($file) } catch { continue }
		if ([string]::IsNullOrEmpty($text)) { continue }

		foreach ($b in (Split-ModBlocks $text)) {
			$body = $text.Substring($b.Start, $b.Length)
			$on   = $true
			$m    = [regex]::Match($body, 'enabled\s*=\s*(true|false)')
			if ($m.Success) { $on = ($m.Groups[1].Value -eq 'true') }
			if ($on -and -not $ids.Contains($b.Id)) { $ids.Add($b.Id) }
		}
	}

	return $ids
}

# $allowed 에 든 모드만 켜고 나머지는 끕니다. 설정값(configuration_options)은
# 그대로 두고 enabled 한 글자만 바꿉니다.
function Set-EnabledMods($files, $allowed) {
	foreach ($file in $files) {
		$text = $null
		try { $text = [IO.File]::ReadAllText($file) } catch { continue }
		if ([string]::IsNullOrEmpty($text)) { continue }

		# 뒤에서부터 고쳐야 앞 블록의 위치가 안 밀립니다.
		$blocks = @(Split-ModBlocks $text)
		for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
			$b    = $blocks[$i]
			$want = $(if ($allowed -contains $b.Id) { 'true' } else { 'false' })
			$body = $text.Substring($b.Start, $b.Length)

			$m = [regex]::Match($body, 'enabled(\s*)=(\s*)(true|false)')
			if ($m.Success) {
				$fixed = $body.Remove($m.Index, $m.Length).Insert($m.Index,
					('enabled' + $m.Groups[1].Value + '=' + $m.Groups[2].Value + $want))
				$text = $text.Remove($b.Start, $b.Length).Insert($b.Start, $fixed)
			} else {
				# enabled 키가 아예 없으면 여는 중괄호 바로 뒤에 넣습니다.
				$at   = $b.Open - $b.Start
				$fixed = $body.Insert($at, (' enabled = ' + $want + ','))
				$text  = $text.Remove($b.Start, $b.Length).Insert($b.Start, $fixed)
			}
		}

		try { [IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false))) }
		catch { Write-Fail ('modoverrides.lua 를 고치지 못했습니다: ' + $file) }
	}
}

# 마지막으로 켜 본 결과를 로그에서 읽습니다.
#   $since 이후에 쓰인 로그가 없으면 $null (아직 안 켜 봤다는 뜻).
function Read-BootResult($since) {
	$paths = @(Get-DstLogs)
	foreach ($root in (Get-KleiRoots)) {
		try {
			foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
					Where-Object { Test-LogName $_.Name })) {
				if ($paths -notcontains $f.FullName) { $paths += $f.FullName }
			}
		} catch { }
	}
	if ($paths.Count -eq 0) { return $null }

	$fresh = @()
	try {
		$fresh = @(Select-DistinctLogs (Get-ChildItem -LiteralPath $paths -ErrorAction SilentlyContinue |
			Where-Object { $_.LastWriteTime -gt $since } |
			Sort-Object LastWriteTime -Descending) | Select-Object -First 4)
	} catch { return $null }

	if ($fresh.Count -eq 0) { return $null }

	$sawOk = $false
	foreach ($f in $fresh) {
		$text = $null
		try { $text = [IO.File]::ReadAllText($f.FullName) } catch { continue }
		if ([string]::IsNullOrEmpty($text)) { continue }

		foreach ($p in $BOOT_FAIL) {
			if ($text -match $p) {
				return [pscustomobject]@{ Ok = $false; Log = $f.FullName; Why = $p }
			}
		}
		foreach ($p in $BOOT_OK) { if ($text -match $p) { $sawOk = $true } }
	}

	if ($sawOk) { return [pscustomobject]@{ Ok = $true; Log = $fresh[0].FullName; Why = '' } }

	# 새 로그는 있는데 성공도 실패도 아니면 판단하지 않습니다.
	return $null
}

$BISECT_STATE = 'bisect_state.json'
$BISECT_BACK  = '_bisect_backup'

function Get-BisectPaths {
	return [pscustomobject]@{
		State  = (Join-Path $PackageRoot $BISECT_STATE)
		Backup = (Join-Path $PackageRoot $BISECT_BACK)
	}
}

function Save-BisectState($state) {
	$p = Get-BisectPaths
	$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p.State -Encoding UTF8
}

function Read-BisectState {
	$p = Get-BisectPaths
	if (-not (Test-Path -LiteralPath $p.State)) { return $null }
	try { return (Get-Content -LiteralPath $p.State -Raw | ConvertFrom-Json) } catch { return $null }
}

function Restore-Bisect($state) {
	$p = Get-BisectPaths
	$n = 0

	if ($state -ne $null -and $state.Files -ne $null) {
		foreach ($pair in $state.Files) {
			try {
				if (Test-Path -LiteralPath $pair.Backup) {
					Copy-Item -LiteralPath $pair.Backup -Destination $pair.Path -Force
					$n++
				}
			} catch { Write-Fail ('되돌리지 못했습니다: ' + $pair.Path) }
		}
	}

	try { if (Test-Path -LiteralPath $p.Backup) { Remove-Item -LiteralPath $p.Backup -Recurse -Force } } catch { }
	try { if (Test-Path -LiteralPath $p.State)  { Remove-Item -LiteralPath $p.State -Force } } catch { }

	return $n
}

# c 를 n 조각으로 자른 것 중 $i 번째.
function Get-Chunk($c, $n, $i) {
	$all  = @($c)
	$size = [Math]::Ceiling($all.Count / [double]$n)
	$from = [int]($i * $size)
	if ($from -ge $all.Count) { return @() }
	$to = [Math]::Min($all.Count - 1, [int]($from + $size - 1))
	return @($all[$from..$to])
}

function Show-BisectPlan($state, $allowed, $names) {
	$all = @($state.Original)
	Add-Line ''
	Add-Line ('━━ ' + $state.Round + ' 번째 시도 ━━')
	Add-Line ''
	Add-Line ('  모드 ' + $all.Count + ' 개 중 ' + (@($allowed)).Count + ' 개만 켰습니다.')

	$left = @($state.Pool).Count
	if ($left -gt 1) {
		$more = [Math]::Ceiling([Math]::Log($left, 2)) * 2
		Add-Line ('  아직 범인 후보 ' + $left + ' 개. 앞으로 ' + $more + ' 번쯤이면 끝납니다.')
	}

	if ((@($allowed)).Count -le 12) {
		Add-Line ''
		Add-Line '  켜 놓은 것:'
		foreach ($id in $allowed) {
			$nm = $(if ($names.ContainsKey($id)) { $names[$id] } else { '' })
			Add-Line ('    workshop-' + $id.PadRight(12) + ' ' + $nm)
		}
	}

	Add-Line ''
	Add-Line '  >> 이제 서버를 켜 보세요. 켜지든 안 켜지든 상관없습니다.'
	Add-Line '     결과가 나오면 bisect.bat 을 다시 실행하시면 됩니다.'
	Add-Line ''
	Add-Line '  (그만두시려면: bisect.bat stop  - 모드 설정을 원래대로 되돌립니다)'
}

function Invoke-Bisect($arg) {
	Write-Head '안 켜지는 원인 모드 찾기'

	$script:reportLines = New-Object System.Collections.Generic.List[string]
	$paths = Get-BisectPaths
	$state = Read-BisectState

	if ($arg -match '^(stop|reset|restore|취소|중단)$') {
		$n = Restore-Bisect $state
		Write-Ok ('모드 설정 ' + $n + ' 개를 원래대로 되돌렸습니다.')
		Write-Host ''
		return
	}

	$fromLog = Get-ModBlameFromLogs
	$names   = $fromLog.Names

	# ── 처음 실행 ─────────────────────────────────────────────────────────
	if ($state -eq $null) {
		$files = @(Get-ModoverrideFiles)
		if ($files.Count -eq 0) {
			Write-Fail 'modoverrides.lua 를 찾지 못했습니다.'
			Write-Host '  이 도구는 데디케이티드 서버(클러스터 폴더)에서만 씁니다.'
			Write-Host ('  보통 여기입니다: ' + (Join-Path $env:USERPROFILE 'Documents\Klei\DoNotStarveTogether\Cluster_1'))
			Write-Host ''
			return
		}

		$enabled = @(Get-EnabledFromFiles $files)
		if ($enabled.Count -lt 2) {
			Write-Fail ('켜져 있는 모드가 ' + $enabled.Count + ' 개뿐입니다. 자를 것이 없습니다.')
			Write-Host ''
			return
		}

		# 먼저 로그가 이미 답을 알고 있는지 봅니다. 그러면 한 번도 안 켜 봐도 됩니다.
		$named = @($fromLog.Blame.Keys | Where-Object { $fromLog.Blame[$_] -contains '로그에 MOD ERROR 로 찍힘' })
		if ($named.Count -gt 0) {
			Add-Line ''
			Add-Line '  시작하기 전에: 로그가 이미 이 모드를 지목하고 있습니다.'
			foreach ($id in $named) {
				$nm = $(if ($names.ContainsKey($id)) { $names[$id] } else { '' })
				Add-Line ('    workshop-' + $id.PadRight(12) + ' ' + $nm)
			}
			Add-Line '  이것부터 꺼 보시고, 그래도 안 켜지면 아래를 계속하세요.'
			Add-Line ''
		}

		New-Item -ItemType Directory -Force -Path $paths.Backup | Out-Null
		$pairs = New-Object System.Collections.Generic.List[object]
		$i = 0
		foreach ($f in $files) {
			$i++
			$bk = Join-Path $paths.Backup ('modoverrides_' + $i + '.lua')
			Copy-Item -LiteralPath $f -Destination $bk -Force
			$pairs.Add([pscustomobject]@{ Path = $f; Backup = $bk })
		}

		$state = [pscustomobject]@{
			Files    = $pairs
			Original = $enabled
			Required = @()
			Pool     = $enabled
			Half     = @()
			Best     = 0
			Phase    = 'confirm'
			Pending  = $enabled
			Round    = 1
			Stamp    = (Get-Date).AddSeconds(-2).ToString('o')
		}

		Add-Line ('  켜져 있는 모드 ' + $enabled.Count + ' 개를 찾았습니다.')
		Add-Line '  원래 설정은 백업해 두었습니다. 끝나거나 bisect.bat stop 을 하면 되돌립니다.'
		Add-Line ''
		Add-Line '  먼저 지금 이대로 한 번 켜 보겠습니다. 제가 로그를 제대로 읽는지'
		Add-Line '  확인하는 단계입니다. 모드는 아직 아무것도 건드리지 않았습니다.'
		Add-Line ''
		Add-Line '  >> 서버를 켜 보시고, 실패하면 bisect.bat 을 다시 실행하세요.'
		Add-Line ''

		$state.Stamp = (Get-Date).ToString('o')
		Save-BisectState $state
		Write-Host ''
		return
	}

	# ── 지난번 결과 읽기 ──────────────────────────────────────────────────
	$since  = [DateTime]::Parse($state.Stamp)
	$result = Read-BootResult $since

	if ($result -eq $null) {
		Write-Warn '지난번 이후에 새로 쓰인 서버 로그가 없습니다.'
		Write-Host '  서버를 한 번 켜 보신 다음에 다시 실행해 주세요.'
		Write-Host '  (켜 보셨는데도 이 말이 나오면, 로그가 성공인지 실패인지 분명하지 않은 경우입니다.'
		Write-Host '   lasterror.bat 으로 로그를 직접 보세요.)'
		Write-Host ''
		return
	}

	if ($result.Ok) { Write-Ok  '지난번 조합은 켜졌습니다.' }
	else            { Write-Fail '지난번 조합은 안 켜졌습니다.' }

	$required = @($state.Required)
	$pool     = @($state.Pool)
	$phase    = [string]$state.Phase
	$half     = @($state.Half)
	$best     = [int]$state.Best
	$done     = $false

	if ($phase -eq 'confirm') {
		if ($result.Ok) {
			Add-Line ''
			Add-Line '  지금 이대로도 서버가 켜집니다. 찾을 것이 없습니다.'
			Add-Line '  (아까는 안 켜졌다면, 그 사이에 스팀이 모드를 업데이트했을 수 있습니다.)'
			$null = Restore-Bisect $state
			Write-Host ''
			return
		}
		$phase = 'firstHalf'
	}
	elseif ($phase -eq 'firstHalf') {
		if (-not $result.Ok) {
			# 앞쪽만 켜도 안 켜진다 -> 뒤쪽은 버려도 된다
			$pool  = $half
			$phase = 'firstHalf'
		} else {
			$phase = 'secondHalf'
		}
	}
	elseif ($phase -eq 'secondHalf') {
		$rest = @($pool | Where-Object { $half -notcontains $_ })
		if (-not $result.Ok) {
			$pool = $rest
		} else {
			# 어느 쪽만으로도 안 터진다 -> 둘에 걸쳐 있다.
			# 앞쪽을 붙박이로 두고 뒤쪽을 계속 좁힙니다.
			$required = @($required + $half)
			$pool     = $rest
		}
		$phase = 'firstHalf'
	}

	# Pool 이 하나로 줄면 그 모드는 확정입니다. 이제 반대쪽을 좁힙니다.
	while ($pool.Count -le 1 -and -not $done) {
		$total = $required.Count + $pool.Count

		if ($required.Count -eq 0) { $done = $true; break }
		if ($best -gt 0 -and $total -ge $best) { $done = $true; break }

		$best     = $total
		$swap     = $required
		$required = $pool
		$pool     = $swap
		$phase    = 'firstHalf'
	}

	# ── 찾았으면 여기서 끝 ────────────────────────────────────────────────
	if ($done) {
		$answer = @($required + $pool)

		Add-Line ''
		Add-Line '━━ 찾았습니다 ━━'
		Add-Line ''
		if ($answer.Count -eq 1) {
			Add-Line '  이 모드 하나 때문입니다:'
		} else {
			Add-Line ('  이 ' + $answer.Count + ' 개가 같이 켜져 있으면 서버가 안 켜집니다.')
			Add-Line '  하나만 꺼도 켜집니다. 어느 것을 끌지는 취향입니다.'
		}
		Add-Line ''
		foreach ($id in $answer) {
			$nm = $(if ($names.ContainsKey($id)) { $names[$id] } else { '' })
			Add-Line ('    workshop-' + $id.PadRight(12) + ' ' + $nm)
		}
		Add-Line ''

		$back = Restore-Bisect $state
		Add-Line ('  모드 설정 ' + $back + ' 개를 원래대로 되돌렸습니다.')
		Add-Line '  이제 위 모드를 게임 안에서 끄시면 됩니다.'
		Add-Line ''

		$file = Join-Path $PackageRoot '범인모드.txt'
		try {
			[IO.File]::WriteAllText($file, (Protect-Text (($script:reportLines) -join "`r`n")),
				(New-Object System.Text.UTF8Encoding($true)))
			Write-Host ('저장했습니다: ' + $file) -ForegroundColor Green
			try { Start-Process notepad.exe $file } catch { }
		} catch { }

		Write-Host ''
		return
	}

	# ── 다음 조합 ─────────────────────────────────────────────────────────
	if ($phase -eq 'firstHalf') {
		$cut  = [Math]::Max(1, [int][Math]::Floor($pool.Count / 2))
		$half = @($pool[0..($cut - 1)])
	}
	# secondHalf 는 방금 쓴 $half 를 그대로 씁니다.

	if ($phase -eq 'firstHalf') {
		$allowed = @($required + $half)
	} else {
		$allowed = @($required + @($pool | Where-Object { $half -notcontains $_ }))
	}

	Set-EnabledMods ($state.Files | ForEach-Object { $_.Path }) $allowed

	$state.Required = $required
	$state.Pool     = $pool
	$state.Half     = $half
	$state.Best     = $best
	$state.Phase    = $phase
	$state.Pending  = $allowed
	$state.Round   = [int]$state.Round + 1
	$state.Stamp   = (Get-Date).ToString('o')

	Show-BisectPlan $state $allowed $names
	Save-BisectState $state
	Write-Host ''
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

if ($Action -eq 'lasterror') {
	Invoke-LastError
	exit 0
}

if ($Action -eq 'modcheck') {
	Invoke-ModCheck $ModFolder
	exit 0
}

if ($Action -eq 'bisect') {
	Invoke-Bisect $Arg
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
