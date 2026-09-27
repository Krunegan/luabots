-- Game compatibility layer. LuaBots does not depend on any game: everything here is optional and falls back to generic behaviour.

local compat = {}
luabots.compat = compat

local function has_mod(name)
	return core.get_modpath(name) ~= nil
end

compat.game = "generic"
if has_mod("mcl_core") then
	compat.game = "mineclone"
elseif has_mod("default") then
	compat.game = "minetest_game"
end

-- Node sounds

function compat.metal_sounds()
	if has_mod("default") and default and default.node_sound_metal_defaults then
		return default.node_sound_metal_defaults()
	elseif has_mod("mcl_sounds") and mcl_sounds and mcl_sounds.node_sound_metal_defaults then
		return mcl_sounds.node_sound_metal_defaults()
	end
	return {
		footstep = {name = "luabots_step", gain = 0.3},
		dig = {name = "luabots_step", gain = 0.5},
		dug = {name = "luabots_ok", gain = 0.5},
		place = {name = "luabots_step", gain = 0.6},
	}
end

function compat.stone_sounds()
	if has_mod("default") and default and default.node_sound_stone_defaults then
		return default.node_sound_stone_defaults()
	elseif has_mod("mcl_sounds") and mcl_sounds and mcl_sounds.node_sound_stone_defaults then
		return mcl_sounds.node_sound_stone_defaults()
	end
	return compat.metal_sounds()
end

-- Extra groups so our nodes can be dug with the game's tools
function compat.node_groups(base)
	local g = table.copy(base)
	g.cracky = g.cracky or 2
	-- MineClone / VoxeLibre use pickaxey + hardness
	g.pickaxey = g.pickaxey or 1
	g.handy = g.handy or 1
	return g
end

compat.mcl_hardness = 2

-- Crafting materials (first registered item wins)

local materials = {
	metal = {"default:steel_ingot", "mcl_core:iron_ingot"},
	gem = {"default:mese_crystal", "mesecons:redstone", "mcl_core:emerald"},
	glass = {"default:glass", "mcl_core:glass"},
	stick = {"default:stick", "mcl_core:stick"},
	paper = {"default:paper", "mcl_core:paper"},
	copper = {"default:copper_ingot", "mcl_copper:copper_ingot", "mcl_core:gold_ingot"},
	stone = {"default:cobble", "mcl_core:cobble"},
}

function compat.material(kind)
	for _, name in ipairs(materials[kind] or {}) do
		if core.registered_items[name] then
			return name
		end
	end
	return nil
end

-- Books
-- Readers return title, text, author for a written item.
-- Writers turn a blank item into a written one.

compat.book_readers = {}
compat.book_writers = {}

function compat.register_book_reader(itemname, fn)
	compat.book_readers[itemname] = fn
end

function compat.register_book_writer(itemname, fn)
	compat.book_writers[itemname] = fn
end

-- Minetest Game books
compat.register_book_reader("default:book_written", function(stack)
	local meta = stack:get_meta()
	return meta:get_string("title"), meta:get_string("text"), meta:get_string("owner")
end)

compat.register_book_writer("default:book", function(stack, title, text, author)
	local out = ItemStack("default:book_written")
	local meta = out:get_meta()
	meta:set_string("title", title)
	meta:set_string("text", text)
	meta:set_string("owner", author)
	meta:set_int("page", 1)
	meta:set_int("page_max", math.max(1, math.ceil(#text / 400)))
	meta:set_string("description", ("\"%s\" by %s"):format(title, author))
	return out
end)

-- MineClone / VoxeLibre books
compat.register_book_reader("mcl_books:written_book", function(stack)
	local meta = stack:get_meta()
	return meta:get_string("title"), meta:get_string("text"), meta:get_string("author")
end)
compat.register_book_reader("mcl_books:writable_book", function(stack)
	local meta = stack:get_meta()
	return "", meta:get_string("text"), ""
end)

compat.register_book_writer("mcl_books:writable_book", function(stack, title, text, author)
	local out = ItemStack("mcl_books:written_book")
	local meta = out:get_meta()
	meta:set_string("title", title)
	meta:set_string("text", text)
	meta:set_string("author", author)
	meta:set_string("description", ("\"%s\" by %s"):format(title, author))
	return out
end)

-- Fuel / cooking helpers

function compat.fuel_time(stack)
	local res = core.get_craft_result({method = "fuel", width = 1, items = {stack}})
	return res and res.time or 0, res
end

function compat.cook_result(stack)
	local res, dec = core.get_craft_result({method = "cooking", width = 1, items = {stack}})
	if not res or res.time == 0 or res.item:is_empty() then
		return nil
	end
	return res, dec
end
