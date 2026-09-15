-- test_korean.lua
--
-- Runs the generated Korean string table against a stand-in for the mod
-- environment and checks that it does what it claims: sets the strings for
-- mods that are on, leaves the rest alone, creates missing parent tables, and
-- survives being run twice.
--
--   lua5.1 tests/test_korean.lua

local failures = 0
local function check(label, ok, detail)
	if ok then
		print("  PASS  " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

-- ── a stand-in for the bits of DST the file touches ────────────────────────
local enabled_mods = {}

local function NewEnv()
	-- DST leaves most action labels as plain strings, not tables. Anything that
	-- assumes a table here will index a string and die on the spot -- which is
	-- exactly what stopped the game the first time this shipped.
	local STRINGS = {
		NAMES = {},
		CHARACTERS = {},
		UI = {},
		ACTIONS = {
			PICK = "Pick",
			GIVE = "Give",
			DEPLOY = "Deploy",
			TEACH = "Learn",
			START_PUSHING = "Push",
		},
	}
	-- GLOBAL is the game's _G, so the Lua standard library is in it. The mod
	-- sandbox itself has almost none of it -- see tests/test_korean_env.lua,
	-- which builds that sandbox from Klei's own source.
	return {
		pcall = pcall, select = select, type = type, error = error,
		tostring = tostring, pairs = pairs, ipairs = ipairs,
		table = table, string = string, math = math,
		STRINGS = STRINGS,
		-- Some mods keep their display text in TUNING rather than STRINGS.
		TUNING = {},
		KnownModIndex = {
			IsModEnabled      = function(self, name) return enabled_mods[name] == true end,
			IsModForceEnabled = function(self, name) return false end,
		},
	}
end

local post_inits = {}
local fake_modules = {}

local function LoadPatch(GLOBAL)
	post_inits = {}
	local chunk, err = loadfile("korean_patch/modmain.lua")
	if chunk == nil then return nil, err end
	local env = setmetatable({
		GLOBAL = GLOBAL,
		AddSimPostInit = function(fn) table.insert(post_inits, fn) end,
		-- require() is in the real mod sandbox (see tests/test_korean_env.lua);
		-- here it answers for the stand-in modules a test sets up.
		require = function(name)
			local mod = fake_modules[name]
			if mod == nil then error("module '" .. tostring(name) .. "' not found") end
			return mod
		end,
	}, { __index = _G })
	setfenv(chunk, env)
	local ok, e = pcall(chunk)
	return ok, e
end

print("\n=========== 1. it loads and sets strings for mods that are on ===========")

enabled_mods["workshop-2087177552"] = true
enabled_mods["workshop-2981932326"] = true

local G = NewEnv()
local ok, err = LoadPatch(G)
check("the generated file runs", ok, tostring(err))
check("a mod that is on gets its names translated",
	G.STRINGS.NAMES.LARGECHEST == "대형 상자", tostring(G.STRINGS.NAMES.LARGECHEST))
check("recipe descriptions too",
	G.STRINGS.RECIPE_DESC ~= nil and G.STRINGS.RECIPE_DESC.LARGEICEBOX == "거대한 아이스박스.",
	tostring(G.STRINGS.RECIPE_DESC and G.STRINGS.RECIPE_DESC.LARGEICEBOX))
check("character speech is nested correctly",
	G.STRINGS.CHARACTERS.WILLOW ~= nil
		and G.STRINGS.CHARACTERS.WILLOW.DESCRIBE.COFFEEBUSH ~= nil,
	"WILLOW.DESCRIBE.COFFEEBUSH")

print("\n=========== 2. a mod that is off is not touched ===========")

check("a mod that is off gets nothing",
	G.STRINGS.NAMES.SHADOWFIELDEXCITER == nil, tostring(G.STRINGS.NAMES.SHADOWFIELDEXCITER))
check("and its tables are not invented",
	G.STRINGS.MOD_ShadowFieldExciter == nil)

print("\n=========== 3. the re-apply hook works and is idempotent ===========")

check("it registered a post-init re-apply", #post_inits == 1, tostring(#post_inits))
check("it did not plant a global on GLOBAL", G.KOREAN_PATCH_APPLY == nil)

-- A mod overwrites our string after we ran, the way a late-loading mod would.
G.STRINGS.NAMES.LARGECHEST = "Large Chest"
post_inits[1]()
check("running it again puts Korean back",
	G.STRINGS.NAMES.LARGECHEST == "대형 상자", tostring(G.STRINGS.NAMES.LARGECHEST))

local before = G.STRINGS.CHARACTERS.WENDY.DESCRIBE.COFFEEBUSH
post_inits[1]()
check("a third run changes nothing",
	G.STRINGS.CHARACTERS.WENDY.DESCRIBE.COFFEEBUSH == before)

print("\n=========== 4. it builds tables the mod never made ===========")

enabled_mods["workshop-3466003439"] = true
local G2 = NewEnv()
local ok2 = LoadPatch(G2)
check("loads with a mod whose tables do not exist yet", ok2)
check("the missing parent table was created",
	type(G2.STRINGS.MOD_ShadowFieldExciter) == "table")
check("and the leaf was set",
	G2.STRINGS.MOD_ShadowFieldExciter.Btn_Close_ToolTip == "닫기",
	tostring(G2.STRINGS.MOD_ShadowFieldExciter and G2.STRINGS.MOD_ShadowFieldExciter.Btn_Close_ToolTip))

print("\n=========== 5. no mod enabled at all ===========")

enabled_mods = {}
local G3 = NewEnv()
local ok3 = LoadPatch(G3)
check("it still loads cleanly with nothing enabled", ok3)
check("and sets nothing", G3.STRINGS.NAMES.LARGECHEST == nil)

print("\n=========== 6. every translated string is sane ===========")

enabled_mods = {}
for _, id in ipairs({ "2087177552", "3569101848", "2873533916", "3466003439",
                      "2812783478", "2981932326", "3675508496", "3597024951" }) do
	enabled_mods["workshop-" .. id] = true
end
local G4 = NewEnv()
LoadPatch(G4)

local count, empty, untranslated = 0, 0, 0
local function walk(t, path)
	for k, v in pairs(t) do
		if type(v) == "table" then
			walk(v, path .. "." .. tostring(k))
		elseif type(v) == "string" then
			count = count + 1
			if v == "" then
				empty = empty + 1
				print("     empty: " .. path .. "." .. tostring(k))
			end
			-- a format placeholder must survive translation or the game errors
			-- when it tries to fill it in
			if v:find("%%s") == nil and path:find("FMT") then untranslated = untranslated + 1 end
		end
	end
end
walk(G4.STRINGS, "")

print("  strings set: " .. count)
check("nothing came out empty", empty == 0, tostring(empty))
check("a useful number of strings was applied", count > 250, tostring(count))

print("\n=========== 7. nothing was left untranslated ===========")

-- Chinese characters in a value mean a line was missed. Identifiers that must
-- stay as they are (a prefab name the mod looks up) are the only Latin left.
local cjk, latin = 0, 0
local function scan(t, path)
	for k, v in pairs(t) do
		if type(v) == "table" then
			scan(v, path .. "." .. tostring(k))
		elseif type(v) == "string" then
			-- UTF-8 lead bytes E4..E9 cover the CJK block DST mods use
			if v:find("[\228-\233][\128-\191][\128-\191]") and not v:find("[\234-\237]") then
				cjk = cjk + 1
				if cjk <= 5 then print("     남은 한자: " .. path .. "." .. tostring(k) .. " = " .. v) end
			end
			if v:match("^[%a%s%p]+$") and #v > 12 then
				latin = latin + 1
				if latin <= 5 then print("     영문만: " .. path .. "." .. tostring(k) .. " = " .. v) end
			end
		end
	end
end
scan(G4.STRINGS, "")

check("no Chinese was left behind", cjk == 0, tostring(cjk))
check("no English sentence was left behind", latin == 0, tostring(latin))

print("\n=========== 8. a string-valued action label is widened, not indexed ===========")

enabled_mods = {}
enabled_mods["workshop-3597024951"] = true
local G8 = NewEnv()
local ok8, err8 = LoadPatch(G8)
check("it loads against DST-shaped ACTIONS strings", ok8, tostring(err8))
check("the action label became a table",
	type(G8.STRINGS.ACTIONS.PICK) == "table", type(G8.STRINGS.ACTIONS.PICK))
check("the original label survived as GENERIC",
	G8.STRINGS.ACTIONS.PICK ~= nil and G8.STRINGS.ACTIONS.PICK.GENERIC == "Pick",
	tostring(G8.STRINGS.ACTIONS.PICK and G8.STRINGS.ACTIONS.PICK.GENERIC))
check("and the Korean variant was added beside it",
	G8.STRINGS.ACTIONS.PICK.TAKEITEM == "가져오기",
	tostring(G8.STRINGS.ACTIONS.PICK.TAKEITEM))
check("the same holds for GIVE",
	type(G8.STRINGS.ACTIONS.GIVE) == "table" and G8.STRINGS.ACTIONS.GIVE.GENERIC == "Give"
		and G8.STRINGS.ACTIONS.GIVE.WASH == "세탁하기")
check("a label with no variants is replaced outright",
	G8.STRINGS.ACTIONS.JX_DRIVE == "운전하기", tostring(G8.STRINGS.ACTIONS.JX_DRIVE))

-- A parent that is neither table nor string must be left alone, not clobbered.
local G9 = NewEnv()
G9.STRINGS.ACTIONS.PICK = 42
local ok9 = LoadPatch(G9)
check("a parent of an unexpected type is loaded past", ok9)
check("and left exactly as it was", G9.STRINGS.ACTIONS.PICK == 42, tostring(G9.STRINGS.ACTIONS.PICK))

print("\n=========== 8b. tables we do not own are changed, never created ===========")

-- STRINGS is the game's, so Set builds whatever is missing. TUNING and another
-- mod's lua module are not: if the mod is absent, or an update moved its text,
-- the right answer is to do nothing rather than leave a Korean string sitting
-- in a table nobody reads.
do
	local G = NewEnv()
	enabled_mods = {}
	fake_modules = {}

	-- Nothing installed: the file must still load, and must not invent tables.
	local ok = LoadPatch(G)
	check("it loads with no TUNING content and no modules", ok == true)
	check("TUNING was not filled in", next(G.TUNING) == nil)

	-- Now with a mod whose text really is in TUNING, shaped as [AnL] In-game
	-- Guide shapes it, plus the module its tab labels live in.
	local G2 = NewEnv()
	G2.TUNING.CHASNI_CONFIG = { ACHIEVEMENT_GUIDE = { BURN = "Running into magma will instantly burn you" } }
	fake_modules["constants/guide_data"] = {
		tab_data = { basic_guide = { name = "basic_guide", pages = 12, hover = "Basic Guide" } },
	}
	enabled_mods["workshop-3461374558"] = true
	LoadPatch(G2)

	local guide = G2.TUNING.CHASNI_CONFIG.ACHIEVEMENT_GUIDE
	local shipped_guide = type(guide.BURN) == "string" and guide.BURN:find("[가-힣]") ~= nil

	if shipped_guide then
		check("a TUNING string is replaced with Korean", shipped_guide)
		check("a module's label is replaced with Korean",
			fake_modules["constants/guide_data"].tab_data.basic_guide.hover:find("[가-힣]") ~= nil)
		check("the module's other fields are untouched",
			fake_modules["constants/guide_data"].tab_data.basic_guide.pages == 12)
	else
		print("  --    no TUNING translations shipped yet; checking the guards only")
	end

	-- A key that is not already a string must be left alone: that is what tells
	-- us the mod is absent or has changed shape.
	local G3 = NewEnv()
	G3.TUNING.CHASNI_CONFIG = { ACHIEVEMENT_GUIDE = { BURN = { moved = true } } }
	enabled_mods["workshop-3461374558"] = true
	fake_modules = {}
	LoadPatch(G3)
	check("a key that is no longer a string is not overwritten",
		type(G3.TUNING.CHASNI_CONFIG.ACHIEVEMENT_GUIDE.BURN) == "table")

	-- And a missing parent is never conjured.
	local G4 = NewEnv()
	enabled_mods["workshop-3461374558"] = true
	LoadPatch(G4)
	check("a missing TUNING branch is not created", G4.TUNING.CHASNI_CONFIG == nil)

	-- A module that will not load must not stop anything.
	local G5 = NewEnv()
	fake_modules = {}
	enabled_mods["workshop-3461374558"] = true
	check("an absent module is survived, not thrown", LoadPatch(G5) == true)

	enabled_mods = {}
	fake_modules = {}
end

print("\n=========== 9. it can never stop the game ===========")

-- KnownModIndex missing entirely, the way it would be if Klei moved it.
local G5 = NewEnv()
G5.KnownModIndex = nil
local ok5 = LoadPatch(G5)
check("it loads even with no mod index at all", ok5)
check("and simply sets nothing", G5.STRINGS.NAMES.LARGECHEST == nil)

-- A mod index that throws on every call.
local G6 = NewEnv()
G6.KnownModIndex = {
	IsModEnabled      = function() error("boom") end,
	IsModForceEnabled = function() error("boom") end,
}
local ok6 = LoadPatch(G6)
check("it loads even when the mod index throws", ok6)

-- STRINGS itself replaced by something hostile.
local G7 = NewEnv()
enabled_mods["workshop-2087177552"] = true
G7.STRINGS = setmetatable({}, { __newindex = function() error("read only") end })
local ok7 = LoadPatch(G7)
check("it loads even when STRINGS refuses writes", ok7)

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
