// LuaJIT Bindings For Odin
// Author: Morikosm
// ©2025 Morikosm
// This software is up-to-date in 2025.
//
// As a trivial software binding, copyright may not apply. Where copyright might apply, this software is released under the BSD 3-Clause License.
//
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// 
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS “AS IS” AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package luajit

import "base:builtin"
import "base:intrinsics"
import "core:c/libc"
import "core:c"
foreign import lj "lua51.lib"

#assert(size_of(c.int) == size_of(b32))

//--------------------------------------------------------------------------------------------------
// Selected defines from LUACONF.
// Please align these with the luaconf.h you compile against.


// Size of Debug.short_src. Changing this breaks the Lua 5.1 ABI.
IDSIZE :: 60 

// Mike Pall can explain:
//
// Size of lauxlib and io.* on-stack buffers. Weird workaround to avoid using
// unreasonable amounts of stack space, but still retain ABI compatibility.
// Blame Lua for depending on BUFSIZ in the ABI, blame **** for wrecking it.
L_BUFFERSIZE :: 8192 when libc.BUFSIZ > 16384 else libc.BUFSIZ

//--------------------------------------------------------------------------------------------------

//--------------------------------------------------------------------------------------------------
// lua.h bindings
// Adapted from luajit/src/lua.h
// With help from https://github.com/odin-lang/Odin/blob/master/vendor/lua/5.1/lua.odin

VERSION 	:: "Lua 5.1"
RELEASE 	:: "Lua 5.1.4"
VERSION_NUM :: 501
COPYRIGHT 	:: "Copyright (C) 1994-2008 Lua.org, PUC-Rio"
AUTHORS 	:: "R. Ierusalimschy, L. H. de Figueiredo & W. Celes"

// Mark for precompiled code (`<esc>Lua`)
SIGNATURE 	:: "\033Lua"

// Option for multiple returns in `lua_pcall` and `lua_call`
MULTRET 	:: -1

// Pseudo-indices
REGISTRYINDEX 	:: -10000
ENVIRONINDEX 	:: -10001
GLOBALSINDEX 	:: -10002
upvalueindex :: #force_inline proc (i: c.int) -> c.int {
	return GLOBALSINDEX-i
}

// Thread Status
Status :: enum c.int {
	OK			= 0,
	YIELD		= 1,
	ERRRUN		= 2,
	ERRSYNTAX	= 3,
	ERRMEM		= 4,
	ERRERR		= 5,
	ERRFILE		= 6, // From lauxlibs
}

OK			:: Status.OK
YIELD		:: Status.YIELD
ERRRUN		:: Status.ERRRUN
ERRSYNTAX	:: Status.ERRSYNTAX
ERRMEM		:: Status.ERRMEM
ERRERR		:: Status.ERRERR
ERRFILE		:: Status.ERRFILE //From lauxlibs

State :: struct {}
CFunction :: #type proc "c" (L: ^State) -> c.int

// Functions that read/write blocks when loading/dumping Lua chunks
Reader :: #type proc "c" (L: ^State, ud: rawptr, sz: ^c.size_t) -> cstring
Writer :: #type proc "c" (L: ^State, p: rawptr, sz: c.size_t, ud: rawptr) -> c.int

// Prototype for memory-allocation functions
Alloc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize: c.size_t, nsize: c.size_t)

// Basic types
Type :: enum c.int {
	NONE          = -1,
	NIL           = 0,
	BOOLEAN       = 1,
	LIGHTUSERDATA = 2,
	NUMBER        = 3,
	STRING        = 4,
	TABLE         = 5,
	FUNCTION      = 6,
	USERDATA      = 7,
	THREAD        = 8,
}

TNONE 			:: Type.NONE
TNIL 			:: Type.NIL
TBOOLEAN 		:: Type.BOOLEAN
TLIGHTUSERDATA 	:: Type.LIGHTUSERDATA
TNUMBER 		:: Type.NUMBER
TSTRING 		:: Type.STRING
TTABLE 			:: Type.TABLE
TFUNCTION 		:: Type.FUNCTION
TUSERDATA 		:: Type.THREAD
NUMTYPES 		:: 9

