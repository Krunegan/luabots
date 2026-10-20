-- Unloader: moves what arrives in a linked chest to a normal chest
-- Linked chest (receive mode) in front of the robot, normal chest behind it.
while true do
	if inv.take("forward", nil, 99) > 0 then
		for _, item in ipairs(inv.list()) do
			inv.put("back", item.name, item.count)
		end
	else
		sleep(5)
	end
end
