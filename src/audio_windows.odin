#+build windows
package inso

import "base:intrinsics"
import "core:log"

import "dep:bass"

EXCLUSIVE_MODE_RETRY_ATTEMPTS   :: 3
EXCLUSIVE_MODE_RETRY_INTERVAL_S :: 1.0

// note(isak): snapshots taken at init. WASAPI_GetDeviceInfo is too expensive to poll per frame
wasapi: struct {
    session: bass.WASAPI_INFO,
    min_period_ms, default_period_ms: f64,
}

// note(isak): bass.WASAPIPROC_BASS is -1, which can't sit in a proc pointer constant
_wasapi_proc_bass := transmute(bass.WASAPIPROC)(~uintptr(0))

// note(isak): probe sessions are never started. nil isn't used since that selects push mode,
// which takes a different init path than the real session
_wasapi_probe_proc :: proc "c" (buffer: rawptr, length: u32, user: rawptr) -> u32 {
    return length
}

_wasapi_float_passthrough_proc :: proc "c" (buffer: rawptr, length: u32, user: rawptr) -> u32 {
    return max(bass.ChannelGetData(audio.output_mixer, buffer, length), 0)
}

/*
note(isak): the flags that make BASS run smoothly with WASAPI in shared mode are courtesy of
LastExceed: https://github.com/ppy/osu-framework/pull/6651

the old lazer init (buffer = 0.02, period = 0, freq/chans/flags = 0) runs BASS badly, and is
useful for provoking large interpolation deltas when testing the music clock

exclusive output is PROC_BASS so basswasapi converts the float mix to the pin's real format.
this driver's format reports lie (it negotiated 16-bit while consuming float-rate data), so
packing the wire format ourselves came out as static with a 2x game clock. shared sessions
reject PROC_BASS with BASS_ERROR_UNKNOWN, but the shared mix format is float, so they take
the mix as-is
*/
_wasapi_try_init :: proc(device: i32, freq, chans, flags: bass.DWORD, callback: bass.WASAPIPROC, user: rawptr) -> (info: bass.WASAPI_INFO, ok: bool) {
    if !bass.WASAPI_Init(
        device = device,
        freq = freq,
        chans = chans,
        flags = flags,
        buffer = 0,
        period = 1.1920929e-07, // math.F32_EPSILON
        _proc = callback,
        user = user,
    ) {
        return
    }
    bass.WASAPI_GetInfo(&info)
    return info, true
}

Wasapi_Format_Pick :: struct {
    freq, chans: bass.DWORD,
    flags:       bass.DWORD,
}

// note(isak): AUTOFORMAT rides every attach since this driver rejects bare explicit formats
// through the low-latency init path
_wasapi_attach_output :: proc(devidx: i32, pick: Wasapi_Format_Pick) -> (info: bass.WASAPI_INFO, ok: bool) {
    exclusive := pick.flags & bass.WASAPI_EXCLUSIVE != 0
    callback: bass.WASAPIPROC = _wasapi_proc_bass if exclusive else _wasapi_float_passthrough_proc
    user := transmute(rawptr)uintptr(audio.output_mixer) if exclusive else nil

    info, ok = _wasapi_try_init(devidx, pick.freq, pick.chans, pick.flags | bass.WASAPI_AUTOFORMAT, callback, user)
    if !ok {
        log.error("BASS_WASAPI init error:", bass.ErrorGetCode())
        return
    }
    if !exclusive && info.format != bass.WASAPI_FORMAT_FLOAT {
        log.errorf("audio: shared session landed on %s, expected float", _wasapi_format_name(i32(info.format)))
        bass.WASAPI_Free()
        return info, false
    }
    return
}

_platform_audio_init :: proc(device: Audio_Device) -> b32 {
    bass.WASAPI_Free()
    wasapi.session = {}
    _platform_audio_free_mixer_chain()

    devidx, device_info, found := _wasapi_find_output(device)
    if !found {
        log.errorf("audio: no wasapi output endpoint for device %v", device)
        return false
    }

    pick, negotiated := _wasapi_output_negotiate(devidx, device_info)
    if !negotiated do return false

    // note(isak): PROC_BASS pulls from the output mixer, so the chain has to exist before the real init
    if !_audio_init_mixers(pick.freq, pick.chans) do return false
    info, attached := _wasapi_attach_output(devidx, pick)
    if !attached do return false

    if info.freq != pick.freq || info.chans != pick.chans {
        log.warnf("audio: endpoint resolved %vhz %vch, rebuilding mixer chain", info.freq, info.chans)
        bass.WASAPI_Free()
        _platform_audio_free_mixer_chain()
        pick.freq, pick.chans = info.freq, info.chans
        if !_audio_init_mixers(pick.freq, pick.chans) do return false
        if info, attached = _wasapi_attach_output(devidx, pick); !attached do return false
    }

    _wasapi_record_session(device, device_info, info)
    return bass.WASAPI_Start()
}

