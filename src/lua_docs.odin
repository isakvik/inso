package notosu

// note(isak): generates a static HTML reference for the Lua API straight from the registration tables
// (lua_classes, luaapi_global_funcs, luaapi_enum_constants). signatures and descriptions live inline on each
// Lua_Reg entry.

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

LUA_DOCS_OUTPUT_PATH :: "docs/lua_api.html"
LUA_DOCS_GEN_ARG :: "--gen-lua-docs"

lua_generate_docs :: proc() {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    w :: fmt.sbprintln
    wf :: fmt.sbprintfln

    w(&sb, LUA_DOCS_HTML_HEAD)
    wf(&sb, "<h1>Lua API for inso v%s</h1>", VERSION)
    wf(&sb, "<p class=\"note\">Documentation automatically generated from the engine's registration tables</p>")
    wf(&sb, "<p class=\"note\">A method with return type <span class=\"sig s\">self</span> returns its own object, so calls can be chained.</p>")

    // table of contents
    w(&sb, "<nav class=\"toc\">")
    w(&sb, "<a href=\"#events\">Events</a>")
    w(&sb, "<a href=\"#globals\">Globals</a>")
    for class_type in Lua_Class_Type {
        class := lua_classes[class_type]
        if class.name == nil do continue
        wf(&sb, "<a href=\"#%s\">%s</a>", class.name, class.name)
    }
    w(&sb, "<a href=\"#enums\">Enums</a>")
    w(&sb, "</nav>")

    // events (engine -> script callbacks)
    lua_docs_write_heading(&sb, "events", "Events")
    w(&sb, "<p class=\"note\">Callbacks the engine invokes on your script. Define the ones you need as global functions; undefined ones are skipped.</p>")
    lua_docs_write_table_open(&sb)
    for event in Lua_Beatmap_Event_Type {
        doc := lua_beatmap_event_docs[event]
        reg := Lua_Function{
            name        = lua_beatmap_event_names[event],
            signature   = doc.signature,
            description = doc.description,
        }
        lua_docs_write_row(&sb, reg, string(lua_beatmap_event_names[event]))
    }
    lua_docs_write_table_close(&sb)

    // globals
    lua_docs_write_heading(&sb, "globals", "Globals")
    w(&sb, "<p class=\"note\">Free functions, called directly.</p>")
    lua_docs_write_table_open(&sb)
    for reg in luaapi_global_funcs {
        lua_docs_write_row(&sb, reg, fmt.tprint(reg.name))
    }
    lua_docs_write_table_close(&sb)

    // classes
    for class_type in Lua_Class_Type {
        class := lua_classes[class_type]
        if class.name == nil do continue

        lua_docs_write_heading(&sb, string(class.name), string(class.name))
        lua_docs_write_table_open(&sb)

        for reg in class.static_funcs {
            if lua_docs_is_internal(reg.name) do continue
            lua_docs_write_row(&sb, reg, fmt.tprintf("%s.%s", class.name, reg.name))
        }
        for reg in class.instance_funcs {
            if lua_docs_is_internal(reg.name) do continue
            lua_docs_write_row(&sb, reg, fmt.tprintf("%s:%s", class.name, reg.name))
        }

        lua_docs_write_table_close(&sb)
    }

    // enums
    lua_docs_write_heading(&sb, "enums", "Enums")
    for e in luaapi_enum_constants {
        wf(&sb, "<h3>%s</h3>", e.name)
        names  := reflect.enum_field_names(e.t)
        values := reflect.enum_field_values(e.t)
        w(&sb, "<table class=\"enum\">\n<thead><tr><th>Constant</th><th>Value</th></tr></thead>\n<tbody>\n")
        for name, i in names {
            wf(&sb, "<tr><td><code>%s.%s</code></td><td>%d</td></tr>", e.name, name, i64(values[i]))
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

    lua_docs_report_missing(luaapi_global_funcs, "")
    for class_type in Lua_Class_Type {
        class := lua_classes[class_type]
        if class.name == nil do continue
        lua_docs_report_missing(class.static_funcs, fmt.tprintf("%s.", class.name))
        lua_docs_report_missing(class.instance_funcs, fmt.tprintf("%s:", class.name))
    }
}

lua_docs_write_heading :: proc(sb: ^strings.Builder, id: string, title: string) {
    fmt.sbprintfln(sb, "<h2 id=\"%s\"><a class=\"hlink\" href=\"#%s\">%s <span class=\"htarget\">#</span></a></h2>", id, id, title)
}

lua_docs_report_missing :: proc(regs: []Lua_Function, key_prefix: string) {
    for reg in regs {
        if lua_docs_is_internal(reg.name) do continue
        if reg.signature == "" || reg.description == "" {
            fmt.printfln("[lua-docs] TODO: %s%s is missing a signature or description", key_prefix, reg.name)
        }
    }
}

lua_docs_write_row :: proc(sb: ^strings.Builder, reg: Lua_Function, key: string) {
    signature := reg.signature if reg.signature != "" else key

    w :: strings.write_string
    w(sb, "<tr><td><code class=\"sig\">")
    lua_docs_write_signature(sb, signature)
    w(sb, "</code>")
    if reg.description != "" {
        w(sb, "<div class=\"desc\">")
        lua_docs_escape(sb, reg.description)
        w(sb, "</div>")
    }
    w(sb, "</td></tr>\n")
}

// note(isak): tokenizes a signature and wraps each token in a span classed by role, so the css can color
// types / method names / receivers / args distinctly. the format is regular - "<ret> recv:method( params )" -
// so a single-token lookaround is enough: an identifier before a ':' or '.' is the receiver, one after is the
// method name, otherwise it's a known/Capitalized type or an argument name.
lua_docs_write_signature :: proc(sb: ^strings.Builder, sig: string) {
    Tok_Kind :: enum { SPACE, IDENT, NUM, SYM }
    Tok :: struct { text: string, kind: Tok_Kind }

    is_space  :: proc(c: byte) -> bool { return c == ' ' || c == '\t' }
    is_digit  :: proc(c: byte) -> bool { return c >= '0' && c <= '9' }
    is_ident0 :: proc(c: byte) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
    is_identc :: proc(c: byte) -> bool { return is_ident0(c) || is_digit(c) }

    toks := make([dynamic]Tok, context.temp_allocator)
    i := 0
    for i < len(sig) {
        c, start := sig[i], i
        switch {
        case is_space(c):
            for i < len(sig) && is_space(sig[i]) do i += 1
            append(&toks, Tok{ sig[start:i], .SPACE })
        case is_digit(c):
            for i < len(sig) && (is_digit(sig[i]) || sig[i] == '.') do i += 1
            append(&toks, Tok{ sig[start:i], .NUM })
        case is_ident0(c):
            for i < len(sig) && is_identc(sig[i]) do i += 1
            append(&toks, Tok{ sig[start:i], .IDENT })
        case:
            i += 1
            append(&toks, Tok{ sig[start:i], .SYM })
        }
    }

    adjacent_symbol :: proc(toks: []Tok, idx, step: int) -> (text: string, is_sym: bool) {
        for j := idx + step; j >= 0 && j < len(toks); j += step {
            if toks[j].kind == .SPACE do continue
            return toks[j].text, toks[j].kind == .SYM
        }
        return "", false
    }

    for tok, idx in toks {
        if tok.kind == .SPACE {
            strings.write_string(sb, tok.text)
            continue
        }

        class: string
        switch tok.kind {
        case .NUM:   class = "number"
        case .SYM:   class = "punctuation"
        case .SPACE:
        case .IDENT:
            prev_text, prev_is_sym := adjacent_symbol(toks[:], idx, -1)
            next_text, next_is_sym := adjacent_symbol(toks[:], idx, +1)
            switch {
            case next_is_sym && (next_text == ":" || next_text == "."): class = "receiver"
            case prev_is_sym && (prev_text == ":" || prev_text == "."): class = "function"
            case next_is_sym && next_text == "(":                       class = "function"
            case tok.text == "self":                                    class = "self"
            case tok.text == "fn":                                      class = "callback"
            case lua_docs_is_type_token(tok.text):                      class = "type"
            case:                                                       class = "argument"
            }
        }

        fmt.sbprintf(sb, "<span class=\"%s\">", class)
        lua_docs_escape(sb, tok.text)
        strings.write_string(sb, "</span>")
    }
}

lua_docs_is_type_token :: proc(s: string) -> bool {
    switch s {
    case "void", "int", "float", "bool", "string", "table", "any": return true
    }
    return len(s) > 0 && s[0] >= 'A' && s[0] <= 'Z'
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
        "<table>\n<thead><tr><th>Method</th></tr></thead>\n<tbody>\n")
}

lua_docs_write_table_close :: proc(sb: ^strings.Builder) {
    strings.write_string(sb, "</tbody>\n</table>\n")
}

LUA_DOCS_HTML_HEAD :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>inso Lua API</title>
<style>
  :root { --bg:#181518; --panel:#1e1b23; --line:#9d8edc40; --text:#ccdcff; --muted:#8b91a0; --accent:#79a6f4; }
  * { box-sizing: border-box; }
  body { margin: 0 auto; max-width: 980px; padding: 2rem 1.25rem 4rem;
         font: 15px/1.55 system-ui, sans-serif; background: var(--bg); color: var(--text); }
  h1 { font-size: 1.8rem; margin: 0 0 .25rem; }
  h2 { margin: 2.4rem 0 .6rem; padding-bottom: .3rem; border-bottom: 1px solid var(--line); color: var(--accent); scroll-margin-top: 1rem; }
  h3 { margin: 1.4rem 0 .4rem; color: var(--text); }
  h2 a.hlink { color: inherit; text-decoration: none; display: inline-block; }
  h2 a.hlink .htarget { color: var(--muted); font-weight: 400; opacity: 0; }
  h2 a.hlink:hover .htarget { opacity: 1; }
  p.note { color: var(--muted); margin: .2rem 0 1rem; }
  nav.toc { display: flex; flex-wrap: wrap; gap: .4rem; margin: 1.2rem 0 2rem; }
  nav.toc a { color: var(--accent); text-decoration: none; background: var(--panel);
              border-radius: .4rem; padding: .2rem .6rem; font-size: .85rem; }
  nav.toc a:hover { text-decoration: underline; }
  code { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; color: var(--code); }
  table { width: 100%; border-collapse: collapse; margin: .5rem 0 1rem; background: var(--panel); }
  th, td { text-align: left; padding: .5rem .7rem; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--muted); font-weight: 600; font-size: .82rem; text-transform: uppercase; letter-spacing: .04em; }
  tr:last-child td { border-bottom: none; }
  code.sig { display: block; line-height: 1.7; }
  code.sig .type { color: rgb(86, 156, 214); }
  code.sig .self { color: rgb(190, 150, 225); }
  code.sig .function { color: rgb(220, 220, 170); font-weight: 600; }
  code.sig .receiver { color: rgb(156, 220, 254); }
  code.sig .argument { color: #dfe3ea; }
  code.sig .callback { color: rgb(200, 150, 225); }
  code.sig .number { color: #e0a071; }
  code.sig .punctuation { color: rgb(150, 140, 160); }
  .desc { color: var(--muted); margin-top: .35rem; }
  table.enum td:nth-child(2) { font-family: ui-monospace, monospace; color: var(--muted); width: 6rem; }
</style>
</head>
<body>
`

LUA_DOCS_HTML_TAIL :: `</body>
</html>
`