// Minimum Lua stack available to a C function
MINSTACK :: 20

// Garbage-collection options
GCWhat :: enum c.int {
	STOP = 0,
	RESTART = 1,
	COLLECT = 2,
	COUNT = 3,
	COUNTB = 4,
	STEP = 5,
	SETPAUSE = 6,
	SETSTEPMUL = 7,
	// There is no 8
	ISRUNNING = 9,
}

GCSTOP :: GCWhat.STOP
GCRESTART :: GCWhat.RESTART
GCCOLLECT :: GCWhat.COLLECT
GCCOUNT :: GCWhat.COUNT
GCCOUNTB :: GCWhat.COUNTB
GCSTEP :: GCWhat.STEP
GCSETPAUSE :: GCWhat.SETPAUSE
GCSETSTEPMUL :: GCWhat.SETSTEPMUL
GCISRUNNING :: GCWhat.ISRUNNING

// Type of numbers in Lua
Number :: distinct (f32 when size_of(uintptr) == 4 else f64)

// Type for integer functions
Integer :: distinct (i32 when size_of(uintptr) == 4 else i64)

// Stack Index
Index :: distinct c.int

// Stack level
Level :: distinct c.int

// GCValue - varying meaning depending on GCWhat called in gc
GCValue :: distinct c.int

