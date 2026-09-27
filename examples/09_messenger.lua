-- Messenger: robots talking to each other with net.*
-- Run it on two or more robots near each other.
net.broadcast({type = "hello", from = robot.name()})
while true do
	local from, data = net.receive()
	if from and type(data) == "table" then
		if data.type == "hello" then
			print("Robot " .. tostring(data.from) .. " (#" .. from .. ") said hello")
			net.send(from, {type = "reply", from = robot.name()})
		elseif data.type == "reply" then
			print("Robot " .. tostring(data.from) .. " answered")
		end
	end
	sleep(0.2)
end
