-- SPDX-License-Identifier: ISC
-- What the driver knows about the systems it builds for: where each
-- keeps its loader and start-up files, and what it calls itself.  The
-- option reader and the link both ask.

local sys = require "mcc.sys"

local M = {}

-- The loader each system runs a dynamic program with, and the startup
-- files it wants in front of and behind the program's own.
M.INTERP = {
	linux = {amd64 = "/lib64/ld-linux-x86-64.so.2",
		 arm64 = "/lib/ld-linux-aarch64.so.1",
		 riscv64 = "/lib/ld-linux-riscv64-lp64d.so.1"},
	openbsd = {amd64 = "/usr/libexec/ld.so"},
}
-- musl names its loader after the machine rather than after the ABI,
-- and a sysroot may hold it where the system holds glibc's.
M.MUSL = {amd64 = "/lib/ld-musl-x86_64.so.1",
	  arm64 = "/lib/ld-musl-aarch64.so.1",
	  riscv64 = "/lib/ld-musl-riscv64.so.1"}
M.CRTSET = {linux = {"Scrt1.o", "crti.o", "crtn.o"},
	    openbsd = {"crt0.o", "crtbegin.o", "crtend.o"}}
-- A shared library's own start-up files.  OpenBSD's crtbeginS.o holds
-- the hidden __guard_local that every -fstack-protector object uses.
M.SHAREDCRT = {openbsd = {"crtbeginS.o", "crtendS.o"}}
-- A static program's start-up files, before the objects and after, when
-- the system's C library is linked in whole rather than mcc's runtime.
M.STATICPIECRT = {openbsd = {{"rcrt0.o", "crtbegin.o"}, {"crtend.o"}}}
M.STATICCRT = {openbsd = {{"crt0.o", "crtbegin.o"}, {"crtend.o"}},
	       linux = {{"crt1.o", "crti.o"}, {"crtn.o"}}}

-- What the system calls itself.  A header asks, and an OpenBSD one asks
-- often: parts of a struct stand behind `#ifdef __OpenBSD__`.
M.OSDEF = {
	openbsd = {__OpenBSD__ = "1", __unix__ = "1", __unix = "1",
		   unix = "1"},
	linux = {__linux__ = "1", __linux = "1", linux = "1",
		 __gnu_linux__ = "1", __unix__ = "1", __unix = "1",
		 unix = "1"},
	freebsd = {__FreeBSD__ = "1", __unix__ = "1", __unix = "1",
		   unix = "1"},
	netbsd = {__NetBSD__ = "1", __unix__ = "1", __unix = "1",
		  unix = "1"},
	darwin = {__APPLE__ = "1", __MACH__ = "1", __unix__ = "1",
		  __unix = "1"},
}

-- The machine this is running on, which decides whether the system
-- headers are the right ones to read.
function M.host()
	-- Each system has its own name for the same machine.
	return ({x86_64 = "amd64", amd64 = "amd64", aarch64 = "arm64",
		 arm64 = "arm64", riscv64 = "riscv64"})[sys.uname().machine
							 or ""]
end

-- Where the system keeps a start-up object.
function M.crtpath(o, name)
	for _, dir in ipairs{"/usr/lib64", "/usr/lib/x86_64-linux-gnu",
			     "/usr/lib", "/lib64", "/usr/lib/gcc"} do
		local d = o.sysroot .. dir
		local f = io.open(d .. "/" .. name, "rb")

		if f then
			f:close()
			return d .. "/" .. name
		end
	end
	return nil
end

-- Which loader a hosted program asks for.  A sysroot may hold a libc
-- other than the one this machine runs, and musl puts its loader
-- where glibc does not.
function M.interpof(o)
	local m = M.MUSL[o.target]
	-- A sysroot is the root to look in.  With none, the machine this
	-- is running on is the root, but only for a program built for it:
	-- a cross build has nothing here to look at.
	local root = o.sysroot ~= "" and o.sysroot or
		(o.target == M.host() and "" or nil)

	if m and root then
		local f = io.open(root .. m)

		if f then
			f:close()
			return m
		end
	end
	return (M.INTERP[o.os] or {})[o.target]
end

return M
