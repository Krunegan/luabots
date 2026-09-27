-- Formspecs: program editor, robot inventory and examples
-- Every formspec submission is checked against the context stored when it was shown (robot id, permissions), so forged submissions do nothing.

local S = luabots.S
local FS = function(...) return core.formspec_escape(S(...)) end
local esc = core.formspec_escape
local config = luabots.config

local contexts = {} -- player name -> {kind, id, draft}
luabots.gui_contexts = contexts

local function can_manage(name, rec)
	return name == rec.owner or luabots.is_admin(name)
end

-- Theme

local gui = {}
luabots.gui = gui

local function n(v) return ("%.2f"):format(v) end

-- Common start of every LuaBots window
function gui.header(w, h, title, title_w)
	return table.concat({
		"formspec_version[6]",
		"size[", n(w), ",", n(h), "]",
		"bgcolor[#00000000;neither]",
		"background9[0,0;0,0;luabots_gui_bg.png;true;8]",
		"style_type[button;bgimg=luabots_gui_btn.png;bgimg_hovered=luabots_gui_btn_hover.png;",
		"bgimg_pressed=luabots_gui_btn_press.png;bgimg_middle=4;border=false;textcolor=#e2e5e9]",
		"style_type[field,textarea;border=false;textcolor=#e6e8eb]",
		"listcolors[#1d2025ff;#2f333aff;#0f1114ff;#1d2025;#e8eaec]",
		"box[0.04,0.04;", n(w - 0.08), ",0.86;#1c1f24]",
		"box[0.04,0.9;", n(w - 0.08), ",0.03;#b8741f]",
		"hypertext[0.35,0.12;", n(title_w or (w - 4.2)), ",0.7;title;",
		esc("<global valign=middle color=#eceef0 size=17><b>" .. title .. "</b>"), "]",
	})
end

-- Dark inset panel with a thin border
function gui.panel(x, y, w, h)
	return ("box[%s,%s;%s,%s;#30343b]box[%s,%s;%s,%s;#0f1114]"):format(
		n(x), n(y), n(w), n(h), n(x + 0.03), n(y + 0.03), n(w - 0.06), n(h - 0.06))
end

-- Small grey section caption
function gui.caption(x, y, text)
	return "label[" .. n(x) .. "," .. n(y) .. ";" .. core.colorize("#e9a43f", esc(text)) .. "]"
end

function gui.color_button(name, color)
	local b = "luabots_gui_btn_" .. color
	return ("style[%s;bgimg=%s.png;bgimg_hovered=%s_hover.png;bgimg_pressed=%s_press.png]")
		:format(name, b, b, b)
end

