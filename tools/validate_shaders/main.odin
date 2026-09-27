package validate_shaders

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "base:runtime"
import posix "core:sys/posix"

// note(isak): validates every shader pair declared by the [Shaders] sections of all .inso files
// under a songs dir, using Khronos glslang (tools/glslang). glslang implements the spec strictly,
// so it rejects what AMD/Intel reject but NVIDIA tolerates: const initializers that aren't
// constant expressions, unknown extensions, vs/fs interface mismatches, undeclared identifiers.
//
// usage: validate_shaders [songs dir]   (default: songs)
//
// glslang binary resolution order:
//   1. $INSO_GLSLANG
//   2. next to this exe (glslang / glslang.exe)
//   3. <exe dir>/../tools/glslang/{linux|windows}/glslang[.exe]
//   4. PATH (glslang, glslangValidator)

Shader_Pair :: struct {
	mapset: string,
	name:   string,
	vs:     string,
	fs:     string,
}

join :: proc(elems: []string) -> string {
	path, _ := filepath.join(elems, context.temp_allocator)
	return path
}

find_glslang :: proc() -> string {
	if env := os.get_env_alloc("INSO_GLSLANG", context.allocator); env != "" {
		if os.is_file(env) do return env
	}

	exe_dir := filepath.dir(os.args[0])
	os_suffix := "linux" if ODIN_OS != .Windows else "windows"
	candidates := []string{
		join({exe_dir, "glslang"}),
		join({exe_dir, "glslang.exe"}),
		join({exe_dir, "glslangValidator"}),
		join({exe_dir, "tools", "glslang", os_suffix, "glslang"}),
		join({exe_dir, "tools", "glslang", os_suffix, "glslang.exe"}),
		"glslang",
		"glslangValidator",
	}
	for c in candidates {
		if os.is_file(c) do return c
	}
	return ""
}

run_glslang :: proc(exe: string, args: []string) -> (output: string, failed: bool) {
	full := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&full, exe)
	append(&full, ..args)

	desc := os.Process_Desc{command = full[:]}
	state, stdout, stderr, err := os.process_exec(desc, context.allocator)
	if err != nil {
		// note(isak): pidfd_open needs kernel >= 5.3; WSL1 is on 4.4, so os.process_exec
		// can't wait there. fall back to plain fork/exec/waitpid.
		if ODIN_OS != .Windows && err == .Unsupported {
			return run_glslang_fork(full[:])
		}
		return fmt.aprintf("spawning '%s' failed: %v", exe, err), true
	}
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)

	out := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&out, stdout)
	strings.write_bytes(&out, stderr)
	return strings.to_string(out), !state.success || state.exit_code != 0
}

run_glslang_fork :: proc(argv_list: []string) -> (output: string, failed: bool) {
	argv: [dynamic]cstring
	append(&argv, strings.clone_to_cstring(argv_list[0], context.temp_allocator))
	for a in argv_list[1:] do append(&argv, strings.clone_to_cstring(a, context.temp_allocator))
	append(&argv, nil)
	argv_data := raw_data(argv)

	// note(isak): built before fork, since the child must only run
	// async-signal-safe calls (no allocators) in a multithreaded process.
	exe_cstr := strings.clone_to_cstring(argv_list[0], context.temp_allocator)
	out_fds: [2]posix.FD
	err_fds: [2]posix.FD
	if posix.pipe(&out_fds) != posix.result.OK || posix.pipe(&err_fds) != posix.result.OK {
		return "pipe() failed", true
	}

	pid := posix.fork()
	if pid < 0 {
		return "fork() failed", true
	}
	if pid == 0 {
		posix.dup2(out_fds[1], posix.STDOUT_FILENO)
		posix.dup2(err_fds[1], posix.STDERR_FILENO)
		posix.close(out_fds[0])
		posix.close(out_fds[1])
		posix.close(err_fds[0])
		posix.close(err_fds[1])
		posix.execv(exe_cstr, argv_data)
		posix._exit(127)
	}

	posix.close(out_fds[1])
	posix.close(err_fds[1])

	buf := make([]u8, 8192, context.temp_allocator)
	out := strings.builder_make(context.temp_allocator)
	for {
		n := posix.read(out_fds[0], &buf[0], len(buf))
		if n <= 0 do break
		strings.write_bytes(&out, buf[:n])
	}
	for {
		n := posix.read(err_fds[0], &buf[0], len(buf))
		if n <= 0 do break
		strings.write_bytes(&out, buf[:n])
	}
	posix.close(out_fds[0])
	posix.close(err_fds[0])

	status: c.int
	posix.waitpid(pid, &status, {})
	exit_code := 1
	if posix.WIFEXITED(status) do exit_code = int(posix.WEXITSTATUS(status))
	return strings.to_string(out), exit_code != 0}

