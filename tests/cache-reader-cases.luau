--!strict
-- The same executable cases run with Tern JSON and with an isolated in-memory codec on the Luau CLI.
return function(cache: any, json: any): number
local checked = 0
local function check(value: any, message: string)
	checked += 1
	assert(value, message)
end
local A = "111-00000000-0000-4000-8000-000000000001.json"
local B = "222-00000000-0000-4000-8000-000000000002.json"
local C = "111-00000000-0000-4000-8000-000000000003.json"
local BASE = 2000000000
local function entry(line: string, at: number, age: number?, provider: string?): any
	return { line = line, fetchedAt = at, maxAgeMs = age or 600000, provider = provider }
end
local function doc(at: number, providers: any?, models: any?): any
	return { generatedAt = at, fetchedAt = at, models = models or {}, providers = providers or {} }
end
local function fixture(): any
	local f: any = { time = BASE, names = {}, requests = {}, fail_list = false, fail_read = false }
	f.reader = cache.new({
		directory = "/synthetic-only",
		now = function() return f.time end,
		decode = json.decode,
		list = function(path: string)
			check(path == "/synthetic-only", "discovery uses only the isolated directory")
			assert(not f.fail_list, "synthetic list failure")
			return f.names
		end,
		timer = function() error("fixture must not schedule real timers") end,
	})
	f.cx = { docs = { read = function(_self: any, path: string)
		assert(not f.fail_read, "synthetic synchronous read failure")
		return { next = function(_request: any, callback: any)
			table.insert(f.requests, { path = path, callback = callback })
		end }
	end } }
	function f.poll()
		f.reader.poll(f.cx)
	end
	function f.reply(name: string, value: any, err: string?)
		for i, request in f.requests do
			if request.path == "/synthetic-only/" .. name then
				table.remove(f.requests, i)
				request.callback(if type(value) == "table" then json.encode(value) else value, err, nil)
				return request.callback
			end
		end
		error("no pending request for " .. name)
	end
	return f
end

