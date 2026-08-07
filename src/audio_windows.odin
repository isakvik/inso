#+build windows
package inso

import "base:intrinsics"
import "core:log"
import "core:strings"

import "dep:bass"

_platform_audio_init :: proc(device: Audio_Device) -> b32 {
    bass.WASAPI_Free()

    // note(isak): the output is wasapi, not a BASS device, so the old decode chain on the host
    // device is not freed by anything - orphan it no longer, release it explicitly before the
    // rebuild (the wasapi output proc is stopped by WASAPI_Free above, so it can't read a freed
    // mixer)
    _audio_free_mixer_chain()

    wasapi_info, ok := _wasapi_output_init(device)
    if !ok do return false
    if !_audio_init_mixers(wasapi_info.freq, wasapi_info.chans, .DECODE) do return false
    return bass.WASAPI_Start()
}


// note(isak): bass runs as a decode source, wasapi reads from it
_bass_wasapi_output_proc :: proc "c" (buffer: rawptr, len: u32, user_data: rawptr) -> u32 {
    if audio.output_mixer != 0 {
        c := bass.ChannelGetData(audio.output_mixer, buffer, len)
        return max(c, 0)
    }
    return 0
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
*/
_wasapi_output_init :: proc(device: Audio_Device = DEVICE_DEFAULT) -> (info: bass.WASAPI_INFO, ok: bool) {
    if !bass.WASAPI_Init(
        device = _wasapi_device_from_bass(device),
        freq = 0,
        chans = 0,
        flags = bass.WASAPI_EVENT | bass.WASAPI_AUTOFORMAT,
        buffer = 0,
        period = 1.1920929e-07, // math.F32_EPSILON
        _proc = _bass_wasapi_output_proc,
        user = nil
    ) {
        log.error("BASS_WASAPI init error (device", device, "):", bass.ErrorGetCode())
        return
    }
    audio.device_index = device
    bass.WASAPI_GetInfo(&info)

    device_info: bass.WASAPI_DEVICEINFO
    bass.WASAPI_GetDeviceInfo(bass.WASAPI_GetDevice(), &device_info)
    if device == DEVICE_DEFAULT {
        // note(isak): we followed the OS default - the endpoint we actually started is the one
        // the dropdown's row-0 label should name, refreshed on every default re-init
        _set_default_device_name(string(device_info.name))
    }

    buffer_samples := info.buflen / (info.chans * _wasapi_format_bytes(info.format))
    audio.output_latency_ms = f64(buffer_samples) * 1000 / f64(info.freq)
    log.infof("WASAPI output: %s :: %vhz %vch, buffer %v samples (%.1fms), device period min %.1fms / default %.1fms",
        device_info.name, info.freq, info.chans, buffer_samples,
        audio.output_latency_ms,
        f64(device_info.minperiod) * 1000, f64(device_info.defperiod) * 1000)

    return info, true
}

_wasapi_format_bytes :: proc(format: bass.DWORD) -> bass.DWORD {
    switch format {
    case bass.WASAPI_FORMAT_8BIT:  return 1
    case bass.WASAPI_FORMAT_16BIT: return 2
    case bass.WASAPI_FORMAT_24BIT: return 3
    }
    return 4 // FLOAT / 32BIT
}

// note(isak): wasapi and BASS don't share an index space, but each BASS (DirectSound) device's
// "driver" string equals its wasapi endpoint "id". indices are cached at init time (we never
// resolve during enumeration, the wasapi endpoint list isn't stable until BASS is up). the
// walk here is a fallback for a device added after init, where the cache is momentarily stale
_wasapi_device_from_bass :: proc(device: Audio_Device) -> i32 {
    if device == DEVICE_DEFAULT do return i32(DEVICE_DEFAULT)
    for dev in audio.devices {
        if dev.index == device {
            if dev.wasapi_index != i32(DEVICE_DEFAULT) do return dev.wasapi_index
            // note(isak): cache miss - live walk, same as resolve once did
            for d in 0..<256 {
                info: bass.WASAPI_DEVICEINFO
                if !bass.WASAPI_GetDeviceInfo(device = bass.DWORD(d), info = &info) do break
                if info.flags & (bass.DEVICE_INPUT | bass.DEVICE_LOOPBACK) != 0 do continue
                if string(info.id) == dev.driver do return i32(d)
            }
            return i32(DEVICE_DEFAULT)
        }
    }
    return i32(DEVICE_DEFAULT)
}

// note(isak): build the bass->wasapi index map once per init. keys are the wasapi endpoint "id"
// strings (bass's DirectSound "driver" equals its wasapi endpoint id). input/loopback endpoints
// share the same enumerate index space but can't be initialized as outputs, so they are excluded
// here - resolving to one of them is how a non-default device init would fail with NOTAVAIL
_platform_audio_resolve_wasapi_indices :: proc() {
    wasapi_index_of_id: map[string]u32
    defer delete(wasapi_index_of_id)

    for d in 0..<256 {
        info: bass.WASAPI_DEVICEINFO
        if !bass.WASAPI_GetDeviceInfo(device = bass.DWORD(d), info = &info) do break
        if info.flags & (bass.DEVICE_INPUT | bass.DEVICE_LOOPBACK) != 0 do continue
        wasapi_index_of_id[strings.clone(string(info.id), context.temp_allocator)] = u32(d)
    }

    for &dev in audio.devices {
        if idx, ok := wasapi_index_of_id[dev.driver]; ok {
            dev.wasapi_index = i32(idx)
        }
    }
}