-- Read-only view of a program with line numbers. 'err' is highlighted in red and the view scrolls to line 'sel' (or to 'err').
function gui.numbered_code(name, x, y, w, h, code, err, sel)
	local cells = {}
	local count = 0
	for line in ((code or "") .. "\n"):gmatch("(.-)\r?\n") do
		count = count + 1
		local bad = count == err
		cells[#cells + 1] = bad and "#ff6a5c" or "#666c74"
		cells[#cells + 1] = tostring(count)
		cells[#cells + 1] = bad and "#ffb0a8" or "#e0e3e7"
		cells[#cells + 1] = esc((line:gsub("\t", "    ")))
	end
	local digits = math.max(2, #tostring(count))
	sel = math.min(math.max(1, sel or err or 1), count)
	return table.concat({
		"style[", name, ";font=mono]",
		"tableoptions[background=#0f1114;border=false;highlight=#1e4a54;highlight_text=#ffffff;color=#e0e3e7]",
		"tablecolumns[color,span=1;text,align=right,width=", digits, ",padding=0.3;",
		"color,span=1;text,padding=1]",
		("table[%s,%s;%s,%s;%s;"):format(n(x), n(y), n(w), n(h), name),
		table.concat(cells, ","), ";", sel, "]",
	})
end

local STATUS_STYLE = {
	running = {"#113f44", "#8ff3ff"},
	error = {"#4a1715", "#ffb0a8"},
	finished = {"#262a30", "#c9ccd1"},
	stopped = {"#262a30", "#b9bdc3"},
}

local function status_pill(rec, x, y, w, h)
	local st = luabots.states[rec.id]
	local status = st and st.status or "stopped"
	local style = STATUS_STYLE[status] or STATUS_STYLE.stopped
	if status == "running" and not luabots.get_body(rec.id) then
		style = {"#3d3413", "#ffe38a"}
	end
	return ("hypertext[%s,%s;%s,%s;status;%s]"):format(n(x), n(y), n(w), n(h), esc(
		"<global valign=middle halign=center size=15 background=" .. style[1] ..
		" color=" .. style[2] .. "><b>" .. luabots.util.hypertext_escape(luabots.status_text(rec)) .. "</b>"))
end

local CONSOLE_LINES = 7
local CONSOLE_COLORS = {error = "#ff9a8f", system = "#7fd4ff"}

local function console_text(rec)
	local st = luabots.states[rec.id]
	local lines = st and st.console or {}
	local out = {}
	local first = math.max(1, #lines - CONSOLE_LINES + 1)
	for i = first, #lines do
		local line = lines[i]
		local color = CONSOLE_COLORS[line.kind] or "#d9dce0"
		out[#out + 1] = "<style color=" .. color .. ">" ..
			luabots.util.hypertext_escape(line.text) .. "</style>"
	end
	if #out == 0 then
		out[1] = "<style color=#666c74>" .. luabots.util.hypertext_escape(S("(console is empty)")) .. "</style>"
	end
	return "<global size=14 font=mono color=#d9dce0>" .. table.concat(out, "\n")
end

local function cpu_bar(x, y, w, used, max)
	local ratio = math.min(1, used / math.max(1, max))
	local color = ratio < 0.5 and "#3fbf6a" or (ratio < 0.85 and "#e8b830" or "#e0503f")
	local fill = math.max(0.02, (w - 0.06) * ratio)
	return ("box[%s,%s;%s,0.22;#1d2025]box[%s,%s;%s,0.16;%s]"):format(
		n(x), n(y), n(w), n(x + 0.03), n(y + 0.03), n(fill), color)
end

gui.status_pill = status_pill
gui.console_text = console_text

-- Editor

function luabots.show_editor(name, rec, draft)
	local ctx = contexts[name]
	if not ctx or ctx.kind ~= "editor" or ctx.id ~= rec.id then
		ctx = {kind = "editor", id = rec.id}
		contexts[name] = ctx
	end
	if draft then ctx.draft = draft end
	local code = ctx.draft or rec.code or ""
	local level = luabots.get_level(rec.owner)
	local st = luabots.states[rec.id]
	local is_owner = name == rec.owner
	local used = st and st.last_used or 0
	local slots = {}
	for i = 1, math.max(level.max_running, rec.slot or 1) do slots[i] = tostring(i) end
	local slot_items = table.concat(slots, ",")

	local W, H = 20, 13
	local LX, LW = 0.35, 3.9 -- left column: buttons
	local CX = LX + LW + 0.3 -- right: code
	local CW = W - CX - 0.35
	local TOP, CODE_BOTTOM = 1.2, 9.5
	local CON_Y = 9.75 -- bottom: console + info
	local BH, GAP = 0.62, 0.08

	local fs = {
		gui.header(W, H, luabots.util.hypertext_escape(luabots.display_name(rec)), 6.4),
		status_pill(rec, 6.9, 0.2, 2.7, 0.5),
		"label[9.95,0.45;", core.colorize("#9aa1aa", FS("Name")), "]",
		"box[10.95,0.17;2.7,0.56;#0f1114]",
		"field[11.05,0.17;2.6,0.56;name;;", esc(rec.name), "]",
		"field_close_on_enter[name;false]",
		"label[13.95,0.45;", core.colorize("#9aa1aa", FS("ID")), "]",
		"dropdown[14.4,0.17;1.35,0.56;slot;", slot_items, ";", rec.slot or 1, ";true]",
		"tooltip[slot;", FS("Run ID: only one of your robots with the same ID runs at a time"), "]",
		"label[16.1,0.45;", core.colorize("#9aa1aa", FS("Level")), "  ",
			core.colorize("#eceef0", esc(level.label)), "]",
		gui.color_button("run", "cyan"),
		gui.color_button("stop", "red"),
	}

	-- left column: buttons grouped in sections
	local y = TOP
	local function section(title)
		fs[#fs + 1] = gui.caption(LX, y + 0.12, title)
		y = y + 0.42
	end
	local function button(fname, label, tip)
		fs[#fs + 1] = ("button[%s,%s;%s,%s;%s;%s]"):format(n(LX), n(y), n(LW), n(BH), fname, esc(label))
		if tip then fs[#fs + 1] = "tooltip[" .. fname .. ";" .. esc(tip) .. "]" end
		y = y + BH + GAP
	end
	section(S("PROGRAM"))
	button("run", S("Run"), S("Save the program and (re)start it"))
	button("stop", S("Stop"))
	button("save", S("Save"))
	button("refresh", S("Refresh"), S("Update status and console (keeps your unsaved edits)"))
	y = y + 0.12
	section(S("ROBOT"))
	button("inventory", S("Inventory"))
	button("reset", S("Reset"), S("Stop, clear the console and bring the robot back to its base"))
	button("unlink", S("Unlink remotes"), S("Remotes linked before stop working (use it if one was stolen)"))
	y = y + 0.12
	section(S("HELP"))
	button("help", S("Manual"))
	button("examples", S("Examples"))

	-- code on the right: toolbar, then the editor or the numbered view
	local lines_view = ctx.view == "lines"
	local err_line = st and st.error_line
	fs[#fs + 1] = gui.color_button(lines_view and "tab_lines" or "tab_edit", "cyan")
	fs[#fs + 1] = ("button[%s,%s;2.1,0.5;tab_edit;%s]"):format(n(CX), n(TOP), FS("Edit"))
	fs[#fs + 1] = ("button[%s,%s;2.9,0.5;tab_lines;%s]"):format(n(CX + 2.2), n(TOP), FS("Line numbers"))
	fs[#fs + 1] = "tooltip[tab_lines;" .. FS("Show the program with line numbers (read only)") .. "]"
	if err_line then
		fs[#fs + 1] = gui.color_button("goto_error", "red")
		fs[#fs + 1] = ("button[%s,%s;3.6,0.5;goto_error;%s]"):format(
			n(CX + 5.3), n(TOP), FS("Error on line @1", err_line))
	end
	local GX = CX + CW
	fs[#fs + 1] = ("button[%s,%s;1.0,0.5;go_line;%s]"):format(n(GX - 1.0), n(TOP), FS("Go"))
	fs[#fs + 1] = ("box[%s,%s;1.2,0.5;#0f1114]"):format(n(GX - 2.3), n(TOP))
	fs[#fs + 1] = ("field[%s,%s;1.1,0.5;goto_line;;%s]"):format(
		n(GX - 2.25), n(TOP), ctx.goto_line and tostring(ctx.goto_line) or "")
	fs[#fs + 1] = "field_close_on_enter[goto_line;false]"
	fs[#fs + 1] = ("label[%s,%s;%s]"):format(n(GX - 4.15), n(TOP + 0.25),
		core.colorize("#9aa1aa", FS("Go to line")))

	local CT = TOP + 0.62
	fs[#fs + 1] = gui.panel(CX, CT, CW, CODE_BOTTOM - CT)
	if lines_view then
		fs[#fs + 1] = gui.numbered_code("lines", CX + 0.06, CT + 0.06, CW - 0.12, CODE_BOTTOM - CT - 0.12,
			code, err_line, ctx.goto_line)
	else
		-- type (or paste) into the code right away, not into the first field (set_focus must come before the element it focuses)
		fs[#fs + 1] = "set_focus[code;true]"
		fs[#fs + 1] = "style[code;font=mono;textcolor=#e0e3e7]"
		fs[#fs + 1] = ("textarea[%s,%s;%s,%s;code;;%s]"):format(
			n(CX + 0.12), n(CT + 0.08), n(CW - 0.2), n(CODE_BOTTOM - CT - 0.16), esc(code))
	end

	-- console at the bottom, info card on its right
	local INFO_W = 4.6
	local CON_W = W - 0.7 - INFO_W - 0.3
	local PANEL_H = H - CON_Y - 0.8
	fs[#fs + 1] = gui.caption(LX, CON_Y + 0.12, S("CONSOLE"))
	fs[#fs + 1] = ("button[%s,%s;3.2,0.52;clear_console;%s]"):format(
		n(LX + CON_W - 3.2), n(CON_Y - 0.1), FS("Clear console"))
	fs[#fs + 1] = gui.panel(LX, CON_Y + 0.45, CON_W, PANEL_H)
	fs[#fs + 1] = ("hypertext[%s,%s;%s,%s;console;%s]"):format(
		n(LX + 0.15), n(CON_Y + 0.55), n(CON_W - 0.3), n(PANEL_H - 0.2), esc(console_text(rec)))

	local IX = W - 0.35 - INFO_W
	fs[#fs + 1] = gui.caption(IX, CON_Y + 0.12, S("INFO"))
	local tracking = luabots.hud_is_tracking(name, rec)
	if tracking then fs[#fs + 1] = gui.color_button("track", "cyan") end
	fs[#fs + 1] = ("button[%s,%s;2.3,0.52;track;%s]"):format(n(IX + INFO_W - 2.3), n(CON_Y - 0.1),
		tracking and FS("Tracking") or FS("Track"))
	fs[#fs + 1] = "tooltip[track;" .. FS("Show this robot on your screen (HUD)") .. "]"
	fs[#fs + 1] = gui.panel(IX, CON_Y + 0.45, INFO_W, PANEL_H)
	local iy = CON_Y + 0.8
	local function info(label, value)
		fs[#fs + 1] = "label[" .. n(IX + 0.2) .. "," .. n(iy) .. ";" ..
			core.colorize("#9aa1aa", esc(label)) .. "  " .. core.colorize("#eceef0", esc(value)) .. "]"
		iy = iy + 0.42
	end
	info(S("Robot ID"), rec.id)
	info(S("Position"), core.pos_to_string(rec.pos))
	info(S("Energy"), tostring(math.floor(rec.energy or 0)))
	info(S("CPU last tick"), used .. " / " .. level.instructions)
	fs[#fs + 1] = cpu_bar(IX + 0.2, iy - 0.1, INFO_W - 0.4, used, level.instructions)

	if not is_owner then
		fs[#fs + 1] = "label[" .. n(LX) .. "," .. n(y + 0.3) .. ";" .. core.colorize("#ffcc66",
			FS("Admin view")) .. "]"
		fs[#fs + 1] = "tooltip[save;" .. FS("Viewing as admin: only the owner can save code.") .. "]"
	end
	core.show_formspec(name, "luabots:editor", table.concat(fs))
end

-- Inventory

function luabots.show_inventory(name, rec)
	contexts[name] = {kind = "inventory", id = rec.id}
	local inv_loc = "detached:" .. luabots.inventory_name(rec)
	luabots.get_inventory(rec)
	local player = core.get_player_by_name(name)
	local pw = player and player:hud_get_hotbar_itemcount() or 8
	if pw < 1 or pw > 12 then pw = 8 end
	local psize = player and player:get_inventory():get_size("main") or 32
	local prows = math.max(1, math.min(4, math.ceil(psize / pw)))
	local slot = 1.25
	local robot_w = 8 * slot - 0.25
	local lib_w = 4 * slot - 0.25
	local W = math.max(0.5 + robot_w + 0.7 + lib_w + 0.4, 0.5 + pw * slot - 0.25 + 0.5)
	local PY = 1.5 + 4 * slot + 0.8   -- room for the library notes
	local H = PY + 0.45 + prows * slot - 0.25 + 0.45
	local tx = 0.5 + robot_w + 0.7
	local fs = {
		gui.header(W, H, luabots.util.hypertext_escape(S("Robot inventory") .. ": " .. luabots.display_name(rec))),
		("button[%s,0.2;3.2,0.5;back;%s]"):format(n(W - 3.5), FS("Back to editor")),
		gui.caption(0.5, 1.3, S("ROBOT")),
		"list[", inv_loc, ";main;0.5,1.6;8,4;]",
		gui.caption(tx, 1.3, S("TOOL")),
		"list[", inv_loc, ";tool;", n(tx), ",1.6;1,1;]",
		"label[", n(tx), ",3.05;", core.colorize("#9aa1aa", FS("Pickaxe, shovel, axe...")), "]",
		gui.caption(tx, 3.6, S("LIBRARY")),
		"list[", inv_loc, ";disks;", n(tx), ",3.9;4,2;]",
		"label[", n(tx), ",6.45;", core.colorize("#9aa1aa", FS("Disks and books with code.")), "]",
		"label[", n(tx), ",6.85;", core.colorize("#9aa1aa", FS("Load them with require('title')")), "]",
		"tooltip[", n(tx), ",3.9;", n(lib_w), ",2.25;",
			FS("Programs load the code of these disks with require('title') or disks.run('title')"), "]",
		gui.caption(0.5, PY + 0.1, S("YOUR INVENTORY")),
		"list[current_player;main;0.5,", n(PY + 0.45), ";", pw, ",", prows, ";]",
		"listring[", inv_loc, ";main]",
		"listring[current_player;main]",
	}
	core.show_formspec(name, "luabots:inventory", table.concat(fs))
end

-- Examples

local examples = {}
do
	local dir = luabots.modpath .. "/examples"
	local files = core.get_dir_list(dir, false) or {}
	table.sort(files)
	for _, file in ipairs(files) do
		if file:match("%.lua$") then
			local f = io.open(dir .. "/" .. file, "rb")
			if f then
				local code = f:read("*a")
				f:close()
				local title = code:match("^%-%-%s*([^\n]+)") or file
				examples[#examples + 1] = {file = file, title = title, code = code}
			end
		end
	end
end
luabots.examples = examples

function luabots.show_examples(name, rec, selected)
	local ctx = contexts[name]
	local draft = ctx and ctx.id == rec.id and ctx.draft or nil
	contexts[name] = {kind = "examples", id = rec.id, selected = selected or 1, draft = draft}
	local titles = {}
	for i, ex in ipairs(examples) do titles[i] = esc(ex.title) end
	local ex = examples[selected or 1]
	local fs = {
		gui.header(20, 13, luabots.util.hypertext_escape(S("Example programs"))),
		("button[16.2,0.2;3.4,0.5;back;%s]"):format(FS("Back to editor")),
		gui.panel(0.35, 1.2, 5.8, 11.45),
		"textlist[0.45,1.3;5.6,11.25;list;", table.concat(titles, ","), ";", selected or 1, ";true]",
		gui.panel(6.45, 1.2, 13.2, 10.5),
		"style[preview;font=mono;textcolor=#e0e3e7]",
		"textarea[6.6,1.3;12.95,10.3;preview;;", esc(ex and ex.code or ""), "]",
		gui.color_button("load", "cyan"),
		"button[15.25,11.95;4.4,0.7;load;", FS("Load into editor"), "]",
	}
	core.show_formspec(name, "luabots:examples", table.concat(fs))
end

-- Field handling

local function valid_name(s)
	return type(s) == "string" and #s >= 1 and #s <= 24 and s:match("^[%w_%-]+$") ~= nil
end

local function handle_editor(player, name, ctx, rec, fields)
	local is_owner = name == rec.owner
	local level = luabots.get_level(rec.owner)
	if fields.code then
		if #fields.code > level.code_kb * 1024 then
			core.chat_send_player(name, S("Program too large (max @1 KB).", level.code_kb))
		else
			ctx.draft = fields.code
		end
	end

	local function save()
		if not is_owner then
			core.chat_send_player(name, S("Only the owner can change the program."))
			return false
		end
		if ctx.draft then rec.code = ctx.draft end
		if fields.name and fields.name ~= rec.name then
			if not valid_name(fields.name) then
				core.chat_send_player(name, S("Invalid name: use 1-24 letters, digits, _ or -."))
			else
				local other = luabots.find_record(rec.owner .. "/" .. fields.name)
				if other and other.id ~= rec.id then
					core.chat_send_player(name, S("You already have a robot with that name."))
				else
					rec.name = fields.name
					local meta = core.get_meta(rec.home)
					if meta:get_string("robot_id") == rec.id then
						meta:set_string("infotext", S("Robot base") .. "\n" .. luabots.display_name(rec))
					end
				end
			end
		end
		luabots.mark_dirty(rec.id)
		return true
	end

	-- run ID changed (dropdowns submit as soon as they change)
	if fields.slot and is_owner then
		local s = math.floor(tonumber(fields.slot) or 0)
		if s >= 1 and s <= math.max(level.max_running, rec.slot or 1) and s ~= (rec.slot or 1) then
			rec.slot = s
			luabots.mark_dirty(rec.id)
			local st = luabots.states[rec.id]
			if st and st.status == "running" then luabots.take_slot(rec) end
			if not (fields.save or fields.run) then
				luabots.show_editor(name, rec)
				return
			end
		end
	end

	-- line numbers view
	if fields.lines then
		local ev = core.explode_table_event(fields.lines)
		if ev.row and ev.row > 0 then ctx.goto_line = ev.row end
	end
	if fields.tab_edit or fields.tab_lines then
		ctx.view = fields.tab_lines and "lines" or nil
		luabots.show_editor(name, rec)
		return
	elseif fields.go_line or fields.key_enter_field == "goto_line" or fields.goto_error then
		local line = tonumber(fields.goto_line)
		if fields.goto_error then
			local st = luabots.states[rec.id]
			line = st and st.error_line
		end
		if line then
			ctx.goto_line = math.max(1, math.min(math.floor(line), 100000))
			ctx.view = "lines"
		end
		luabots.show_editor(name, rec)
		return
	end

	if fields.save then
		if save() then
			core.chat_send_player(name, S("Program saved."))
		end
	elseif fields.run then
		if is_owner then save() end
		luabots.stop(rec, "stopped")
		luabots.start(rec, nil, name) -- puts the robot back on its base first
	elseif fields.stop then
		luabots.stop(rec, "stopped")
	elseif fields.reset then
		luabots.stop(rec, "stopped")
		luabots.remove_body(rec)
		luabots.release(rec)
		rec.pos = vector.offset(rec.home, 0, 1, 0)
		rec.facing = luabots.home_facing(rec)
		rec.angle = nil
		luabots.mark_dirty(rec.id)
		luabots.clear_console(rec.id)
		local node = core.get_node_or_nil(rec.pos)
		if node and luabots.util.is_passable(node) then luabots.spawn_body(rec) end
	elseif fields.unlink then
		if can_manage(name, rec) then
			if not is_owner then
				core.log("action", ("[luabots] admin %s unlinked the remotes of %s"):format(name, luabots.display_name(rec)))
			end
			luabots.unlink_remotes(rec)
			core.chat_send_player(name, S("All remotes of @1 were unlinked. Place your remote on the base to link it again.",
				luabots.display_name(rec)))
		else
			core.chat_send_player(name, S("Only the owner can unlink the remotes."))
		end
	elseif fields.track then
		if luabots.hud_is_tracking(name, rec) then
			luabots.hud_untrack(name)
		else
			luabots.hud_track(name, rec)
		end
	elseif fields.clear_console then
		luabots.clear_console(rec.id)
	elseif fields.inventory then
		if can_manage(name, rec) then
			if not is_owner then
				core.log("action", ("[luabots] admin %s opened the inventory of %s"):format(name, luabots.display_name(rec)))
			end
			luabots.show_inventory(name, rec)
		else
			core.chat_send_player(name, S("Only the owner can open the robot inventory."))
		end
		return
	elseif fields.help then
		luabots.show_help(name, nil, rec.id)
		return
	elseif fields.examples then
		luabots.show_examples(name, rec, 1)
		return
	elseif fields.quit then
		contexts[name] = nil
		return
	elseif not (fields.refresh or fields.key_enter_field) then
		return -- e.g. clicking the console list
	end
	luabots.show_editor(name, rec)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:editor" and formname ~= "luabots:inventory"
			and formname ~= "luabots:examples" then
		return false
	end
	local name = player:get_player_name()
	local ctx = contexts[name]
	local expected = formname:sub(#"luabots:" + 1)
	if not ctx or ctx.kind ~= expected then return true end
	local rec = luabots.get_record(ctx.id)
	if not rec or not can_manage(name, rec) then
		contexts[name] = nil
		return true
	end

	if formname == "luabots:editor" then
		handle_editor(player, name, ctx, rec, fields)
	elseif formname == "luabots:inventory" then
		if fields.back then
			luabots.show_editor(name, rec)
		elseif fields.quit then
			contexts[name] = nil
		end
	elseif formname == "luabots:examples" then
		if fields.list then
			local ev = core.explode_textlist_event(fields.list)
			if ev.type == "CHG" or ev.type == "DCL" then
				luabots.show_examples(name, rec, ev.index)
			end
		elseif fields.load then
			local ex = examples[ctx.selected or 1]
			if ex then
				contexts[name] = {kind = "editor", id = rec.id}
				luabots.show_editor(name, rec, ex.code)
			end
		elseif fields.back then
			local draft = ctx.draft
			contexts[name] = {kind = "editor", id = rec.id}
			luabots.show_editor(name, rec, draft)
		elseif fields.quit then
			contexts[name] = nil
		end
	end
	return true
end)

core.register_on_leaveplayer(function(player)
	contexts[player:get_player_name()] = nil
end)
