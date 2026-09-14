-- test_korean_env.lua
--
-- Runs the generated modmain.lua inside the environment Don't Starve Together
-- actually gives a mod -- not one I imagined.
--
-- The mod sandbox is built by CreateEnvironment() in Klei's mods.lua as a flat
-- table with NO metatable, so a mod can only see the names that table holds.
-- pcall, select, error, setmetatable and most of the Lua standard library are
-- NOT among them; reaching for one gets nil and the mod dies on the spot.
--
-- So this test reads Klei's own mods.lua and modutil.lua, takes the name list
-- straight out of the source, and runs the patch under exactly that. If Klei
-- changes the sandbox, this test changes with it.
--
--   lua5.1 tests/test_korean_env.lua [path-to-dst-scripts]

local DST = arg[1] or "/tmp/claude-0/-home-user-etc/535ff019-a8c4-5c97-985d-74a2ab67890d/scratchpad"

local failures = 0
local function check(label, ok, detail)
	if ok then
		print("  PASS  " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

local function slurp(path)
	local f = io.open(path, "r")
	if f == nil then return nil end
	local t = f:read("*a")
	f:close()
	return t
end

-- ── the sandbox, read out of Klei's source ─────────────────────────────────

local mods_src = slurp(DST .. "/mods.lua")
if mods_src == nil then
	print("  SKIP  no mods.lua at " .. DST)
	os.exit(0)
end

-- CreateEnvironment's literal table: every "name =" line up to the closing brace
local env_names = {}
do
	local from = mods_src:find("function CreateEnvironment", 1, true)
	local tbl_from = mods_src:find("local env =", from, true)
	local tbl_to = mods_src:find("if isworldgen == false", tbl_from, true)
	for name in mods_src:sub(tbl_from, tbl_to):gmatch("\n%s*([A-Za-z_][%w_]*)%s*=") do
		env_names[name] = true
	end
end

-- everything modutil hands the mod on top of that (AddSimPostInit and friends)
local modutil_src = slurp(DST .. "/modutil.lua")
if modutil_src ~= nil then
	for name in modutil_src:gmatch("\n%s*env%.([A-Za-z_][%w_]*)%s*=") do
		env_names[name] = true
	end
end

local n_env = 0
for _ in pairs(env_names) do n_env = n_env + 1 end
check("the sandbox was read from Klei's source", n_env > 10, tostring(n_env) .. " names")
check("and it does not include pcall",  env_names.pcall  == nil)
check("and it does not include select", env_names.select == nil)

-- ── the game side of GLOBAL ────────────────────────────────────────────────

local post_inits

local function NewGlobal()
	-- GLOBAL is the game's _G: the whole Lua standard library plus the game's
	-- own tables. DST's ACTIONS labels are plain strings, which is what broke
	-- the first version.
	local G = {
		pcall = pcall, select = select, type = type, error = error,
		tostring = tostring, pairs = pairs, ipairs = ipairs,
		table = table, string = string, math = math,
		STRINGS = {
			NAMES = {}, CHARACTERS = {}, UI = {},
			ACTIONS = { PICK = "Pick", GIVE = "Give", DEPLOY = "Deploy",
			            TEACH = "Learn", START_PUSHING = "Push" },
		},
		KnownModIndex = {
			IsModEnabled      = function(self, name) return true end,
			IsModForceEnabled = function(self, name) return false end,
		},
	}
	return G
end

local function RunModmain(G)
	post_inits = {}

	local chunk, err = loadfile("korean_patch/modmain.lua")
	if chunk == nil then return false, err end

	-- exactly what CreateEnvironment builds: a flat table, no metatable.
	local env = {}
	for name in pairs(env_names) do
		env[name] = _G[name]        -- most are nil, which is the point
	end
	env.GLOBAL = G
	env.modname = "mod_korean_patch"
	env.MODROOT = "mods/mod_korean_patch/"
	env.env = env
	env.AddSimPostInit = function(fn) table.insert(post_inits, fn) end
	env.print = print
	env.type = type

	-- RunInEnvironment(fn, env) in Klei's util.lua
	setfenv(chunk, env)
	return xpcall(chunk, debug.traceback)
end

print("\n=========== 1. it runs inside the real sandbox ===========")

local G = NewGlobal()
local ok, err = RunModmain(G)
check("modmain.lua runs with no metatable fallback to _G", ok, tostring(err))

print("\n=========== 2. it actually translated something ===========")

local count = 0
local function walk(t)
	for _, v in pairs(t) do
		if type(v) == "table" then walk(v)
		elseif type(v) == "string" then count = count + 1 end
	end
end
if ok then walk(G.STRINGS) end
print("  strings set: " .. count)
check("over a thousand strings landed", count > 1200, tostring(count))
check("a name was translated", G.STRINGS.NAMES.JX_POTTED == "브라질나무 화분",
	tostring(G.STRINGS.NAMES.JX_POTTED))

print("\n=========== 3. a string-valued action label was widened ===========")

check("PICK became a table", type(G.STRINGS.ACTIONS.PICK) == "table",
	type(G.STRINGS.ACTIONS.PICK))
check("its original label is kept as GENERIC",
	type(G.STRINGS.ACTIONS.PICK) == "table" and G.STRINGS.ACTIONS.PICK.GENERIC == "Pick")
check("and the Korean variant sits beside it",
	type(G.STRINGS.ACTIONS.PICK) == "table" and G.STRINGS.ACTIONS.PICK.TAKEITEM == "가져오기")

print("\n=========== 4. the re-apply hook was registered ===========")

check("AddSimPostInit was called once", #post_inits == 1, tostring(#post_inits))
if #post_inits == 1 then
	G.STRINGS.NAMES.JX_POTTED = "Potted Plant"
	local ok2 = pcall(post_inits[1])
	check("running it again does not raise", ok2)
	check("and it puts Korean back", G.STRINGS.NAMES.JX_POTTED == "브라질나무 화분",
		tostring(G.STRINGS.NAMES.JX_POTTED))
end

print("\n=========== 5. it survives a hostile game side ===========")

local G3 = NewGlobal()
G3.KnownModIndex = nil
check("no mod index at all", (RunModmain(G3)))

local G4 = NewGlobal()
G4.KnownModIndex = {
	IsModEnabled      = function() error("boom") end,
	IsModForceEnabled = function() error("boom") end,
}
check("a mod index that throws", (RunModmain(G4)))

local G5 = NewGlobal()
G5.STRINGS.ACTIONS.PICK = 42
local ok5 = RunModmain(G5)
check("a parent of an unexpected type", ok5)
check("and it is left alone", G5.STRINGS.ACTIONS.PICK == 42, tostring(G5.STRINGS.ACTIONS.PICK))

print("\n=========== 6. modinfo.lua runs in its own, tighter sandbox ===========")

-- InitializeModInfo in Klei's modindex.lua hands modinfo.lua a table with
-- three names in it and nothing else, then requires a fixed set of fields.
local info_names = {}
do
	local src = slurp(DST .. "/modindex.lua")
	if src ~= nil then
		local from = src:find("function ModIndex:InitializeModInfo", 1, true)
		local to = src:find("kleiloadlua", from, true)
		for name in src:sub(from, to):gmatch("\n%s*([A-Za-z_][%w_]*)%s*=") do
			info_names[name] = true
		end
	end
end

local info_env = {}
for name in pairs(info_names) do info_env[name] = _G[name] end
info_env.locale = "ko"
info_env.folder_name = "mod_korean_patch"
info_env.ChooseTranslationTable = function(tbl) return tbl[1] end

local ichunk, ierr = loadfile("korean_patch/modinfo.lua")
check("modinfo.lua parses", ichunk ~= nil, tostring(ierr))
if ichunk ~= nil then
	setfenv(ichunk, info_env)
	local iok, ie = xpcall(ichunk, debug.traceback)
	check("modinfo.lua runs in its sandbox", iok, tostring(ie))

	-- the fields InitializeModInfo insists on, taken from its own checkinfo list
	for _, field in ipairs({ "name", "description", "author", "version",
	                         "api_version", "dst_compatible" }) do
		check("modinfo declares " .. field, info_env[field] ~= nil)
	end
	check("api_version is a number", type(info_env.api_version) == "number",
		type(info_env.api_version))
	check("priority is a number", info_env.priority == nil or type(info_env.priority) == "number")
	check("it is marked client-only", info_env.client_only_mod == true)
end

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
