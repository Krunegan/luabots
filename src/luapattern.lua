-- Pure Lua implementation of Lua 5.1 patterns.
-- The native string.find/match/gsub are written in C, so the instruction hook cannot interrupt them and a pathological pattern could freeze the
-- server. Programs therefore use the native functions only when the worst case cost is provably small, and this implementation otherwise. Being plain Lua, it is counted and interrupted like any other program code.

local lp = {}
luabots.luapattern = lp

local byte, sub, char = string.byte, string.sub, string.char
local concat = table.concat

local L_ESC = 37      -- %
local CAP_UNFINISHED = -1
local CAP_POSITION = -2
local MAXCCALLS = 200
local MAXCAPTURES = 32

local function is_alpha(c) return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) end
local function is_digit(c) return c >= 48 and c <= 57 end
local function is_lower(c) return c >= 97 and c <= 122 end
local function is_upper(c) return c >= 65 and c <= 90 end
local function is_space(c) return c == 32 or (c >= 9 and c <= 13) end
local function is_cntrl(c) return c < 32 or c == 127 end
local function is_punct(c)
	return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or
		(c >= 91 and c <= 96) or (c >= 123 and c <= 126)
end
local function is_xdigit(c)
	return is_digit(c) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
end

local CLASSES = {
	[97] = is_alpha, -- a
	[100] = is_digit, -- d
	[108] = is_lower, -- l
	[115] = is_space, -- s
	[117] = is_upper, -- u
	[119] = function(c) return is_alpha(c) or is_digit(c) end, -- w
	[120] = is_xdigit, -- x
	[112] = is_punct, -- p
	[99] = is_cntrl, -- c
	[122] = function(c) return c == 0 end, -- z
}

local function match_class(c, cl)
	local f = CLASSES[cl]
	if f then return f(c) end
	if cl >= 65 and cl <= 90 then
		f = CLASSES[cl + 32]
		if f then return not f(c) end
	end
	return cl == c
end

-- The matcher keeps its state in a table: src, slen, pat, plen, level, cap_init[], cap_len[], depth

