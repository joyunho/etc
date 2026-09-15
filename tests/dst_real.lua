-- dst_real.lua
--
-- Loads Don't Starve Together's own cooking system -- the real scripts/cooking.lua,
-- with the real 142 ingredients and the real Crock Pot recipes -- and then loads
-- the player's installed food mods on top of it, the way the game does.
--
-- Everything else in tests/ runs against dst_stub.lua, which is a careful
-- re-implementation. This one runs against the article itself, so a claim like
-- "the chef can now cook Halloween Theme Food's dishes" is measured against
-- that mod's actual recipes rather than a fixture written from reading them.
--
-- Nothing here is shipped and no mod code is copied into this repo: the caller
-- points it at a DST scripts folder and a Steam workshop folder it already has.
--
--   Load(dst_scripts)             -> cooking
--   AddMod(spec)                  -> registers one mod's recipes/ingredients
--
-- The handful of globals below are what the cooking chain reaches for on the
-- way up. They are stubs only in the sense that nothing in cooking.lua looks at
-- their contents -- the recipes, ingredients and tags are all genuine.

local Real = {}

local function deeptable()
	return setmetatable({},
	{
		__index    = function(t, k) local v = deeptable() rawset(t, k, v) return v end,
		__concat   = function() return "" end,
		__tostring = function() return "" end,
	})
end

function Real.Load(dst_scripts)
	if dst_scripts == nil or dst_scripts == "" then
		return nil, "no DST scripts folder given"
	end

	local probe = io.open(dst_scripts .. "/cooking.lua", "r")
	if probe == nil then
		return nil, dst_scripts .. "/cooking.lua not found"
	end
	probe:close()

	package.path = dst_scripts .. "/?.lua;" .. package.path

	-- strict.lua turns a read of an undeclared global into an error, which is
	-- right inside the game and wrong out here, where the engine has not
	-- declared any of them yet.
	package.loaded["strict"] = true

	_G.TheSim = { SeedRandomNumberGenerator = function() end, GetTick = function() return 0 end }
	_G.PLATFORM, _G.BRANCH, _G.APP_VERSION, _G.CONFIGURATION = "LINUX", "release", "0", "PRODUCTION"
	_G.kleifileexists = function() return false end
	_G.STRINGS = deeptable()

	require("class")
	require("constants")
	require("tuning")

	-- The ocean fish tables index these before worldgen has filled them in, and
	-- they must be the same table: the file writes through WORLD_TILES and
	-- reads back through GROUND.
	local tiles = setmetatable({},
		{ __index = function(t, k) local v = "TILE_" .. tostring(k) rawset(t, k, v) return v end })
	_G.WORLD_TILES, _G.GROUND = tiles, tiles

	local ok, cooking = pcall(require, "cooking")
	if not ok then
		return nil, tostring(cooking)
	end

	Real.cooking = cooking
	return cooking
end

-- The real scripts/containers.lua, which is where a station's slot count comes
-- from. It reaches for two things the engine would have provided; nothing else
-- in it is stubbed, so params.portablespicer.widget.slotpos is the genuine
-- article.
function Real.Containers()
	if _G.Vector3 == nil then
		_G.Vector3 = function(x, y, z) return { x = x, y = y, z = z } end
	end
	if _G.IsSteamDeck == nil then
		_G.IsSteamDeck = function() return false end
	end

	local ok, containers = pcall(require, "containers")
	if not ok then
		return nil, tostring(containers)
	end
	return containers
end

