#+build windows
package inso

import "base:intrinsics"
import "core:log"

import "dep:bass"

// note(isak): bass.WASAPIPROC_BASS sentinel; the -1 constant can't sit in a proc pointer directly
_wasapi_proc_bass := transmute(bass.WASAPIPROC)(~uintptr(0))

// note(isak): throwaway proc for probe sessions; never driven since probes are never started.
// nil isn't used because push-mode init takes a different path than the callback shapes we know work
_wasapi_probe_proc :: proc "c" (buffer: rawptr, length: u32, user: rawptr) -> u32 {
    return length
}

// note(isak): plan-b pull: straight float passthrough from the output mixer. correct whenever the
// endpoint truly consumes the float mix format (as this hdaudio driver measurably does), and it's
// the exact shape shared mode ran on for years
_wasapi_passthrough_proc :: proc "c" (buffer: rawptr, length: u32, user: rawptr) -> u32 {
    mixer := audio.output_mixer
    if mixer == 0 do return 0
    c := bass.ChannelGetData(mixer, buffer, length)
    return max(c, 0)
}

// note(isak): single funnel over WASAPI_Init so every call site shares one shape; buffer=0 +
// epsilon period rides the win10 low-latency path. returns the session's actually-resolved info,
// which cannot be taken at its word around here
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

// note(isak): attaches the output mixer to a live wasapi session, trying conversion strategies in
// order of preference. PROC_BASS lets un4seen convert to the pin's true format; if the runtime
// won't take the sentinel (older dlls), the passthrough keeps us playing
//
// AUTOFORMAT is seeded onto every attempt because this driver rejects bare explicit formats
// through the low-latency init path outright. on success pick is updated with what actually
// landed, since auto-negotiation may wiggle off the seed
_wasapi_attach_output :: proc(device: Audio_Device, pick: ^Wasapi_Format_Pick) -> (info: bass.WASAPI_INFO, ok: bool) {
    devidx := _wasapi_device_from_bass(device)

    Attempt :: struct {
        label:    string,
        callback: bass.WASAPIPROC,
        user:     rawptr,
    }
    attempts := []Attempt{
        {label = "basswasapi conversion (PROC_BASS)",
         callback = _wasapi_proc_bass,
         user = transmute(rawptr)uintptr(audio.output_mixer)},
        {label = "float passthrough",
         callback = _wasapi_passthrough_proc,
         user = nil},
    }

    for a in attempts {
        info, ok = _wasapi_try_init(devidx, pick.freq, pick.chans,
            pick.flags | bass.WASAPI_AUTOFORMAT, a.callback, a.user)
        if !ok {
            log.warnf("audio: %s attach failed (error %v)", a.label, bass.ErrorGetCode())
            continue
        }
        pick.freq = info.freq
        pick.chans = info.chans
        log.infof("audio: wasapi output attached via %s (%vhz %vch %s)",
            a.label, info.freq, info.chans, _wasapi_format_name(i32(info.format)))
        return
    }
    return
}

_platform_audio_init :: proc(device: Audio_Device) -> b32 {
    bass.WASAPI_Free()
    _platform_audio_free_mixer_chain()

    // note(isak): two-phase init; BASSWASAPI pulls from the output mixer itself (PROC_BASS), so the
    // chain has to exist before the real init. negotiate the endpoint's format with a throwaway
    // probe session, build for it, then attach
    pick, negotiated := _wasapi_output_negotiate(device)
    if !negotiated do return false
    if !_audio_init_mixers(pick.freq, pick.chans) do return false

    built_freq, built_chans := pick.freq, pick.chans
    info, attached := _wasapi_attach_output(device, &pick)
    if !attached do return false
    if pick.freq != built_freq || pick.chans != built_chans {
        // note(isak): auto-negotiation wiggled off the seed; the chain has to match the wire
        log.warnf("audio: endpoint resolved %vhz %vch, rebuilding mixer chain", pick.freq, pick.chans)
        _platform_audio_free_mixer_chain()
        if !_audio_init_mixers(pick.freq, pick.chans) do return false
    }

    _wasapi_refresh_status(device, &info)
    return bass.WASAPI_Start()
}