local function run()
	local f = fixture()
	f.names = { A, B, C, "usage-remaining.json", "../" .. A, A .. ".tmp", "1-not-a-uuid.json", "0-00000000-0000-4000-8000-000000000001.json" }
	f.poll()
	check(#f.requests == 3, "only PID-UUID.json files are read, including same-PID instances")
	f.poll()
	check(#f.requests == 3, "pending body reads never overlap")
	local cpa = entry("CPA 5h 70%", BASE - 100, 10000, "cpa:pool:openai")
	cpa.details = { { text = "original account details" } }
	cpa.accounts = { "one", "two" }
	f.reply(A, doc(BASE - 10, { ["cpa:pool:openai"] = cpa }, { GPT = cpa }))
	f.reply(B, doc(BASE, { anthropic = entry("Claude 5h 50%", BASE) }, { GPT = entry("", BASE, nil, "cpa:pool:openai") }))
	f.reply(C, doc(BASE, { ["keeper:pool:anthropic"] = entry("Keeper 7d 90%", BASE) }))
	local merged = f.reader.read(f.time)
	check(merged.providers["cpa:pool:openai"].line == "CPA 5h 70%", "native-only snapshots preserve fresh CPA pools")
	check(merged.providers["keeper:pool:anthropic"] ~= nil and merged.providers.anthropic ~= nil, "all/selected providers retain disjoint pools")
	check(merged.models.GPT.line == cpa.line, "empty model without provider report cannot erase a mapped model")
	check(merged.providers["cpa:pool:openai"].details[1].text == "original account details" and #merged.providers["cpa:pool:openai"].accounts == 2, "provider pools remain atomic")
	check(f.reader.read(BASE + 1) == merged, "unchanged fresh reads reuse the merged identity")
	f.time += 100
	f.poll()
	f.reply(A, doc(BASE, { ["cpa:pool:openai"] = entry("fresh observation", BASE - 1) }))
	f.reply(B, doc(f.time, { ["cpa:pool:openai"] = entry("new document, old observation", BASE - 500) }))
	f.reply(C, doc(BASE, { ["keeper:pool:anthropic"] = entry("Keeper 7d 90%", BASE) }))
	check(f.reader.read(f.time).providers["cpa:pool:openai"].line == "fresh observation", "observations win independently of snapshot generation time")
	f.time += 100
	f.poll()
	f.reply(B, doc(f.time, { ["cpa:pool:openai"] = entry("error diagnostic transition", BASE - 1) }))
	check(f.reader.read(f.time).providers["cpa:pool:openai"].line == "error diagnostic transition", "equal observation freshness uses generatedAt for stale/error transitions")
	f.reply(A, "not JSON")
	f.reply(C, nil, "read failed")
	check(f.reader.read(f.time).providers["keeper:pool:anthropic"] ~= nil, "failed reads retain recent good snapshots")
	f.fail_list = true
	f.poll()
	check(f.reader.read(f.time).providers["cpa:pool:openai"] ~= nil, "failed discovery retains recent good snapshots")
	f.fail_list = false
	for _, bad in { string.rep("x", 1048577), json.encode(doc(f.time + 1)), json.encode(doc(f.time - 600000)), json.encode({ generatedAt = f.time }), "null" } do
		f.poll()
		f.reply(B, bad)
		check(f.reader.read(f.time).providers["cpa:pool:openai"].line == "error diagnostic transition", "oversize/future/malformed snapshots cannot replace good observations")
	end
	-- Complete other pending requests before exercising another round.
	f.reply(A, nil, "read failed")
	f.reply(C, nil, "read failed")
	f.poll()
	f.reply(B, doc(BASE - 1, { ["cpa:pool:openai"] = entry("rollback", BASE) }))
	check(f.reader.read(f.time).providers["cpa:pool:openai"].line == "error diagnostic transition", "an older generated snapshot cannot roll back an accepted file")
	local old = f.reply(A, nil, "read failed")
	f.names = { C }
	f.poll()
	check(f.reader.read(f.time).providers["cpa:pool:openai"] == nil, "successful removal immediately drops that session")
	f.names = { A, C }
	f.poll()
	old(json.encode(doc(f.time, { resurrected = entry("late", f.time) })), nil, nil)
	check(f.reader.read(f.time).providers.resurrected == nil, "duplicate/out-of-order callbacks cannot resurrect removed sessions")
	f.reply(A, doc(f.time, { returned = entry("new incarnation", f.time) }))
	check(f.reader.read(f.time).providers.returned ~= nil, "a new discovery can read a reappearing session")

	local expiry = fixture()
	expiry.names = { A, B }
	expiry.poll()
	expiry.reply(A, doc(BASE - 599900, { session = entry("fresh entry in expiring session", BASE) }))
	expiry.reply(B, doc(BASE, { short = entry("short", BASE - 10, 20), long = entry("long", BASE, 999999999), future = entry("future", BASE + 1), invalid = entry("invalid", BASE, -1) }))
	check(expiry.reader.read(BASE).providers.future == nil and expiry.reader.read(BASE).providers.invalid == nil, "future and invalid entry timestamps/lifetimes are ignored")
	check(expiry.reader.read(BASE + 10).providers.short == nil, "entries expire at their own deadline without file changes")
	check(expiry.reader.read(BASE + 100).providers.session == nil, "session expiry bounds even fresher contained observations")
	check(expiry.reader.read(BASE + 600000) == nil, "maximum lifetime is bounded and unchanged snapshots expire completely")

	local unrelated = fixture()
	unrelated.names = { A, B }
	unrelated.poll()
	unrelated.reply(A, doc(BASE, { cpa = entry("CPA", BASE, 10) }, { Chip = entry("CPA model", BASE, 10) }))
	unrelated.reply(B, doc(BASE, { native = entry("native", BASE) }))
	check(unrelated.reader.read(BASE).models.Chip ~= nil, "short-lived model observation initially exists")
	unrelated.time += 9
	unrelated.poll()
	unrelated.reply(A, doc(unrelated.time, { cpa = entry("CPA", BASE, 10) }, { Chip = entry("CPA model", BASE, 10) }))
	unrelated.reply(B, doc(unrelated.time, { native = entry("native refreshed", unrelated.time) }))
	check(unrelated.reader.read(BASE + 10).providers.cpa == nil and unrelated.reader.read(BASE + 10).models.Chip == nil, "neither a fresh document nor another writer renews old provider/model observations")
	check(unrelated.reader.read(BASE + 10).providers.native.line == "native refreshed", "expiring one source preserves unrelated fresh providers")

	local ambiguous = fixture()
	ambiguous.names = { A, B }
	ambiguous.poll()
	ambiguous.reply(A, doc(BASE - 100, {}, { Chip = entry("mapped", BASE - 100) }))
	local tombstone = doc(BASE)
	tombstone.fetchedAt = BASE - 100000 -- Mapping ambiguity is current even when quota observations are old.
	tombstone.ambiguousModels = { "Chip" }
	ambiguous.reply(B, tombstone)
	check(ambiguous.reader.read(BASE).models.Chip == nil, "a current same-chip ambiguity suppresses an older mapping")
	ambiguous.time += 1
	ambiguous.poll()
	ambiguous.reply(A, doc(ambiguous.time, {}, { Chip = entry("new mapping", ambiguous.time) }))
	check(ambiguous.reader.read(ambiguous.time).models.Chip.line == "new mapping", "a newer observation resolves old ambiguity")
	local invalid_tombstone = doc(ambiguous.time + 1)
	invalid_tombstone.ambiguousModels = { "Chip" }
	ambiguous.reply(B, invalid_tombstone)
	check(ambiguous.reader.read(ambiguous.time).models.Chip.line == "new mapping", "future ambiguity observations cannot hide valid mappings")

	local removed = fixture()
	removed.names = { A }
	removed.poll()
	local callback = removed.requests[1].callback
	removed.names = {}
	removed.poll()
	removed.names = { A }
	removed.poll()
	check(#removed.requests == 1, "removal/reappearance does not overlap the original in-flight read")
	removed.reply(A, doc(BASE, { old = entry("old request", BASE) }))
	check(removed.reader.read(BASE) == nil, "a request invalidated before completion cannot resurrect a removed snapshot")
	removed.poll()
	removed.reply(A, doc(BASE, { new = entry("new request", BASE) }))
	callback(json.encode(doc(BASE, { old = entry("late duplicate", BASE) })), nil, nil)
	check(removed.reader.read(BASE).providers.new ~= nil and removed.reader.read(BASE).providers.old == nil, "late callbacks cannot replace a reappeared session")
	removed.fail_read = true
	removed.poll()
	removed.fail_read = false
	removed.poll()
	check(#removed.requests == 1, "synchronous read failures release the in-flight guard for retry")

	local tie = fixture()
	tie.names = { B, A }
	tie.poll()
	tie.reply(B, doc(BASE, { pool = entry("B", BASE) }))
	tie.reply(A, doc(BASE, { pool = entry("A", BASE) }))
	check(tie.reader.read(BASE).providers.pool.line == "B", "equal timestamps have a deterministic filename tie-break independent of callback order")
end

	run()
	return checked
end
