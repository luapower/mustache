
--full-spec mustache parser and bytecode-based renderer.
--Written by Cosmin Apreutesei. Public Domain.

--for a string, return a function that given a char position in the
--string returns the line and column numbers corresponding to that position.
local function textpos(s)
	--collect char indices of all the lines in s, incl. the index at #s + 1
	local t = {}
	for i in s:gmatch'()[^\r\n]*\r?\n?' do
		t[#t+1] = i
	end
	--print(pp.format(t))
	assert(#t >= 2)
	return function(i)
		--do a binary search in t to find the line
		assert(i > 0 and i <= #s + 1)
		local min, max = 1, #t
		while true do
			local k = math.floor(min + (max - min) / 2)
			if i >= t[k] then
				if k == #t or i < t[k+1] then --found it
					return k, i - t[k] + 1
				else --look forward
					min = k
				end
			else --look backward
				max = k
			end
		end
	end
end

local function raise(s, i, err, ...)
	err = string.format(err, ...)
	local where
	if s then
		if i then
			local pos = textpos(s)
			local line, col = pos(i)
			where = string.format('line %d, col %d', line, col)
		else
			where = 'eof'
		end
		err = string.format('error at %s: %s', where, err)
	else
		err = string.format('error: %s', err)
	end
	error(err)
end

local function trim(s) --from glue
	local from = s:match('^%s*()')
	return from > #s and '' or s:match('.*%S', from)
end

--calls parse(char_index, token_type, token) for each token in the string.
--tokens can be: ('var', name, [modifier]) or ('text', s).
--for 'var' tokens, modifiers can be: '&', '#', '^', '>', '/'.
--set delimiters are dealt with in the tokenizer so there's no '=' modifier.
local function tokenize(s, parse)
	local d1 = '{{' --start delimiter
	local d2 = '}}' --end delimiter
	local i = 1
	while i <= #s do
		local j = s:find(d1, i, true) -- {{
		if j then
			if j > i then --there's text before {{
				parse(i, 'text', s:sub(i, j - 1))
				i = j
			end
			local i0 = i --position of {{
			i = i + #d1
			local modifier = s:match('^[{&#%^/>=]', i)
			local d2_now = d2
			if modifier then
				i = i + 1
				if modifier == '{' then
					d2_now = '}'..d2 --expect }}}
					modifier = '&' --merge { and & cases
				elseif modifier == '=' then --set delimiter
					d1, d2 = s:match('^([^%s]+)%s+([^=]+)=', i)
					if not d1 or trim(d1) == '' or trim(d2) == '' then
						raise(s, i, 'invalid set delimiter')
					end
				end
			end
			local j = s:find(d2_now, i, true) -- }} or }}}
			if not j then
				raise(s, nil, d2_now..' expected')
			end
			local var = s:sub(i, j - 1) --text before }}, could be empty
			i = j + #d2_now
			var = trim(var)
			if #var == '' then
				raise(s, i0, 'empty name')
			end
			parse(i0, 'var', var, modifier)
		else --text till the end
			parse(i, 'text', s:sub(i))
			i = #s + 1
		end
	end

end

