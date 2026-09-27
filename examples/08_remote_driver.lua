-- Remote driver: control the robot with a linked Remote Control
-- Link: place the remote on this robot's base.
-- Punch a node with the remote = the robot goes there.
-- Punch the air = move forward. Place/right-click = turn right.
chat.owner("Ready for remote control")
while true do
	local player, action, pos = remote.receive()
	if player then
		if action == "use" and pos then
			print(player .. " sent me to " .. vector.to_string(pos))
			local ok, why = move.to(vector.offset(pos, 0, 1, 0))
			if not ok then print("cannot go there: " .. tostring(why)) end
		elseif action == "use" then
			move.forward()
		elseif action == "place" then
			turn.right()
		end
	end
	sleep(0.05)
end
