-- Admin: online players report (IP, ping, version) and shared IPs
-- Needs the luabots_admin privilege. IPs are shown only if you also
-- have the ban or server privilege.
local by_ip = {}
for _, name in ipairs(admin.players()) do
	local p = admin.player_info(name)
	if p then
		local ip = p.ip or "?"
		print(("%-16s %-15s %4s ms  %s  %s"):format(name, ip, p.ping or "?",
			p.version or "?", vector.to_string(p.pos)))
		if p.ip then
			by_ip[p.ip] = by_ip[p.ip] or {}
			table.insert(by_ip[p.ip], name)
		end
	end
end
for ip, names in pairs(by_ip) do
	if #names > 1 then
		print("Same IP " .. ip .. ": " .. table.concat(names, ", "))
	end
end
