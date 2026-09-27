-- In-game manual. Pages are hypertext files in help/<language>/

local S = luabots.S
local esc = core.formspec_escape

local manuals = {}

local function load_language(lang)
	local dir = luabots.modpath .. "/help/" .. lang
	local files = core.get_dir_list(dir, false)
	if not files or #files == 0 then return nil end
	table.sort(files)
	local pages = {}
	for _, file in ipairs(files) do
		if file:match("%.txt$") then
			local f = io.open(dir .. "/" .. file, "rb")
			if f then
				local content = f:read("*a")
				f:close()
				local title, body = content:match("^([^\n]*)\n(.*)$")
				pages[#pages + 1] = {title = title or file, body = body or content}
			end
		end
	end
	return pages
end

for _, lang in ipairs(core.get_dir_list(luabots.modpath .. "/help", true) or {}) do
	manuals[lang] = load_language(lang)
end

local function manual_for(name)
	local info = core.get_player_information(name)
	local code = info and info.lang_code or ""
	if code == "" then code = core.settings:get("language") or "" end
	code = code:match("^(%a+)") or "en"
	return manuals[code] or manuals.en or {}
end

local help_ctx = {}

function luabots.show_help(name, page, robot_id)
	local pages = manual_for(name)
	page = math.max(1, math.min(page or 1, #pages))
	help_ctx[name] = {page = page, robot_id = robot_id}
	local titles = {}
	for i, p in ipairs(pages) do titles[i] = esc(p.title) end
	local body = pages[page] and pages[page].body or ""
	local gui = luabots.gui
	local fs = {
		gui.header(20, 13, luabots.util.hypertext_escape(S("LuaBots manual"))),
		gui.panel(0.35, 1.2, 5.3, 11.45),
		"textlist[0.45,1.3;5.1,11.25;pages;", table.concat(titles, ","), ";", page, ";true]",
		gui.panel(5.95, 1.2, 13.7, 11.45),
		"hypertext[6.05,1.3;13.5,11.25;text;", esc(
			"<global margin=12 size=16 color=#e3e5e8>"
			.. "<tag name=code color=#a8f0c0 font=mono>"
			.. "<tag name=h color=#7fd4ff size=22>"
			.. body), "]",
	}
	if robot_id then
		fs[#fs + 1] = "button[16.2,0.2;3.4,0.5;back;" .. esc(S("Back to editor")) .. "]"
	end
	core.show_formspec(name, "luabots:help", table.concat(fs))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:help" then return false end
	local name = player:get_player_name()
	local ctx = help_ctx[name]
	if not ctx then return true end
	if fields.pages then
		local ev = core.explode_textlist_event(fields.pages)
		if ev.type == "CHG" or ev.type == "DCL" then
			luabots.show_help(name, ev.index, ctx.robot_id)
		end
	elseif fields.back and ctx.robot_id then
		local rec = luabots.get_record(ctx.robot_id)
		help_ctx[name] = nil
		if rec and (rec.owner == name or luabots.is_admin(name)) then
			luabots.show_editor(name, rec)
		end
	elseif fields.quit then
		help_ctx[name] = nil
	end
	return true
end)

core.register_on_leaveplayer(function(player)
	help_ctx[player:get_player_name()] = nil
end)
