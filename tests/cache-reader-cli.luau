--!strict
-- Run: luau tests/cache-reader-cli.luau
-- Exercises the actual production module with a deterministic in-memory codec and asynchronous callbacks.
-- The Tern runner executes the same cases with the real JSON decoder, plus a real asynchronous disk read.
local cache = require("../cache")
local cases = require("./cache-reader-cases")
local values: { [string]: any } = {}
local sequence = 0
local codec = {
	encode = function(value: any): string
		sequence += 1
		local key = "fixture:" .. tostring(sequence)
		values[key] = value
		return key
	end,
	decode = function(text: string): any
		local value = values[text]
		assert(value ~= nil, "malformed synthetic document")
		return value
	end,
}
local checked = cases(cache, codec)
print("cache reader: " .. tostring(checked) .. " assertions passed")