// note(isak): frees the current mixer chain. the linux backend doesn't need this, it just frees the device
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

// note(isak): basswasapi wraps the COM device event listener for us; this runs on its event thread,
// so we only set a flag here and let the main loop do the reinit
_bass_wasapi_notify_proc :: proc "c" (notify: bass.DWORD, device: bass.DWORD, user: rawptr) {
    switch notify {
    case bass.WASAPI_NOTIFY_DEFOUTPUT, bass.WASAPI_NOTIFY_FAIL:
        intrinsics.atomic_store(&audio.device_reinit_requested, true)
    case bass.WASAPI_NOTIFY_ENABLED:
        intrinsics.atomic_store(&audio.device_list_rebuild_requested, true)
        if !audio.ready {
            intrinsics.atomic_store(&audio.device_reinit_requested, true)
        }
    }
}

/*
note(isak): we're using some flags that make BASS run very smoothly with WASAPI in windows' shared audio mode
courtesy of LastExceed: https://github.com/ppy/osu-framework/pull/6651

the following is the old osu lazer init that makes BASS run like ass, which are useful for provoking large
interpolation deltas (for handling the music buffer granularity/play time discrepancy):

    device = _wasapi_device_from_bass(device),
    freq = 0,
    chans = 0,
    flags = 0,
    buffer = 0.02,
    period = 0,
    _proc = _bass_wasapi_output_proc,
    user = nil

output is PROC_BASS: basswasapi pulls from the output mixer itself and converts to whatever the pin
truly wants. we used to pack floats to the reported wire format ourselves, but this driver's reports
lie - it negotiated 16-bit@48k while the endpoint consumed at float rate (384kb/s measured against a
192kb/s contract), so hand-rolled packing came out as loud static with a 2x game clock. un4seen owns
both sides of that conversation now
*/
Wasapi_Format_Pick :: struct {
    freq, chans: bass.DWORD,
    flags:       bass.DWORD, // note(isak): mode/format flags; attach seeds AUTOFORMAT on top
}

// note(isak): discovers what to init the endpoint with via a throwaway probe session; leaves the
// device free for the real PROC_BASS init
_wasapi_output_negotiate :: proc(device: Audio_Device) -> (pick: Wasapi_Format_Pick, ok: bool) {
    devidx := _wasapi_device_from_bass(device)

    if game.user_config.audio_backend == .EXCLUSIVE_MODE {
        pick, ok = _wasapi_negotiate_exclusive(devidx)
        if ok do return
        log.warnf("audio: exclusive negotiation failed on device %v (error %v), falling back to shared",
            device, bass.ErrorGetCode())
        bass.WASAPI_Free()
    }

    session, discovered := _wasapi_try_init(devidx, 0, 0,
        bass.WASAPI_AUTOFORMAT | bass.WASAPI_EVENT, _wasapi_probe_proc, nil)
    if !discovered {
        log.error("BASS_WASAPI shared discovery error:", bass.ErrorGetCode())
        return
    }
    bass.WASAPI_Free()

    log.infof("audio: shared discovery resolved %vhz %vch %s",
        session.freq, session.chans, _wasapi_format_name(i32(session.format)))
    return Wasapi_Format_Pick{freq = session.freq, chans = session.chans, flags = bass.WASAPI_EVENT}, true
}