local function class_end(ms, p)
	local pat = ms.pat
	local c = byte(pat, p)
	p = p + 1
	if c == L_ESC then
		if p > ms.plen then error("malformed pattern (ends with '%')", 0) end
		return p + 1
	elseif c == 91 then -- [
		if byte(pat, p) == 94 then p = p + 1 end
		repeat
			if p > ms.plen then error("malformed pattern (missing ']')", 0) end
			local cc = byte(pat, p)
			p = p + 1
			if cc == L_ESC then
				if p > ms.plen then error("malformed pattern (missing ']')", 0) end
				p = p + 1
			end
		until byte(pat, p) == 93
		return p + 1
	end
	return p
end

-- p points at '[', ec at the closing ']'
local function match_bracket_class(ms, c, p, ec)
	local pat = ms.pat
	local sig = true
	p = p + 1
	if byte(pat, p) == 94 then
		sig = false
		p = p + 1
	end
	while p < ec do
		local pc = byte(pat, p)
		if pc == L_ESC then
			p = p + 1
			if match_class(c, byte(pat, p)) then return sig end
		elseif byte(pat, p + 1) == 45 and p + 2 < ec then -- range
			if pc <= c and c <= byte(pat, p + 2) then return sig end
			p = p + 2
		elseif pc == c then
			return sig
		end
		p = p + 1
	end
	return not sig
end

local function single_match(ms, s, p, ep)
	if s > ms.slen then return false end
	local c = byte(ms.src, s)
	local pc = byte(ms.pat, p)
	if pc == 46 then return true end -- .
	if pc == L_ESC then return match_class(c, byte(ms.pat, p + 1)) end
	if pc == 91 then return match_bracket_class(ms, c, p, ep - 1) end
	return pc == c
end

local do_match

local function match_balance(ms, s, p)
	if p + 1 > ms.plen then error("missing arguments to '%b'", 0) end
	if s > ms.slen or byte(ms.src, s) ~= byte(ms.pat, p) then return nil end
	local b, e = byte(ms.pat, p), byte(ms.pat, p + 1)
	local cont = 1
	s = s + 1
	while s <= ms.slen do
		local c = byte(ms.src, s)
		if c == e then
			cont = cont - 1
			if cont == 0 then return s + 1 end
		elseif c == b then
			cont = cont + 1
		end
		s = s + 1
	end
	return nil
end

local function max_expand(ms, s, p, ep)
	local i = 0
	while single_match(ms, s + i, p, ep) do i = i + 1 end
	while i >= 0 do
		local r = do_match(ms, s + i, ep + 1)
		if r then return r end
		i = i - 1
	end
	return nil
end

local function min_expand(ms, s, p, ep)
	while true do
		local r = do_match(ms, s, ep + 1)
		if r then return r end
		if single_match(ms, s, p, ep) then
			s = s + 1
		else
			return nil
		end
	end
end

local function start_capture(ms, s, p, what)
	local level = ms.level + 1
	if level > MAXCAPTURES then error("too many captures", 0) end
	ms.cap_init[level] = s
	ms.cap_len[level] = what
	ms.level = level
	local r = do_match(ms, s, p)
	if not r then ms.level = ms.level - 1 end
	return r
end

local function capture_to_close(ms)
	for l = ms.level, 1, -1 do
		if ms.cap_len[l] == CAP_UNFINISHED then return l end
	end
	error("invalid pattern capture", 0)
end

local function end_capture(ms, s, p)
	local l = capture_to_close(ms)
	ms.cap_len[l] = s - ms.cap_init[l]
	local r = do_match(ms, s, p)
	if not r then ms.cap_len[l] = CAP_UNFINISHED end
	return r
end

local function check_capture(ms, l)
	l = l - 48 -- '0'
	if l < 1 or l > ms.level or ms.cap_len[l] == CAP_UNFINISHED then
		error("invalid capture index", 0)
	end
	return l
end

local function match_capture(ms, s, l)
	l = check_capture(ms, l)
	local init, len = ms.cap_init[l], ms.cap_len[l]
	if ms.slen - s + 1 >= len and sub(ms.src, init, init + len - 1) == sub(ms.src, s, s + len - 1) then
		return s + len
	end
	return nil
end

do_match = function(ms, s, p)
	ms.depth = ms.depth + 1
	if ms.depth > MAXCCALLS then error("pattern too complex", 0) end
	local pat, plen = ms.pat, ms.plen
	local result
	while true do
		if p > plen then
			result = s
			break
		end
		local pc = byte(pat, p)
		if pc == 40 then -- (
			if byte(pat, p + 1) == 41 then
				result = start_capture(ms, s, p + 2, CAP_POSITION)
			else
				result = start_capture(ms, s, p + 1, CAP_UNFINISHED)
			end
			break
		elseif pc == 41 then -- )
			result = end_capture(ms, s, p + 1)
			break
		elseif pc == 36 and p == plen then -- $ at end
			result = (s == ms.slen + 1) and s or nil
			break
		end
		local handled = false
		if pc == L_ESC then
			local nc = byte(pat, p + 1)
			if nc == 98 then -- %b
				s = match_balance(ms, s, p + 2)
				if not s then result = nil break end
				p = p + 4
				handled = true
			elseif nc == 102 then -- %f
				p = p + 2
				if byte(pat, p) ~= 91 then error("missing '[' after '%f' in pattern", 0) end
				local ep = class_end(ms, p)
				local prev = (s == 1) and 0 or byte(ms.src, s - 1)
				local cur = (s <= ms.slen) and byte(ms.src, s) or 0
				if not match_bracket_class(ms, prev, p, ep - 1) and match_bracket_class(ms, cur, p, ep - 1) then
					p = ep
					handled = true
				else
					result = nil
					break
				end
			elseif nc and is_digit(nc) then -- back reference
				s = match_capture(ms, s, nc)
				if not s then result = nil break end
				p = p + 2
				handled = true
			end
		end
		if not handled then
			local ep = class_end(ms, p)
			local m = single_match(ms, s, p, ep)
			local epc = byte(pat, ep)
			if epc == 63 then -- ?
				if m then
					local r = do_match(ms, s + 1, ep + 1)
					if r then result = r break end
				end
				p = ep + 1
			elseif epc == 42 then -- *
				result = max_expand(ms, s, p, ep)
				break
			elseif epc == 43 then -- +
				result = m and max_expand(ms, s + 1, p, ep) or nil
				break
			elseif epc == 45 then -- -
				result = min_expand(ms, s, p, ep)
				break
			else
				if not m then result = nil break end
				s = s + 1
				p = ep
			end
		end
	end
	ms.depth = ms.depth - 1
	return result
end

local function new_state(src, pat)
	return {
		src = src, slen = #src, pat = pat, plen = #pat,
		level = 0, cap_init = {}, cap_len = {}, depth = 0,
	}
end

local function get_capture(ms, i, s, e)
	if i > ms.level then
		if i == 1 then return sub(ms.src, s, e - 1) end
		error("invalid capture index", 0)
	end
	local len = ms.cap_len[i]
	if len == CAP_UNFINISHED then error("unfinished capture", 0) end
	if len == CAP_POSITION then return ms.cap_init[i] end
	return sub(ms.src, ms.cap_init[i], ms.cap_init[i] + len - 1)
end

local function push_captures(ms, s, e, whole)
	local n = (ms.level == 0 and whole) and 1 or ms.level
	local out = {}
	for i = 1, n do out[i] = get_capture(ms, i, s, e) end
	return out, n
end

local unpack = unpack or table.unpack

local function norm_init(init, len)
	init = init or 1
	if init < 0 then init = len + init + 1 end
	if init < 1 then init = 1 end
	return init
end

local SPECIALS = "[%^%$%*%+%?%.%(%)%[%]%%%-]"

local function str_find_aux(s, pat, init, plain, find)
	local len = #s
	init = norm_init(init, len)
	if init > len + 1 then return nil end
	if find and (plain or not pat:find(SPECIALS)) then
		-- plain search, written in Lua to keep it interruptible
		local plen = #pat
		if plen == 0 then return init, init - 1 end
		local first = byte(pat, 1)
		for i = init, len - plen + 1 do
			if byte(s, i) == first and sub(s, i, i + plen - 1) == pat then
				return i, i + plen - 1
			end
		end
		return nil
	end
	local anchor = byte(pat, 1) == 94
	local p = anchor and 2 or 1
	local ms = new_state(s, pat)
	local si = init
	repeat
		ms.level = 0
		ms.depth = 0
		local e = do_match(ms, si, p)
		if e then
			if find then
				local caps, n = push_captures(ms, nil, nil, false)
				if ms.level == 0 then return si, e - 1 end
				return si, e - 1, unpack(caps, 1, n)
			else
				local caps, n = push_captures(ms, si, e, true)
				return unpack(caps, 1, n)
			end
		end
		si = si + 1
	until anchor or si > len + 1
	return nil
end

function lp.find(s, pat, init, plain)
	return str_find_aux(s, pat, init, plain, true)
end

function lp.match(s, pat, init)
	return str_find_aux(s, pat, init, false, false)
end

function lp.gmatch(s, pat)
	local si = 1
	local len = #s
	local ms = new_state(s, pat)
	return function()
		while si <= len + 1 do
			ms.level = 0
			ms.depth = 0
			local e = do_match(ms, si, 1)
			if e then
				local start = si
				if e == si then si = si + 1 else si = e end
				local caps, n = push_captures(ms, start, e, true)
				return unpack(caps, 1, n)
			end
			si = si + 1
		end
		return nil
	end
end

-- gsub; max_len limits the result size
function lp.gsub(s, pat, repl, max_n, max_len)
	local rt = type(repl)
	if rt ~= "string" and rt ~= "number" and rt ~= "table" and rt ~= "function" then
		error("bad argument #3 to 'gsub' (string/function/table expected)", 0)
	end
	if rt == "number" then repl = tostring(repl) rt = "string" end
	local len = #s
	local anchor = byte(pat, 1) == 94
	local p = anchor and 2 or 1
	local ms = new_state(s, pat)
	local out, total = {}, 0
	local si, n = 1, 0
	max_n = max_n or (len + 1)

	local function add(str)
		total = total + #str
		if total > max_len then error("string too long", 0) end
		out[#out + 1] = str
	end

	local function add_value(start, e)
		local whole = sub(s, start, e - 1)
		local value
		if rt == "string" then
			local i, rl = 1, #repl
			local buf = {}
			while i <= rl do
				local c = byte(repl, i)
				if c == L_ESC then
					i = i + 1
					local d = byte(repl, i)
					if d and is_digit(d) then
						if d == 48 then
							buf[#buf + 1] = whole
						else
							local cap = get_capture(ms, d - 48, start, e)
							buf[#buf + 1] = tostring(cap)
						end
					elseif d then
						buf[#buf + 1] = char(d)
					end
				else
					buf[#buf + 1] = char(c)
				end
				i = i + 1
			end
			add(concat(buf))
			return
		elseif rt == "table" then
			value = repl[get_capture(ms, 1, start, e)]
		else
			local caps, cn = push_captures(ms, start, e, true)
			value = repl(unpack(caps, 1, cn))
		end
		if value == nil or value == false then
			add(whole)
		elseif type(value) == "string" or type(value) == "number" then
			add(tostring(value))
		else
			error("invalid replacement value (a " .. type(value) .. ")", 0)
		end
	end

	while n < max_n do
		ms.level = 0
		ms.depth = 0
		local e = do_match(ms, si, p)
		if e then
			n = n + 1
			add_value(si, e)
		end
		if e and e > si then
			si = e
		elseif si <= len then
			add(sub(s, si, si))
			si = si + 1
		else
			break
		end
		if anchor then break end
	end
	if si <= len then add(sub(s, si)) end
	return concat(out), n
end

-- Estimate the worst case work of the native matcher for a pattern.
-- Every quantifier can multiply the backtracking by the subject length.
function lp.native_cost(slen, pat)
	local q = 0
	local i, plen = 1, #pat
	while i <= plen do
		local c = byte(pat, i)
		if c == L_ESC then
			local d = byte(pat, i + 1)
			if d == 98 or (d and is_digit(d)) then q = q + 1 end
			i = i + 2
		else
			if c == 42 or c == 43 or c == 45 or c == 63 then q = q + 1 end
			i = i + 1
		end
	end
	local n = slen + 1
	local cost = n * (plen + 1)
	for _ = 1, q do
		cost = cost * n
		if cost > 1e12 then return cost end
	end
	return cost
end
