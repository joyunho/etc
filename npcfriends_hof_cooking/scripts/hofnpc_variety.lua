-- hofnpc_variety.lua
-- Keeps a short memory of what the chef NPC recently cooked and turns that
-- memory into a score penalty, so the same dish stops coming out of the pot
-- over and over.

local Core = require("hofnpc_core")

local Variety = {}

local HISTORY_MAX = 40

-- Newest entry is at the end of the array.
Variety.history = {}

function Variety.Reset()
	Variety.history = {}
end

function Variety.Record(product)
	if product == nil then
		return
	end

	local h = Variety.history
	h[#h + 1] = product

	while #h > HISTORY_MAX do
		table.remove(h, 1)
	end
end

-- How many cooks ago this dish was last made.
-- 1 == the dish that just came out of the pot. nil == not in memory at all.
function Variety.CooksAgo(product)
	local h = Variety.history
	local n = #h

	for i = n, 1, -1 do
		if h[i] == product then
			return n - i + 1
		end
	end

	return nil
end

-- score = food value
--         - repeat_penalty  * (how many are already stored)
--         - recency_penalty * (how recently we cooked it)
--         + novelty_bonus   (never cooked in this session)
--         + jitter          (breaks ties so equal dishes alternate)
function Variety.Score(product, base_value, already_stored, preset)
	preset = preset or Core.Variety()

	local score = base_value

	score = score - (already_stored or 0) * preset.repeat_penalty

	local ago = Variety.CooksAgo(product)
	if ago ~= nil then
		-- Linear falloff: the most recent dish takes the full penalty, a dish
		-- HISTORY_MAX cooks back takes none.
		local freshness = math.max(0, HISTORY_MAX - ago + 1) / HISTORY_MAX
		score = score - preset.recency_penalty * freshness
	else
		score = score + preset.novelty_bonus
	end

	if preset.jitter > 0 then
		score = score + math.random() * preset.jitter
	end

	return score
end

return Variety