Validation_Result :: struct {
	ok:      bool,
	details: string,
}

validate_pair :: proc(glslang: string, pair: Shader_Pair, tmp: string, index: int) -> (result: Validation_Result) {
	name := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&name, "map_%d", index)
	vert := join({tmp, strings.concatenate({strings.to_string(name), ".vert"}, context.temp_allocator)})
	frag := join({tmp, strings.concatenate({strings.to_string(name), ".frag"}, context.temp_allocator)})

	if cerr := os.copy_file(vert, pair.vs); cerr != nil {
		return Validation_Result{details = fmt.aprintf("can't copy '%s': %v", pair.vs, cerr)}
	}
	if cerr := os.copy_file(frag, pair.fs); cerr != nil {
		return Validation_Result{details = fmt.aprintf("can't copy '%s': %v", pair.fs, cerr)}
	}

	variant_args := [][]string{
		{"--quiet", "-l", vert, frag},
		{"--quiet", "-l", "--define-macro", "BINDLESS=1", vert, frag},
	}
	variant_names := []string{"non-bindless", "bindless"}

	details := strings.builder_make(runtime.heap_allocator())
	result.ok = true
	for v, i in variant_args {
		output, failed := run_glslang(glslang, v)
		if failed {
			result.ok = false
			fmt.sbprintf(&details, "failed ({})\n", variant_names[i])
			if strings.trim_space(output) != "" {
				for line in strings.split_lines(output) {
					fmt.sbprintf(&details, "  {}\n", line)
				}
			}
		}
	}
	result.details = strings.to_string(details)
	return
}

Worker_Context :: struct {
	glslang: string,
	pairs:   []Shader_Pair,
	tmp:     string,
	results: []Validation_Result,
	next:    int,
	mu:      sync.Mutex,
}

worker :: proc(data: rawptr) {
	ctx := (^Worker_Context)(data)
	for {
		sync.mutex_lock(&ctx.mu)
		i := ctx.next
		ctx.next += 1
		sync.mutex_unlock(&ctx.mu)

		if i >= len(ctx.pairs) do break
		ctx.results[i] = validate_pair(ctx.glslang, ctx.pairs[i], ctx.tmp, i)
	}
}

Section :: enum {
	NONE,
	SHADERS,
}

collect_pairs :: proc(songs_dir: string) -> [dynamic]Shader_Pair {
	pairs: [dynamic]Shader_Pair

	walker := os.walker_create_path(songs_dir)
	for info, ok := os.walker_walk(&walker); ok; info, ok = os.walker_walk(&walker) {
		if info.type != .Directory && strings.ends_with(strings.to_lower(info.name), ".inso") {
			collect_from_inso(&pairs, info.fullpath)
		}
	}

	return pairs
}

