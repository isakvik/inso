package notosu

// note(isak): generates a static HTML reference for the Lua API straight from the registration tables
// (lua_classes, luaapi_global_funcs, luaapi_enum_constants) so the function/class/enum list can never drift
// from what the engine actually registers.
//
// signatures and descriptions live in an external, hand-edited store (docs/lua_api_docs.ini) keyed by the
// call form, so regenerating the HTML never overwrites them. new functions get blank stubs appended to that
// file (existing entries are left untouched); entries with no matching function are reported as stale.
//
// run with:  notosu --gen-lua-docs   (generates docs/lua_api.html and exits before any window/audio init)

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

LUA_DOCS_OUTPUT_PATH :: "docs/lua_api.html"
LUA_DOCS_STORE_PATH :: "docs/lua_api_docs.ini"
LUA_DOCS_GEN_ARG :: "--gen-lua-docs"

// note(isak): called first thing in main. returns true if docs were requested, so main can exit early.
lua_generate_docs_if_requested :: proc() -> (requested: bool) {
    for arg in os.args {
        if arg == LUA_DOCS_GEN_ARG {
            requested = true
            break
        }
    }
    if !requested do return

    lua_generate_docs()
    return
}

lua_generate_docs :: proc() {
    store, _, _ := ini.load_map_from_path(LUA_DOCS_STORE_PATH, context.allocator) // empty map if the file is absent

    registered: map[string]bool   // every key we render, for stale-entry detection
    missing: [dynamic]string      // registered keys with no entry in the store yet

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    w :: strings.write_string

    w(&sb, LUA_DOCS_HTML_HEAD)
    fmt.sbprintf(&sb, "<h1>notosu Lua API</h1>\n")
    fmt.sbprintf(&sb, "<p class=\"note\">version %s &mdash; functions and enums are generated from the engine; ", VERSION)
    fmt.sbprintf(&sb, "signatures and descriptions come from <code>%s</code>.</p>\n", LUA_DOCS_STORE_PATH)

    // globals
    w(&sb, "<h2 id=\"globals\">Globals</h2>\n")
    w(&sb, "<p class=\"note\">free functions, called directly.</p>\n")
    lua_docs_write_table_open(&sb)
    for reg in luaapi_global_funcs {
        if reg.name == nil do continue
        lua_docs_write_row(&sb, store, fmt.tprint(reg.name), &registered, &missing)
    }
    lua_docs_write_table_close(&sb)

    // classes
    for class_type in Lua_Class_Type {
        class := lua_classes[class_type]
        if class.name == nil do continue

        fmt.sbprintf(&sb, "<h2 id=\"%s\">%s</h2>\n", class.name, class.name)
        lua_docs_write_table_open(&sb)

        for reg in class.static_funcs {
            if reg.name == nil || lua_docs_is_internal(reg.name) do continue
            lua_docs_write_row(&sb, store, fmt.tprintf("%s.%s", class.name, reg.name), &registered, &missing)
        }
        for reg in class.instance_funcs {
            if reg.name == nil || lua_docs_is_internal(reg.name) do continue
            lua_docs_write_row(&sb, store, fmt.tprintf("%s:%s", class.name, reg.name), &registered, &missing)
        }

        lua_docs_write_table_close(&sb)
    }

    // enums (members + values are authoritative from reflection, no external docs needed)
    w(&sb, "<h2 id=\"enums\">Enums</h2>\n")
    for e in luaapi_enum_constants {
        fmt.sbprintf(&sb, "<h3>%s</h3>\n", e.name)
        names  := reflect.enum_field_names(e.t)
        values := reflect.enum_field_values(e.t)
        w(&sb, "<table class=\"enum\">\n<thead><tr><th>Constant</th><th>Value</th></tr></thead>\n<tbody>\n")
        for name, i in names {
            fmt.sbprintf(&sb, "<tr><td><code>%s.%s</code></td><td>%d</td></tr>\n", e.name, name, i64(values[i]))
        }
        w(&sb, "</tbody>\n</table>\n")
    }

    w(&sb, LUA_DOCS_HTML_TAIL)

    _ = os.make_directory("docs")

    if err := os.write_entire_file(LUA_DOCS_OUTPUT_PATH, transmute([]byte)strings.to_string(sb)); err != os.General_Error.None {
        fmt.eprintfln("[lua-docs] failed to write %s: %v", LUA_DOCS_OUTPUT_PATH, err)
        return
    }
    fmt.printfln("[lua-docs] wrote %s", LUA_DOCS_OUTPUT_PATH)

    // append blank stubs for any newly-registered functions so they're easy to find and fill in
    if len(missing) > 0 {
        lua_docs_append_stubs(missing[:])
    }

    // report doc entries that no longer match a registered function
    for section in store {
        if section == "" do continue
        if section not_in registered {
            fmt.printfln("[lua-docs] stale doc entry (no such function): %s", section)
        }
    }
}