-- Heap of Foods registers its ingredients in one file, main/foods/hof_cooking.lua.
-- Running the whole of it outside the game is not realistic -- it reaches for
-- the engine in a dozen places -- but the ingredient registration happens near
-- the top, before any of that, and it is the only part this repo needs to know
-- about: it is what decides whether the chef will pick a bag of flour out of a
-- chest.
--
-- So it is run under pcall and the *outcome* is what gets checked, not whether
-- the file reached its last line. When Heap of Foods changes and the file stops
-- part way somewhere new, the caller sees no ingredients and skips, rather than
-- going red over something that is not this patch's business.
function Real.LoadHeapOfFoods(root)
	local probe = io.open(root .. "/main/foods/hof_cooking.lua", "r")
	if probe == nil then
		return nil, "hof_cooking.lua not found"
	end
	probe:close()

	package.path = root .. "/scripts/?.lua;" .. root .. "/main/?.lua;" .. package.path

	local function permissive()
		return setmetatable({},
		{
			__index = function(t, k) local v = permissive() rawset(t, k, v) return v end,
			__call = function() end, __concat = function() return "" end,
			__tostring = function() return "" end,
		})
	end

	_G.GLOBAL = _G

	-- strict.lua normally supplies global(); it is kept out of this harness, and
	-- with no strict mode there is nothing for it to declare.
	_G.global = _G.global or function() end

	_G.Asset = _G.Asset or function(kind, file) return { type = kind, file = file } end
	_G.PICKABLE_FOOD_PRODUCTS = _G.PICKABLE_FOOD_PRODUCTS or permissive()
	_G.AnimState = _G.AnimState or permissive()

	-- Its recipes read a pile of its own TUNING constants that live in a file we
	-- are not loading; anything missing answers 1.
	if getmetatable(_G.TUNING) == nil then
		setmetatable(_G.TUNING, { __index = function(t, k) rawset(t, k, 1) return 1 end })
	end

	local chunk, err = loadfile(root .. "/main/foods/hof_cooking.lua")
	if chunk == nil then
		return nil, err
	end

	setfenv(chunk, setmetatable(
	{
		GLOBAL              = _G,
		AddIngredientValues = _G.AddIngredientValues,
		AddCookerRecipe     = _G.AddCookerRecipe,
		modimport           = function() end,
		GetModConfigData    = function() return false end,
		Asset               = _G.Asset,
	}, { __index = _G }))

	local ok, err2 = pcall(chunk)

	-- The caller checks what registered, not whether it finished; the message is
	-- only there to say where it stopped when nothing did.
	return true, (not ok) and tostring(err2) or nil
end

-- One food mod, described the way its own modmain.lua registers things.
--   { root = "<workshop folder>",
--     scripts = "scripts",                       -- added to package.path
--     ingredients = { {names, tags, cancook, candry}, ... },
--     recipes = { { module = "htf_foodrecipes", cookers = {"cookpot", ...} }, ... },
--     files = { { path = "init/init_cooking.lua", cookers = "self" }, ... } }
--
-- Returns the set of dish names the mod added.
function Real.AddMod(spec)
	local added = {}

	if spec.scripts then
		package.path = spec.root .. "/" .. spec.scripts .. "/?.lua;" .. package.path
	end

	for _, ing in ipairs(spec.ingredients or {}) do
		_G.AddIngredientValues(ing[1], ing[2], ing[3], ing[4])
	end

	for _, entry in ipairs(spec.recipes or {}) do
		local list = require(entry.module)
		for _, cooker in ipairs(entry.cookers) do
			for _, recipe in pairs(list) do
				_G.AddCookerRecipe(cooker, recipe, true)
				added[recipe.name] = true
			end
		end
	end

	-- Some mods build their recipes inside a modimport'ed file rather than a
	-- module that returns a table. Those run with the mod environment, where
	-- GLOBAL is the game and AddCookerRecipe is supplied by modutil.
	for _, entry in ipairs(spec.files or {}) do
		local chunk, err = loadfile(spec.root .. "/" .. entry.path)
		if chunk == nil then
			return nil, err
		end

		local env = setmetatable(
		{
			GLOBAL = _G,
			AddCookerRecipe = function(cooker, recipe)
				_G.AddCookerRecipe(cooker, recipe, true)
				added[recipe.name] = true
			end,
			AddIngredientValues = _G.AddIngredientValues,
		}, { __index = _G })

		setfenv(chunk, env)

		local ok, e = pcall(chunk)
		if not ok then
			return nil, tostring(e)
		end
	end

	return added
end

return Real
