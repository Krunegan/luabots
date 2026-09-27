-- Persistent memory: storage.* survives server restarts
local runs = (storage.get("runs") or 0) + 1
storage.set("runs", runs)
chat.owner("I have been started " .. runs .. " times")

-- remember visitors
local visitors = storage.get("visitors") or {}
for _, name in ipairs(sense.players(10)) do
	if not visitors[name] then
		visitors[name] = true
		chat.tell(name, "Nice to meet you, " .. name)
	end
end
storage.set("visitors", visitors)