lua_docs_write_row :: proc(
    sb: ^strings.Builder, store: ini.Map, key: string,
    registered: ^map[string]bool, missing: ^[dynamic]string,
) {
    registered[key] = true

    signature, description: string
    if section, ok := store[key]; ok {
        signature = section["signature"]
        description = section["description"]
    } else {
        append(missing, key)
    }

    w :: strings.write_string
    w(sb, "<tr><td><code>")
    lua_docs_escape(sb, key)
    w(sb, "</code></td>")
    lua_docs_write_cell(sb, signature)
    lua_docs_write_cell(sb, description)
    w(sb, "</tr>\n")
}

lua_docs_write_cell :: proc(sb: ^strings.Builder, text: string) {
    if text == "" {
        strings.write_string(sb, "<td class=\"todo\">TODO</td>")
        return
    }
    strings.write_string(sb, "<td>")
    lua_docs_escape(sb, text)
    strings.write_string(sb, "</td>")
}

// note(isak): append-only - writes blank stub sections for new keys without touching existing entries, so
// hand-written signatures/descriptions are never lost on regeneration
lua_docs_append_stubs :: proc(keys: []string) {
    existing, _ := os.read_entire_file(LUA_DOCS_STORE_PATH, context.allocator)

    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    strings.write_bytes(&sb, existing)
    if len(existing) > 0 && existing[len(existing) - 1] != '\n' {
        strings.write_byte(&sb, '\n')
    }
    for key in keys {
        fmt.sbprintf(&sb, "\n[%s]\nsignature = \ndescription = \n", key)
    }

    if err := os.write_entire_file(LUA_DOCS_STORE_PATH, transmute([]byte)strings.to_string(sb)); err != os.General_Error.None {
        fmt.eprintfln("[lua-docs] failed to write stubs to %s: %v", LUA_DOCS_STORE_PATH, err)
        return
    }
    fmt.printfln("[lua-docs] added %d stub entr%s to %s (fill them in)",
        len(keys), len(keys) == 1 ? "y" : "ies", LUA_DOCS_STORE_PATH)
}

// note(isak): metamethods like __gc / __index aren't part of the scripting surface
lua_docs_is_internal :: proc(name: cstring) -> bool {
    s := string(name)
    return len(s) >= 2 && s[0] == '_' && s[1] == '_'
}

lua_docs_escape :: proc(sb: ^strings.Builder, s: string) {
    for r in s {
        switch r {
        case '&': strings.write_string(sb, "&amp;")
        case '<': strings.write_string(sb, "&lt;")
        case '>': strings.write_string(sb, "&gt;")
        case:     strings.write_rune(sb, r)
        }
    }
}

lua_docs_write_table_open :: proc(sb: ^strings.Builder) {
    strings.write_string(sb,
        "<table>\n<thead><tr><th>Function</th><th>Signature</th><th>Description</th></tr></thead>\n<tbody>\n")
}

lua_docs_write_table_close :: proc(sb: ^strings.Builder) {
    strings.write_string(sb, "</tbody>\n</table>\n")
}

LUA_DOCS_HTML_HEAD :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>notosu Lua API</title>
<style>
  :root { --bg:#1b1d23; --panel:#23262e; --line:#363a45; --text:#dfe3ea; --muted:#8b91a0; --accent:#7fb3ff; --code:#c8e1ff; }
  * { box-sizing: border-box; }
  body { margin: 0 auto; max-width: 980px; padding: 2rem 1.25rem 4rem;
         font: 15px/1.55 system-ui, sans-serif; background: var(--bg); color: var(--text); }
  h1 { font-size: 1.8rem; margin: 0 0 .25rem; }
  h2 { margin: 2.4rem 0 .6rem; padding-bottom: .3rem; border-bottom: 1px solid var(--line); color: var(--accent); }
  h3 { margin: 1.4rem 0 .4rem; color: var(--text); }
  p.note { color: var(--muted); margin: .2rem 0 1rem; }
  code { font-family: ui-monospace, "Cascadia Code", Menlo, Consolas, monospace; color: var(--code); }
  table { width: 100%; border-collapse: collapse; margin: .5rem 0 1rem; background: var(--panel); }
  th, td { text-align: left; padding: .5rem .7rem; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--muted); font-weight: 600; font-size: .82rem; text-transform: uppercase; letter-spacing: .04em; }
  tr:last-child td { border-bottom: none; }
  td.todo { color: var(--muted); font-style: italic; }
  table.enum td:nth-child(2) { font-family: ui-monospace, monospace; color: var(--muted); width: 6rem; }
</style>
</head>
<body>
`

LUA_DOCS_HTML_TAIL :: `</body>
</html>
`
