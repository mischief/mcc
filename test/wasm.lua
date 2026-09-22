-- SPDX-License-Identifier: ISC
-- The module writer against a real engine: what wasm.lua emits has to
-- validate and run under node, which is the only oracle there is for a
-- format with no assembler to diff against.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local tap = require "test.tap"

local node = os.getenv("NODE") or "node"
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/comp-wasm"

local function has(prog)
	local p = io.popen("command -v " .. prog .. " 2>/dev/null")
	local s = p:read("l")

	p:close()
	return s ~= nil and s ~= ""
end

if not has(node) then tap.skipall("no node to run a module under") end
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

local p = io.popen(node .. " " .. jsfile .. " 2>&1")
local out = p:read("a")

p:close()

local got = {}

for line in out:gmatch("[^\n]+") do
	local k, v = line:match("^(%a+) ?(.*)$")

	if k then got[k] = v end
end

if got.valid == nil then tap.diag(out) end
tap.ok(got.valid ~= nil, "the module validates")
tap.is(got.add, "7", "i32 add")
tap.is(got.big, "-1234567890123000", "i64 constant and multiply")
tap.is(got.flt, "6", "f64 divide")
tap.is(got.sum, "5050", "a loop with br and br_if")
tap.is(got.indir, "42", "call_indirect through the table")
tap.is(got.main, "28", "a call to an import, then to a definition")
tap.is(got.wrote, "hello", "the data segment reached the host")
tap.done()
