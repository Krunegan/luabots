-- Guard: attacks monsters that come close (combat must be enabled on the server)
-- Give the robot a sword in its tool slot for more damage.
while true do
	for _, obj in ipairs(sense.objects(8, "entity")) do
		if obj.name:find("monster") then
			local target = vector.round(obj.pos)
			move.to(vector.offset(target, 1, 0, 0))
			combat.attack(obj.name)
		end
	end
	sleep(0.5)
end
