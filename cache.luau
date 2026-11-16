--!strict
-- Each extension instance owns one snapshot. Bodies are read off the window thread; discovery only lists names.
local MAX_AGE_MS = 600000
local MAX_BYTES = 1048576
local POLL_MS = 3000

type File = { raw: string?, doc: any }
type Candidate = { item: any, at: number, generated: number, name: string }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function timestamp(value: any, now: number): boolean
	return finite(value) and value > 0 and value <= now
end

local function filename(name: any): boolean
	if type(name) ~= "string" then
		return false
	end
	local pid, uuid = string.match(name, "^([1-9]%d*)%-([%x%-]+)%.json$")
	if pid == nil or uuid == nil then
		return false
	end
	return string.match(uuid, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function expires(item: any, generated: number, now: number): number?
	if type(item) ~= "table" or not timestamp(item.fetchedAt, now) or not finite(item.maxAgeMs) or item.maxAgeMs <= 0 then
		return nil
	end
	local until_ms = math.min(generated + MAX_AGE_MS, item.fetchedAt + math.min(item.maxAgeMs, MAX_AGE_MS))
	return if now < until_ms then until_ms else nil
end

local function newer(a: Candidate, b: Candidate?): boolean
	return b == nil or a.at > b.at or (a.at == b.at and (a.generated > b.generated or (a.generated == b.generated and a.name > b.name)))
end

local cache = {}

-- A separate instance also makes executable tests independent of the user's HOME, filesystem and timers.
-- env: directory, list(path), decode(text), now(), and timer(ms, callback); bodies always use cx.docs:read.
function cache.new(env: any): any
	local files: { [string]: File } = {}
	local pending: { [string]: File } = {}
	local dirty = true
	local deadline = math.huge
	local merged: any = nil
	local last_now = 0
	local started = false
	local reader = {}

	function reader.poll(cx: any)
		if cx == nil or env.directory == nil then
			return
		end
		local listed, names = pcall(env.list, env.directory)
		if not listed or type(names) ~= "table" then
			return -- A transient discovery failure must not discard good, independently expiring observations.
		end
		local present: { [string]: boolean } = {}
		for _, name in names do
			if filename(name) then
				present[name] = true
			end
		end
		for name in files do
			if not present[name] then
				files[name] = nil
				dirty = true
			end
		end
		for name in present do
			local file = files[name]
			if file == nil then
				file = { raw = nil, doc = nil }
				files[name] = file
			end
			if pending[name] ~= nil then
				continue
			end
			local current = file :: File
			pending[name] = current
			local ok = pcall(function()
				cx.docs:read(env.directory .. "/" .. name):next(function(text: string?, err: string?, _later: any)
					if pending[name] ~= current then
						return
					end
					pending[name] = nil
					-- Removal/reappearance invalidates the old request, even if it completes after the new discovery.
					if files[name] ~= current or err ~= nil or type(text) ~= "string" or #text > MAX_BYTES or text == current.raw then
						return
					end
					local decoded, doc = pcall(env.decode, text)
					local now = env.now()
					if not decoded or type(doc) ~= "table" or type(doc.models) ~= "table" or type(doc.providers) ~= "table" or not timestamp(doc.generatedAt, now) or now >= doc.generatedAt + MAX_AGE_MS then
						return
					end
					if current.doc ~= nil and doc.generatedAt < current.doc.generatedAt then
						return
					end
					current.raw = text
					current.doc = doc
					dirty = true
				end)
			end)
			if not ok and pending[name] == current then
				pending[name] = nil
			end
		end
	end

	function reader.read(now: number): any
		if not dirty and now < deadline and now >= last_now then
			return merged
		end
		last_now = now
		dirty = false
		deadline = math.huge
		local providers: { [string]: Candidate } = {}
		local models: { [string]: Candidate } = {}
		local generated = 0
		for name, file in files do
			local doc = file.doc
			if doc == nil or not timestamp(doc.generatedAt, now) or now >= doc.generatedAt + MAX_AGE_MS then
				continue
			end
			deadline = math.min(deadline, doc.generatedAt + MAX_AGE_MS)
			local function consider(target: { [string]: Candidate }, key: any, item: any)
				if type(key) ~= "string" or key == "" or type(item) ~= "table" or type(item.line) ~= "string" then
					return
				end
				local until_ms = expires(item, doc.generatedAt, now)
				if until_ms == nil then
					return
				end
				deadline = math.min(deadline, until_ms)
				local candidate: Candidate = { item = item, at = item.fetchedAt, generated = doc.generatedAt, name = name }
				if newer(candidate, target[key]) then
					target[key] = candidate
				end
			end
			if type(doc.providers) == "table" then
				for id, item in doc.providers do
					if type(item) == "table" and item.line ~= "" then
						consider(providers, id, item)
					end
				end
			end
			if type(doc.models) == "table" then
				for model, item in doc.models do
					-- A native-only session can know the chip but have no report for its external pool.
					local report = if type(item) == "table" and type(item.provider) == "string" then doc.providers[item.provider] else nil
					if type(item) == "table" and (item.line ~= "" or (type(report) == "table" and type(report.line) == "string" and report.line ~= "" and expires(report, doc.generatedAt, now) ~= nil)) then
						consider(models, model, item)
					end
				end
			end
			if type(doc.ambiguousModels) == "table" then
				-- A chip-name ambiguity is a mapping observation, not a quota fetch.
				for _, model in doc.ambiguousModels do
					if type(model) == "string" and model ~= "" then
						local candidate: Candidate = { item = nil, at = doc.generatedAt, generated = doc.generatedAt, name = name }
						if newer(candidate, models[model]) then
							models[model] = candidate
						end
					end
				end
			end
		end
		local result: any = { generatedAt = 0, models = {}, providers = {} }
		local any_entry = false
		for id, candidate in providers do
			result.providers[id] = candidate.item
			generated = math.max(generated, candidate.generated)
			any_entry = true
		end
		for model, candidate in models do
			result.models[model] = candidate.item
			generated = math.max(generated, candidate.generated)
			any_entry = true -- An ambiguity-only snapshot deliberately leaves the model unmapped.
		end
		result.generatedAt = generated
		merged = if any_entry then result else nil
		return merged
	end

	function reader.start()
		if started then
			return
		end
		started = true
		local function tick(cx: any)
			env.timer(POLL_MS, tick)
			reader.poll(cx)
		end
		env.timer(0, tick)
	end

	return reader
end

local default: any = nil
function cache.start()
	if default == nil then
		local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
		default = cache.new({
			directory = if home and home ~= "" then home .. "/.omp/cache/usage-remaining" else nil,
			list = tern.fs.list,
			decode = tern.json.decode,
			now = function(): number return os.time() * 1000 end,
			timer = tern.timer,
		})
	end
	default.start()
end

function cache.read(now: number): any
	return if default ~= nil then default.read(now) else nil
end

return cache
