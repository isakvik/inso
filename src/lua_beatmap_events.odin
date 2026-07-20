package inso

import "core:strings"
import lua "luajit"
import sdl "vendor:sdl3"


Lua_Beatmap_Event_Type :: enum {
    ON_INIT,
    ON_UPDATE,
    ON_FIXED_UPDATE,
    ON_BEAT,
    ON_TIMING_CHANGE,
    ON_PAUSE_CHANGE,
    ON_CONTROLLER_PRESSED,
    ON_CONTROLLER_RELEASED,
    ON_KEY_DOWN,
    ON_KEY_UP,
    ON_CURSOR_MOVED,
    ON_JUDGEMENT,
    VALIDATE_JUDGEMENT,
    ON_KIAI_CHANGE,
    ON_COMBO_BREAK,
    ON_MAP_COMPLETE,
}
lua_beatmap_event_names := [Lua_Beatmap_Event_Type]cstring {
    .ON_INIT = "on_init",
    .ON_UPDATE = "on_update",
    .ON_FIXED_UPDATE = "on_fixed_update",
    .ON_BEAT = "on_beat",
    .ON_TIMING_CHANGE = "on_timing_change",
    .ON_PAUSE_CHANGE = "on_pause_change",
    .ON_CONTROLLER_PRESSED = "on_controller_pressed",
    .ON_CONTROLLER_RELEASED = "on_controller_released",
    .ON_KEY_DOWN = "on_key_pressed",
    .ON_KEY_UP = "on_key_released",
    .ON_CURSOR_MOVED = "on_cursor_moved",
    .ON_JUDGEMENT = "on_judgement",
    .VALIDATE_JUDGEMENT = "validate_judgement",
    .ON_KIAI_CHANGE = "on_kiai_change",
    .ON_COMBO_BREAK = "on_combo_break",
    .ON_MAP_COMPLETE = "on_map_complete",
}

Lua_Beatmap_Event_Doc :: struct {
    signature:   string,
    description: string,
}
lua_beatmap_event_docs := [Lua_Beatmap_Event_Type]Lua_Beatmap_Event_Doc {
    .ON_INIT = {
        "void on_init( void )",
        "called once after the beatmap loads, before play. events scheduled in on_init replay when seeking backwards.",
    },
    .ON_UPDATE = {
        "void on_update( float music_time_ms )",
        "called once per rendered frame. framerate-dependent and is not re-run when seeking.",
    },
    .ON_FIXED_UPDATE = {
        "void on_fixed_update( float music_time_ms )",
        "called at a fixed rate in music time, decoupled from framerate. useful for simulation logic as it catches up in a loop on forward seek and replays deterministically. the rate is customizable by setting FixedUpdateRate in the inso file. " +
        "note: if this is declared, the engine will call scheduled events using the fixed update timer for consistency.",
    },
    .ON_BEAT = {
        "void on_beat( int beat )",
        "called when the music time crosses a beat of the active uninherited timing point.",
    },
    .ON_TIMING_CHANGE = {
        "void on_timing_change( int beat, float bpm )",
        "called when a new uninherited timing point becomes active.",
    },
    .ON_PAUSE_CHANGE = {
        "void on_pause_change( bool paused )",
        "called when playback is paused or resumed.",
    },
    .ON_CONTROLLER_PRESSED = {
        "void on_controller_pressed( string key )",
        "called when a gameplay key goes down. key is one of \"k1\", \"k2\", \"m1\", \"m2\".",
    },
    .ON_CONTROLLER_RELEASED = {
        "void on_controller_released( string key )",
        "called when a gameplay key goes up. key is one of \"k1\", \"k2\", \"m1\", \"m2\".",
    },
    .ON_KEY_DOWN = {
        "void on_key_pressed( string key )",
        "called when a keyboard key goes down. key is the SDL3 scancode name.",
    },
    .ON_KEY_UP = {
        "void on_key_released( string key )",
        "called when a keyboard key goes up. key is the SDL3 scancode name.",
    },
    .ON_CURSOR_MOVED = {
        "void on_cursor_moved( float x, float y )",
        "called when the cursor moves, with the new position in screen pixels.",
    },
    .ON_JUDGEMENT = {
        "void on_judgement( Hitobject hitobject, Judgement judgement, float timing_error_ms )",
        "called when an object is judged. judgement is a Judgement enum value; timing_error_ms is signed (hit time minus perfect time). hitobject is nil for judgements spawned via judgement_spawn without one.",
    },
    .VALIDATE_JUDGEMENT = {
        "(Judgement|nil, float|nil) validate_judgement( Hitobject hitobject, Judgement judgement, float timing_error_ms )",
        "called before a judgement is committed. return nothing to let it pass, or return a Judgement value (and optionally a replacement timing error) to overwrite it - score, combo, hitsounds, animations and the judgement graphic all follow the overwritten result. Judgement.NONE is rejected; a judgement cannot be cancelled, overwrite to Judgement.IGNORED_HIT instead. judgements from judgement_spawn are not filtered.",
    },
    .ON_KIAI_CHANGE = {
        "void on_kiai_change( bool kiai )",
        "called when the kiai state is set or unset.",
    },
    .ON_COMBO_BREAK = {
        "void on_combo_break( int lost_combo )",
        "called when the combo resets to 0, with the combo count that was lost. not called for breaks at 0 combo.",
    },
    .ON_MAP_COMPLETE = {
        "void on_map_complete( void )",
        "called once when the last scoring hitobject has been judged and the results screen appears (play mode only). seeking backward re-arms it.",
    },
}

