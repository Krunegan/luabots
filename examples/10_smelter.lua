-- Smelter: burns fuel to get energy, then cooks everything it can
-- Put fuel (coal, wood...) and ores in the robot inventory.
local FUELS = {"default:coal_lump", "default:tree", "mcl_core:coal_lump", "mcl_core:tree"}

for _, fuel in ipairs(FUELS) do
	-- pcall: the item may not exist in this game
	local ok, gained = pcall(machine.burn, fuel, 10)
	if ok and gained and gained > 0 then
		print("energy from " .. fuel .. ": " .. gained)
	end
end
print("energy:", machine.energy())

for _, item in ipairs(inv.list()) do
	local cooked = machine.cook(item.name, item.count)
	if cooked and cooked > 0 then
		print("cooked " .. cooked .. " x " .. item.name)
	end
end
print("energy left:", machine.energy())