@(link_prefix="lua_")
@(default_calling_convention="c")
foreign lj {
	// State manipulation
	newstate	:: proc(f: Alloc, ud: rawptr)	-> ^State 	---
	close		:: proc(L: ^State)							---
	newthread	:: proc(L: ^State)				-> ^State	---

	atpanic		:: proc(L: ^State, 
		panicf: CFunction)						-> CFunction ---

	// Basic stack manipulation
	gettop		:: proc(L: ^State)				-> Index	---
	settop		:: proc(L: ^State, idx: Index)				---
	pushvalue	:: proc(L: ^State, idx: Index) 				---
	remove		:: proc(L: ^State, idx: Index) 				---
	insert		:: proc(L: ^State, idx: Index) 				---
	replace		:: proc(L: ^State, idx: Index) 				---
	checkstack	:: proc(L: ^State, sz: c.int)	-> b32		---

	xmove		:: proc(from, to: ^State, n: c.int) 		---

	// Access functions (stack -> C)

	isnumber	:: proc(L: ^State, idx: Index)	-> b32		---
	isstring	:: proc(L: ^State, idx: Index)	-> b32 		---
	iscfunction	:: proc(L: ^State, idx: Index)	-> b32 		---
	isuserdata	:: proc(L: ^State, idx: Index)	-> b32 		---
	type		:: proc(L: ^State, idx: Index)	-> Type 	---
	typename	:: proc(L: ^State, tp: Type)	-> cstring	---

	equal		:: proc(L: ^State, idx1, idx2: Index)	-> b32	---
	rawequal	:: proc(L: ^State, idx1, idx2: Index)	-> b32	---
	lessthan	:: proc(L: ^State, idx1, idx2: Index)	-> b32	---

	tonumber	:: proc(L: ^State, idx: Index)					-> Number		---
	tointeger	:: proc(L: ^State, idx: Index)					-> Integer		---
	toboolean	:: proc(L: ^State, idx: Index)					-> b32			---
	tolstring	:: proc(L: ^State, idx: Index, len: ^c.size_t)	-> cstring		---
	objlen		:: proc(L: ^State, idx: Index)					-> c.size_t		---
	tocfunction	:: proc(L: ^State, idx: Index)					-> CFunction	---
	touserdata	:: proc(L: ^State, idx: Index)					-> rawptr		---
	tothread	:: proc(L: ^State, idx: Index)					-> ^State		---
	topointer	:: proc(L: ^State, idx: Index)					-> rawptr		---

	// Push functions (C -> stack)

	pushnil				:: proc(L: ^State)													---
	pushnumber			:: proc(L: ^State, n: Number)										---
	pushinteger			:: proc(L: ^State, n: Integer)										---
	pushlstring			:: proc(L: ^State, s: cstring, l: c.size_t)							---
	pushstring			:: proc(L: ^State, s: cstring)										---
	pushvfstring		:: proc(L: ^State, fmt: cstring, argp: c.va_list)		-> cstring 	---
	pushfstring			:: proc(L: ^State, fmt: cstring, #c_vararg args: ..any)	-> cstring 	---
	pushcclosure		:: proc(L: ^State, fn: CFunction, n: c.int)							---
	pushboolean			:: proc(L: ^State, b: b32)											---
	pushlightuserdata	:: proc(L: ^State, p: rawptr)										---
	pushthread			:: proc(L: ^State)										-> Status	---

	// Get functions (Lua -> stack)

	gettable		:: proc(L: ^State, idx: Index)							---
	getfield		:: proc(L: ^State, idx: Index, k: cstring)				---
	rawget			:: proc(L: ^State, idx: Index)							---
	rawgeti			:: proc(L: ^State, idx: Index, n: Integer)				---
	createtable		:: proc(L: ^State, narr, nrec: c.int)					---
	newuserdata		:: proc(L: ^State, sz: c.size_t)			-> rawptr	---
	getmetatable	:: proc(L: ^State, objindex: Index)			-> b32		---
	getfenv			:: proc(L: ^State, idx: Index)							---

	// Set functions (stack -> Lua)

	settable		:: proc(L: ^State, idx: Index)						---
	setfield		:: proc(L: ^State, idx: Index, k: cstring)			---
	rawset			:: proc(L: ^State, idx: Index)						---
	rawseti			:: proc(L: ^State, idx: Index, n: c.int)			---
	setmetatable	:: proc(L: ^State, objindex: Index)		-> b32		---
	setfenv			:: proc(L: ^State, idx: Index)			-> Level	---

	// Load and call functions (load and run Lua code)
	call	:: proc(L: ^State, nargs, nresults: c.int)										---
	pcall	:: proc(L: ^State, nargs, nresults, errfunc: c.int)					-> Status	---
	cpcall	:: proc(L: ^State, func: CFunction, ud: rawptr)						-> Status	---
	load	:: proc(L: ^State, reader: Reader, dt: rawptr, chunkname: cstring)	-> Status	---
	dump	:: proc(L: ^State, writer: Writer, data: rawptr)					-> Status	---

	// Coroutine functions
	yield	:: proc(L: ^State, nresults: c.int)	-> b32 ---
	resume	:: proc(L: ^State, narg: c.int)		-> Status ---
	status	:: proc(L: ^State)					-> Status ---

	// Garbage-collection function and options
	gc :: proc(L: ^State, what: GCWhat, data: c.int) -> GCValue ---

	// Miscellaneous functions
	error		:: proc(L: ^State)						-> Status	---
	next		:: proc(L: ^State, idx: c.int)			-> b32	---
	concat		:: proc(L: ^State, n: c.int)						---
	getallocf	:: proc(L: ^State, ud: ^rawptr)			-> Alloc	---
	setallocf	:: proc(L: ^State, f: Alloc, ud: rawptr)			---
}

// Compatibility macros and functions

pop :: #force_inline proc "c" (L: ^State, n: Index) {
	settop(L, -n-1)
}

newtable :: #force_inline proc "c" (L: ^State) {
	createtable(L, 0, 0)
}

register :: #force_inline proc "c" (L: ^State, n: cstring, f: CFunction) {
	pushcfunction(L, f)
	setglobal(L, n)
}
pushcfunction :: #force_inline proc "c" (L: ^State, f: CFunction) {
	pushcclosure(L, f, 0)
}