//////////////////////////////////////////////////////
// note(isak): beatmap event API

lua_beatmap_on_update :: proc(time_ms: f64) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_UPDATE], time_ms,
        proc(time_ms: f64) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(time_ms))
            return 1
        }
    )
}

lua_beatmap_on_fixed_update :: proc(time_ms: f64) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_FIXED_UPDATE], time_ms,
        proc(time_ms: f64) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(time_ms))
            return 1
        }
    )
}

lua_beatmap_on_beat :: proc(beat: int) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_BEAT], beat,
        proc(beat: int) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(beat))
            return 1
        }
    )
}

lua_beatmap_on_timing_change :: proc(beat: int, bpm: f64) {
    Lua_Timing_Change_Params :: struct {
        beat: int, 
        bpm: f64
    }
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_TIMING_CHANGE], Lua_Timing_Change_Params{beat, bpm},
        proc(params: Lua_Timing_Change_Params) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(params.beat))
            lua.pushnumber(lua_beatmap.state, lua.Number(params.bpm))
            return 2
        }
    )
}

lua_beatmap_on_pause_change :: proc(paused: bool) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_PAUSE_CHANGE], paused,
        proc(paused: bool) -> i32 {
            lua.pushboolean(lua_beatmap.state, b32(paused))
            return 1
        }
    )
}

lua_beatmap_on_kiai_change :: proc(kiai: bool) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_KIAI_CHANGE], kiai,
        proc(kiai: bool) -> i32 {
            lua.pushboolean(lua_beatmap.state, b32(kiai))
            return 1
        }
    )
}

lua_beatmap_on_controller_pressed :: proc(key: cstring) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_CONTROLLER_PRESSED], key,
        proc(key: cstring) -> i32 {
            lua.pushstring(lua_beatmap.state, key)
            return 1
        }
    )
}
lua_beatmap_on_controller_released :: proc(key: cstring) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_CONTROLLER_RELEASED], key,
        proc(key: cstring) -> i32 {
            lua.pushstring(lua_beatmap.state, key)
            return 1
        }
    )
}

lua_beatmap_on_key_pressed :: proc(key: sdl.Scancode) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_KEY_DOWN], key,
        proc(key: sdl.Scancode) -> i32 {
            lua.pushstring(lua_beatmap.state, sdl.GetScancodeName(key))
            return 1
        }
    )
}
lua_beatmap_on_key_released :: proc(key: sdl.Scancode) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_KEY_UP], key,
        proc(key: sdl.Scancode) -> i32 {
            lua.pushstring(lua_beatmap.state, sdl.GetScancodeName(key))
            return 1
        }
    )
}

lua_beatmap_on_cursor_moved :: proc(pos: vec2) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_CURSOR_MOVED], pos,
        proc(pos: vec2) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(pos.x))
            lua.pushnumber(lua_beatmap.state, lua.Number(pos.y))
            return 2
        }
    )
}

lua_beatmap_on_map_complete :: proc() {
    if !lua_cares_about_event(.ON_MAP_COMPLETE) do return
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_MAP_COMPLETE])
}

lua_beatmap_on_combo_break :: proc(lost_combo: int) {
    if !lua_cares_about_event(.ON_COMBO_BREAK) do return
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_COMBO_BREAK], lost_combo,
        proc(lost_combo: int) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(lost_combo))
            return 1
        }
    )
}

lua_beatmap_on_judgement :: proc(hobj_index: int, judgement: Judgement_Type, timing_error_ms: f64) {
    if lua_cares_about_event(.ON_JUDGEMENT) {
        Lua_Judgement_Result :: struct {
            hobj_index:      int,
            judgement:       Judgement_Type,
            timing_error_ms: f64,
        }
        lua_call_beatmap_func(lua_beatmap_event_names[.ON_JUDGEMENT], Lua_Judgement_Result{hobj_index, judgement, timing_error_ms},
            proc(result: Lua_Judgement_Result) -> i32 {
                if result.hobj_index >= 0 {
                    lua_create_userdata(lua_beatmap.state, result.hobj_index, lua_classes[.HITOBJECT].name)
                } else {
                    lua.pushnil(lua_beatmap.state)
                }
                lua.pushinteger(lua_beatmap.state, cast(lua.Integer)result.judgement)
                lua.pushnumber(lua_beatmap.state, lua.Number(result.timing_error_ms))
                return 3
            }
        )
    }

    _lua_dispatch_judgement_events(hobj_index, judgement, timing_error_ms)
}

