-- Item collector: patrols a square and picks up items on the ground
local SIZE = 6

while true do
	for side = 1, 4 do
		for step = 1, SIZE do
			move.forward()
			local n = inv.pickup(2)
			if n > 0 then print("picked up " .. n .. " items") end
		end
		turn.right()
	end
	if inv.free() == 0 then
		chat.owner("My inventory is full!")
		sleep(30)
	end
end