strlen :: #force_inline proc "c" (L: ^State, i: Index) {
	objlen(L, i)
}

isfunction :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .FUNCTION
}

istable :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .TABLE
}

islightuserdata :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .LIGHTUSERDATA
}

isnil :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .NIL
}

isboolean :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .BOOLEAN
}

isthread :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .THREAD
}

isnone :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) == .NONE
}

isnoneornil :: #force_inline proc "c" (L: ^State, n: Index) -> b32 {
	return type(L, n) <= .NIL
}

tostring :: #force_inline proc "c" (L: ^State, i: Index) -> cstring {
	return tolstring(L, i, nil)
}

pushliteral :: #force_inline proc "c" (L: ^State, s: cstring) {
	pushlstring(L, s, size_of(s)/size_of(c.char)-1)
}

setglobal :: #force_inline proc "c" (L: ^State, s: cstring) {
	setfield(L, GLOBALSINDEX, (s))
}

getglobal :: #force_inline proc "c" (L: ^State, s: cstring) {
	getfield(L, GLOBALSINDEX, s)
}

// Compatability macros and functions 

open :: L_newstate

getregistry :: #force_inline proc "c" (L: ^State) {
	pushvalue(L, REGISTRYINDEX)
}

getgccount :: #force_inline proc "c" (L: ^State) {
	gc(L, GCCOUNT, 0)
}

Chunkreader :: Reader
Chunkwriter :: Writer

// hack

@(link_prefix="lua_")
@(default_calling_convention="c")
foreign lj {
	setlevel :: proc(from, to: ^State) ---
}

//--------------------------------------------------------------------------------------------------

//--------------------------------------------------------------------------------------------------
// Debug API

HookEvent :: enum c.int {
	CALL	= 0,
	RET		= 1,
	LINE	= 2,
	COUNT	= 3,
	TAILRET	= 4,
}
HOOKCALL	:: HookEvent.CALL
HOOKRET		:: HookEvent.RET
HOOKLINE	:: HookEvent.LINE
HOOKCOUNT	:: HookEvent.COUNT
HOOKTAILRET	:: HookEvent.TAILRET

HookMask	:: distinct bit_set[HookEvent; c.int]
MASKCALL	:: HookMask{.CALL}
MASKRET		:: HookMask{.RET}
MASKLINE	:: HookMask{.LINE}
MASKCOUNT	:: HookMask{.COUNT}

Debug :: struct {
	event:				HookEvent,	// (n)
	name:				cstring,	// (n) 'global', 'local', 'field', 'method'
	namewhat:			cstring,	// (S) `Lua', `C', `main', `tail'
	what:				cstring,	// (S)
	currentline:		c.int,		// (l)
	nups:				c.int,		// (u) number of upvalues
	linedefined:		c.int,		// (S)
	lastlinedefined:	c.int,		// (S)
	short_src:			[IDSIZE]c.char `fmt:"s"`, // (S)
	// private part
	i_ci:				c.int, // active function
}

// Functions to be called by the debugger in specific events
Hook :: #type proc "c" (L: ^State, ar: ^Debug)

