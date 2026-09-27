-- A player-like object used when a robot digs, places or uses things.
-- Node and item callbacks written for players then work unchanged, and all permission checks (protection, ownership) apply to the robot's owner.

local util = luabots.util

local function noop() end

local fake_meta = {
	get_string = function() return "" end,
	get_int = function() return 0 end,
	get_float = function() return 0 end,
	contains = function() return false end,
	to_table = function() return {fields = {}} end,
	get_keys = function() return {} end,
	set_string = noop, set_int = noop, set_float = noop, from_table = noop,
	mark_as_private = noop,
}

local methods = {}

function methods:get_player_name() return self._owner end
-- Like other fake players (fakelib, pipeworks) this reports false, so mods
-- that keep per-player data skip it; the name is still the owner's, so
-- protection and ownership checks apply to the owner.
function methods:is_player() return false end
function methods:is_valid() return true end
function methods:get_pos() return vector.copy(self._rec.pos) end
function methods:get_look_dir()
	return vector.copy(util.facing_vectors[self._rec.facing % 4])
end
function methods:get_look_horizontal() return util.facing_to_yaw(self._rec.facing) end
function methods:get_look_yaw() return util.facing_to_yaw(self._rec.facing) end
function methods:get_look_vertical() return 0 end
function methods:get_look_pitch() return 0 end
function methods:get_inventory() return luabots.get_inventory(self._rec) end
-- The wielded item is the tool slot, or the slot chosen with :wield()
function methods:get_wield_list() return self._wlist end
function methods:get_wield_index() return self._windex end
function methods:get_wielded_item()
	return luabots.get_inventory(self._rec):get_stack(self._wlist, self._windex)
end
function methods:set_wielded_item(stack)
	luabots.get_inventory(self._rec):set_stack(self._wlist, self._windex, ItemStack(stack))
	luabots.mark_dirty(self._rec.id)
	return true
end
function methods:wield(list, index)
	self._wlist, self._windex = list, index
end
-- A robot "sneaks" when it uses an item, so nodes do not take the click for themselves (like a player holding sneak)
function methods:set_sneak(on) self._sneak = on end
function methods:get_player_control()
	return {up = false, down = false, left = false, right = false, jump = false,
		aux1 = false, sneak = self._sneak == true, dig = false, place = false, LMB = false,
		RMB = false, zoom = false}
end
function methods:get_player_control_bits() return self._sneak and 64 or 0 end
function methods:get_meta() return fake_meta end
function methods:get_hp() return 20 end
function methods:get_breath() return 10 end
function methods:get_velocity() return vector.zero() end
function methods:get_properties() return {} end
function methods:get_armor_groups() return {} end
function methods:get_physics_override() return {speed = 1, jump = 1, gravity = 1} end
function methods:get_eye_offset() return vector.zero(), vector.zero() end
function methods:get_attach() return nil end
function methods:get_children() return {} end
function methods:get_luaentity() return nil end
function methods:get_player_velocity() return vector.zero() end
function methods:hud_get_flags() return {} end
function methods:get_nametag_attributes() return {text = ""} end
function methods:get_fov() return 0, false, 0 end
function methods:get_formspec_prepend() return "" end
function methods:get_inventory_formspec() return "" end

local mt = {
	__index = function(_, k)
		local m = methods[k]
		if m then return m end
		-- unknown methods (set_*, hud_*, ...) do nothing
		return noop
	end,
}

function luabots.get_fake_player(rec)
	return setmetatable({
		_rec = rec,
		_owner = rec.owner,
		_wlist = "tool",
		_windex = 1,
		is_fake_player = "luabots",
	}, mt)
end
