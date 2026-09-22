-- SPDX-License-Identifier: ISC
-- The module writer against real engines. A format with no assembler
-- has no bytes to diff against, so the oracle is an engine that agrees
-- or does not: wasm3 for what it can run, node for the import and the
-- memory it cannot.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local node = os.getenv("NODE") or "node"
local wasm3 = os.getenv("WASM3") or "wasm3"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-wasm"

local function has(prog)
	local p = io.popen("command -v " .. prog .. " 2>/dev/null")
	local s = p:read("l")

	p:close()
	return s ~= nil and s ~= ""
end

local hasnode, has3 = has(node), has(wasm3)

if not hasnode and not has3 then
	tap.skipall("no engine to run a module under")
end
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

local w = require "wasm"
local I = w.instr

-- ---- the module ----

local m = w.new()
local twrite = m:import("env", "write", m:type({ "i32", "i32" }, {}))

local ti = m:type({ "i32", "i32" }, { "i32" })
local add = m:func(ti, {}, I("local.get", 0) .. I("local.get", 1) ..
    I("i32.add"))

local big = m:func(m:type({}, { "i64" }), {},
    I("i64.const", -1234567890123) .. I("i64.const", 1000) .. I("i64.mul"))

local flt = m:func(m:type({}, { "f64" }), {},
    I("f64.const", 1.5) .. I("f64.const", 0.25) .. I("f64.div"))

-- a loop, which is what every backward jump has to become
local sum = m:func(m:type({ "i32" }, { "i32" }), { { 2, "i32" } },
    I("i32.const", 0) .. I("local.set", 1) ..
    I("i32.const", 1) .. I("local.set", 2) ..
    I("block", "void") ..
      I("loop", "void") ..
        I("local.get", 2) .. I("local.get", 0) .. I("i32.gt_s") ..
        I("br_if", 1) ..
        I("local.get", 1) .. I("local.get", 2) .. I("i32.add") ..
        I("local.set", 1) ..
        I("local.get", 2) .. I("i32.const", 1) .. I("i32.add") ..
        I("local.set", 2) ..
        I("br", 0) ..
      I("end") ..
    I("end") ..
    I("local.get", 1))

-- a call through the table, which is what a function pointer becomes
local indir = m:func(ti, {}, I("local.get", 0) .. I("local.get", 1) ..
    I("i32.const", 0) .. I("call_indirect", ti, 0))

-- the import, reading its bytes out of the data segment
local main = m:func(m:type({}, { "i32" }), {},
    I("i32.const", 16) .. I("i32.const", 5) .. I("call", twrite) ..
    I("i32.const", 7) .. I("call", sum))

m:table({ add })
m:memory(1)
m:segment(16, "hello")
for name, f in pairs({ add = add, big = big, flt = flt, sum = sum,
    indir = indir, main = main }) do
	m:export(name, "func", f)
end
m:export("memory", "memory", 0)

local path = dir .. "/t.wasm"
local fh = assert(io.open(path, "wb"))

fh:write(m:emit())
fh:close()

-- ---- what the engine says ----

local js = ([[
const fs = require('fs');
const b = fs.readFileSync(%q);
if (!WebAssembly.validate(b)) { console.log('INVALID'); process.exit(0); }
let said = '';
const i = new WebAssembly.Instance(new WebAssembly.Module(b),
  {env: {write: (p, n) => {
    said = Buffer.from(i.exports.memory.buffer, p, n).toString();
  }}});
const e = i.exports;
console.log('valid');
console.log('add ' + e.add(3, 4));
console.log('big ' + e.big());
console.log('flt ' + e.flt());
console.log('sum ' + e.sum(100));
console.log('indir ' + e.indir(20, 22));
console.log('main ' + e.main());
console.log('wrote ' + said);
]]):format(path)

local jsfile = dir .. "/run.js"

fh = assert(io.open(jsfile, "w"))
fh:write(js)
fh:close()

-- ---- wasm3, which takes no imports but needs nothing installed ----

local function run3(fn, ...)
	local args = table.concat({ ... }, " ")
	local p = io.popen(("%s --func %s %s %s 2>&1"):format(wasm3, fn, path,
	    args))
	local out = p:read("a")

	p:close()
	return (out:match("Result:%s*([^\n]+)") or out:gsub("%s+$", ""))
end

if has3 then
	tap.is(run3("add", 3, 4), "7", "wasm3: i32 add")
	tap.is(run3("big"), "-1234567890123000", "wasm3: i64 constant and multiply")
	tap.is(run3("flt"), "6.000000", "wasm3: f64 divide")
	tap.is(run3("sum", 100), "5050", "wasm3: a loop with br and br_if")
	tap.is(run3("indir", 20, 22), "42", "wasm3: call_indirect through the table")
else
	for _, n in ipairs({ "add", "i64", "f64", "loop", "call_indirect" }) do
		tap.skip("wasm3: " .. n, "no wasm3")
	end
end

-- ---- node, for the import and the memory behind it ----

if hasnode then
	local p = io.popen(node .. " " .. jsfile .. " 2>&1")
	local out = p:read("a")

	p:close()

	local got = {}

	for line in out:gmatch("[^\n]+") do
		local k, v = line:match("^(%a+) ?(.*)$")

		if k then got[k] = v end
	end

	if got.valid == nil then tap.diag(out) end
	tap.ok(got.valid ~= nil, "node: the module validates")
	tap.is(got.main, "28", "node: a call to an import, then to a definition")
	tap.is(got.wrote, "hello", "node: the data segment reached the host")
else
	for _, n in ipairs({ "validates", "import", "data segment" }) do
		tap.skip("node: " .. n, "no node")
	end
end

tap.done()
