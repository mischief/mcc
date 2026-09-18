-- A growing text buffer.
--
-- A plain list of pieces costs about five times the text it holds, because
-- every piece is a separate string object in a separate array slot, and one
-- large function's assembly is the biggest thing this compiler ever keeps.
-- Merging each new piece into the one before it while that one is no longer
-- keeps the count down to the logarithm of the total and the cost to O(n log
-- n) bytes copied.

local buf = {}
buf.__index = buf

function buf.new()
	return setmetatable({n = 0}, buf)
end

function buf:add(s)
	if s == "" then return end
	local n = self.n + 1
	self[n] = s
	while n > 1 and #self[n - 1] <= #self[n] do
		self[n - 1] = self[n - 1] .. self[n]
		self[n] = nil
		n = n - 1
	end
	self.n = n
end

-- Anything that takes a writer wants this name.
buf.write = buf.add

function buf:len()
	local n = 0
	for i = 1, self.n do n = n + #self[i] end
	return n
end

function buf:text()
	return table.concat(self, "", 1, self.n)
end

-- The lines, without joining the pieces first.  A quarter of a megabyte
-- of assembly is the biggest thing this compiler holds, and a reader
-- that wants it a line at a time should not have to hold it twice.
function buf:lines()
	local i, at, tail = 1, 1, nil

	return function()
		while i <= self.n do
			local s = self[i]
			local nl = s:find("\n", at, true)

			if nl then
				local part = s:sub(at, nl - 1)

				at = nl + 1
				if tail then
					part, tail = tail .. part, nil
				end
				return part
			end
			tail = (tail or "") .. s:sub(at)
			i, at = i + 1, 1
		end
		if tail and tail ~= "" then
			local last = tail

			tail = nil
			return last
		end
	end
end

function buf:reset()
	for i = 1, self.n do self[i] = nil end
	self.n = 0
end

-- Append to another buffer and empty this one.
function buf:move(dst)
	for i = 1, self.n do
		dst:add(self[i])
		self[i] = nil
	end
	self.n = 0
end

return buf
