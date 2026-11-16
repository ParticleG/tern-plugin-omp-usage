--!strict
-- Executed by a temporary Tern plugin, with the real cache module and JSON decoder.
local cache = require("./cache")
local cases = require("./cache-reader-cases")
local BASE = 2000000000

local result = tern.getenv("CACHE_READER_TEST_RESULT") :: string
local ok, checked = pcall(cases, cache, tern.json)
if not ok then
	tern.fs.write(result, tern.json.encode({ ok = false, error = tostring(checked) }))
	return
end
-- Also prove production discovery and cx.docs:read against a real, isolated on-disk snapshot.
local directory = tern.getenv("CACHE_READER_TEST_FIXTURES") :: string
local disk = cache.new({ directory = directory, list = tern.fs.list, decode = tern.json.decode, now = function() return BASE end })
tern.timer(0, function(cx: WindowCx?)
	if cx == nil then
		tern.fs.write(result, tern.json.encode({ ok = false, error = "Tern timer supplied no WindowCx" }))
		return
	end
	disk.poll(cx)
	local attempts = 0
	local function finish(_cx: WindowCx?)
		attempts += 1
		local merged = disk.read(BASE)
		if merged == nil and attempts < 100 then
			tern.timer(20, finish)
			return
		end
		local passed, failure = pcall(function()
			assert(merged ~= nil and merged.providers.synthetic.line == "Disk 5h 42%", "real async docs read loads the synthetic disk snapshot")
		end)
		tern.fs.write(result, tern.json.encode({ ok = passed, error = if passed then nil else tostring(failure), checked = checked + 1 }))
	end
	tern.timer(20, finish)
end)