/*
note(isak): exclusive formats are probed explicitly instead of trusting AUTOFORMAT, whose trial order
(float first) gives no say in what sticks. each candidate is verified with a real throwaway
WASAPI_Init - this driver's CheckFormat answers have already been caught disagreeing with reality -
and the pick carries whatever GetInfo says that init actually produced. 16-bit leads since
integer-16 pipes have no container ambiguity; the depth rides the flags HIWORD so the real init
starts there
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
        resolved := bass.WASAPI_CheckFormat(transmute(bass.DWORD)devidx, c.freq, c.chans,
            bass.WASAPI_EXCLUSIVE | (c.hint << 16))
        if resolved < bass.WASAPI_FORMAT_16BIT || resolved > bass.WASAPI_FORMAT_32BIT do continue

        session, session_ok := _wasapi_try_init(devidx, c.freq, c.chans,
            bass.WASAPI_EVENT | bass.WASAPI_AUTOFORMAT | bass.WASAPI_EXCLUSIVE | (resolved << 16),
            _wasapi_probe_proc, nil)
        if !session_ok {
            log.infof("audio: exclusive candidate %vhz %vch %s failed to init (%v)",
                c.freq, c.chans, _wasapi_format_name(i32(resolved)), bass.ErrorGetCode())
            continue
        }
        bass.WASAPI_Free()

        log.infof("audio: exclusive candidate %vhz %vch landed on %vhz %vch %s",
            c.freq, c.chans, session.freq, session.chans, _wasapi_format_name(i32(session.format)))
        return Wasapi_Format_Pick{
            freq  = session.freq,
            chans = session.chans,
            flags = bass.WASAPI_EVENT | bass.WASAPI_EXCLUSIVE | (resolved << 16),
        }, true
    }
    return
}

// note(isak): fills the ui diagnostics from the live session; called after the real init lands
_wasapi_refresh_status :: proc(device: Audio_Device, info: ^bass.WASAPI_INFO) {
    device_info: bass.WASAPI_DEVICEINFO
    bass.WASAPI_GetDeviceInfo(bass.WASAPI_GetDevice(), &device_info)
    if device == DEVICE_DEFAULT {
        _set_default_device_name(string(device_info.name))
    }
    audio.device_index = device

    frame_bytes := max(int(info.chans) * int(_wasapi_format_bytes(info.format)), 1)
    buffer_samples := int(info.buflen) / frame_bytes
    audio.output_latency_ms = f64(buffer_samples) * 1000 / f64(max(info.freq, 1))
    audio.wasapi_status = Wasapi_Output_Status{
        backend        = .EXCLUSIVE_MODE if info.initflags & bass.WASAPI_EXCLUSIVE != 0 else .SHARED_MODE,
        freq           = i32(info.freq),
        chans          = i32(info.chans),
        wire_format    = i32(info.format),
        buffer_samples = i32(buffer_samples),
        device_minperiod_ms = f64(device_info.minperiod) * 1000,
        device_defperiod_ms = f64(device_info.defperiod) * 1000,
    }

    log.infof("WASAPI output (%s): %s :: %vhz %vch %s, buffer %v samples (%.1fms), device period min %.1fms / default %.1fms",
        audio_backend_keys[audio.wasapi_status.backend],
        device_info.name, info.freq, info.chans, _wasapi_format_name(i32(info.format)),
        buffer_samples,
        audio.output_latency_ms,
        f64(device_info.minperiod) * 1000, f64(device_info.defperiod) * 1000)
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

_wasapi_device_from_bass :: proc(device: Audio_Device) -> i32 {
    if device == DEVICE_DEFAULT do return i32(DEVICE_DEFAULT)
    for dev in audio.devices {
        if dev.index != device do continue
        // note(isak): the bass "driver" strings are the wasapi endpoint ids; walk the wasapi
        // list to find the matching endpoint. happens only on device switches, so no caching
        for d in 0..<256 {
            info: bass.WASAPI_DEVICEINFO
            if !bass.WASAPI_GetDeviceInfo(device = bass.DWORD(d), info = &info) do break
            if info.flags & (bass.DEVICE_INPUT | bass.DEVICE_LOOPBACK) != 0 do continue
            if string(info.id) == dev.driver do return i32(d)
        }
        return i32(DEVICE_DEFAULT)
    }
    return i32(DEVICE_DEFAULT)
}