@(link_prefix="lua_")
@(default_calling_convention="c")
foreign lj {
	getstack		:: proc(L: ^State, level: c.int, ar: ^Debug)		-> b32		---
	getinfo			:: proc(L: ^State, what: cstring, ar: ^Debug)		-> b32		---
	getlocal		:: proc(L: ^State, ar: ^Debug, n: c.int)			-> cstring	---
	setlocal		:: proc(L: ^State, ar: ^Debug, n: c.int)			-> cstring	---
	getupvalue		:: proc(L: ^State, funcindex, n: c.int)				-> cstring	---
	setupvalue		:: proc(L: ^State, funcindex, n: c.int)				-> cstring	---
	sethook			:: proc(L: ^State, func: Hook, mask, count: c.int)	-> HookMask	---
	gethook			:: proc(L: ^State)									-> Hook		---
	gethookmask		:: proc(L: ^State)									-> HookMask	---
	gethookcount	:: proc(L: ^State)									-> c.int	---

	// From Lua 5.2
	upvalueid		:: proc(L: ^State, idx, n: c.int)					-> rawptr	---
	upvaluejoin		:: proc(L: ^State, idx1, n1, idx2, n2: c.int)					---
	version			:: proc(L: ^State)									-> Number	---
	copy			:: proc(L: ^State, fromidx, toidx: c.int)						---
	tonumberx		:: proc(L: ^State, idx: c.int, isnum: ^c.int)		-> Number	---
	tointegerx		:: proc(L: ^State, idx: c.int, idnum: ^c.int)		-> Integer	---

	// From Lua 5.3
	isyieldable		:: proc(L: ^State)									-> b32		---
}

//--------------------------------------------------------------------------------------------------

//--------------------------------------------------------------------------------------------------
// lauxlib.h bindings
// Adapted from luajit/src/lauxlib.h

// Generic Buffer manipulation

L_Buffer :: struct {
	p: [^]byte, // Current position in the buffer
	lvl: c.int, // number of strings in the stack (level)
	L: ^State,
	buffer: [L_BUFFERSIZE]c.char,
}

L_Reg :: struct {
	name: cstring,
	func: CFunction
}

Ref :: enum c.int {
	NOREF = -2,
	REFNIL = -1,
}
NOREF	:: Ref.NOREF
REFNIL	:: Ref.REFNIL

@(link_prefix="lua")
@(default_calling_convention="c")
foreign lj {
	L_openlib		:: proc(L: ^State, libname: cstring, l: ^L_Reg, nup: int)			---
	L_register		:: proc(L: ^State, libname: cstring, l: ^L_Reg)						---
	L_getmetafield	:: proc(L: ^State, obj: c.int, e: cstring)				-> c.int	---
	L_callmeta		:: proc(L: ^State, obj: c.int, e: cstring)				-> c.int	---
	L_typerror		:: proc(L: ^State, narg: c.int, tname: cstring)			-> c.int	---
	L_argerror		:: proc(L: ^State, numarg: c.int, extramsg: cstring)	-> c.int	---
	L_checklstring	:: proc(L: ^State, numArg: c.int, l: ^c.size_t = nil)	-> cstring	---
	L_optlstring	:: proc(L: ^State, numArg: c.int, def: cstring,
		l: ^c.size_t = nil)													-> cstring	---
	
	L_checknumber	:: proc(L: ^State, numArg: c.int)						-> Number	---
	L_optnumber		:: proc(L: ^State, nArg: c.int, def: Number)			-> Number	---
	
	L_checkinteger	:: proc(L: ^State, numArg: c.int)						-> Integer	---
	L_optinteger	:: proc(L: ^State, nArg: c.int, def: Integer)			-> Integer	---
	
	L_checkstack	:: proc(L: ^State, sz: int, msg: cstring)							---
	L_checktype		:: proc(L: ^State, narg: c.int, t: Type)							---
	L_checkany		:: proc(L: ^State, narg: c.int)										---

	L_newmetatable	:: proc(L: ^State, tname: cstring)						-> c.int	---
	L_checkudata	:: proc(L: ^State, ud: int, tname: cstring)				-> rawptr	---
	
	L_where			:: proc(L: ^State, lvl: int)										---
	L_error			:: proc(L: ^State, fmt: cstring, #c_vararg args: ..any)	-> c.int	---

	L_checkoption	:: proc(L: ^State, narg: int, def: cstring,
		lst: [^]cstring)													-> c.int	---


	L_ref			:: proc(L: ^State, t: c.int)							-> Ref		---
	L_unref			:: proc(L: ^State, t, ref: c.int)									---

	L_loadfile		:: proc(L: ^State, filename: cstring)					-> Status	---
	L_loadbuffer	:: proc(L: ^State, buff: [^]byte, sz: c.size_t,
		name: cstring)														-> Status	---
	L_loadstring	:: proc(L: ^State, s: cstring)							-> Status	---

	L_newstate		:: proc()												-> ^State	---

	L_gsub			:: proc(L: ^State, s, p, r: cstring)					-> cstring	---
	L_findtable		:: proc(L: ^State, idx: int, fname: cstring,
		szhint: int)														-> cstring	---

	//From Lua 5.2
	L_fileresult	:: proc(L: ^State, stat: int, fname: cstring)			-> c.int	---
	L_execresult	:: proc(L: ^State, stat: int)							-> c.int	---
	L_loadfilex		:: proc(L: ^State, filename, mode: cstring)				-> Status	---
	L_loadbufferx	:: proc(L: ^State, buff: cstring, sz: c.size_t,
		name, mode: cstring)												-> Status	---
	L_traceback		:: proc(L, L1: ^State, msg: cstring, level: int)					---
	L_setfuncs		:: proc(L: ^State, l: [^]L_Reg, nup: int)							---
	L_pushmodule	:: proc(L: ^State, modname: cstring, sizehint: int)					---
	L_testudata		:: proc(L: ^State, ud: int, tname: cstring)				-> rawptr	---
	L_setmetatable	:: proc(L: ^State, tname: cstring)									---
}

// some useful macros

L_argcheck :: #force_inline proc "c" (L: ^State, cond: bool, numarg: c.int, extramsg: cstring) {
	if cond {
		L_argerror(L, numarg, extramsg)
	}
}

