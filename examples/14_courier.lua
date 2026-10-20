-- Courier: sends everything it carries home through a linked chest
-- Put a linked chest (send mode) in front of the robot and another one at home
-- (receive mode, same channel). The robot pays the trip with its own coal.
local KEEP = {["default:coal_lump"] = true, ["mcl_core:coal_lump"] = true}

while true do
	for _, item in ipairs(inv.list()) do
		if not KEEP[item.name] then
			inv.put("forward", item.name, item.count)
		end
	end
	-- machine.charge(0) only reads the chest energy
	local _, energy = machine.charge(0)
	if energy and energy < 20 then machine.charge(40) end
	sleep(10)
end
