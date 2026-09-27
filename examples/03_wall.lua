-- Wall builder: builds a wall to the right while moving forward
-- Put building blocks in the robot inventory and set BLOCK.
local BLOCK = "default:cobble"   -- MineClone / VoxeLibre: "mcl_core:cobble"
local LENGTH, HEIGHT = 8, 3

for x = 1, LENGTH do
	for y = 1, HEIGHT do
		if not inv.has(BLOCK) then
			chat.owner("I need more " .. BLOCK)
			return
		end
		place.right(BLOCK)
		if y < HEIGHT then move.up() end
	end
	for y = 1, HEIGHT - 1 do move.down() end
	move.forward()
end
print("Wall done")
