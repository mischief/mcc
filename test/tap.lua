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

-- The whole file skipped, which ends it.
function tap.skipall(why)
	emit("1..0 # SKIP " .. why)
	os.exit(0)
end

function tap.done()
	emit(("1..%d"):format(tap.n))
	os.exit(tap.failed == 0 and 0 or 1)
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
