-- A small Lua 5.1 tokenizer.
-- It is NOT used to make code safe (the sandbox does that at run time); it only enforces a limit on very long '..' chains, because a single concatenation instruction with hundreds of operands could allocate a
-- huge string before the instruction hook gets a chance to run.

local lexer = {}
luabots.lexer = lexer

local byte, sub, find = string.byte, string.sub, string.find

local KEYWORDS = {}
for w in ([[and break do else elseif end false for function goto if in local
		nil not or repeat return then true until while]]):gmatch("%a+") do
	KEYWORDS[w] = true
end

-- Returns list of tokens {type, value, line} or nil, err types: "name", "keyword", "number", "string", "op", "eof"
function lexer.tokenize(src)
	local tokens = {}
	local i, len, line = 1, #src, 1

	local function push(t, v)
		tokens[#tokens + 1] = {t, v, line}
	end

	-- Reads a long bracket starting at i ('[' followed by '='* and '[').
	-- Returns end index or nil
	local function long_bracket(start)
		local s, e, eq = find(src, "^%[(=*)%[", start)
		if not s then return nil end
		local close = "]" .. eq .. "]"
		local cs, ce = find(src, close, e + 1, true)
		if not cs then return false end
		local _, nl = sub(src, start, ce):gsub("\n", "")
		line = line + nl
		return ce
	end

	while i <= len do
		local c = byte(src, i)
		if c == 10 then
			line = line + 1
			i = i + 1
		elseif c == 32 or c == 9 or c == 13 or c == 11 or c == 12 then
			i = i + 1
		elseif c == 45 and byte(src, i + 1) == 45 then -- comment
			local e = nil
			if byte(src, i + 2) == 91 then
				e = long_bracket(i + 2)
				if e == false then return nil, ("line %d: unfinished long comment"):format(line) end
			end
			if e then
				i = e + 1
			else
				local nl = find(src, "\n", i, true)
				i = nl or len + 1
			end
		elseif c == 91 and (byte(src, i + 1) == 91 or byte(src, i + 1) == 61) then
			local startline = line
			local e = long_bracket(i)
			if e == false then return nil, ("line %d: unfinished long string"):format(startline) end
			if e then
				tokens[#tokens + 1] = {"string", "", startline}
				i = e + 1
			else
				push("op", "[")
				i = i + 1
			end
		elseif c == 34 or c == 39 then -- quoted string
			local q = c
			local j = i + 1
			local startline = line
			while true do
				local d = byte(src, j)
				if d == nil or d == 10 then
					return nil, ("line %d: unfinished string"):format(startline)
				elseif d == 92 then -- backslash
					if byte(src, j + 1) == 10 then line = line + 1 end
					j = j + 2
				elseif d == q then
					break
				else
					j = j + 1
				end
			end
			tokens[#tokens + 1] = {"string", "", startline}
			i = j + 1
		elseif (c >= 48 and c <= 57) or (c == 46 and (byte(src, i + 1) or 0) >= 48
				and (byte(src, i + 1) or 0) <= 57) then
			local s, e = find(src, "^0[xX][%x]+", i)
			if not s then
				s, e = find(src, "^%d*%.?%d*[eE][%+%-]?%d+", i)
			end
			if not s then
				s, e = find(src, "^%d*%.?%d*", i)
			end
			local _, e2 = find(src, "^[%w_]*", e + 1) -- suffixes like LL, ULL, i
			push("number", sub(src, i, e2))
			i = e2 + 1
		elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
			local _, e = find(src, "^[%w_]+", i)
			local w = sub(src, i, e)
			push(KEYWORDS[w] and "keyword" or "name", w)
			i = e + 1
		else
			local three = sub(src, i, i + 2)
			local two = sub(src, i, i + 1)
			if three == "..." then
				push("op", three)
				i = i + 3
			elseif two == ".." or two == "==" or two == "~=" or two == "<=" or
					two == ">=" or two == "::" then
				push("op", two)
				i = i + 2
			else
				push("op", sub(src, i, i))
				i = i + 1
			end
		end
	end
	push("eof", "")
	return tokens
end

-- Tokens that end a concatenation chain (lower precedence or statements)
local CHAIN_BREAK_OPS = {
	[","] = true, [";"] = true, ["="] = true, ["=="] = true, ["~="] = true,
	["<"] = true, [">"] = true, ["<="] = true, [">="] = true, ["::"] = true,
}
local CHAIN_KEEP_KEYWORDS = {["nil"] = true, ["true"] = true, ["false"] = true, ["not"] = true}

local OPEN = {["("] = ")", ["["] = "]", ["{"] = "}"}
local CLOSE = {[")"] = true, ["]"] = true, ["}"] = true}

-- Returns nil if fine, or an error message
function lexer.check(src, max_chain)
	local tokens, err = lexer.tokenize(src)
	if not tokens then return err end
	local counts = {0}
	for _, tok in ipairs(tokens) do
		local t, v = tok[1], tok[2]
		if t == "op" then
			if v == ".." then
				local d = #counts
				counts[d] = counts[d] + 1
				if counts[d] > max_chain then
					return ("line %d: too many '..' in one expression (max %d), split it into several statements")
							:format(tok[3], max_chain)
				end
			elseif OPEN[v] then
				counts[#counts + 1] = 0
			elseif CLOSE[v] then
				if #counts > 1 then counts[#counts] = nil end
			elseif CHAIN_BREAK_OPS[v] then
				counts[#counts] = 0
			end
		elseif t == "keyword" and not CHAIN_KEEP_KEYWORDS[v] then
			counts[#counts] = 0
		end
	end
	return nil
end
