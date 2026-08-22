--!nonstrict

local Memoizer = require("./Memoizer")

local passed = 0
local failed = 0
local total = 0
local MODEL_FUZZ_SEED = 5182026
local CONCURRENCY_FUZZ_SEED = 7319941
local MODEL_FUZZ_OPERATIONS = 400
local CONCURRENCY_FUZZ_ROUNDS = 30

local function waitFor(predicate, timeout)
	local elapsed = 0

	while elapsed < timeout do
		if predicate() then
			return true
		end

		elapsed += task.wait()
	end

	return predicate()
end

local function expectEqual(actual, expected, label)
	assert(
		actual == expected,
		string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual))
	)
end

local function expectSame(actual, expected, label)
	assert(actual == expected, label .. ": expected the exact same value")
end

local function expectValue(actual, expected, label)
	if type(expected) == "table" then
		expectSame(actual, expected, label)
	else
		expectEqual(actual, expected, label)
	end
end

local function expectPendingEmpty(cache, label)
	assert(next(cache._pending) == nil, label .. ": pending tree was not empty")
end

local function readCachePath(cache, keys)
	local current = cache._cache

	for index, key in ipairs(keys) do
		local value = current[key]

		if value == nil then
			return false, nil
		end

		if index == #keys then
			return true, value
		end

		if type(value) ~= "table" then
			return false, nil
		end

		current = value
	end

	return false, nil
end

local function expectCachePath(cache, keys, expectedPresent, label)
	local present, value = readCachePath(cache, keys)
	expectEqual(present, expectedPresent, label)
	return value
end

local function expectCeilingInvariants(cache, label)
	assert(cache._maxCacheRecords ~= nil, label .. ": cache ceiling was not enabled")
	assert(
		cache._cacheRecordsCount <= cache._maxCacheRecords,
		label .. ": record count exceeded ceiling"
	)

	local recordSlots = 0

	for _, record in pairs(cache._cacheRecords) do
		recordSlots += 1
		assert(record.layer[record.key] ~= nil, label .. ": FIFO record pointed to a missing leaf")
	end

	expectEqual(recordSlots, cache._cacheRecordsCount, label .. ": FIFO slot count")

	local reachableLayers = {}

	local function visitLayer(layer)
		local leafCount = 0
		local branchCount = 0

		for _, value in pairs(layer) do
			if type(value) == "table" and cache._parentByLayer[value] == layer then
				assert(not reachableLayers[value], label .. ": cache layer was reachable twice")
				reachableLayers[value] = true
				assert(next(value) ~= nil, label .. ": reachable cache layer was empty")

				local childLeaves, childBranches = visitLayer(value)
				leafCount += childLeaves
				branchCount += childBranches + 1
			else
				leafCount += 1
			end
		end

		return leafCount, branchCount
	end

	local leafCount, reachableLayerCount = visitLayer(cache._cache)
	expectEqual(leafCount, cache._cacheRecordsCount, label .. ": cached leaf count")

	local parentMetadataCount = 0

	for layer, parent in pairs(cache._parentByLayer) do
		parentMetadataCount += 1
		assert(reachableLayers[layer], label .. ": parent metadata retained a detached layer")

		local parentKey = cache._keyByLayer[layer]
		assert(parentKey ~= nil, label .. ": cache layer had no parent key")
		expectSame(parent[parentKey], layer, label .. ": parent metadata did not point back to layer")
	end

	local keyMetadataCount = 0

	for layer, _ in pairs(cache._keyByLayer) do
		keyMetadataCount += 1
		assert(cache._parentByLayer[layer] ~= nil, label .. ": parent-key metadata had no parent")
	end

	expectEqual(parentMetadataCount, reachableLayerCount, label .. ": reachable metadata count")
	expectEqual(keyMetadataCount, parentMetadataCount, label .. ": metadata table counts")
end