collect_from_inso :: proc(pairs: ^[dynamic]Shader_Pair, inso_path: string) {
	data, err := os.read_entire_file_from_path(inso_path, context.allocator)
	if err != nil do return
	defer delete(data)
	mapset_dir := filepath.dir(inso_path)
	section := Section.NONE

	name, vs, fs: string
	flush := proc(pairs: ^[dynamic]Shader_Pair, mapset_dir, name, vs, fs: string) {
		if name == "" || vs == "" || fs == "" do return
		append(pairs, Shader_Pair{
			mapset = strings.clone(filepath.base(mapset_dir), context.allocator),
			name   = strings.clone(name, context.allocator),
			vs     = strings.clone(vs, context.allocator),
			fs     = strings.clone(fs, context.allocator),
		})
	}

	root := filepath.dir(filepath.dir(inso_path))
	for i := 0; i < 3; i += 1 {
		if os.is_dir(join({root, "shaders"})) {
			break
		}
		parent := filepath.dir(root)
		if parent == root do break
		root = parent
	}

	for line in strings.split_lines(string(data)) {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue

		if strings.has_prefix(trimmed, "[[" ) && strings.has_suffix(trimmed, "]]") {
			if section == .SHADERS {
				flush(pairs, mapset_dir, name, vs, fs)
			}
			name, vs, fs = trimmed[2:len(trimmed)-2], "", ""
			continue
		}
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			if section == .SHADERS {
				flush(pairs, mapset_dir, name, vs, fs)
			}
			section = .SHADERS if trimmed == "[Shaders]" else .NONE
			name, vs, fs = "", "", ""
			continue
		}

		split := strings.split(trimmed, ":")
		if len(split) < 2 || section != .SHADERS do continue
		key := strings.trim_space(split[0])
		value := strings.trim_space(strings.join(split[1:], ":"))

		switch key {
		case "VertexShader":
			vs = resolve_shader_path(root, mapset_dir, value, true)
		case "FragmentShader":
			fs = resolve_shader_path(root, mapset_dir, value, false)
		}
	}
	flush(pairs, mapset_dir, name, vs, fs)
}

resolve_shader_path :: proc(root, mapset_dir, value: string, is_vertex: bool) -> string {
	switch value {
	case "builtin.quad":
		return join({root, "shaders", "quad.vs.glsl" if is_vertex else "quad.fs.glsl"})
	case "builtin.slider":
		return join({root, "shaders", "slider.vs.glsl" if is_vertex else "slider.fs.glsl"})
	case "builtin.text":
		return join({root, "shaders", "text.vs.glsl" if is_vertex else "text.fs.glsl"})
	case "builtin.slider_present":
		if is_vertex {
			return join({root, "shaders", "quad.vs.glsl"})
		}
		return join({root, "shaders", "slider_present.fs.glsl"})
	case:
		return join({mapset_dir, value})
	}
}

main :: proc() {
	songs_dir := "songs"
	if len(os.args) > 1 do songs_dir = os.args[1]

	glslang := find_glslang()
	if glslang == "" {
		fmt.eprintln("glslang not found. set $INSO_GLSLANG or place it under tools/glslang/<platform>/")
		os.exit(1)
	}

	version, _ := run_glslang(glslang, {"--version"})
	first_line := strings.trim_space(strings.split_lines(version)[0] if len(strings.split_lines(version)) > 0 else "")
	fmt.printfln("validator: {} ({})", first_line, glslang)
	fmt.printfln("scanning:  {}", songs_dir)

	pairs := collect_pairs(songs_dir)
	if len(pairs) == 0 {
		fmt.eprintln("no [Shaders] pairs found under", songs_dir)
		os.exit(1)
	}

	tmp := join({filepath.dir(os.args[0]), "shader_validate_tmp"})
	os.make_directory(tmp)

	results := make([]Validation_Result, len(pairs))
	ctx := Worker_Context{
		glslang = glslang,
		pairs   = pairs[:],
		tmp     = tmp,
		results = results,
	}
	n_workers := min(4, len(pairs))
	threads := make([]^thread.Thread, n_workers)
	for i in 0 ..< n_workers {
		threads[i] = thread.create_and_start_with_data(&ctx, worker)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	failed: int
	for pair, i in pairs {
		if results[i].ok {
			fmt.printfln("[{}] {}: ok", pair.mapset, pair.name)
		} else {
			failed += 1
			fmt.eprintfln("[{}] {}: FAILED", pair.mapset, pair.name)
			fmt.eprint(results[i].details)
		}
		delete(results[i].details, runtime.heap_allocator())
	}
	os.remove_all(tmp)

	fmt.printfln("{} shader(s), {} failed", len(pairs), failed)
	os.exit(1 if failed > 0 else 0)
}
