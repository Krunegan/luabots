-- Tunnel digger: digs a 1x2 tunnel forward
-- Put a pickaxe in the robot tool slot and some coal in its inventory
-- (digging uses energy; the robot burns the coal by itself).
local LENGTH = 20

for i = 1, LENGTH do
	dig.forward()          -- lower block
	dig.forward_up()       -- upper block
	local ok, why = move.forward()
	if not ok then
		print("stopped at step " .. i .. ": " .. why)
		break
	end
	inv.pickup(2)          -- collect dropped items
end

-- come back
turn.around()
while vector.distance(robot.pos(), robot.home()) > 1.5 do
	if not move.forward() then break end
end
chat.owner("Tunnel finished!")
