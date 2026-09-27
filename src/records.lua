-- Persistent robot data (mod storage) and robot inventories
-- A record holds everything that must survive a server restart: owner, name, base position, body position/facing, program code, running flag, energy, appearance, user storage and inventory.

local S = luabots.S
local storage = luabots.mod_storage
local config = luabots.config

local records = {}
local dirty = {}
luabots.records = records

local INV_SIZES = {main = 32, tool = 1, disks = 8}
luabots.INV_SIZES = INV_SIZES

local function key(id) return "robot_" .. id end

-- Load everything at startup
for _, k in ipairs(storage:get_keys()) do
	local id = k:match("^robot_(%d+)$")
	if id then
		local rec = core.deserialize(storage:get_string(k), true)
		if type(rec) == "table" and rec.owner then
			rec.id = id
			records[id] = rec
		end
	end
end

function luabots.get_record(id)
	return id and records[tostring(id)]
end

function luabots.mark_dirty(id)
	dirty[id] = true
end

function luabots.owner_count(owner)
	local n = 0
	for _, rec in pairs(records) do
		if rec.owner == owner then n = n + 1 end
	end
	return n
end

function luabots.new_record(owner, home)
	local next_id = storage:get_int("next_id")
	if next_id < 1 then next_id = 1 end
	storage:set_int("next_id", next_id + 1)
	local id = tostring(next_id)
	local n = 1
	local names = {}
	for _, rec in pairs(records) do
		if rec.owner == owner then names[rec.name] = true end
	end
	while names["robot" .. n] do n = n + 1 end
	local rec = {
		id = id,
		owner = owner,
		name = "robot" .. n,
		home = vector.copy(home),
		pos = vector.offset(home, 0, 1, 0),
		facing = 0,
		slot = 1, -- run ID: one running robot per ID and owner
		code = "",
		running = false,
		spawned = false,
		energy = 0,
		skin = 1,
		size = 1,
		label = "",
		data = {}, -- robot storage.* values
		inv = {}, -- serialized inventory lists
		created = os.time(),
	}
	records[id] = rec
	dirty[id] = true
	return rec
end

-- Inventories

local inventories = {}

local function inv_name(id) return "luabots_" .. id end

local function allowed(rec, player)
	local name = player and player:get_player_name() or ""
	return name == rec.owner or luabots.is_admin(name)
end

-- Items that can go in the library slots (programs load code from them)
local function library_item(stack)
	return luabots.read_book ~= nil and luabots.read_book(stack) ~= nil
end

function luabots.get_inventory(rec)
	local inv = inventories[rec.id]
	if inv then return inv end
	local id = rec.id
	inv = core.create_detached_inventory(inv_name(id), {
		allow_move = function(inv, from_list, from_index, to_list, _, count, player)
			local r = records[id]
			if not (r and allowed(r, player)) then return 0 end
			if to_list == "disks" then
				return library_item(inv:get_stack(from_list, from_index)) and 1 or 0
			end
			return count
		end,
		allow_put = function(_, list, _, stack, player)
			local r = records[id]
			if not (r and allowed(r, player)) then return 0 end
			-- the library only holds data disks and written books, one per slot
			if list == "disks" then return library_item(stack) and 1 or 0 end
			return stack:get_count()
		end,
		allow_take = function(_, _, _, stack, player)
			local r = records[id]
			return (r and allowed(r, player)) and stack:get_count() or 0
		end,
		on_move = function() dirty[id] = true end,
		on_put = function() dirty[id] = true end,
		on_take = function() dirty[id] = true end,
	}, rec.owner)
	for list, size in pairs(INV_SIZES) do
		inv:set_size(list, size)
		local saved = rec.inv[list]
		if saved then
			for i = 1, size do
				inv:set_stack(list, i, ItemStack(saved[i] or ""))
			end
		end
	end
	inventories[id] = inv
	return inv
end

function luabots.inventory_name(rec)
	return inv_name(rec.id)
end

function luabots.inventory_is_empty(rec)
	local inv = luabots.get_inventory(rec)
	for list in pairs(INV_SIZES) do
		if not inv:is_empty(list) then return false end
	end
	return true
end

local function store_inventory(rec)
	local inv = inventories[rec.id]
	if not inv then return end
	for list, size in pairs(INV_SIZES) do
		local out = {}
		for i = 1, size do
			out[i] = inv:get_stack(list, i):to_string()
		end
		rec.inv[list] = out
	end
end

-- Saving

local function save(id)
	local rec = records[id]
	if not rec then
		storage:set_string(key(id), "")
		return
	end
	store_inventory(rec)
	storage:set_string(key(id), core.serialize(rec))
end

function luabots.save_all(force)
	for id in pairs(force and records or dirty) do
		save(id)
	end
	dirty = {}
end

function luabots.delete_record(id)
	records[id] = nil
	if inventories[id] then
		core.remove_detached_inventory(inv_name(id))
		inventories[id] = nil
	end
	storage:set_string(key(id), "")
	dirty[id] = nil
end

local timer = 0
core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer >= config.save_interval then
		timer = 0
		luabots.save_all()
	end
end)

core.register_on_shutdown(function()
	luabots.save_all(true)
end)

-- Owner-facing display name
function luabots.display_name(rec)
	return rec.owner .. "/" .. rec.name
end

-- Find a record by "name" (own robots) or "owner/name" or id
function luabots.find_record(query, owner)
	if records[query] then return records[query] end
	local o, n = query:match("^([^/]+)/(.+)$")
	if not o then o, n = owner, query end
	for _, rec in pairs(records) do
		if rec.owner == o and rec.name == n then return rec end
	end
	return nil
end

luabots.S_inventory_title = S("Robot inventory")
