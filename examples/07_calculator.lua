-- Calculator: shows a custom form to the owner
local owner = robot.owner()
local display = "0"
local keys = {"7", "8", "9", "/", "4", "5", "6", "*", "1", "2", "3", "-", "C", "0", "=", "+"}

local function show()
	local fs = "formspec_version[6]size[6,7.6]" ..
		"box[0.5,0.5;5,1;#102030]" ..
		"label[0.7,1;" .. forms.escape(display) .. "]"
	for i, k in ipairs(keys) do
		local x = 0.5 + ((i - 1) % 4) * 1.3
		local y = 2 + math.floor((i - 1) / 4) * 1.3
		fs = fs .. ("button[%.1f,%.1f;1.1,1.1;k%d;%s]"):format(x, y, i, k)
	end
	forms.show(owner, fs)
end

local function calculate()
	local a, op, b = display:match("^(%-?[%d%.]+)([%+%-%*/])([%d%.]+)$")
	a, b = tonumber(a), tonumber(b)
	if not (a and b) then return "error" end
	if op == "+" then return tostring(a + b) end
	if op == "-" then return tostring(a - b) end
	if op == "*" then return tostring(a * b) end
	if b == 0 then return "error" end
	return tostring(a / b)
end

show()
while true do
	local player, fields = forms.receive()
	if player then
		if fields.quit then break end
		for name in pairs(fields) do
			local k = keys[tonumber(name:match("^k(%d+)$") or 0)]
			if k == "C" then
				display = "0"
			elseif k == "=" then
				display = calculate()
			elseif k then
				if display == "0" or display == "error" then
					display = k
				else
					display = display .. k
				end
			end
		end
		show()
	end
	sleep(0.05)
end
