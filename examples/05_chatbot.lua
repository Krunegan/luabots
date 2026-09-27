-- Chat bot: answers messages said near it
-- Say: "bot hello", "bot time", "bot follow", "bot stop"
-- or talk to it from anywhere: /luabots msg <robot name> hello
chat.listen(true)
local following = nil

local function answer(name, msg)
	msg = msg:lower()
	if msg:find("hello") then
		chat.tell(name, "Hello " .. name .. "!")
	elseif msg:find("time") then
		local t = sense.time_of_day() * 24
		chat.tell(name, ("It is %02d:%02d"):format(math.floor(t), math.floor((t % 1) * 60)))
	elseif msg:find("follow") then
		following = name
		chat.tell(name, "Following " .. name)
	elseif msg:find("stop") then
		following = nil
		chat.tell(name, "OK, staying here")
	end
end

while true do
	local name, msg, direct = chat.receive()
	if name and (direct or msg:lower():find("^bot")) then
		answer(name, msg)
	end
	if following then
		for _, obj in ipairs(sense.objects(nil, "player")) do
			if obj.name == following then
				local target = vector.round(obj.pos)
				if vector.distance(target, robot.pos()) > 2 then
					move.to(vector.offset(target, 1, 0, 0))
				end
			end
		end
	end
	sleep(0.3)
end