L_checkstring :: L_checklstring
L_optstring :: L_optlstring

L_typename :: #force_inline proc "c" (L: ^State, i: Index) -> cstring {
	return typename(L, type(L, i))
}

L_dofile :: #force_inline proc "c" (L: ^State, fn: cstring) -> Status {
	status := L_loadfile(L, fn)
	if status != .OK {
		return status
	}

	return pcall(L, 0, MULTRET, 0)
}

L_dostring :: #force_inline proc "c" (L: ^State, s: cstring) -> Status {
	status := L_loadstring(L, s)
	if status != .OK {
		return status
	}

	return pcall(L, 0, MULTRET, 0)
}

L_getmetatable :: #force_inline proc "c" (L: ^State, n: cstring) {
	getfield(L, REGISTRYINDEX, n)
}

L_opt :: #force_inline proc "c" (L: ^State, f: $F, n: Index, d: $T) -> T where intrinsics.type_is_proc(F) {
	return d if isnoneornil(L, n) else f(L, n)
}

L_newlibtable :: #force_inline proc "c" (L: ^State, l: []L_Reg) {
	createtable(L, 0, c.int(builtin.len(l) - 1))
}

L_newlib :: #force_inline proc "c" (L: ^State, l: []L_Reg) {
	L_newlibtable(L, l)
	L_setfuncs(L, raw_data(l), 0)
}

//--------------------------------------------------------------------------------------------------

//--------------------------------------------------------------------------------------------------
// lualib.h bindings
// Adapted from luajit/src/lualib.h

@(link_prefix="lua")
@(default_calling_convention="c")
foreign lj {
	open_base			:: proc(L: ^State) ---
	open_math			:: proc(L: ^State) ---
	open_string			:: proc(L: ^State) ---
	open_table			:: proc(L: ^State) ---
	open_io				:: proc(L: ^State) ---
	open_os				:: proc(L: ^State) ---
	open_package		:: proc(L: ^State) ---
	open_debug			:: proc(L: ^State) ---
	open_bit			:: proc(L: ^State) ---
	open_jit			:: proc(L: ^State) ---
	open_ffi			:: proc(L: ^State) ---
	open_string_buffer	:: proc(L: ^State) ---

	L_openlibs			:: proc(L: ^State) ---
}
//--------------------------------------------------------------------------------------------------