_platform_audio_free_mixer_chain :: proc() {
    for group in Sound_Group {
        if audio.group_mixers[group] != 0 {
            bass.StreamFree(audio.group_mixers[group])
            audio.group_mixers[group] = 0
        }
    }
    if audio.output_mixer != 0 {
        bass.StreamFree(audio.output_mixer)
        audio.output_mixer = 0
    }
}

// note(isak): runs on basswasapi's event thread, so only flag work for the main loop here
_bass_wasapi_notify_proc :: proc "c" (notify: bass.DWORD, device: bass.DWORD, user: rawptr) {
    switch notify {
    case bass.WASAPI_NOTIFY_DEFOUTPUT:
        if audio.device_index == DEVICE_DEFAULT {
            intrinsics.atomic_store(&audio.device_reinit_requested, true)
        }
    case bass.WASAPI_NOTIFY_FAIL:
        intrinsics.atomic_store(&audio.device_reinit_requested, true)
    case bass.WASAPI_NOTIFY_ENABLED:
        intrinsics.atomic_store(&audio.device_list_rebuild_requested, true)
        if !audio.ready {
            intrinsics.atomic_store(&audio.device_reinit_requested, true)
        }
    }
}

_wasapi_output_negotiate :: proc(devidx: i32, device_info: bass.WASAPI_DEVICEINFO) -> (pick: Wasapi_Format_Pick, ok: bool) {
    if game.user_config.audio_backend == .EXCLUSIVE_MODE {
        if pick, ok = _wasapi_negotiate_exclusive(devidx); ok do return
        log.warnf("audio: exclusive negotiation failed on device %v (error %v), falling back to shared",
            devidx, bass.ErrorGetCode())
    }
    return Wasapi_Format_Pick{freq = device_info.mixfreq, chans = device_info.mixchans, flags = bass.WASAPI_EVENT}, true
}

/*
note(isak): exclusive formats are probed explicitly since AUTOFORMAT's trial order (float first)
doesn't give useful info. each candidate is verified with a throwaway WASAPI_Init because we've had
issues with driver's CheckFormat answers not actually matching what the device expects
*/
_wasapi_negotiate_exclusive :: proc(devidx: i32) -> (pick: Wasapi_Format_Pick, ok: bool) {
    Format_Candidate :: struct { freq, chans, hint: bass.DWORD }
    candidates := []Format_Candidate{
        {freq = 48000, chans = 2, hint = bass.WASAPI_FORMAT_16BIT},
        {freq = 44100, chans = 2, hint = bass.WASAPI_FORMAT_16BIT},
        {freq = 48000, chans = 2, hint = bass.WASAPI_FORMAT_24BIT},
        {freq = 44100, chans = 2, hint = bass.WASAPI_FORMAT_24BIT},
    }

    for c in candidates {
        resolved := bass.WASAPI_CheckFormat(bass.DWORD(devidx), c.freq, c.chans,
            bass.WASAPI_EXCLUSIVE | (c.hint << 16))
        if resolved < bass.WASAPI_FORMAT_16BIT || resolved > bass.WASAPI_FORMAT_32BIT do continue

        flags := bass.WASAPI_EVENT | bass.WASAPI_EXCLUSIVE | (resolved << 16)
        session, session_ok := _wasapi_try_init(devidx, c.freq, c.chans, flags | bass.WASAPI_AUTOFORMAT,
            _wasapi_probe_proc, nil)
        if !session_ok {
            log.infof("audio: exclusive candidate %vhz %vch %s failed to init (%v)",
                c.freq, c.chans, _wasapi_format_name(i32(resolved)), bass.ErrorGetCode())
            continue
        }
        bass.WASAPI_Free()
        return Wasapi_Format_Pick{freq = session.freq, chans = session.chans, flags = flags}, true
    }
    return
}

