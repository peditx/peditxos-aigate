--[[
  PeDItXOS-AiGate engine v0.2.0 — native Lua AI gateway (no Node.js anywhere)
  CGI under a dedicated uhttpd (cgi_prefix='/'); route stubs dofile() this.

  v0.2: CROSS-DIALECT TRANSLATION — a client speaking OpenAI reaches
  Anthropic-style providers and vice versa, request + response + SSE + tools.
  Any provider may add extra headers (UCI option headers: 'A: 1|B: 2').
  Fallback = UCI section order across ALL providers regardless of dialect.
]]
io.stdout:setvbuf("no")

-- ================= bundled JSON (round-trip faithful, zero deps) =================
local json = {}
local JSONNULL = {}
json.null = JSONNULL
local OBJMT = { __jsonobj = true }
local ARRMT = { __jsonarr = true }
local function arr() return setmetatable({}, ARRMT) end

local function json_escstr(s)
	local q = { ['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
	return s:gsub('[%c"\\]', function(c) return q[c] or string.format('\\u%04x', c:byte()) end)
end

local function is_array(t)
	if getmetatable(t) == ARRMT then return true end
	if getmetatable(t) == OBJMT then return false end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
		n = n + 1
	end
	return n == #t
end

function json.encode(v)
	local tv = type(v)
	if v == JSONNULL or v == nil then return 'null' end
	if tv == 'boolean' then return v and 'true' or 'false' end
	if tv == 'number' then
		if math.type(v) == 'integer' then return tostring(v) end
		if v ~= v or v == math.huge or v == -math.huge then return 'null' end
		return string.format('%.14g', v)
	end
	if tv == 'string' then return '"' .. json_escstr(v) .. '"' end
	if tv == 'table' then
		local parts = {}
		if is_array(v) then
			for i = 1, #v do parts[#parts + 1] = json.encode(v[i]) end
			return '[' .. table.concat(parts, ',') .. ']'
		end
		for k, val in pairs(v) do
			parts[#parts + 1] = '"' .. json_escstr(tostring(k)) .. '":' .. json.encode(val)
		end
		return '{' .. table.concat(parts, ',') .. '}'
	end
	return 'null'
end

local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000),
		0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function json.decode(s)
	local i, n = 1, #s
	local parse_value
	local function skip_ws()
		local _, j = s:find('^[ \t\r\n]*', i); i = j + 1
	end
	local function parse_string()
		i = i + 1
		local out = {}
		while i <= n do
			local c = s:sub(i, i)
			if c == '"' then i = i + 1; return table.concat(out) end
			if c == '\\' then
				local e = s:sub(i + 1, i + 1)
				if e == 'u' then
					local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0
					i = i + 6
					if cp >= 0xD800 and cp <= 0xDBFF then -- surrogate pair
						local lo = tonumber(s:sub(i + 2, i + 5), 16) or 0
						i = i + 6
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					end
					out[#out + 1] = utf8_char(cp)
				else
					local map = { n = '\n', r = '\r', t = '\t', b = '\b',
						f = '\f', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
					out[#out + 1] = map[e] or e
					i = i + 2
				end
			else
				out[#out + 1] = c; i = i + 1
			end
		end
		error('unterminated string')
	end
	local function parse_number()
		local num = s:match('^-?%d+%.?%d*[eE][-+]?%d+', i) or s:match('^-?%d+%.?%d*', i)
		i = i + #num
		return tonumber(num)
	end
	local function parse_array()
		i = i + 1
		local t = setmetatable({}, ARRMT)
		skip_ws()
		if s:sub(i, i) == ']' then i = i + 1; return t end
		while true do
			t[#t + 1] = parse_value()
			skip_ws()
			local c = s:sub(i, i)
			if c == ',' then i = i + 1
			elseif c == ']' then i = i + 1; return t
			else error('bad array at ' .. i) end
		end
	end
	local function parse_object()
		i = i + 1
		local t = setmetatable({}, OBJMT)
		skip_ws()
		if s:sub(i, i) == '}' then i = i + 1; return t end
		while true do
			skip_ws()
			if s:sub(i, i) ~= '"' then error('bad key at ' .. i) end
			local k = parse_string()
			skip_ws()
			if s:sub(i, i) ~= ':' then error('bad colon at ' .. i) end
			i = i + 1
			t[k] = parse_value()
			skip_ws()
			local c = s:sub(i, i)
			if c == ',' then i = i + 1
			elseif c == '}' then i = i + 1; return t
			else error('bad object at ' .. i) end
		end
	end
	parse_value = function()
		skip_ws()
		local c = s:sub(i, i)
		if c == '"' then return parse_string()
		elseif c == '{' then return parse_object()
		elseif c == '[' then return parse_array()
		elseif c == 't' then i = i + 4; return true
		elseif c == 'f' then i = i + 5; return false
		elseif c == 'n' then i = i + 4; return JSONNULL
		elseif c == '-' or c:match('%d') then return parse_number()
		end
		error('bad value at ' .. i)
	end
	local v = parse_value()
	skip_ws()
	return v
end

-- not-null helper (JSON null decodes to JSONNULL sentinel)
local function nn(v) return v ~= nil and v ~= JSONNULL end

-- ================= plumbing =================
local function emit(s) io.write(s); io.flush() end

local function read_file(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local d = f:read('*a'); f:close(); return d
end

local function sq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function http_error(code, reason)
	emit('Status: ' .. code .. ' ' .. reason .. '\r\n')
	emit('Content-Type: application/json\r\n\r\n')
	emit(json.encode({ error = { message = reason, type = 'aigate_error' } }) .. '\n')
end

-- ================= config =================
-- 9router-style model:
--   provider sections: type (anthropic|openai), base_url, headers, models
--   account  sections: provider=<name>, api_key, tier (subscription|cheap|free),
--                      priority, model (override), max_tokens, enabled
-- Fallback order: tier (subscription→cheap→free), then priority, then
-- round-robin among accounts tied on both — exactly like upstream 9router.
local CONFIG_CMD = (os.getenv('AIGATE_CONFIG_FILE')
	and ('cat ' .. os.getenv('AIGATE_CONFIG_FILE')))
	or 'uci -q show aigate 2>/dev/null'

local cfg = { providers = {}, accounts = {}, combos = {} }
local p = io.popen(CONFIG_CMD)
if p then
	for line in p:lines() do
		local sec, key, val = line:match("^aigate%.([%w_]+)%.([%w_]+)='(.*)'$")
		if sec then
			if sec == 'main' then
				cfg.main = cfg.main or {}; cfg.main[key] = val
			else
				local rec
				-- section TYPE is classified lazily: an option 'provider <name>'
				-- marks the section as an account (see re-bucket below).
				for _, list in ipairs({ cfg.providers, cfg.accounts }) do
					for _, r in ipairs(list) do
						if r._name == sec then rec = r; break end
					end
					if rec then break end
				end
				if not rec then
					rec = { _name = sec }
					-- provisional: land in providers; re-bucket on option 'provider'
					cfg.providers[#cfg.providers + 1] = rec
				end
				rec[key] = val
				if key == 'provider' and rec._bucket ~= 'account' then
					rec._bucket = 'account'
					for i, r in ipairs(cfg.providers) do
						if r == rec then table.remove(cfg.providers, i); break end
					end
					cfg.accounts[#cfg.accounts + 1] = rec
				elseif key == 'chain' and rec._bucket ~= 'combo' then
					rec._bucket = 'combo'
					for i, r in ipairs(cfg.providers) do
						if r == rec then table.remove(cfg.providers, i); break end
					end
					cfg.combos[rec._name] = rec
				end
			end
		end
	end
	p:close()
end
cfg.main = cfg.main or {}

-- round-robin state (like 9router: rotate accounts inside a tier)
local RR_DIR = '/tmp/aigate-rr'
local function rr_next(provider_name)
	local f = io.open(RR_DIR .. '/' .. provider_name, 'r')
	local last = f and tonumber(f:read('*a')) or -1
	if f then f:close() end
	os.execute('mkdir -p ' .. sq(RR_DIR) .. ' 2>/dev/null')
	local wf = io.open(RR_DIR .. '/' .. provider_name, 'w')
	if wf then wf:write(tostring(last + 1)); wf:close() end
	return last + 1
end

local TIER_RANK = { subscription = 1, cheap = 2, free = 3 }

-- candidate accounts for a requested model, in 9router fallback order:
-- GLOBAL tier order (subscription -> cheap -> free across all providers),
-- then priority; round-robin rotates accounts inside each provider so two
-- same-tier accounts alternate like upstream 9router.
local function pick_accounts(model)
	local flat = {}
	for pidx, pr in ipairs(cfg.providers) do
		if pr.enabled ~= '0' and pr.type and pr.base_url then
			-- model catalog gate: empty = accepts any model
			local catalog_ok = true
			if pr.models and pr.models ~= '' then
				catalog_ok = false
				for m in pr.models:gmatch('[^,]+') do
					m = m:match('^%s*(.-)%s*$')
					if m == (model or '') then catalog_ok = true; break end
				end
			end
			if catalog_ok then
				local mine = {}
				for _, ac in ipairs(cfg.accounts) do
					if ac.enabled ~= '0' and ac.provider == pr._name
						and nn(ac.api_key) and ac.api_key ~= '' then
						mine[#mine + 1] = ac
					end
				end
				if #mine > 0 then
					local rot = rr_next(pr._name)
					for i = 1, #mine do
						local ac = mine[(i + rot) % #mine + 1]
						flat[#flat + 1] = { pr = pr, ac = ac, p = pidx, i = i }
					end
				end
			end
		end
	end
	table.sort(flat, function(a, b)
		local ta = TIER_RANK[a.ac.tier or 'free'] or 3
		local tb = TIER_RANK[b.ac.tier or 'free'] or 3
		if ta ~= tb then return ta < tb end
		local pa = tonumber(a.ac.priority or a.pr.priority or 0)
		local pb = tonumber(b.ac.priority or b.pr.priority or 0)
		if pa ~= pb then return pa < pb end
		if a.p ~= b.p then return a.p < b.p end
		return a.i < b.i
	end)
	return flat
end

local path = (os.getenv('REQUEST_URI') or '/'):gsub('[?#].*$', '')
local method = os.getenv('REQUEST_METHOD') or 'GET'
local auth = os.getenv('HTTP_AUTHORIZATION')

-- ================= health (JSON only — the LuCI page is THE dashboard) =======
local function page_health()
	local ver = (read_file('/usr/lib/aigate/VERSION') or 'dev'):match('^%s*(.-)%s*$')
	local provs, accts = 0, 0
	for _, pr in ipairs(cfg.providers) do
		if pr.enabled ~= '0' then provs = provs + 1 end
	end
	for _, ac in ipairs(cfg.accounts) do
		if ac.enabled ~= '0' then accts = accts + 1 end
	end
	emit('Content-Type: application/json\r\n\r\n')
	emit(json.encode({
		app = 'aigate', version = ver, providers = provs, accounts = accts,
		auth = (nn(cfg.main.api_key) and cfg.main.api_key ~= '') and 'on' or 'off',
		port = cfg.main.port or '20128',
		endpoints = { '/v1/messages', '/v1/chat/completions', '/v1/models' },
	}) .. '\n')
end

-- ================= /v1/models =================
local function page_models()
	local ids, seen = {}, {}
	for _, pr in ipairs(cfg.providers) do
		if pr.enabled ~= '0' and pr.models then
			for m in pr.models:gmatch('[^,]+') do
				m = m:match('^%s*(.-)%s*$')
				if m and m ~= '' and not seen[m] then
					seen[m] = true; ids[#ids + 1] = m
				end
			end
		end
	end
	for cname in pairs(cfg.combos) do
		if not seen[cname] then seen[cname] = true; ids[#ids + 1] = cname end
	end
	emit('Content-Type: application/json\r\n\r\n')
	local t = arr()
	for _, id in ipairs(ids) do
		t[#t + 1] = { id = id, object = 'model',
			owned_by = cfg.combos[id] and 'aigate-combo' or 'aigate' }
	end
	emit(json.encode({ object = 'list', data = t }) .. '\n')
end

-- ================= /v1/providers (preset registry from JSON) ============
local function page_providers()
	local raw = read_file(os.getenv('AIGATE_PROVIDERS_FILE')
		or '/usr/share/aigate/providers.json') or '{}'
	local okd, doc = pcall(json.decode, raw)
	if not okd or type(doc) ~= 'table' then doc = {} end
	emit('Content-Type: application/json\r\n\r\n')
	local out = { object = 'list', data = arr() }
	local provs = doc.providers or {}
	for name, p in pairs(provs) do
		if type(p) == 'table' then
			out.data[#out.data + 1] = {
				id = name, object = 'provider',
				display = p.display, dialect = p.type,
				base_url = p.url, auth = p.auth,
				capabilities = { chat = true,
					embeddings = p.embeddings and true or false,
					images = p.images and true or false,
					tts = p.tts and true or false,
					stt = p.stt and true or false,
					search = p.search and true or false },
			}
		end
	end
	emit(json.encode(out) .. '\n')
end

-- ================= request translators =================
-- helpers
local function text_of_content(c) -- OpenAI parts-array or string → string
	if type(c) == 'string' then return c end
	local out = {}
	if type(c) == 'table' then
		for _, part in ipairs(c) do
			if type(part) == 'table' and part.type == 'text' and nn(part.text) then
				out[#out + 1] = part.text
			end
		end
	end
	return table.concat(out, '\n')
end

-- Anthropic image block → OpenAI image_url part
local function aimg_to_oimg(blk)
	if type(blk.source) ~= 'table' then return nil end
	local src = blk.source
	if src.type == 'base64' then
		return { type = 'image_url',
			image_url = { url = 'data:' .. (src.media_type or 'image/png') .. ';base64,' .. src.data } }
	elseif src.type == 'url' then
		return { type = 'image_url', image_url = { url = src.url } }
	end
	return nil
end

-- OpenAI image part → Anthropic image block
local function oimg_to_aimg(part)
	local url = (type(part.image_url) == 'table') and part.image_url.url
		or part.image_url
	if type(url) ~= 'string' then return nil end
	local b64 = url:match('^data:([^;]+);base64,(.+)$')
	if b64 then
		local media, data = url:match('^data:([^;]+);base64,(.+)$')
		return { type = 'image', source = { type = 'base64', media_type = media, data = data } }
	end
	return { type = 'image', source = { type = 'url', url = url } }
end

-- client=anthropic, provider=openai
local function a2o_req(b, pr)
	local o = { model = b.model, stream = nn(b.stream) and b.stream or nil }
	if nn(b.temperature) then o.temperature = b.temperature end
	if nn(b.top_p) then o.top_p = b.top_p end
	if nn(b.max_tokens) then o.max_tokens = b.max_tokens end
	if nn(b.stop_sequences) then o.stop = b.stop_sequences end
	if nn(b.user) then o.user = b.user end
	-- thinking (anthropic client field) -> reasoning_effort (openai field)
	if nn(b.thinking) and type(b.thinking) == 'table' then
		local t = b.thinking
		if t.type == 'enabled' then
			local bt = tonumber(t.budget_tokens) or 10000
			o.reasoning_effort = (bt >= 12000) and 'high'
				or (bt >= 5000) and 'medium' or 'low'
		elseif t.type == 'disabled' then
			o.reasoning_effort = 'none'
		end
	elseif nn(b.reasoning_effort) then
		o.reasoning_effort = b.reasoning_effort
	end
	if pr and pr.effort then o.reasoning_effort = pr.effort end
	if nn(b.stream_options) then o.stream_options = b.stream_options end
	if nn(b.tool_choice) then
		local tc = b.tool_choice
		if tc.type == 'auto' or tc.type == 'any' then
			o.tool_choice = (tc.type == 'any') and 'required' or 'auto'
		elseif tc.type == 'tool' and nn(tc.name) then
			o.tool_choice = { type = 'function', ['function'] = { name = tc.name } }
		end
	end
	local msgs = arr()
	if nn(b.system) then
		local s = b.system
		msgs[#msgs + 1] = { role = 'system',
			content = (type(s) == 'table') and text_of_content(s) or s }
	end
	for _, m in ipairs(b.messages or {}) do
		if m.role == 'assistant' then
			local am = { role = 'assistant' }
			if type(m.content) == 'string' then
				am.content = m.content
			elseif type(m.content) == 'table' then
				local txt = {}
				for _, blk in ipairs(m.content) do
					if blk.type == 'text' and nn(blk.text) then txt[#txt + 1] = blk.text end
				end
				if #txt > 0 then am.content = table.concat(txt, '\n') end
			end
			if nn(m.tool_calls) and #m.tool_calls > 0 then
				local tcs = arr()
				for _, tc in ipairs(m.tool_calls) do
					local f = tc['function'] or tc['function'] or {}
					tcs[#tcs + 1] = { id = tc.id, type = 'function',
						['function'] = { name = f.name, arguments = f.arguments } }
				end
				am.tool_calls = tcs
				if am.content == nil then am.content = JSONNULL end
			end
			msgs[#msgs + 1] = am
		elseif m.role == 'tool' then
			msgs[#msgs + 1] = { role = 'tool', tool_call_id = m.tool_call_id,
				content = m.content }
		else -- user
			local um = { role = 'user' }
			if type(m.content) == 'string' then
				um.content = m.content
			elseif type(m.content) == 'table' then
				local parts = arr()
				for _, blk in ipairs(m.content) do
					if blk.type == 'text' and nn(blk.text) then
						parts[#parts + 1] = { type = 'text', text = blk.text }
					elseif blk.type == 'image' then
						local img = aimg_to_oimg(blk)
						if img then parts[#parts + 1] = img end
					elseif blk.type == 'tool_result' then
						-- flatten into a tool message before this user turn
						local c = blk.content
						if type(c) == 'table' then
							local bits = {}
							for _, p2 in ipairs(c) do
								if p2.type == 'text' and nn(p2.text) then bits[#bits + 1] = p2.text end
							end
							c = table.concat(bits, '\n')
						end
						msgs[#msgs + 1] = { role = 'tool', tool_call_id = blk.tool_use_id,
							content = c or '' }
					end
				end
				um.content = (#parts > 0) and parts or JSONNULL
			end
			msgs[#msgs + 1] = um
		end
	end
	o.messages = msgs
	if nn(b.tools) and #b.tools > 0 then
		local tools = arr()
		for _, t in ipairs(b.tools) do
			tools[#tools + 1] = { type = 'function',
				['function'] = { name = t.name, description = t.description,
					parameters = t.input_schema or { type = 'object' } } }
		end
		o.tools = tools
	end
	return o
end

-- client=openai, provider=anthropic
local function o2a_req(b, pr)
	local o = { model = b.model, stream = nn(b.stream) and b.stream or nil }
	o.max_tokens = (nn(b.max_tokens) and b.max_tokens)
		or tonumber(pr and pr.max_tokens) or 8192
	if nn(b.temperature) then o.temperature = b.temperature end
	if nn(b.top_p) then o.top_p = b.top_p end
	if nn(b.top_k) then o.top_k = b.top_k end
	-- reasoning_effort (openai client field) -> thinking (anthropic field)
	if nn(b.reasoning_effort) then
		local e = b.reasoning_effort
		if e == 'none' then
			o.thinking = { type = 'disabled' }
		elseif e == 'low' or e == 'medium' or e == 'high' then
			o.thinking = { type = 'enabled',
				budget_tokens = (e == 'high') and 16000
					or (e == 'medium') and 8000 or 2000 }
		end
	elseif nn(b.thinking) and type(b.thinking) == 'table' then
		o.thinking = b.thinking
	end
	if pr and pr.thinking == 'on' then
		o.thinking = { type = 'enabled', budget_tokens = 10000 }
	elseif pr and pr.thinking == 'off' then
		o.thinking = { type = 'disabled' }
	end
	if nn(b.stop) then
		o.stop_sequences = (type(b.stop) == 'table') and b.stop or { b.stop }
	end
	if nn(b.user) then o.metadata = { user_id = b.user } end
	if nn(b.tool_choice) then
		local tc = b.tool_choice
		if tc == 'auto' or tc == 'required' then
			o.tool_choice = { type = (tc == 'required') and 'any' or 'auto' }
		elseif type(tc) == 'table' and tc.type == 'function' and nn(tc['function']) then
			o.tool_choice = { type = 'tool', name = tc['function'].name }
		end
	end
	local sys, msgs = {}, arr()
	for _, m in ipairs(b.messages or {}) do
		if m.role == 'system' then
			sys[#sys + 1] = text_of_content(m.content)
		elseif m.role == 'tool' then
			local tr = { type = 'tool_result', tool_use_id = m.tool_call_id,
				content = m.content }
			local last = msgs[#msgs]
			if last and last.role == 'user' and type(last.content) == 'table'
				and getmetatable(last.content) then
				last.content[#last.content + 1] = tr
			else
				msgs[#msgs + 1] = { role = 'user', content = setmetatable({ tr }, { __jsonarr = true }) }
			end
		elseif m.role == 'assistant' then
			local blocks = arr()
			if type(m.content) == 'string' and m.content ~= '' then
				blocks[#blocks + 1] = { type = 'text', text = m.content }
			elseif type(m.content) == 'table' then
				for _, part in ipairs(m.content) do
					if part.type == 'text' and nn(part.text) then
						blocks[#blocks + 1] = { type = 'text', text = part.text }
					elseif part.type == 'image_url' then
						local img = oimg_to_aimg(part)
						if img then blocks[#blocks + 1] = img end
					end
				end
			end
			if nn(m.tool_calls) then
				for _, tc in ipairs(m.tool_calls) do
					local f = tc['function'] or tc['function'] or {}
					local input = {}
					if nn(f.arguments) then
						local okj, parsed = pcall(json.decode, f.arguments)
						if okj and type(parsed) == 'table' then input = parsed end
					end
					blocks[#blocks + 1] = { type = 'tool_use', id = tc.id,
						name = f.name, input = setmetatable(input, { __jsonobj = true }) }
				end
			end
			msgs[#msgs + 1] = { role = 'assistant',
				content = (#blocks > 0) and blocks or '' }
		else -- user
			if type(m.content) == 'string' then
				msgs[#msgs + 1] = { role = 'user', content = m.content }
			elseif type(m.content) == 'table' then
				local blocks = arr()
				for _, part in ipairs(m.content) do
					if part.type == 'text' and nn(part.text) then
						blocks[#blocks + 1] = { type = 'text', text = part.text }
					elseif part.type == 'image_url' then
						local img = oimg_to_aimg(part)
						if img then blocks[#blocks + 1] = img end
					end
				end
				msgs[#msgs + 1] = { role = 'user',
					content = (#blocks > 0) and blocks or '' }
			end
		end
	end
	if #sys > 0 then o.system = table.concat(sys, '\n\n') end
	o.messages = msgs
	if nn(b.tools) and #b.tools > 0 then
		local tools = arr()
		for _, t in ipairs(b.tools) do
			local f = t['function'] or t['function'] or t
			tools[#tools + 1] = { name = f.name, description = f.description,
				input_schema = f.parameters or { type = 'object' } }
		end
		o.tools = tools
	end
	return o
end

-- ================= response translators (non-stream) =================
local A2O_STOP = { end_turn = 'stop', max_tokens = 'length', tool_use = 'tool_calls',
	stop_sequence = 'stop', refusal = 'content_filter' }
local O2A_STOP = { stop = 'end_turn', length = 'max_tokens', tool_calls = 'tool_use',
	content_filter = 'end_turn' }

local function a2o_resp(r)
	local text, tcs = {}, arr()
	for _, blk in ipairs(r.content or {}) do
		if blk.type == 'text' and nn(blk.text) then text[#text + 1] = blk.text
		elseif blk.type == 'tool_use' then
			tcs[#tcs + 1] = { id = blk.id, type = 'function',
				['function'] = { name = blk.name, arguments = json.encode(blk.input or {}) } }
		end
	end
	local msg = { role = 'assistant' }
	local body = table.concat(text, '')
	if body ~= '' then msg.content = body else msg.content = JSONNULL end
	if #tcs > 0 then msg.tool_calls = tcs end
	local u = r.usage or {}
	local inp, out = u.input_tokens or 0, u.output_tokens or 0
	return { id = r.id, object = 'chat.completion', created = os.time(),
		model = r.model, choices = arr({ { index = 0, message = msg,
			finish_reason = A2O_STOP[r.stop_reason] or 'stop' } }),
		usage = { prompt_tokens = inp, completion_tokens = out,
			total_tokens = inp + out } }
end

local function o2a_resp(r)
	local ch = (r.choices and r.choices[1]) or {}
	local m = ch.message or {}
	local blocks = arr()
	if nn(m.content) and m.content ~= '' then
		blocks[#blocks + 1] = { type = 'text', text = m.content }
	end
	if nn(m.tool_calls) then
		for _, tc in ipairs(m.tool_calls) do
			local f = tc['function'] or {}
			local input = {}
			if nn(f.arguments) then
				local okj, parsed = pcall(json.decode, f.arguments)
				if okj and type(parsed) == 'table' then input = parsed end
			end
			blocks[#blocks + 1] = { type = 'tool_use', id = tc.id, name = f.name,
				input = setmetatable(input, { __jsonobj = true }) }
		end
	end
	local u = r.usage or {}
	return { id = r.id or 'msg_aigate', type = 'message', role = 'assistant',
		model = r.model, content = blocks,
		stop_reason = O2A_STOP[ch.finish_reason] or 'end_turn', stop_sequence = JSONNULL,
		usage = { input_tokens = u.prompt_tokens or 0,
			output_tokens = u.completion_tokens or 0 } }
end

-- ================= SSE stream translators =================
-- returns { line = fn(l)->str|nil , finish = fn()->str|nil }
local function a2o_stream() -- anthropic upstream → openai client
	local st = { ev = nil, buf = {}, id = nil, model = nil, finish = nil,
		tool_idx = {}, nt = 0, usage_in = 0, usage_out = 0, done = false, started = false }
	local function chunk(delta, fin, usage)
		local c = { id = st.id or 'chatcmpl-aigate', object = 'chat.completion.chunk',
			created = os.time(), model = st.model,
			choices = arr({ { index = 0, delta = delta,
				finish_reason = fin or JSONNULL } }) }
		if usage then c.usage = usage end
		return 'data: ' .. json.encode(c) .. '\n\n'
	end
	local function dispatch(raw)
		if raw == '[DONE]' then return '' end
		local okj, d = pcall(json.decode, raw)
		if not okj or type(d) ~= 'table' then return '' end
		local t = d.type or st.ev
		st.ev = nil
		if t == 'message_start' and type(d.message) == 'table' then
			st.started = true
			st.id = d.message.id
			st.model = d.message.model
			if type(d.message.usage) == 'table' then
				st.usage_in = d.message.usage.input_tokens or 0
			end
			return chunk({ role = 'assistant', content = '' })
		elseif t == 'content_block_start' then
			local cb = d.content_block or {}
			if cb.type == 'tool_use' then
				st.nt = st.nt + 1
				st.tool_idx[d.index or 0] = st.nt
				return chunk({ tool_calls = arr({ { index = st.nt - 1, id = cb.id,
					type = 'function', ['function'] = { name = cb.name,
						arguments = '' } } }) })
			end
			return '' -- text block start: nothing for openai
		elseif t == 'content_block_delta' then
			local dl = d.delta or {}
			if dl.type == 'text_delta' and nn(dl.text) then
				return chunk({ content = dl.text })
			elseif dl.type == 'input_json_delta' and nn(dl.partial_json) then
				local j = st.tool_idx[d.index or 0] or 0
				return chunk({ tool_calls = arr({ { index = j - 1,
					['function'] = { arguments = dl.partial_json } } }) })
			end
			return ''
		elseif t == 'message_delta' then
			if type(d.delta) == 'table' and nn(d.delta.stop_reason) then
				st.finish = A2O_STOP[d.delta.stop_reason] or 'stop'
			end
			if type(d.usage) == 'table' then
				st.usage_out = d.usage.output_tokens or st.usage_out
			end
			return ''
		elseif t == 'message_stop' then
			st.done = true
			local out = chunk({}, st.finish or 'stop',
				{ prompt_tokens = st.usage_in, completion_tokens = st.usage_out,
					total_tokens = st.usage_in + st.usage_out })
			return out .. 'data: [DONE]\n\n'
		end
		return '' -- ping etc.
	end
	return {
		line = function(l)
			if l:match('^event:') then
				st.ev = l:match('^event:%s*(.+)$')
				return nil
			elseif l:match('^data:') then
				st.buf[#st.buf + 1] = l:match('^data:%s?(.*)$') or ''
				return nil
			elseif l == '' then
				if #st.buf == 0 then return nil end
				local raw = table.concat(st.buf, '\n')
				st.buf = {}
				return dispatch(raw)
			end
			return nil
		end,
		finish = function()
			if st.done or not st.started then return nil end
			return 'data: [DONE]\n\n'
		end,
	}
end

local function o2a_stream() -- openai upstream → anthropic client
	local st = { buf = {}, id = nil, model = nil, finish = nil, started = false,
		done = false, open_block = nil, block_seq = 0, tool_idx = {},
		usage_in = 0, usage_out = 0 }
	local function ev(name, data)
		return 'event: ' .. name .. '\ndata: ' .. json.encode(data) .. '\n\n'
	end
	local function dispatch(raw)
		if raw == '[DONE]' then
			st.done = true
			local out = ''
			if st.open_block then
				out = out .. ev('content_block_stop', { index = st.open_block })
				st.open_block = nil
			end
			out = out .. ev('message_delta', {
				delta = { stop_reason = O2A_STOP[st.finish] or 'end_turn',
					stop_sequence = JSONNULL },
				usage = { input_tokens = st.usage_in, output_tokens = st.usage_out } })
			out = out .. ev('message_stop', {})
			return out
		end
		local okj, d = pcall(json.decode, raw)
		if not okj or type(d) ~= 'table' then return '' end
		if not st.started then
			st.started = true
			st.id = d.id
			st.model = d.model
			return ev('message_start', { message = {
				id = st.id or 'msg_aigate', type = 'message', role = 'assistant',
				model = st.model, content = arr(),
				stop_reason = JSONNULL, stop_sequence = JSONNULL,
				usage = { input_tokens = 0, output_tokens = 0 } } })
		end
		if type(d.usage) == 'table' then
			st.usage_in = d.usage.prompt_tokens or st.usage_in
			st.usage_out = d.usage.completion_tokens or st.usage_out
		end
		local out = ''
		local ch = d.choices and d.choices[1]
		if type(ch) == 'table' then
			local dl = ch.delta or {}
			if nn(dl.content) and dl.content ~= '' then
				if not st.text_open then
					if st.open_block then
						out = out .. ev('content_block_stop', { index = st.open_block })
						st.open_block = nil
					end
					st.block_seq = st.block_seq + 1
					st.text_idx = st.block_seq
					st.text_open = true
					st.open_block = st.text_idx
					out = out .. ev('content_block_start', { index = st.text_idx,
						content_block = { type = 'text', text = '' } })
				end
				out = out .. ev('content_block_delta', { index = st.text_idx,
					delta = { type = 'text_delta', text = dl.content } })
			end
			if nn(dl.tool_calls) then
				for _, tc in ipairs(dl.tool_calls) do
					local j = tc.index or 0
					if not st.tool_idx[j] then
						if st.open_block then
							out = out .. ev('content_block_stop', { index = st.open_block })
							st.open_block = nil
						end
						st.text_open = false
						st.block_seq = st.block_seq + 1
						st.tool_idx[j] = st.block_seq
						st.open_block = st.block_seq
						local f = tc['function'] or {}
						out = out .. ev('content_block_start', { index = st.block_seq,
							content_block = { type = 'tool_use', id = tc.id or ('toolu_' .. j),
								name = f.name or '', input = setmetatable({}, { __jsonobj = true }) } })
					end
					local f2 = tc['function'] or {}
					if nn(f2.arguments) and f2.arguments ~= '' then
						out = out .. ev('content_block_delta', { index = st.tool_idx[j],
							delta = { type = 'input_json_delta', partial_json = f2.arguments } })
					end
				end
			end
			if nn(ch.finish_reason) then st.finish = ch.finish_reason end
		end
		return out
	end
	return {
		line = function(l)
			if l:match('^data:') then
				st.buf[#st.buf + 1] = l:match('^data:%s?(.*)$') or ''
				return nil
			elseif l == '' then
				if #st.buf == 0 then return nil end
				local raw = table.concat(st.buf, '\n')
				st.buf = {}
				return dispatch(raw)
			end
			return nil
		end,
		finish = function()
			if st.done or not st.started then return nil end
			return dispatch('[DONE]')
		end,
	}
end

-- ================= auth =================
local function require_auth()
	local key = cfg.main.api_key
	if nn(key) and key ~= '' and auth ~= 'Bearer ' .. key then
		http_error(401, 'Unauthorized')
		return false
	end
	return true
end


-- ================= quota / oauth / logging =================
local QUOTA_DIR = '/tmp/aigate-quota'
local OAUTH_DIR = '/tmp/aigate-oauth'
local LOG_FILE = '/root/.aigate/requests.log'

local function today()
	return os.date('%Y-%m-%d')
end

local function quota_read(acct_name)
	local f = io.open(QUOTA_DIR .. '/' .. acct_name .. '_' .. today(), 'r')
	if not f then return 0 end
	local v = tonumber(f:read('*a')) or 0
	f:close()
	return v
end

local function quota_add(acct_name, n)
	os.execute('mkdir -p ' .. sq(QUOTA_DIR) .. ' 2>/dev/null')
	local cur = quota_read(acct_name) + n
	local f = io.open(QUOTA_DIR .. '/' .. acct_name .. '_' .. today(), 'w')
	if f then f:write(tostring(cur)); f:close() end
end

local function log_request(entry)
	os.execute('mkdir -p ' .. sq(LOG_FILE:match('^(.*)/') or '/root/.aigate') .. ' 2>/dev/null')
	local f = io.open(LOG_FILE, 'a')
	if f then
		entry.time = os.date('%Y-%m-%dT%H:%M:%S')
		f:write(json.encode(entry) .. '\n')
		f:close()
	end
end

local function http_post_json(url, body, extra_headers)
	local bodyf = os.tmpname()
	local bf = io.open(bodyf, 'w')
	if bf then bf:write(body); bf:close() end
	local hdrs = {}
	if extra_headers then
		for _, h in ipairs(extra_headers) do hdrs[#hdrs+1] = '-H ' .. sq(h) end
	end
	local cmd = table.concat({
		'curl -sS --connect-timeout 10 --max-time 30', '-D -',
		table.concat(hdrs, ' '),
		'-H ' .. sq('content-type: application/json'),
		'--data-binary @' .. sq(bodyf), sq(url), '2>/dev/null',
	}, ' ')
	local ph = io.popen(cmd, 'r')
	local out = {}
	if ph then
		for line in ph:lines() do out[#out+1] = line:gsub('\r$', '') end
		ph:close()
	end
	os.remove(bodyf)
	return table.concat(out, '\n')
end

-- OAuth: resolve a usable access_token, refreshing if needed.
-- ac.oauth = {token_url, client_id, refresh_token, scope?}
local function oauth_token(ac)
	-- UCI fields are flat: oauth_token_url / oauth_client_id / oauth_refresh_token
	local token_url, refresh_token, client_id =
		ac.oauth_token_url, ac.oauth_refresh_token, ac.oauth_client_id
	if not token_url or token_url == '' or not refresh_token or refresh_token == '' then
		return nil
	end
	ac.oauth = { token_url = token_url, refresh_token = refresh_token,
		client_id = client_id }
	local cache = OAUTH_DIR .. '/' .. ac._name .. '.json'
	local now = os.time()
	local cf = io.open(cache, 'r')
	if cf then
		local ok, cached = pcall(json.decode, cf:read('*a') or '')
		cf:close()
		if ok and type(cached) == 'table' and cached.access_token
			and (cached.expires_at or 0) > now + 30 then
			return cached.access_token
		end
	end
	local req = json.encode({
		grant_type = 'refresh_token',
		refresh_token = ac.oauth.refresh_token,
		client_id = ac.oauth.client_id,
	})
	local resp = http_post_json(ac.oauth.token_url, req, nil)
	local body = resp:match('\n\n(.*)$') or resp
	local ok, tok = pcall(json.decode, body)
	if ok and type(tok) == 'table' and tok.access_token then
		os.execute('mkdir -p ' .. sq(OAUTH_DIR) .. ' 2>/dev/null')
		local f = io.open(cache, 'w')
		if f then
			f:write(json.encode({
				access_token = tok.access_token,
				expires_at = now + (tonumber(tok.expires_in) or 3600),
			}))
			f:close()
		end
		return tok.access_token
	end
	return nil
end

-- resolve effective auth header for an account (oauth > api_key)
local function ac_auth_header(ac, dialect)
	local tok = oauth_token(ac)
	if tok then
		if dialect == 'anthropic' then
			return 'Authorization: Bearer ' .. tok
		end
		return 'Authorization: Bearer ' .. tok
	end
	if dialect == 'anthropic' then
		return 'x-api-key: ' .. (ac.api_key or '')
	end
	return 'Authorization: Bearer ' .. (ac.api_key or '')
end

local function account_skipped(ac)
	-- daily token limit
	local lim = tonumber(ac.daily_limit)
	if lim and lim > 0 and quota_read(ac._name) >= lim then
		return 'quota_exceeded'
	end
	return nil
end

-- ================= provider chain =================
local function chain(client_dialect)
	local clen = tonumber(os.getenv('CONTENT_LENGTH') or '0') or 0
	local body = (clen > 0 and io.read(clen)) or ''
	local okb, b = pcall(json.decode, body)
	if not okb or type(b) ~= 'table' then
		http_error(400, 'invalid JSON body')
		return false
	end
	local orig_model = b.model
	local cands = {}
	local combo = cfg.combos[tostring(orig_model or '')]
	if combo and combo.chain and combo.chain ~= '' then
		-- combo = ordered model chain (9router-style): try each model's
		-- accounts in turn, translating per provider as needed.
		for step in combo.chain:gmatch('[^,]+') do
			step = step:match('^%s*(.-)%s*$')
			if step ~= '' then
				local saved = b.model
				b.model = step
				for _, c in ipairs(pick_accounts(step)) do cands[#cands + 1] = c end
				b.model = saved
			end
		end
	else
		cands = pick_accounts(orig_model)
	end
	if #cands == 0 then
		http_error(404, 'no account serves model: ' .. tostring(orig_model))
		return false
	end
	local last = 'no provider'

	local t_start = os.time()
	for _, cand in ipairs(cands) do
		local pr, ac = cand.pr, cand.ac
		do
			local skipped = account_skipped(ac)
			if skipped then
				last = pr._name .. '/' .. ac._name .. ' -> ' .. skipped
			else
			b.model = nn(ac.model) and ac.model or orig_model

			local up = pr.type
			local suffix = (up == 'anthropic') and '/messages' or '/chat/completions'
			local send = body
			local skip = false

			if up ~= client_dialect then
				local okt, nb = pcall(up == 'openai' and a2o_req or o2a_req, b, ac)
				if okt and type(nb) == 'table' then
					send = json.encode(nb)
				else
					last = pr._name .. '/' .. ac._name .. ' -> request translate failed'
					skip = true
				end
			elseif nn(ac.model) then
				send = json.encode(b)
			end

			if not skip then
				local bodyf = os.tmpname()
				local bf = io.open(bodyf, 'w')
				if bf then bf:write(send); bf:close() end

				local base = pr.base_url:gsub('/+$', '')
				local hdrs = {}
				hdrs[#hdrs + 1] = '-H ' .. sq(ac_auth_header(ac, up))
				if up == 'anthropic' then
					hdrs[#hdrs + 1] = '-H ' .. sq('anthropic-version: 2023-06-01')
					if ac.cache == '1' then
						hdrs[#hdrs + 1] = '-H ' .. sq('anthropic-beta: prompt-caching-2024-07-31')
					end
				end
				-- extra provider headers (UCI option headers: 'A: 1|B: 2')
				if nn(pr.headers) then
					for h in pr.headers:gmatch('[^|]+') do
						h = h:match('^%s*(.-)%s*$')
						if h:find(':', 1, true) then
							hdrs[#hdrs + 1] = '-H ' .. sq(h)
						end
					end
				end

				local cmd = table.concat({
					'curl -sS -N --connect-timeout 15 --max-time 3600',
					'-D -',
					table.concat(hdrs, ' '),
					'-H ' .. sq('content-type: application/json'),
					'--data-binary @' .. sq(bodyf),
					sq(base .. suffix),
					'2>/dev/null',
				}, ' ')

				local ph = io.popen(cmd, 'r')
				local status, ctype, eof = nil, nil, false
				if ph then
					repeat
						status, ctype = nil, nil
						while true do
							local l = ph:read('*l')
							if not l then eof = true; break end
							l = l:gsub('\r$', '')
							if l == '' then break end
							local stcode = l:match('^HTTP/[%d%.]+ (%d+)')
							if stcode then status = tonumber(stcode) end
							local ct = l:match('^[Cc]ontent%-[Tt]ype:%s*(.+)$')
							if ct then ctype = ct:match('^%s*(.-)%s*$') end
						end
					until eof or status ~= 100
				end

				if ph and not eof and status and status >= 200 and status < 300 then
					local stream_wanted = (b.stream == true)
					local translated = (up ~= client_dialect)
					local tag = pr._name .. '/' .. ac._name

					-- helper: was this payload actually usable? (9router: HTTP200 with
					-- zero usable content must fall through to the next account)
					local function usable_json(resp)
						if type(resp) ~= 'table' then return false end
						if resp.error then return false end
						local ch = resp.choices and resp.choices[1]
						if ch then
							local m = ch.message
							if (nn(ch.text) and ch.text ~= '')
								or (m and ((nn(m.content) and m.content ~= '')
									or nn(m.tool_calls))) then
								return true
							end
							if nn(ch.finish_reason) or nn(ch.delta) then return true end
						end
						if resp.content and #resp.content > 0 then return true end
						if resp.type == 'message' or resp.object == 'chat.completion'
							or resp.object == 'chat.completion.chunk' then
							return true
						end
						return false
					end

					local function done_ok()
						-- accounting + audit log (best-effort)
						local usage = nil
						if type(_G.__last_usage) == 'table' then usage = _G.__last_usage end
						if usage then
							local toks = (tonumber(usage.prompt_tokens)
								or tonumber(usage.input_tokens) or 0)
								+ (tonumber(usage.completion_tokens)
								or tonumber(usage.output_tokens) or 0)
							if toks > 0 then quota_add(ac._name, toks) end
						end
						log_request({
							model = tostring(orig_model),
							provider = pr._name, account = ac._name,
							dialect = up, client = client_dialect,
							translated = translated, stream = stream_wanted,
							status = 200, usage = usage,
							elapsed = os.time() - t_start,
						})
					end

					if not translated and not stream_wanted then
						-- buffer non-stream passthrough: verify content + capture usage
						local all = ph:read('*a') or ''
						ph:close()
						local okr, resp = pcall(json.decode, all)
						if not okr or not usable_json(resp) then
							last = tag .. (okr and ' -> empty 200 body' or ' -> bad JSON')
							os.remove(bodyf)
							goto continue
						end
						_G.__last_usage = (type(resp) == 'table') and resp.usage or nil
						emit('Status: 200 OK\r\nContent-Type: '
							.. (ctype or 'application/json') .. '\r\n')
						emit('Cache-Control: no-cache\r\n\r\n')
						emit(all:gsub('\r$', '') .. '\n')
						done_ok()
						os.remove(bodyf)
						return true
					end

					if stream_wanted then
						-- peek the FIRST line before committing headers, so an empty
						-- 200 can still fall through to the next account
						local xf = translated and ((up == 'anthropic')
							and a2o_stream() or o2a_stream()) or nil
						local first, pre = nil, nil
						while true do
							first = ph:read('*l')
							if not first then break end
							first = first:gsub('\r$', '')
							if first ~= '' then
								if xf then pre = xf.line(first) else pre = first end
								break
							end
							if xf then local o = xf.line(''); if nn(o) and o ~= '' then pre = o break end end
						end
						if not first and not pre then
							last = tag .. ' -> empty 200 stream'
							ph:read('*a'); ph:close()
							os.remove(bodyf)
							goto continue
						end
						emit('Status: 200 OK\r\nContent-Type: '
							.. (translated and 'text/event-stream' or (ctype or 'text/event-stream'))
							.. '\r\n')
						emit('Cache-Control: no-cache\r\n\r\n')
						if nn(pre) and pre ~= '' then emit(pre) end
						while true do
							local l = ph:read('*l')
							if not l then break end
							local o = xf and xf.line(l:gsub('\r$', '')) or (l:gsub('\r$', '') .. '\n')
							if nn(o) and o ~= '' then emit(o) end
						end
						if xf then
							local tail = xf.finish()
							if nn(tail) and tail ~= '' then emit(tail) end
						end
						done_ok()
						ph:close(); os.remove(bodyf)
						return true
					end

					-- non-stream translated: buffer, transform, emit once
					local all = ph:read('*a') or ''
					ph:close()
					local okr, resp = pcall(json.decode, all)
					if okr and type(resp) == 'table' then
						local okx, out = pcall(up == 'anthropic' and a2o_resp or o2a_resp, resp)
						if okx and type(out) == 'table' and usable_json(resp) then
							_G.__last_usage = out.usage or nil
							emit('Status: 200 OK\r\nContent-Type: application/json\r\n\r\n')
							emit(json.encode(out) .. '\n')
							done_ok()
							os.remove(bodyf)
							return true
						end
						last = tag .. ' -> empty/unusable translated response'
					else
						last = tag .. ' -> bad upstream JSON'
					end
					os.remove(bodyf)
					goto continue
				else
					last = pr._name .. '/' .. ac._name .. ' -> HTTP '
						.. (status and tostring(status) or 'curl-fail')
					if ph then
						ph:read('*a')
						ph:close()
					end
					os.remove(bodyf)
				end
			end -- if not skip
			end -- if not account_skipped
			::continue::
		end
	end

	http_error(502, 'Bad Gateway: ' .. last)
	return false
end

-- ================= side endpoints (embeddings / images) =================
local function chain_side(suffix, capflag)
	local clen = tonumber(os.getenv('CONTENT_LENGTH') or '0') or 0
	local body = (clen > 0 and io.read(clen)) or ''
	local last = 'no provider'
	for _, pr in ipairs(cfg.providers) do
		if pr.enabled ~= '0' and pr.type == 'openai' and pr.base_url
			and pr[capflag] == '1' then
			for _, ac in ipairs(cfg.accounts) do
				if ac.enabled ~= '0' and ac.provider == pr._name
					and nn(ac.api_key) and ac.api_key ~= '' then
					local bodyf = os.tmpname()
					local bf = io.open(bodyf, 'w')
					if bf then bf:write(body); bf:close() end
					local hdrs = { '-H ' .. sq('Authorization: Bearer ' .. ac.api_key) }
					if nn(pr.headers) then
						for h in pr.headers:gmatch('[^|]+') do
							h = h:match('^%s*(.-)%s*$')
							if h:find(':', 1, true) then hdrs[#hdrs + 1] = '-H ' .. sq(h) end
						end
					end
					local base = pr.base_url:gsub('/+$', '')
					local cmd = table.concat({
						'curl -sS -N --connect-timeout 15 --max-time 600',
						'-D -', table.concat(hdrs, ' '),
						'-H ' .. sq('content-type: application/json'),
						'--data-binary @' .. sq(bodyf),
						sq(base .. suffix), '2>/dev/null',
					}, ' ')
					local ph = io.popen(cmd, 'r')
					local status, eof = nil, false
					if ph then
						repeat
							status = nil
							while true do
								local l = ph:read('*l')
								if not l then eof = true; break end
								l = l:gsub('\r$', '')
								if l == '' then break end
								local c = l:match('^HTTP/[%d%.]+ (%d+)')
								if c then status = tonumber(c) end
							end
						until eof or status ~= 100
					end
					if ph and not eof and status and status >= 200 and status < 300 then
						emit('Status: 200 OK\r\nContent-Type: application/json\r\n\r\n')
						while true do
							local l = ph:read('*l')
							if not l then break end
							emit(l:gsub('\r$', '') .. '\n')
						end
						ph:close(); os.remove(bodyf)
						return true
					end
					last = pr._name .. '/' .. ac._name .. ' -> HTTP '
						.. (status and tostring(status) or 'curl-fail')
					if ph then ph:read('*a'); ph:close() end
					os.remove(bodyf)
				end
			end
		end
	end
	http_error(502, 'Bad Gateway: ' .. last)
	return false
end

-- ================= route =================
if path == '/' and method == 'GET' then
	page_health()
elseif path == '/v1/models' and method == 'GET' then
	if require_auth() then page_models() end
elseif path == '/v1/providers' and method == 'GET' then
	if require_auth() then page_providers() end
elseif path == '/v1/messages' and method == 'POST' then
	if require_auth() then chain('anthropic') end
elseif path == '/v1/chat/completions' and method == 'POST' then
	if require_auth() then chain('openai') end
elseif path == '/v1/embeddings' and method == 'POST' then
	if require_auth() then chain_side('/embeddings', 'embeddings') end
elseif path == '/v1/images/generations' and method == 'POST' then
	if require_auth() then chain_side('/images/generations', 'images') end
elseif path == '/v1/audio/speech' and method == 'POST' then
	if require_auth() then chain_side('/audio/speech', 'tts') end
elseif path == '/v1/audio/transcriptions' and method == 'POST' then
	if require_auth() then chain_side('/audio/transcriptions', 'stt') end
elseif path == '/v1/search' and method == 'POST' then
	if require_auth() then chain_side('/search', 'search') end
elseif path == '/v1/web/fetch' and method == 'POST' then
	if require_auth() then chain_side('/web/fetch', 'fetch') end
elseif path == '/v1/videos/generations' and method == 'POST' then
	if require_auth() then chain_side('/videos/generations', 'video') end
elseif path == '/v1/audio/music' and method == 'POST' then
	if require_auth() then chain_side('/audio/music', 'music') end
elseif path == '/v1/images/understanding' and method == 'POST' then
	if require_auth() then chain_side('/images/understanding', 'imageToText') end
else
	http_error(404, 'Not Found')
end
