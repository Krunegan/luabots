-- Lights Out: a puzzle game played by punching keys
-- Punch a light to toggle it and its neighbours. Turn them all off!
-- Placing keys needs the luabots privilege (server setting luabots.keyboard_level).
local N = 5
local p = robot.pos()
local origin = {x = p.x + 2, y = p.y, z = p.z - 2}   -- the board stands to the east
local on = {}

local function key_at(i, j)
	return {x = origin.x, y = origin.y + j - 1, z = origin.z + i - 1}
end

local function draw_all()
	for i = 1, N do
		for j = 1, N do
			keyboard.set(key_at(i, j), on[i][j] and "yellow" or "gray")
		end
	end
end

local function press(i, j)
	for _, d in ipairs({{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
		local a, b = i + d[1], j + d[2]
		if on[a] and on[a][b] ~= nil then on[a][b] = not on[a][b] end
	end
end

for i = 1, N do
	on[i] = {}
	for j = 1, N do on[i][j] = false end
end
-- random but always solvable start: apply random presses
for _ = 1, 8 do press(math.random(N), math.random(N)) end
draw_all()
chat.nearby("Lights Out! Turn off every light.")

local moves = 0
while true do
	local player, key, pos = keyboard.receive()
	if player then
		local i, j = pos.z - origin.z + 1, pos.y - origin.y + 1
		if on[i] and on[i][j] ~= nil then
			press(i, j)
			moves = moves + 1
			draw_all()
			local left = 0
			for a = 1, N do
				for b = 1, N do
					if on[a][b] then left = left + 1 end
				end
			end
			if left == 0 then
				chat.nearby(player .. " solved it in " .. moves .. " moves!")
				robot.sound("ok")
				break
			end
		end
	end
	sleep(0.1)
end