_wasapi_arm_exclusive_retry :: proc() {
    wants_exclusive := game.user_config.audio_backend == .EXCLUSIVE_MODE
    audio.exclusive_retries_left = EXCLUSIVE_MODE_RETRY_ATTEMPTS if wants_exclusive && !_wasapi_is_exclusive() else 0
    audio.exclusive_retry_at_s = game.frame_clock_s + EXCLUSIVE_MODE_RETRY_INTERVAL_S
}

audio_service_exclusive_retry :: proc() {
    if audio.exclusive_retries_left == 0 || game.frame_clock_s < audio.exclusive_retry_at_s do return

    audio.exclusive_retries_left -= 1
    audio.exclusive_retry_at_s = game.frame_clock_s + EXCLUSIVE_MODE_RETRY_INTERVAL_S
    audio.ready = bool(_platform_audio_init(audio.device_index))
    if _wasapi_is_exclusive() do audio.exclusive_retries_left = 0
}

_wasapi_is_exclusive :: proc() -> bool {
    return wasapi.session.initflags & bass.WASAPI_EXCLUSIVE != 0
}

_wasapi_backend :: proc(info: bass.WASAPI_INFO) -> Audio_Backend {
    return .EXCLUSIVE_MODE if info.initflags & bass.WASAPI_EXCLUSIVE != 0 else .SHARED_MODE
}

_wasapi_buffer_samples :: proc(info: bass.WASAPI_INFO) -> int {
    frame_bytes := max(int(info.chans) * int(_wasapi_format_bytes(info.format)), 1)
    return int(info.buflen) / frame_bytes
}

_wasapi_record_session :: proc(device: Audio_Device, device_info: bass.WASAPI_DEVICEINFO, info: bass.WASAPI_INFO) {
    if device == DEVICE_DEFAULT {
        _set_default_device_name(string(device_info.name))
    }
    audio.device_index = device
    wasapi.session = info
    wasapi.min_period_ms = f64(device_info.minperiod) * 1000
    wasapi.default_period_ms = f64(device_info.defperiod) * 1000

    buffer_samples := _wasapi_buffer_samples(info)
    audio.output_latency_ms = f64(buffer_samples) * 1000 / f64(max(info.freq, 1))

    log.infof("WASAPI output (%s): %s :: %vhz %vch %s, buffer %v samples (%.1fms), device period min %.1fms / default %.1fms",
        audio_backend_keys[_wasapi_backend(info)],
        device_info.name, info.freq, info.chans, _wasapi_format_name(i32(info.format)),
        buffer_samples, audio.output_latency_ms, wasapi.min_period_ms, wasapi.default_period_ms)
}

_wasapi_format_name :: proc(format: i32) -> string {
    switch format {
    case bass.WASAPI_FORMAT_FLOAT: return "float"
    case bass.WASAPI_FORMAT_8BIT:  return "8-bit"
    case bass.WASAPI_FORMAT_16BIT: return "16-bit"
    case bass.WASAPI_FORMAT_24BIT: return "24-bit"
    case bass.WASAPI_FORMAT_32BIT: return "32-bit"
    }
    return "?"
}

_wasapi_format_bytes :: proc(format: bass.DWORD) -> bass.DWORD {
    switch format {
    case bass.WASAPI_FORMAT_8BIT:  return 1
    case bass.WASAPI_FORMAT_16BIT: return 2
    case bass.WASAPI_FORMAT_24BIT: return 3
    }
    return 4 // FLOAT / 32BIT
}

// note(isak): the bass "driver" strings are the wasapi endpoint ids
_wasapi_find_output :: proc(device: Audio_Device) -> (index: i32, info: bass.WASAPI_DEVICEINFO, found: bool) {
    endpoint_id := ""
    for dev in audio.devices {
        if dev.index == device do endpoint_id = dev.driver
    }
    for d in 0..<256 {
        if !bass.WASAPI_GetDeviceInfo(bass.DWORD(d), &info) do break
        if info.flags & (bass.DEVICE_INPUT | bass.DEVICE_LOOPBACK) != 0 do continue
        matches := string(info.id) == endpoint_id if endpoint_id != "" else info.flags & bass.DEVICE_DEFAULT != 0
        if matches do return i32(d), info, true
    }
    return
}
