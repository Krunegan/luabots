-- Sandboxed standard library for robot programs.
-- Rules followed here:
--  * Every function that may run for long or allocate a lot is either bounded before calling C code, or implemented in Lua (so the instruction/memory hook can stop it).
--  * These functions run inside the program's context (hook active), so user metamethods they trigger are counted too.
--  * No function here gives access to the real global environment.

local safestd = {}
luabots.safestd = safestd

local lp = luabots.luapattern
local config = luabots.config

local native = {
	string = {},
	table = {},
}
for k, v in pairs(string) do native.string[k] = v end
for k, v in pairs(table) do native.table[k] = v end

local s_rep, s_format, s_find, s_match, s_gmatch, s_gsub =
	string.rep, string.format, string.find, string.match, string.gmatch, string.gsub
local tconcat, tsort = table.concat, table.sort
local select, type, tostring, error = select, type, tostring, error
local unpack = unpack or table.unpack

local NATIVE_COST = 300000 -- max estimated steps for native matcher
local NATIVE_SORT = 20000 -- tables larger than this are sorted in Lua

local function max_string()
	return config.max_string_kb * 1024
end

local function pack(...)
	return {n = select("#", ...), ...}
end

-- Coerce numbers to strings like the real string library does
local function str_arg(v, fname, n)
	local t = type(v)
	if t == "string" then return v end
	if t == "number" then return tostring(v) end
	error(("bad argument #%d to '%s' (string expected, got %s)"):format(n, fname, t), 3)
end

local function int_arg(v, fname, n, default)
	if v == nil then return default end
	local x = tonumber(v)
	if not x then
		error(("bad argument #%d to '%s' (number expected, got %s)"):format(n, fname, type(v)), 3)
	end
	return math.floor(x)
end

