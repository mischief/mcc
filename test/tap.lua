-- SPDX-License-Identifier: ISC
-- TAP, so that a test says what it did rather than only whether it worked,
-- and so that meson can run the lot in parallel and report each one.
--
-- The plan comes last: a test that finds out how much there is to check as
-- it goes cannot say the number first, and a count that is written down
-- twice is a count that can disagree with itself.

local tap = {n = 0, failed = 0}

local function emit(s)
	io.write(s, "\n")
	io.flush()
end

-- The scratch directories this test made.  /tmp is memory on the
-- machines this runs on, and a whole suite leaves a gigabyte behind, so
-- they go when the Lua state closes: after the plan, after a skip, and
-- after an error, which never reaches the plan.  MCC_KEEP_SCRATCH=1 keeps
-- them for a look.
local scratch = {}
local keep = os.getenv("MCC_KEEP_SCRATCH") == "1"

tap.sweeper = setmetatable({}, {__gc = function()
	if keep then return end
	for _, d in ipairs(scratch) do
		os.execute("rm -rf '" .. d:gsub("'", "'\\''") .. "'")
	end
end})

-- A directory of this test's own, empty, and gone at the end.  A test
-- that runs as several instances at once under one directory name says
-- `shared`, and gets a private directory inside it instead, so that one
-- instance never empties another's.
function tap.scratch(dir, shared)
	if shared then
		local t = os.tmpname()

		os.remove(t)
		os.execute("mkdir -p '" .. dir .. "'")
		dir = dir .. "/" .. t:gsub(".*/", "")
	end
	os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
	scratch[#scratch + 1] = dir
	return dir
end

function tap.ok(cond, name)
	tap.n = tap.n + 1
	if cond then
		emit(("ok %d - %s"):format(tap.n, name))
	else
		tap.failed = tap.failed + 1
		emit(("not ok %d - %s"):format(tap.n, name))
	end
	return cond
end

function tap.is(got, want, name)
	if got ~= want then
		tap.diag(("got %s, want %s"):format(tostring(got),
			tostring(want)))
	end
	return tap.ok(got == want, name)
end

-- A note for a reader, which a TAP consumer keeps with the test above it.
function tap.diag(s)
	for line in (tostring(s) .. "\n"):gmatch("([^\n]*)\n") do
		emit("# " .. line)
	end
end

-- One assertion that did not run, with the reason.  What the harness can
-- decide from outside belongs outside; this is for what only the test can
-- know, such as a tree it was pointed at not being there.
function tap.skip(name, why)
	tap.n = tap.n + 1
	emit(("ok %d - %s # SKIP %s"):format(tap.n, name, why))
end

-- A gap that is known.  A consumer counts it as expected either way, and
-- says so when it starts passing, which is when it should be taken off the
-- list.
function tap.todo(cond, name)
	tap.n = tap.n + 1
	emit(("%sok %d - %s # TODO not supported yet")
		:format(cond and "" or "not ", tap.n, name))
	return cond
end

-- True when `tool --version` names GNU binutils at least major.minor.
-- The tests compare against that output; OpenBSD's nm and its gas 2.17
-- print other shapes.
function tap.gnu(tool, major, minor)
	local p = io.popen(tool .. " --version 2>/dev/null")
	local line = p and p:read("l") or ""

	if p then p:close() end
	local x, y = line:match("^GNU .- (%d+)%.(%d+)")

	x, y = tonumber(x), tonumber(y)
	return x ~= nil and (x > major or (x == major and y >= minor))
end

-- The whole file skipped, which ends it.
function tap.skipall(why)
	emit("1..0 # SKIP " .. why)
	os.exit(0, true)
end

function tap.done()
	emit(("1..%d"):format(tap.n))
	os.exit(tap.failed == 0 and 0 or 1, true)
end

-- Run one named check, so that an error inside it is a failed assertion
-- rather than a test that stops with no plan.
function tap.try(name, f, ...)
	local ok, err = pcall(f, ...)
	if ok then return err end
	tap.ok(false, name)
	tap.diag(err)
	return nil
end

return tap