local function makeSchema(keys, tail)
	local schema = {}
	local current = schema

	for index = 1, #keys - 1 do
		local nextLayer = {}
		current[keys[index]] = nextLayer
		current = nextLayer
	end

	current[keys[#keys]] = tail
	return schema
end

local function recordValue(cache, keys, value)
	local tail = if type(value) == "table"
		then {
			value = value,
		}
		else value

	cache:Record(makeSchema(keys, tail))
end

local function randomValue(random, token)
	local kind = random:NextInteger(1, 5)

	if kind == 1 then
		return nil
	elseif kind == 2 then
		return false
	elseif kind == 3 then
		return token
	elseif kind == 4 then
		return "value_" .. token
	else
		return {
			token = token,
		}
	end
end

local function test(name, callback, timeout)
	total += 1

	local done = false
	local success = false
	local result

	local runner = task.spawn(function()
		success, result = xpcall(callback, debug.traceback)
		done = true
	end)

	if not waitFor(function()
		return done
	end, timeout or 4) then
		task.cancel(runner)
		failed += 1
		warn("[TIMEOUT] " .. name)
	elseif success then
		passed += 1
		print("[PASS] " .. name)
	else
		failed += 1
		warn("[FAIL] " .. name .. "\n" .. tostring(result))
	end
end

print("[RUN] Memoizer extended suite: 40 tests")

-- A primitive value is fetched once and then served from the cache.
test("number result caches once", function()
	local cache = Memoizer.new()
	local calls = 0

	local first = cache:Get({
		numberValue = function()
			calls += 1
			return 42
		end,
	})

	local second = cache:Get({
		numberValue = function()
			calls += 1
			error("number callback ran twice")
		end,
	})

	expectEqual(first, 42, "first number result")
	expectEqual(second, 42, "cached number result")
	expectEqual(calls, 1, "number callback count")
end)

-- nil must be distinguishable from a cache miss.
test("nil result caches once", function()
	local cache = Memoizer.new()
	local calls = 0

	local first = cache:Get({
		nilValue = function()
			calls += 1
			return nil
		end,
	})

	local second = cache:Get({
		nilValue = function()
			calls += 1
			error("nil callback ran twice")
		end,
	})

	expectEqual(first, nil, "first nil result")
	expectEqual(second, nil, "cached nil result")
	expectEqual(calls, 1, "nil callback count")
end)

-- false must be distinguishable from a cache miss.
test("false result caches once", function()
	local cache = Memoizer.new()
	local calls = 0

	local first = cache:Get({
		falseValue = function()
			calls += 1
			return false
		end,
	})

	local second = cache:Get({
		falseValue = function()
			calls += 1
			error("false callback ran twice")
		end,
	})

	expectEqual(first, false, "first false result")
	expectEqual(second, false, "cached false result")
	expectEqual(calls, 1, "false callback count")
end)

-- A table result remains the exact callback-owned table.
test("table result preserves identity and mutations", function()
	local cache = Memoizer.new()
	local expected = { count = 1 }
	local calls = 0

	local first = cache:Get({
		tableValue = function()
			calls += 1
			return expected
		end,
	})

	first.count = 2

	local second = cache:Get({
		tableValue = function()
			calls += 1
			error("table callback ran twice")
		end,
	})

	expectSame(first, expected, "first table result")
	expectSame(second, expected, "cached table result")
	expectEqual(second.count, 2, "table mutation")
	expectEqual(calls, 1, "table callback count")
end)

-- An empty table is a value, not another schema layer.
test("empty table result caches", function()
	local cache = Memoizer.new()
	local expected = {}
	local calls = 0

	local first = cache:Get({
		empty = function()
			calls += 1
			return expected
		end,
	})

	local second = cache:Get({
		empty = function()
			calls += 1
			error("empty table callback ran twice")
		end,
	})

	expectSame(first, expected, "first empty table")
	expectSame(second, expected, "cached empty table")
	expectEqual(calls, 1, "empty table callback count")
end)

-- A returned table may itself contain keys named value.
test("table result may contain value keys", function()
	local cache = Memoizer.new()
	local expected = {
		value = "payload",
		nested = {
			value = 99,
		},
	}

	local result = cache:Get({
		marked = function()
			return expected
		end,
	})

	expectSame(result, expected, "marked table result")
	expectEqual(result.value, "payload", "top-level value field")
	expectEqual(result.nested.value, 99, "nested value field")
end)

-- Storage must not clone or otherwise normalize unusual tables.
test("cyclic metatable and frozen table identity", function()
	local cache = Memoizer.new()
	local metatable = { marker = "memoizer-test" }
	local expected = setmetatable({}, metatable)
	expected.self = expected
	table.freeze(expected)

	local result = cache:Get({
		complex = function()
			return expected
		end,
	})

	expectSame(result, expected, "complex table result")
	expectSame(result.self, expected, "cyclic reference")
	expectSame(getmetatable(result), metatable, "metatable")
	assert(table.isfrozen(result), "frozen state was not preserved")
end)

-- Separate deep paths and sibling paths must not collide.
test("deep paths and siblings stay isolated", function()
	local cache = Memoizer.new()
	local user7 = { id = 7 }
	local user8 = { id = 8 }
	local calls7 = 0
	local calls8 = 0
	local settingsCalls = 0

	expectSame(cache:Get({
		users = {
			[7] = function()
				calls7 += 1
				return user7
			end,
		},
	}), user7, "user 7")

	expectSame(cache:Get({
		users = {
			[8] = function()
				calls8 += 1
				return user8
			end,
		},
	}), user8, "user 8")

	expectEqual(cache:Get({
		settings = function()
			settingsCalls += 1
			return "dark"
		end,
	}), "dark", "settings")

	expectSame(cache:Get({
		users = {
			[7] = function()
				error("user 7 callback ran twice")
			end,
		},
	}), user7, "cached user 7")

	expectEqual(calls7, 1, "user 7 callback count")
	expectEqual(calls8, 1, "user 8 callback count")
	expectEqual(settingsCalls, 1, "settings callback count")
end)

-- Record writes a direct table tail and a later Record overwrites it.
test("Record stores and overwrites direct table values", function()
	local cache = Memoizer.new()
	local first = { revision = 1 }
	local second = { revision = 2 }

	cache:Record({
		item = {
			value = first,
		},
	})

	expectSame(cache:Get({
		item = function()
			error("recorded item callback ran")
		end,
	}), first, "first recorded item")

	cache:Record({
		item = {
			value = second,
		},
	})

	expectSame(cache:Get({
		item = function()
			error("overwritten item callback ran")
		end,
	}), second, "overwritten recorded item")
end)

-- Record also supports an empty table at a deep, single schema path.
test("Record stores a deep empty table value", function()
	local cache = Memoizer.new()
	local expected = {}

	cache:Record({
		users = {
			[7] = {
				value = expected,
			},
		},
	})

	local result = cache:Get({
		users = {
			[7] = function()
				error("deep recorded callback ran")
			end,
		},
	})

	expectSame(result, expected, "deep recorded empty table")
end)

-- Many immediately completing workers must not lose their completion wake-up.
test("50 immediate table completions", function()
	local cache = Memoizer.new()
	local calls = {}
	local expected = {}

	for index = 1, 50 do
		calls[index] = 0
		expected[index] = { id = index }

		local first = cache:Get({
			values = {
				[index] = function()
					calls[index] += 1
					return expected[index]
				end,
			},
		})

		local second = cache:Get({
			values = {
				[index] = function()
					calls[index] += 1
					error("immediate callback ran twice")
				end,
			},
		})

		expectSame(first, expected[index], "first immediate result " .. index)
		expectSame(second, expected[index], "cached immediate result " .. index)
		expectEqual(calls[index], 1, "immediate callback count " .. index)
	end
end, 10)

-- Immediate failures clear pending state so the same path can retry.
test("20 immediate errors can retry", function()
	local cache = Memoizer.new()

	for index = 1, 20 do
		local success, message = pcall(function()
			cache:Get({
				errors = {
					[index] = function()
						error("expected_failure_" .. index)
					end,
				},
			})
		end)

		assert(not success, "error path " .. index .. " unexpectedly succeeded")
		assert(
			string.find(tostring(message), "expected_failure_" .. index, 1, true),
			"error path " .. index .. " lost its error message"
		)

		expectEqual(cache:Get({
			errors = {
				[index] = function()
					return index
				end,
			},
		}), index, "retry result " .. index)
	end
end, 10)

-- All concurrent callers for one path share one worker and one table.
test("20 concurrent callers share one result", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local expected = { shared = true }
	local calls = 0
	local started = false
	local completed = 0
	local results = {}

	local function fetch()
		calls += 1
		started = true
		gate.Event:Wait()
		return expected
	end

	for index = 1, 20 do
		task.spawn(function()
			results[index] = cache:Get({
				shared = fetch,
			})
			completed += 1
		end)
	end

	assert(waitFor(function()
		return started
	end, 1), "shared worker never started")

	task.wait()
	gate:Fire()

	assert(waitFor(function()
		return completed == 20
	end, 3), "not all shared callers completed")

	gate:Destroy()

	expectEqual(calls, 1, "shared worker call count")

	for index = 1, 20 do
		expectSame(results[index], expected, "shared result " .. index)
	end
end, 6)

-- One worker error is delivered to every waiter, then the path is reusable.
test("10 concurrent callers share one error and retry", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local started = false
	local calls = 0
	local completed = 0
	local successes = {}
	local messages = {}

	local function fetch()
		calls += 1
		started = true
		gate.Event:Wait()
		error("fanout_failure")
	end

	for index = 1, 10 do
		task.spawn(function()
			successes[index], messages[index] = pcall(function()
				return cache:Get({
					sharedError = fetch,
				})
			end)
			completed += 1
		end)
	end

	assert(waitFor(function()
		return started
	end, 1), "error worker never started")

	task.wait()
	gate:Fire()

	assert(waitFor(function()
		return completed == 10
	end, 3), "not all error waiters completed")

	gate:Destroy()

	expectEqual(calls, 1, "error worker call count")

	for index = 1, 10 do
		assert(not successes[index], "error waiter " .. index .. " unexpectedly succeeded")
		assert(
			string.find(tostring(messages[index]), "fanout_failure", 1, true),
			"error waiter " .. index .. " lost its error"
		)
	end

	expectEqual(cache:Get({
		sharedError = function()
			return 123
		end,
	}), 123, "error retry")
end, 6)

-- A table-valued Lua error must also clear pending state.
test("table-valued error can retry", function()
	local cache = Memoizer.new()
	local failure = { code = "E_TABLE" }

	local success = pcall(function()
		cache:Get({
			tableError = function()
				error(failure)
			end,
		})
	end)

	assert(not success, "table-valued error unexpectedly succeeded")

	expectEqual(cache:Get({
		tableError = function()
			return 17
		end,
	}), 17, "table-error retry")
end)

-- Canceling a waiting caller must not cancel or poison the shared fetch.
test("canceled waiter does not poison fetch", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local expected = { ok = true }
	local started = false
	local initiatorDone = false
	local initiatorResult

	task.spawn(function()
		initiatorResult = cache:Get({
			cancelWaiter = function()
				started = true
				gate.Event:Wait()
				return expected
			end,
		})
		initiatorDone = true
	end)

	assert(waitFor(function()
		return started
	end, 1), "initiator worker never started")

	local waiter = task.spawn(function()
		cache:Get({
			cancelWaiter = function()
				error("waiter callback ran")
			end,
		})
	end)

	task.wait()
	task.cancel(waiter)
	gate:Fire()

	assert(waitFor(function()
		return initiatorDone
	end, 3), "initiator did not finish after waiter cancellation")

	gate:Destroy()

	expectSame(initiatorResult, expected, "initiator result")
	expectSame(cache:Get({
		cancelWaiter = function()
			error("cached callback ran after waiter cancellation")
		end,
	}), expected, "cached result after waiter cancellation")
end, 6)

-- Canceling the caller that started a fetch must not cancel the detached worker.
test("canceled initiating caller does not poison fetch", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local expected = { ok = "detached" }
	local calls = 0
	local started = false
	local waiterDone = false
	local waiterResult

	local initiatingCaller = task.spawn(function()
		cache:Get({
			cancelInitiator = function()
				calls += 1
				started = true
				gate.Event:Wait()
				return expected
			end,
		})
	end)

	assert(waitFor(function()
		return started
	end, 1), "detached worker never started")
	task.cancel(initiatingCaller)

	task.spawn(function()
		waiterResult = cache:Get({
			cancelInitiator = function()
				error("replacement callback ran")
			end,
		})
		waiterDone = true
	end)

	task.wait()
	gate:Fire()

	assert(waitFor(function()
		return waiterDone
	end, 3), "waiter did not receive detached worker result")

	gate:Destroy()

	expectEqual(calls, 1, "detached worker call count")
	expectSame(waiterResult, expected, "detached worker result")
end, 6)

-- Record resolves both initiator and waiters and the stale worker cannot overwrite it.
test("Record supersedes an active callback", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local workerValue = { source = "worker" }
	local recordedValue = { source = "Record" }
	local started = false
	local firstDone = false
	local secondDone = false
	local firstResult
	local secondResult

	task.spawn(function()
		firstResult = cache:Get({
			supersede = function()
				started = true
				gate.Event:Wait()
				return workerValue
			end,
		})
		firstDone = true
	end)

	assert(waitFor(function()
		return started
	end, 1), "superseded worker never started")

	task.spawn(function()
		secondResult = cache:Get({
			supersede = function()
				error("waiter callback ran")
			end,
		})
		secondDone = true
	end)

	task.wait()

	cache:Record({
		supersede = {
			value = recordedValue,
		},
	})

	assert(waitFor(function()
		return firstDone and secondDone
	end, 2), "Record did not resolve all callers")

	expectSame(firstResult, recordedValue, "initiating caller recorded result")
	expectSame(secondResult, recordedValue, "waiting caller recorded result")

	gate:Fire()
	task.wait()
	gate:Destroy()

	expectSame(cache:Get({
		supersede = function()
			error("stale worker overwrote recorded value")
		end,
	}), recordedValue, "final recorded value")
end, 7)

-- Different paths may execute concurrently while each path deduplicates its callers.
test("30 keys x 5 callers stress", function()
	local cache = Memoizer.new()
	local calls = {}
	local results = {}
	local completed = 0

	for key = 1, 30 do
		calls[key] = 0
		results[key] = {}

		for caller = 1, 5 do
			task.spawn(function()
				results[key][caller] = cache:Get({
					byId = {
						[key] = function()
							calls[key] += 1
							task.wait()
							return { id = key }
						end,
					},
				})
				completed += 1
			end)
		end
	end

	assert(waitFor(function()
		return completed == 150
	end, 6), "stress callers did not all complete")

	for key = 1, 30 do
		expectEqual(calls[key], 1, "stress callback count " .. key)

		local expected = results[key][1]
		expectEqual(expected.id, key, "stress result id " .. key)

		for caller = 2, 5 do
			expectSame(results[key][caller], expected, "stress shared result " .. key .. "/" .. caller)
		end
	end
end, 10)

-- Cached reads must never recreate the pending hierarchy.
test("1000 deep cache hits leave pending empty", function()
	local cache = Memoizer.new()
	local expected = {}

	for key = 1, 100 do
		expected[key] = {
			id = key,
		}
		recordValue(cache, { "deepHits", "users", key, "profile" }, expected[key])
	end

	expectPendingEmpty(cache, "before deep cache hits")

	for repetition = 1, 10 do
		for key = 1, 100 do
			local result = cache:Get(makeSchema(
				{ "deepHits", "users", key, "profile" },
				function()
					error("deep cached callback ran")
				end
			))

			expectSame(result, expected[key], "deep cached result " .. key)
		end
	end

	expectPendingEmpty(cache, "after 1000 deep cache hits")
end, 12)

-- Supported paths work across several depths and key types.
test("path depth and key-type matrix", function()
	local cache = Memoizer.new()
	local tableKey = {}
	local cases = {
		{
			keys = { "direct" },
			value = "one",
		},
		{
			keys = { "number", 17 },
			value = 17,
		},
		{
			keys = { "boolean", true, "tail" },
			value = false,
		},
		{
			keys = { "table", tableKey, "tail" },
			value = {
				tableKey = true,
			},
		},
		{
			keys = { "depth", 2, 3, 4, 5, 6, 7, 8 },
			value = {
				depth = 8,
			},
		},
	}

	for index, case in ipairs(cases) do
		local calls = 0
		local first = cache:Get(makeSchema(case.keys, function()
			calls += 1
			return case.value
		end))

		local second = cache:Get(makeSchema(case.keys, function()
			calls += 1
			error("matrix callback ran twice")
		end))

		expectValue(first, case.value, "first matrix value " .. index)
		expectValue(second, case.value, "cached matrix value " .. index)
		expectEqual(calls, 1, "matrix callback count " .. index)
	end

	expectPendingEmpty(cache, "after path matrix")
end)

-- Completing one pending sibling must not prune another pending sibling.
test("simultaneous sibling paths clean independently", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local started = 0
	local completed = 0
	local calls = {
		left = 0,
		right = 0,
	}
	local expected = {
		left = {
			side = "left",
		},
		right = {
			side = "right",
		},
	}
	local results = {}

	for _, side in ipairs({ "left", "right" }) do
		task.spawn(function()
			results[side] = cache:Get(makeSchema(
				{ "siblings", side },
				function()
					calls[side] += 1
					started += 1
					gate.Event:Wait()
					return expected[side]
				end
			))
			completed += 1
		end)
	end

	assert(waitFor(function()
		return started == 2
	end, 2), "both sibling workers did not start")

	gate:Fire()

	assert(waitFor(function()
		return completed == 2
	end, 3), "both sibling workers did not complete")

	gate:Destroy()

	expectEqual(calls.left, 1, "left sibling callback count")
	expectEqual(calls.right, 1, "right sibling callback count")
	expectSame(results.left, expected.left, "left sibling result")
	expectSame(results.right, expected.right, "right sibling result")
	expectPendingEmpty(cache, "after sibling completion")
end, 7)

-- An error on one sibling must not remove or corrupt a successful sibling.
test("erroring sibling does not disrupt successful sibling", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local started = 0
	local completed = 0
	local successResult
	local errorSuccess
	local errorMessage
	local expected = {
		ok = true,
	}

	task.spawn(function()
		successResult = cache:Get(makeSchema(
			{ "mixedSiblings", "success" },
			function()
				started += 1
				gate.Event:Wait()
				return expected
			end
		))
		completed += 1
	end)

	task.spawn(function()
		errorSuccess, errorMessage = pcall(function()
			return cache:Get(makeSchema(
				{ "mixedSiblings", "error" },
				function()
					started += 1
					gate.Event:Wait()
					error("mixed_sibling_failure")
				end
			))
		end)
		completed += 1
	end)

	assert(waitFor(function()
		return started == 2
	end, 2), "both mixed sibling workers did not start")

	gate:Fire()

	assert(waitFor(function()
		return completed == 2
	end, 3), "both mixed sibling workers did not complete")

	gate:Destroy()

	expectSame(successResult, expected, "successful sibling result")
	assert(not errorSuccess, "erroring sibling unexpectedly succeeded")
	assert(
		string.find(tostring(errorMessage), "mixed_sibling_failure", 1, true),
		"erroring sibling lost its error"
	)

	expectEqual(cache:Get(makeSchema(
		{ "mixedSiblings", "error" },
		function()
			return 91
		end
	)), 91, "erroring sibling retry")

	expectPendingEmpty(cache, "after mixed sibling completion")
end, 7)

-- Record can replace a deferred worker before its callback begins.
test("Record before deferred callback starts", function()
	local cache = Memoizer.new()
	local recorded = {
		source = "early Record",
	}
	local callbackCalls = 0
	local completed = false
	local result

	task.spawn(function()
		result = cache:Get({
			earlyRecord = function()
				callbackCalls += 1
				return {
					source = "callback",
				}
			end,
		})
		completed = true
	end)

	cache:Record({
		earlyRecord = {
			value = recorded,
		},
	})

	assert(waitFor(function()
		return completed
	end, 2), "early Record did not resolve caller")

	task.wait()

	expectEqual(callbackCalls, 0, "early canceled callback count")
	expectSame(result, recorded, "early recorded result")
	expectPendingEmpty(cache, "after early Record")
end, 6)

-- BindableEvent resumes are deferred, so Record in the same turn must win.
test("Record after gate Fire but before worker resumes", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local started = false
	local completed = false
	local result
	local workerValue = {
		source = "worker",
	}
	local recordedValue = {
		source = "same-turn Record",
	}

	task.spawn(function()
		result = cache:Get({
			fireThenRecord = function()
				started = true
				gate.Event:Wait()
				return workerValue
			end,
		})
		completed = true
	end)

	assert(waitFor(function()
		return started
	end, 2), "fire-then-Record worker did not start")

	gate:Fire()
	cache:Record({
		fireThenRecord = {
			value = recordedValue,
		},
	})

	assert(waitFor(function()
		return completed
	end, 2), "fire-then-Record caller did not finish")

	task.wait()
	gate:Destroy()

	expectSame(result, recordedValue, "fire-then-Record caller result")
	expectSame(cache:Get({
		fireThenRecord = function()
			error("fire-then-Record value was overwritten")
		end,
	}), recordedValue, "fire-then-Record cached result")
	expectPendingEmpty(cache, "after fire-then-Record")
end, 7)

-- A detached worker must finish and clean up even if every caller is canceled.
test("all callers canceled still settles cache", function()
	local cache = Memoizer.new()
	local gate = Instance.new("BindableEvent")
	local expected = {
		detached = true,
	}
	local started = false
	local calls = 0
	local callers = {}

	for index = 1, 12 do
		callers[index] = task.spawn(function()
			cache:Get({
				allCanceled = function()
					calls += 1
					started = true
					gate.Event:Wait()
					return expected
				end,
			})
		end)
	end

	assert(waitFor(function()
		return started
	end, 2), "all-canceled worker did not start")

	task.wait()

	for _, caller in ipairs(callers) do
		task.cancel(caller)
	end

	gate:Fire()

	assert(waitFor(function()
		return next(cache._pending) == nil
	end, 3), "detached worker did not clear pending state")

	gate:Destroy()

	expectEqual(calls, 1, "all-canceled callback count")
	expectSame(cache:Get({
		allCanceled = function()
			error("all-canceled cached callback ran")
		end,
	}), expected, "all-canceled cached result")
	expectPendingEmpty(cache, "after all callers canceled")
end, 7)

-- A deterministic reference model checks mixed sequential Get, Record, nil, table, and error behavior.
test("seeded sequential model fuzz", function()
	print("[SEED] sequential model fuzz: " .. MODEL_FUZZ_SEED)

	local random = Random.new(MODEL_FUZZ_SEED)
	local cache = Memoizer.new()
	local model = {}

	for operation = 1, MODEL_FUZZ_OPERATIONS do
		local key = random:NextInteger(1, 50)
		local action = random:NextInteger(1, 5)
		local existing = model[key]

		if action <= 3 then
			if existing then
				local result = cache:Get(makeSchema(
					{ "model", key },
					function()
						error("model hit callback ran")
					end
				))
				expectValue(result, existing.value, "model cached value " .. operation)
			else
				local expected = randomValue(random, operation)
				local calls = 0
				local result = cache:Get(makeSchema(
					{ "model", key },
					function()
						calls += 1
						return expected
					end
				))

				model[key] = {
					value = expected,
				}

				expectValue(result, expected, "model fetched value " .. operation)
				expectEqual(calls, 1, "model fetch count " .. operation)
			end
		elseif action == 4 then
			local expected = randomValue(random, operation)

			if expected == nil then
				expected = "recorded_nil_replacement_" .. operation
			end

			recordValue(cache, { "model", key }, expected)
			model[key] = {
				value = expected,
			}

			local result = cache:Get(makeSchema(
				{ "model", key },
				function()
					error("model recorded callback ran")
				end
			))
			expectValue(result, expected, "model recorded value " .. operation)
		else
			local errorKey = operation
			local success, message = pcall(function()
				cache:Get(makeSchema(
					{ "modelErrors", errorKey },
					function()
						error("model_error_" .. operation)
					end
				))
			end)

			assert(not success, "model error unexpectedly succeeded " .. operation)
			assert(
				string.find(tostring(message), "model_error_" .. operation, 1, true),
				"model error message was lost " .. operation
			)

			local retryValue = {
				retry = operation,
			}
			expectSame(cache:Get(makeSchema(
				{ "modelErrors", errorKey },
				function()
					return retryValue
				end
			)), retryValue, "model error retry " .. operation)
		end

		expectPendingEmpty(cache, "model operation " .. operation)

		-- Let completed deferred work unwind during long stress runs.
		if operation % 20 == 0 then
			task.wait()
		end
	end
end, 25)

-- Seeded batches vary fanout, cancellation, success, errors, and Record supersession.
test("seeded concurrent interleaving fuzz", function()
	print("[SEED] concurrent interleaving fuzz: " .. CONCURRENCY_FUZZ_SEED)

	local random = Random.new(CONCURRENCY_FUZZ_SEED)
	local cache = Memoizer.new()

	for round = 1, CONCURRENCY_FUZZ_ROUNDS do
		local mode = random:NextInteger(1, 3)
		local callerCount = random:NextInteger(3, 12)
		local gate = Instance.new("BindableEvent")
		local started = false
		local calls = 0
		local completed = 0
		local callers = {}
		local canceled = {}
		local successes = {}
		local results = {}
		local workerValue = {
			round = round,
			source = "worker",
		}
		local recordedValue = {
			round = round,
			source = "Record",
		}

		local function fetch()
			calls += 1
			started = true
			gate.Event:Wait()

			if mode == 2 then
				error("concurrency_fuzz_error_" .. round)
			end

			return workerValue
		end

		for caller = 1, callerCount do
			callers[caller] = task.spawn(function()
				successes[caller], results[caller] = pcall(function()
					return cache:Get(makeSchema(
						{ "concurrencyFuzz", round },
						fetch
					))
				end)
				completed += 1
			end)
		end

		assert(waitFor(function()
			return started
		end, 2), "concurrency fuzz worker did not start in round " .. round)

		task.wait()

		local remaining = callerCount

		for caller = 1, callerCount do
			if remaining > 1 and random:NextNumber() < 0.25 then
				canceled[caller] = true
				remaining -= 1
				task.cancel(callers[caller])
			end
		end

		if mode == 3 then
			recordValue(cache, { "concurrencyFuzz", round }, recordedValue)
			gate:Fire()
		else
			gate:Fire()
		end

		assert(waitFor(function()
			return completed == remaining
		end, 4), "concurrency fuzz callers did not settle in round " .. round)

		gate:Destroy()

		expectEqual(calls, 1, "concurrency fuzz callback count " .. round)

		for caller = 1, callerCount do
			if not canceled[caller] then
				if mode == 1 then
					assert(successes[caller], "success fuzz caller failed in round " .. round)
					expectSame(results[caller], workerValue, "success fuzz result " .. round .. "/" .. caller)
				elseif mode == 2 then
					assert(not successes[caller], "error fuzz caller succeeded in round " .. round)
					assert(
						string.find(
							tostring(results[caller]),
							"concurrency_fuzz_error_" .. round,
							1,
							true
						),
						"error fuzz message was lost in round " .. round
					)
				else
					assert(successes[caller], "Record fuzz caller failed in round " .. round)
					expectSame(results[caller], recordedValue, "Record fuzz result " .. round .. "/" .. caller)
				end
			end
		end

		if mode == 1 then
			expectSame(cache:Get(makeSchema(
				{ "concurrencyFuzz", round },
				function()
					error("success fuzz cached callback ran")
				end
			)), workerValue, "success fuzz cached value " .. round)
		elseif mode == 2 then
			local retryValue = {
				round = round,
				source = "retry",
			}
			expectSame(cache:Get(makeSchema(
				{ "concurrencyFuzz", round },
				function()
					return retryValue
				end
			)), retryValue, "error fuzz retry " .. round)
		else
			expectSame(cache:Get(makeSchema(
				{ "concurrencyFuzz", round },
				function()
					error("Record fuzz cached callback ran")
				end
			)), recordedValue, "Record fuzz cached value " .. round)
		end

		expectPendingEmpty(cache, "after concurrency fuzz round " .. round)
	end
end, 35)

-- Ceiling inputs are normalized to positive integer capacities.
test("cache ceiling normalizes capacity", function()
	local minimum = Memoizer.new(nil, 0)
	local roundedDown = Memoizer.new(nil, 2.4)
	local roundedUp = Memoizer.new(nil, 2.6)

	expectEqual(minimum._maxCacheRecords, 1, "minimum ceiling")
	expectEqual(roundedDown._maxCacheRecords, 2, "rounded-down ceiling")
	expectEqual(roundedUp._maxCacheRecords, 3, "rounded-up ceiling")
	expectCeilingInvariants(minimum, "minimum empty ceiling")
	expectCeilingInvariants(roundedDown, "rounded-down empty ceiling")
	expectCeilingInvariants(roundedUp, "rounded-up empty ceiling")
end)

-- A capacity of one must survive repeated modulo wrapping and shared-parent eviction.
test("cache ceiling one repeatedly keeps newest value", function()
	local cache = Memoizer.new(nil, 1)

	for key = 1, 12 do
		recordValue(cache, { "single", key }, key)

		expectCachePath(cache, { "single", key }, true, "single newest " .. key)

		if key > 1 then
			expectCachePath(cache, { "single", key - 1 }, false, "single evicted " .. (key - 1))
		end

		expectEqual(cache._cacheRecordsCount, 1, "single record count " .. key)
		expectEqual(cache._oldestCacheRecordIndex, 1, "single oldest index " .. key)
		expectCeilingInvariants(cache, "single rotation " .. key)
	end
end)

-- The circular FIFO must visit every slot over several complete rotations.
test("cache ceiling preserves FIFO across rotations", function()
	local cache = Memoizer.new(nil, 3)

	for key = 1, 15 do
		recordValue(cache, { "fifo", key }, key)
		expectCeilingInvariants(cache, "FIFO insertion " .. key)
	end

	for key = 1, 15 do
		expectCachePath(
			cache,
			{ "fifo", key },
			key >= 13,
			"FIFO final presence " .. key
		)
	end

	expectEqual(cache._cacheRecordsCount, 3, "FIFO final count")
end)

-- Evicting one sibling must retain the shared layer's metadata until its last leaf is gone.
test("cache ceiling prunes shared parent only after final sibling", function()
	local cache = Memoizer.new(nil, 2)

	recordValue(cache, { "shared", "left" }, 1)
	recordValue(cache, { "shared", "right" }, 2)

	local sharedLayer = cache._cache.shared
	recordValue(cache, { "other", "third" }, 3)

	expectCachePath(cache, { "shared", "left" }, false, "shared first sibling evicted")
	expectCachePath(cache, { "shared", "right" }, true, "shared second sibling retained")
	expectSame(cache._parentByLayer[sharedLayer], cache._cache, "shared parent retained")
	expectEqual(cache._keyByLayer[sharedLayer], "shared", "shared parent key retained")
	expectCeilingInvariants(cache, "shared layer after first eviction")

	recordValue(cache, { "other", "fourth" }, 4)

	expectCachePath(cache, { "shared" }, false, "shared branch pruned")
	expectEqual(cache._parentByLayer[sharedLayer], nil, "shared parent metadata released")
	expectEqual(cache._keyByLayer[sharedLayer], nil, "shared key metadata released")
	expectCeilingInvariants(cache, "shared layer after final eviction")
end)

-- Installing the new leaf before eviction must keep a reused parent attached to the cache.
test("cache ceiling keeps new leaf in oldest leaf's parent", function()
	local cache = Memoizer.new(nil, 1)

	recordValue(cache, { "sameParent", "old" }, "old")
	local sharedLayer = cache._cache.sameParent
	recordValue(cache, { "sameParent", "new" }, "new")

	expectSame(cache._cache.sameParent, sharedLayer, "same-parent layer remained attached")
	expectCachePath(cache, { "sameParent", "old" }, false, "same-parent old leaf removed")
	expectEqual(
		expectCachePath(cache, { "sameParent", "new" }, true, "same-parent new leaf retained"),
		"new",
		"same-parent new value"
	)
	expectCeilingInvariants(cache, "same-parent replacement")
end)

-- Removing a unique deep path must release every layer without disturbing root siblings.
test("cache ceiling deeply prunes only isolated root branch", function()
	local cache = Memoizer.new(nil, 2)

	recordValue(cache, { "discard", "one", "two", "three", "leaf" }, 1)
	recordValue(cache, { "keeper" }, 2)

	local discardRoot = cache._cache.discard
	local discardMiddle = discardRoot.one.two
	recordValue(cache, { "replacement", "deep", "leaf" }, 3)

	expectCachePath(cache, { "discard" }, false, "isolated deep root removed")
	expectCachePath(cache, { "keeper" }, true, "unrelated root leaf retained")
	expectCachePath(cache, { "replacement", "deep", "leaf" }, true, "replacement retained")
	expectEqual(cache._parentByLayer[discardRoot], nil, "discard root metadata released")
	expectEqual(cache._parentByLayer[discardMiddle], nil, "discard middle metadata released")
	expectCeilingInvariants(cache, "deep isolated pruning")
end)

-- False is valid as both a cached value and a path key, and overwriting it must not enqueue twice.
test("cache ceiling supports false keys and false values", function()
	local cache = Memoizer.new(nil, 2)

	recordValue(cache, { false, false }, false)
	recordValue(cache, { false, false }, false)
	expectEqual(cache._cacheRecordsCount, 1, "false overwrite record count")

	recordValue(cache, { true }, false)
	expectEqual(
		expectCachePath(cache, { true }, true, "direct false value present"),
		false,
		"direct false cached value"
	)

	recordValue(cache, { "third" }, 3)

	expectCachePath(cache, { false }, false, "false root key pruned")
	expectCachePath(cache, { true }, true, "true root key retained")
	expectCachePath(cache, { "third" }, true, "third root key retained")
	expectCeilingInvariants(cache, "false keys and values")
end)

-- Overwriting preserves original FIFO age and does not consume another slot.
test("cache ceiling overwrite does not refresh FIFO position", function()
	local cache = Memoizer.new(nil, 2)

	recordValue(cache, { "overwrite", "a" }, 1)
	recordValue(cache, { "overwrite", "b" }, 2)
	recordValue(cache, { "overwrite", "a" }, 3)

	expectEqual(cache._cacheRecordsCount, 2, "overwrite did not increase count")
	recordValue(cache, { "overwrite", "c" }, 4)

	expectCachePath(cache, { "overwrite", "a" }, false, "overwritten oldest still evicted")
	expectEqual(
		expectCachePath(cache, { "overwrite", "b" }, true, "second FIFO value retained"),
		2,
		"second FIFO cached value"
	)
	expectEqual(
		expectCachePath(cache, { "overwrite", "c" }, true, "new FIFO value retained"),
		4,
		"new FIFO cached value"
	)
	expectCeilingInvariants(cache, "overwrite FIFO order")
end)

-- Nil, false, and table results must each occupy exactly one ceiling slot.
test("cache ceiling handles nil false and table results", function()
	local cache = Memoizer.new(nil, 2)
	local expectedTable = {
		kind = "table",
	}

	expectEqual(cache:Get(makeSchema({ "values", "nil" }, function()
		return nil
	end)), nil, "ceiling nil result")
	expectEqual(cache:Get(makeSchema({ "values", "false" }, function()
		return false
	end)), false, "ceiling false result")
	expectSame(cache:Get(makeSchema({ "values", "table" }, function()
		return expectedTable
	end)), expectedTable, "ceiling table result")

	expectCachePath(cache, { "values", "nil" }, false, "ceiling nil evicted")
	expectEqual(cache:Get(makeSchema({ "values", "false" }, function()
		error("ceiling false callback reran")
	end)), false, "ceiling false cached hit")
	expectSame(cache:Get(makeSchema({ "values", "table" }, function()
		error("ceiling table callback reran")
	end)), expectedTable, "ceiling table cached hit")
	expectCeilingInvariants(cache, "nil false table ceiling")
end)

-- ClearCache must release all ceiling bookkeeping and remain reusable.
test("ClearCache resets and reuses cache ceiling", function()
	local cache = Memoizer.new(nil, 3)

	for key = 1, 8 do
		recordValue(cache, { "beforeClear", key, "leaf" }, key)
	end

	cache:ClearCache()

	assert(next(cache._cache) == nil, "cleared cache was not empty")
	assert(next(cache._cacheRecords) == nil, "cleared FIFO records were not empty")
	assert(next(cache._keyByLayer) == nil, "cleared parent-key metadata was not empty")
	assert(next(cache._parentByLayer) == nil, "cleared parent metadata was not empty")
	expectEqual(cache._cacheRecordsCount, 0, "cleared record count")
	expectEqual(cache._oldestCacheRecordIndex, 1, "cleared oldest index")
	expectEqual(cache._cacheRecordsInsertionIndex, 1, "cleared insertion index")
	expectCeilingInvariants(cache, "after ceiling clear")

	for key = 1, 5 do
		recordValue(cache, { "afterClear", key }, key)
	end

	for key = 1, 5 do
		expectCachePath(cache, { "afterClear", key }, key >= 3, "post-clear presence " .. key)
	end

	expectCeilingInvariants(cache, "after ceiling reuse")
end)

-- Pending fanout must still deduplicate while the completed value evicts the oldest entry.
test("cache ceiling integrates with pending fanout", function()
	local cache = Memoizer.new(nil, 1)
	local gate = Instance.new("BindableEvent")
	local expected = {
		fresh = true,
	}
	local calls = 0
	local completed = 0
	local results = {}

	recordValue(cache, { "old" }, "old")

	for caller = 1, 8 do
		task.spawn(function()
			results[caller] = cache:Get({
				fresh = function()
					calls += 1
					gate.Event:Wait()
					return expected
				end,
			})
			completed += 1
		end)
	end

	assert(waitFor(function()
		return calls == 1
	end, 2), "ceiling pending worker did not start")

	gate:Fire()
	assert(waitFor(function()
		return completed == 8
	end, 4), "ceiling pending callers did not settle")
	gate:Destroy()

	for caller = 1, 8 do
		expectSame(results[caller], expected, "ceiling pending result " .. caller)
	end

	expectCachePath(cache, { "old" }, false, "pending completion evicted old value")
	expectCachePath(cache, { "fresh" }, true, "pending completion cached fresh value")
	expectPendingEmpty(cache, "ceiling pending fanout")
	expectCeilingInvariants(cache, "ceiling pending fanout")
end, 7)

-- A seeded model stresses hits, misses, overwrites, clears, rotations, and deep dynamic paths.
test("seeded cache ceiling model fuzz", function()
	local seed = 8222026
	local operations = 350
	local limit = 7
	local random = Random.new(seed)
	local cache = Memoizer.new(nil, limit)
	local model = {}
	local order = {}

	print("[SEED] cache ceiling model fuzz: " .. seed)

	local function nextValue(token)
		local kind = random:NextInteger(1, 4)

		if kind == 1 then
			return false
		elseif kind == 2 then
			return token
		elseif kind == 3 then
			return "ceiling_" .. token
		else
			return {
				token = token,
			}
		end
	end

	local function remember(key, value)
		if model[key] == nil then
			if #order == limit then
				local evicted = table.remove(order, 1)
				model[evicted] = nil
			end

			table.insert(order, key)
		end

		model[key] = {
			value = value,
		}
	end

	for operation = 1, operations do
		-- Break long chains of immediately-completing task.defer calls so the
		-- fuzz test exercises the cache rather than Roblox's re-entrancy guard.
		if operation % 50 == 0 then
			task.wait()
		end

		local key = random:NextInteger(1, 24)
		local action = random:NextInteger(1, 10)

		if action <= 5 then
			local value = nextValue(operation)
			recordValue(cache, { "ceilingModel", key, "leaf" }, value)
			remember(key, value)
		elseif action <= 9 then
			local existing = model[key]

			if existing then
				local result = cache:Get(makeSchema(
					{ "ceilingModel", key, "leaf" },
					function()
						error("ceiling model hit callback ran")
					end
				))
				expectValue(result, existing.value, "ceiling model hit " .. operation)
			else
				local value = nextValue(operation)
				local result = cache:Get(makeSchema(
					{ "ceilingModel", key, "leaf" },
					function()
						return value
					end
				))
				expectValue(result, value, "ceiling model miss " .. operation)
				remember(key, value)
			end
		else
			cache:ClearCache()
			model = {}
			order = {}
		end

		for candidate = 1, 24 do
			expectCachePath(
				cache,
				{ "ceilingModel", candidate, "leaf" },
				model[candidate] ~= nil,
				"ceiling model presence " .. operation .. "/" .. candidate
			)
		end

		expectCeilingInvariants(cache, "ceiling model operation " .. operation)
		expectPendingEmpty(cache, "ceiling model operation " .. operation)
	end
end, 25)

print(string.format(
	"[SUMMARY] Memoizer: %d run, %d passed, %d failed",
	total,
	passed,
	failed
))