local function parse_var(s) --parse 'a.b.c' to {'a', 'b', 'c'}
	if s == '.' or not s:find('.', 1, true) then
		return s --simple var, leave it
	end
	local path = {}
	for s in id:gmatch'[^%.]+' do --split by `.`
		path[#path+1] = s
	end
	return path
end

--compile a template to a program that can be interpreted with render().
--the program is a list of commands with 0, 1, or 2 args as follows:
--  'text', s            : constant text, render it as is
--  'html', var          : substitute var and render it as html, escaped
--  'string', var        : substitute var and render it as is, unescaped
--  'iter', var, nextpc  : section; nexpc is the command index right after it
--  'ifnot', var, nextpc : inverted section
--  'end'                : end of section or inverted section
--  'render', var        : partial
local function compile(template)

	local prog = {template = template}
	local function cmd(cmd, arg1, arg2)
		prog[#prog+1] = cmd
		if arg1 then prog[#prog+1] = arg1 end
		if arg2 then prog[#prog+1] = arg2 end
	end

	local section_stack = {} --stack of unparsed section names
	local nextpc_stack = {} --stack of indices where nextpc needs to be set

	tokenize(template, function(i, what, s, modifier)

		if what == 'text' then
			cmd('text', s)
		elseif what == 'var' then
			if not modifier then
				cmd('html', parse_var(s))
			elseif modifier == '&' then --no escaping
				cmd('string', parse_var(s))
			elseif modifier == '#' or modifier == '^' then --section
				local c = modifier == '#' and 'iter' or 'ifnot'
			 	cmd(c, parse_var(s), 0) --0 because we don't know nextpc yet
				table.insert(section_stack, s)
				table.insert(nextpc_stack, #prog) --where the 0 above is
			elseif modifier == '/' then --close section
				local expected = table.remove(section_stack)
				if expected ~= s then
					raise(template, i,
						'expected {{/%s}} but {{/%s}} found', expected, s)
				end
				cmd('end')
				local nextpc_index = table.remove(nextpc_stack)
				prog[nextpc_index] = #prog + 1 --set nextpc on the last iter cmd
			elseif modifier == '>' then --partial
				cmd('render', s)
			end
		end

	end)

	if #section_stack > 0 then
		local sections = table.concat(section_stack, ', ')
		raise(template, nil, 'unclosed sections: %s', sections)
	end

	return prog
end

local function dump(prog) --dump bytecode (only for debugging)
	local pp = require'pp'
	local function str(var)
		return type(var) == 'table' and table.concat(var, '.') or var
	end
	local pc = 1
	while pc <= #prog do
		local cmd = prog[pc]
		pc = pc + 1
		if cmd == 'text' then
			local s = pp.format(prog[pc])
			if #s > 50 then
				s = s:sub(1, 50-3)..'...'
			end
			print(string.format('%-4d %-6s %s', pc, cmd, s))
			pc = pc + 1
		elseif cmd == 'html' or cmd == 'string' or cmd == 'render' then
			print(string.format('%-4d %-6s %-12s', pc, cmd, str(prog[pc])))
			pc = pc + 1
		elseif cmd == 'iter' or cmd == 'ifnot' then
			print(string.format('%-4d %-6s %-12s nextpc: %d', pc, cmd, str(prog[pc]), prog[pc+1]))
			pc = pc + 2
		elseif cmd == 'end' then
			print(string.format('%-4d %-6s', pc, 'end'))
			pc = pc + 1
		else
			assert(false)
		end
	end
end

local escapes = {
	['&']  = '&amp;',
	['\\'] = '&#92;',
	['"']  = '&quot;',
	['<']  = '&lt;',
	['>']  = '&gt;',
}
local function escape_html(v)
	return v and v:gsub('[&\\"<>]', escapes)
end

--check if a value is considered valid, mustache-wise.
local function istrue(v)
	if type(v) == 'table' then
		return next(v) ~= nil
	else
		return v and true or false
	end
end

--check if a value is considered a valid list.
local function islist(t)
	return type(t) == 'table' and #t > 0
end

local function render(prog, context, getpartial, write)

	if type(prog) == 'string' then --template not compiled
		prog = compile(prog)
	end

	if type(getpartial) == 'table' then --partials table given
		local partials = getpartial
		getpartial = function(name)
			return partials[name]
		end
	end

	local outbuf
	if not write then --writer not given, do buffered output
		outbuf = {}
		write = function(s)
			outbuf[#outbuf+1] = s
		end
	end

	local function out(s)
		if s == nil then return end
		write(tostring(s))
	end

	--resolve a variable in the current context. vars can be of form: 'a.b.c'
	local ctx
	local ctx_stack = {}

	local function resolve(var)
		local val
		if ctx then
			if var == '.' then
				--TODO
			elseif type(var) == 'table' then --'a.b.c' parsed as {'a', 'b', 'c'}
				--TODO
			else --simple var
				val = ctx[var]
				print(var, val, pp.format(ctx))
			end
			if type(val) == 'function' then --callback
				val = val()
			end
		end
		return val
	end

	local function push_context(val)
		table.insert(ctx_stack, ctx)
		ctx = val
	end

	local function replace_context(val)
		ctx_stack[#ctx_stack] = val
		ctx = val
	end

	local function pop_context()
		ctx = table.remove(ctx_stack)
	end

	local pc = 1 --program counter
	local function pull()
		local val = prog[pc]
		pc = pc + 1
		return val
	end

	local iter_stack = {}
	local HASH, COND = {}, {} --signaling constants
	local function iter(val, nextpc)
		if islist(val) then --list value, iterate it
			table.insert(iter_stack, {list = val, n = 1, pc = pc})
			push_context(val[1])
		else
			if type(val) == 'table' then --hash map, set as context
				table.insert(iter_stack, HASH)
				push_context(val)
			else --conditional value, preserve context
				table.insert(iter_stack, COND)
			end
		end
	end

	local function enditer()
		local iter = iter_stack[#iter_stack]
		if iter.n then
			iter.n = iter.n + 1
			if iter.n <= #iter.list then
				replace_context(iter.list[iter.n])
				pc = iter.pc --loop
			end
		else
			table.remove(iter_stack)
			if iter == HASH then
				pop_context()
			end
		end
	end

	push_context(context)

	dump(prog)

	while pc <= #prog do
		local cmd = pull()
		print(cmd)
		if cmd == 'text' then
			out(pull())
		elseif cmd == 'html' then
			out(escape_html(resolve(pull())))
		elseif cmd == 'string' then
			out(resolve(pull()))
		elseif cmd == 'iter' or cmd == 'ifnot' then
			local val = resolve(pull())
			local nextpc = pull()
			if cmd == 'ifnot' then
				val = not istrue(val)
			end
			if istrue(val) then --valid section value, iterate it
				iter(val, nextpc)
			else
				pc = nextpc --skip section entirely
			end
		elseif cmd == 'end' then
			enditer() --loop back or pop iteration
		end
	end

	if outbuf then
		return table.concat(outbuf)
	end
end

if not ... then

--[==[
local s = [[

text {{var}}

{{#section}}

	more text

	{{#subsection}}

		text inside {{{var2}}}

	{{/subsection}}

	text outside

{{/section}}


]]

local t = {
	var = 'hello',
	section = {
		subsection = {
			{var2 = 'once'},
			{var2 = 'twice'},
		},
	},
}

print(render(s, t))
]==]

--[[
print(render('{{var}} world!', {var = 'hello (a & b)'}))
print(render('{{{var}}} world!', {var = 'hello'}))
print(render('{{& var }} world!', {var = 'hello'}))
print(render('{{=$$  $$=}}$$ var $$ world!$$={{  }}=$$ and {{var}} again!', {var = 'hello'}))
]]
print(render('{{#a}}[{{b}}] {{/a}}', {a = {{b = '1'}, {b = '2'}}}))

end

return {
	compile = compile,
	render = render,
	dump = dump,
}