// note(isak): asks the script to validate a pending judgement before it commits. nil/no return
// passes it through; a Judgement value (with an optional replacement timing error) overwrites it.
// NONE and out-of-range values are rejected - a judgement can be rewritten, never cancelled
lua_beatmap_validate_judgement :: proc(hobj_index: int, type: Judgement_Type, time_error_ms: f64) -> (Judgement_Type, f64) {
    if !lua_cares_about_event(.VALIDATE_JUDGEMENT) do return type, time_error_ms

    L := lua_beatmap.state
    lua_beatmap.last_callback = lua_beatmap_event_names[.VALIDATE_JUDGEMENT]
    lua.getglobal(L, lua_beatmap_event_names[.VALIDATE_JUDGEMENT])
    lua_create_userdata(L, hobj_index, lua_classes[.HITOBJECT].name)
    lua.pushinteger(L, cast(lua.Integer)type)
    lua.pushnumber(L, lua.Number(time_error_ms))
    if !lua_pcall_with_watchdog(L, 3, 2, "judgement validation error:") {
        return type, time_error_ms
    }
    defer lua.pop(L, 2)

    if !lua.isnumber(L, -2) do return type, time_error_ms
    replacement := lua.tointeger(L, -2)
    if replacement <= cast(lua.Integer)Judgement_Type.NONE || replacement > cast(lua.Integer)max(Judgement_Type) {
        return type, time_error_ms
    }

    error_ms := time_error_ms
    if lua.isnumber(L, -1) do error_ms = f64(lua.tonumber(L, -1))
    return Judgement_Type(replacement), error_ms
}


// note(isak): the event key suffix for a judgement type, e.g. "judgement:Miss".
// only used to build/match registration names; callbacks receive the numeric enum value.
judgement_type_name :: proc "contextless" (j: Judgement_Type) -> cstring {
    switch j {
    case .NONE:                    return "None"
    case .MISS:                    return "Miss"
    case .OK:                      return "Ok"
    case .GOOD:                    return "Good"
    case .MARVELOUS:               return "Marvelous"
    case .SLIDER_SMALL_SCOREPOINT: return "SliderSmallScorepoint"
    case .SLIDER_LARGE_SCOREPOINT: return "SliderLargeScorepoint"
    case .SLIDER_SCOREPOINT_MISS:  return "SliderScorepointMiss"
    case .SLIDER_HEAD_MISS:        return "SliderHeadMiss"
    case .SLIDER_HEAD_OK:          return "SliderHeadOk"
    case .SLIDER_HEAD_GOOD:        return "SliderHeadGood"
    case .SLIDER_HEAD_MARVELOUS:   return "SliderHeadMarvelous"
    case .IGNORED_HIT:             return "IgnoredHit"
    case .COMBO_BREAK:             return "ComboBreak"
    case .SLIDER_END_MISS:         return "SliderEndMiss"
    }
    return "None"
}

// note(isak): fires the event-bus side of a judgement. per-object callbacks registered on this
// exact hitobject under "judgement" get (self, value, err); globals registered under "judgement"
// and "judgement:<Type>" get (value, err). value is the numeric Judgement enum, so scripts compare
// against the exported Judgement table.
_lua_dispatch_judgement_events :: proc(hobj_index: int, judgement: Judgement_Type, timing_error_ms: f64) {
    L := lua_beatmap.state
    typed := strings.concatenate({"judgement:", string(judgement_type_name(judgement))}, context.temp_allocator)

    for reg in lua_beatmap.event_registrations {
        per_object := !reg.is_global &&
            reg.class == .HITOBJECT &&
            reg.handle_key == u64(hobj_index) &&
            reg.name == "judgement"
        global := reg.is_global && (reg.name == "judgement" || reg.name == typed)
        if !per_object && !global do continue

        lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(reg.callback_ref))
        n_args := i32(2)
        if per_object {
            _lua_push_event_target(L, .HITOBJECT, u64(hobj_index))
            n_args = 3
        }
        lua.pushinteger(L, cast(lua.Integer)judgement)
        lua.pushnumber(L, lua.Number(timing_error_ms))
        lua_pcall_with_watchdog(L, n_args, 0, "judgement event error:")
    }
}

lua_call_beatmap_func :: proc {
    _lua_call_beatmap_func_no_params,
    _lua_call_beatmap_func_with_params,
}

_lua_call_beatmap_func_with_params :: proc(name: cstring, data: $T, param_writer: proc(data: T) -> i32) {
    L:= lua_beatmap.state
    lua_beatmap.last_callback = name
    lua.getglobal(L, name)
    
    param_count := param_writer(data)
    lua_pcall_with_watchdog(L, param_count, 0)
}

_lua_call_beatmap_func_no_params :: proc(name: cstring) {
    L:= lua_beatmap.state
    lua_beatmap.last_callback = name
    lua.getglobal(L, name)
    lua_pcall_with_watchdog(L, 0, 0)
}
