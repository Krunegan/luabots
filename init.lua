-- LuaBots: programmable robots for Luanti
-- Code: MIT license. Media: CC BY-SA 4.0. See LICENSE.txt

luabots = {}

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

luabots.modname = modname
luabots.modpath = modpath
luabots.S = core.get_translator(modname)
luabots.mod_storage = core.get_mod_storage()

local modules = {
	"config", -- settings and privilege levels
	"util", -- directions, validation, small helpers
	"compat", -- game detection (Minetest Game, MineClone/VoxeLibre, others)
	"lexer", -- Lua tokenizer used for static checks
	"luapattern", -- pure Lua implementation of Lua patterns (interruptible)
	"safestd", -- sandboxed versions of string/table/os/... libraries
	"sandbox", -- program environment, instruction and memory limits
	"records", -- persistent robot data and inventories
	"fakeplayer", -- player-like object used when robots interact with nodes
	"runtime", -- robot program scheduler
	"fullaccess", -- the real server API for robots of the server owner
	"api_core", -- robot.*, print, sleep, storage, ...
	"api_world", -- move, turn, dig, place, sense
	"api_items", -- inventory, crafting, machine
	"api_comm", -- chat, net, forms, remote, keyboard, books
	"api_extra", -- path finding, combat, admin
	"api_more", -- players, crypto, energy transfer, punch events
	"api_act", -- inv.use, interact, jobs, status, shop
	"api_build", -- blueprints and build.fill
	"entity", -- the robot body
	"nodes", -- robot base, keys, remote, disk, recipes
	"gui", -- editor, inventory and console formspecs
	"help", -- in-game manual
	"manual", -- manual driving with the remote control
	"remote", -- remote keys and the shared control panel
	"display", -- text on the robot face and the screen block
	"appearance", -- robot.appearance / robot.animation
	"hud", -- robot tracking on the HUD
	"commands", -- chat commands
}

-- Code of these modules runs inside robot programs (with the instruction hook active), so it must not be JIT compiled: compiled loops do not trigger the hook.
local no_jit = {luapattern = true, safestd = true, sandbox = true}

for _, name in ipairs(modules) do
	local fn = assert(loadfile(modpath .. "/src/" .. name .. ".lua"))
	if no_jit[name] and jit then
		jit.off(fn, true)
	end
	fn()
end