-- ctx is the program context; ctx.checkpoint() may pause the program
function safestd.make_string(ctx)
	local S = {}
	S.len = native.string.len
	S.lower = native.string.lower
	S.upper = native.string.upper
	S.reverse = native.string.reverse
	S.byte = native.string.byte
	S.char = native.string.char
	S.sub = native.string.sub

	function S.rep(s, n, sep)
		s = str_arg(s, "rep", 1)
		n = int_arg(n, "rep", 2, nil)
		if not n then error("bad argument #2 to 'rep' (number expected, got no value)", 2) end
		if n <= 0 then return "" end
		sep = sep ~= nil and str_arg(sep, "rep", 3) or ""
		if (#s + #sep) * n > max_string() then
			error("string.rep: resulting string too large", 2)
		end
		ctx.checkpoint()
		if sep == "" then return s_rep(s, n) end
		return s_rep(s .. sep, n - 1) .. s
	end

	function S.format(fmt, ...)
		fmt = str_arg(fmt, "format", 1)
		if #fmt > 16384 then error("string.format: format string too long", 2) end
		local args = pack(...)
		local bound = #fmt * 50
		for i = 1, args.n do
			local v = args[i]
			local t = type(v)
			if t == "string" then
				bound = bound + #v
			elseif t == "number" then
				bound = bound + 64
			else
				v = tostring(v)
				args[i] = v
				bound = bound + #v
			end
		end
		if bound > max_string() then
			error("string.format: resulting string too large", 2)
		end
		ctx.checkpoint()
		return s_format(fmt, unpack(args, 1, args.n))
	end

	local function native_ok(s, pat)
		return lp.native_cost(#s, pat) <= NATIVE_COST
	end

	function S.find(s, pat, init, plain)
		s = str_arg(s, "find", 1)
		pat = str_arg(pat, "find", 2)
		init = int_arg(init, "find", 3, 1)
		ctx.checkpoint()
		if plain then
			if (#s + 1) * (#pat + 1) <= NATIVE_COST then
				return s_find(s, pat, init, true)
			end
			return lp.find(s, pat, init, true)
		end
		if native_ok(s, pat) then return s_find(s, pat, init) end
		return lp.find(s, pat, init, false)
	end

	function S.match(s, pat, init)
		s = str_arg(s, "match", 1)
		pat = str_arg(pat, "match", 2)
		init = int_arg(init, "match", 3, 1)
		ctx.checkpoint()
		if native_ok(s, pat) then return s_match(s, pat, init) end
		return lp.match(s, pat, init)
	end

	function S.gmatch(s, pat)
		s = str_arg(s, "gmatch", 1)
		pat = str_arg(pat, "gmatch", 2)
		ctx.checkpoint()
		if native_ok(s, pat) then return s_gmatch(s, pat) end
		return lp.gmatch(s, pat)
	end

	function S.gsub(s, pat, repl, n)
		s = str_arg(s, "gsub", 1)
		pat = str_arg(pat, "gsub", 2)
		n = int_arg(n, "gsub", 4, nil)
		ctx.checkpoint()
		local rt = type(repl)
		if (rt == "string" or rt == "number") and native_ok(s, pat) then
			repl = tostring(repl)
			local pct = select(2, s_gsub(repl, "%%", "%%"))
			local bound = #s + (#s + 1) * (#repl + pct * #s)
			if bound <= max_string() then
				return s_gsub(s, pat, repl, n)
			end
		end
		return lp.gsub(s, pat, repl, n, max_string())
	end

	function S.split(s, sep, include_empty, max_splits)
		s = str_arg(s, "split", 1)
		sep = sep ~= nil and str_arg(sep, "split", 2) or ","
		if sep == "" then error("bad argument #2 to 'split' (empty separator)", 2) end
		max_splits = max_splits or -1
		local out = {}
		local pos = 1
		while true do
			ctx.checkpoint()
			local a, b
			if max_splits ~= 0 then
				a, b = S.find(s, sep, pos, true)
			end
			local piece = S.sub(s, pos, (a or #s + 1) - 1)
			if include_empty or piece ~= "" then out[#out + 1] = piece end
			if not a then break end
			pos = b + 1
			max_splits = max_splits - 1
		end
		return out
	end

	function S.trim(s)
		s = str_arg(s, "trim", 1)
		local a = 1
		local b = #s
		local byte = native.string.byte
		while a <= b do
			local c = byte(s, a)
			if c ~= 32 and (c < 9 or c > 13) then break end
			a = a + 1
		end
		while b >= a do
			local c = byte(s, b)
			if c ~= 32 and (c < 9 or c > 13) then break end
			b = b - 1
		end
		return S.sub(s, a, b)
	end

	return S
end

-- Merge sort written in Lua (interruptible), used for large tables
local function lua_sort(t, n, lt)
	local tmp = {}
	local width = 1
	while width < n do
		local i = 1
		while i <= n do
			local mid = math.min(i + width, n + 1)
			local hi = math.min(i + 2 * width, n + 1)
			local a, b, k = i, mid, i
			while a < mid and b < hi do
				if lt(t[b], t[a]) then
					tmp[k] = t[b]
					b = b + 1
				else
					tmp[k] = t[a]
					a = a + 1
				end
				k = k + 1
			end
			while a < mid do tmp[k] = t[a] a = a + 1 k = k + 1 end
			while b < hi do tmp[k] = t[b] b = b + 1 k = k + 1 end
			i = i + 2 * width
		end
		for j = 1, n do t[j] = tmp[j] end
		width = width * 2
	end
end

local function default_lt(a, b) return a < b end

function safestd.make_table(ctx)
	local T = {}
	T.insert = native.table.insert
	T.remove = native.table.remove
	T.maxn = native.table.maxn

	function T.unpack(t, i, j)
		if type(t) ~= "table" then
			error("bad argument #1 to 'unpack' (table expected, got " .. type(t) .. ")", 2)
		end
		i = i or 1
		j = j or #t
		if j - i >= 7999 then error("too many results to unpack", 2) end
		return unpack(t, i, j)
	end

	function T.concat(t, sep, i, j)
		if type(t) ~= "table" then
			error("bad argument #1 to 'concat' (table expected, got " .. type(t) .. ")", 2)
		end
		sep = sep ~= nil and str_arg(sep, "concat", 2) or ""
		i = int_arg(i, "concat", 3, 1)
		j = int_arg(j, "concat", 4, #t)
		local total = 0
		local limit = max_string()
		for k = i, j do
			local v = rawget(t, k)
			local tv = type(v)
			if tv == "string" then
				total = total + #v + #sep
			elseif tv == "number" then
				total = total + 24 + #sep
			else
				error(("invalid value (at index %d) in table for 'concat'"):format(k), 2)
			end
			if total > limit then error("table.concat: resulting string too large", 2) end
		end
		ctx.checkpoint()
		return tconcat(t, sep, i, j)
	end

	function T.sort(t, lt)
		if type(t) ~= "table" then
			error("bad argument #1 to 'sort' (table expected, got " .. type(t) .. ")", 2)
		end
		if lt ~= nil and type(lt) ~= "function" then
			error("bad argument #2 to 'sort' (function expected)", 2)
		end
		local n = #t
		ctx.checkpoint()
		if n <= NATIVE_SORT then
			return tsort(t, lt)
		end
		lua_sort(t, n, lt or default_lt)
	end

	return T
end

function safestd.make_math(ctx)
	local M = {}
	for k, v in pairs(math) do M[k] = v end
	local rng = PcgRandom(math.random(0, 2147483646))
	local function float()
		return (rng:next() + 2147483648) / 4294967296
	end
	function M.random(m, n)
		if m == nil then return float() end
		m = math.floor(tonumber(m) or error("bad argument #1 to 'random' (number expected)", 2))
		if n == nil then
			m, n = 1, m
		else
			n = math.floor(tonumber(n) or error("bad argument #2 to 'random' (number expected)", 2))
		end
		if m > n then error("bad argument to 'random' (interval is empty)", 2) end
		return m + math.floor(float() * (n - m + 1))
	end
	function M.randomseed(seed)
		rng = PcgRandom(math.floor(tonumber(seed) or 0))
	end
	return M
end

function safestd.make_os()
	local O = {}
	O.time = function(t)
		if t ~= nil and type(t) ~= "table" then error("bad argument #1 to 'time' (table expected)", 2) end
		if t then t = luabots.util.copy_data(t, 1024) end
		return os.time(t)
	end
	O.clock = os.clock
	O.difftime = os.difftime
	O.date = function(fmt, t)
		if fmt ~= nil then fmt = str_arg(fmt, "date", 1) end
		if fmt and #fmt > 256 then error("os.date: format too long", 2) end
		if t ~= nil and type(t) ~= "number" then error("bad argument #2 to 'date' (number expected)", 2) end
		return os.date(fmt, t)
	end
	return O
end

-- Coroutines: internal tokens (actions waiting, automatic pauses) must travel through the program's own coroutines up to the scheduler.
function safestd.make_coroutine(ctx)
	local C = {}
	local c_resume, c_yield, c_status, c_create =
		coroutine.resume, coroutine.yield, coroutine.status, coroutine.create
	local internal = ctx.internal_tokens
	local KILL = ctx.KILL

	local function resume(co, ...)
		if type(co) ~= "thread" then
			error("bad argument #1 to 'resume' (coroutine expected)", 2)
		end
		local r = pack(c_resume(co, ...))
		while r[1] and internal[r[2]] and c_status(co) == "suspended" do
			c_yield(r[2])
			r = pack(c_resume(co))
		end
		if not r[1] and r[2] == KILL then error(KILL, 0) end
		return unpack(r, 1, r.n)
	end

	C.create = function(f)
		if type(f) ~= "function" then error("bad argument #1 to 'create' (function expected)", 2) end
		return c_create(f)
	end
	C.resume = resume
	C.yield = c_yield
	C.status = c_status
	C.running = coroutine.running
	C.wrap = function(f)
		local co = C.create(f)
		return function(...)
			local r = pack(resume(co, ...))
			if not r[1] then error(r[2], 2) end
			return unpack(r, 2, r.n)
		end
	end
	return C
end

-- Plain vector helpers (tables without metatables)
function safestd.make_vector()
	local V = {}
	local function num(v) return type(v) == "number" and v or 0 end
	local function vec(a)
		if type(a) ~= "table" then error("vector expected", 3) end
		return num(rawget(a, "x")), num(rawget(a, "y")), num(rawget(a, "z"))
	end
	function V.new(x, y, z)
		if type(x) == "table" then x, y, z = vec(x) end
		return {x = num(x), y = num(y), z = num(z)}
	end
	V.copy = V.new
	function V.zero() return {x = 0, y = 0, z = 0} end
	function V.add(a, b)
		local ax, ay, az = vec(a)
		if type(b) == "number" then return {x = ax + b, y = ay + b, z = az + b} end
		local bx, by, bz = vec(b)
		return {x = ax + bx, y = ay + by, z = az + bz}
	end
	function V.subtract(a, b)
		local ax, ay, az = vec(a)
		if type(b) == "number" then return {x = ax - b, y = ay - b, z = az - b} end
		local bx, by, bz = vec(b)
		return {x = ax - bx, y = ay - by, z = az - bz}
	end
	function V.multiply(a, s)
		local ax, ay, az = vec(a)
		s = num(s)
		return {x = ax * s, y = ay * s, z = az * s}
	end
	function V.divide(a, s)
		local ax, ay, az = vec(a)
		s = num(s)
		return {x = ax / s, y = ay / s, z = az / s}
	end
	function V.offset(a, x, y, z)
		local ax, ay, az = vec(a)
		return {x = ax + num(x), y = ay + num(y), z = az + num(z)}
	end
	function V.length(a)
		local x, y, z = vec(a)
		return math.sqrt(x * x + y * y + z * z)
	end
	function V.distance(a, b)
		return V.length(V.subtract(a, b))
	end
	function V.equals(a, b)
		local ax, ay, az = vec(a)
		local bx, by, bz = vec(b)
		return ax == bx and ay == by and az == bz
	end
	function V.round(a)
		local x, y, z = vec(a)
		return {x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5)}
	end
	function V.floor(a)
		local x, y, z = vec(a)
		return {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
	end
	function V.direction(a, b)
		local d = V.subtract(b, a)
		local l = V.length(d)
		if l == 0 then return V.zero() end
		return V.divide(d, l)
	end
	function V.to_string(a)
		local x, y, z = vec(a)
		return ("(%s, %s, %s)"):format(x, y, z)
	end
	return V
end

-- JSON through the engine; input is copied/limited first
function safestd.make_json(ctx)
	local J = {}
	function J.encode(value, styled)
		local ok, data = pcall(luabots.util.copy_data, value, max_string() / 4)
		if not ok then
			if data == ctx.KILL then error(data, 0) end
			error("json.encode: " .. luabots.util.format_error(data), 2)
		end
		local s, err = core.write_json(data, styled and true or false)
		if not s then error("json.encode: " .. tostring(err), 2) end
		return s
	end
	function J.decode(s)
		s = str_arg(s, "decode", 1)
		if #s > max_string() then error("json.decode: string too large", 2) end
		local v, err = core.parse_json(s, nil, true)
		if v == nil and err then error("json.decode: " .. tostring(err), 2) end
		return v
	end
	return J
end

-- Base functions (pcall/xpcall/getmetatable/...) for one program
function safestd.make_base(ctx, env)
	local KILL = ctx.KILL
	local r_pcall, r_xpcall = pcall, xpcall

	env._VERSION = _VERSION
	env.assert = assert
	env.error = error
	env.ipairs = ipairs
	env.pairs = pairs
	env.next = next
	env.select = select
	env.tonumber = tonumber
	env.tostring = tostring
	env.type = type
	env.unpack = unpack
	env.rawequal = rawequal
	env.rawget = rawget
	env.rawset = rawset

	env.getmetatable = function(v)
		if type(v) ~= "table" then return nil end
		return getmetatable(v)
	end
	env.setmetatable = function(t, mt)
		if type(t) ~= "table" then
			error("bad argument #1 to 'setmetatable' (table expected)", 2)
		end
		return setmetatable(t, mt)
	end

	env.pcall = function(f, ...)
		local r = pack(r_pcall(f, ...))
		if not r[1] and r[2] == KILL then error(KILL, 0) end
		return unpack(r, 1, r.n)
	end
	env.xpcall = function(f, handler, ...)
		if type(handler) ~= "function" then
			error("bad argument #2 to 'xpcall' (function expected)", 2)
		end
		local r = pack(r_xpcall(f, function(e)
			if e == KILL then return KILL end
			return handler(e)
		end, ...))
		if not r[1] and r[2] == KILL then error(KILL, 0) end
		return unpack(r, 1, r.n)
	end
end
