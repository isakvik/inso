package notosu

import "core:strings"
import "core:log"
import os "core:os"

import "bass"


audio: struct {
    ready: bool,
    output_mixer: bass.HSTREAM
}

Device :: i32
Sound_Handle :: bass.DWORD

Sound_Flags :: distinct bit_set[Sound_Flag; u32]
Sound_Flag :: enum u32 {
    PAUSED,
    STREAM,
    LOOP,
    PRESCAN,
    TEMPO,
}

Base_Sound :: struct {
    flags: Sound_Flags,
    volume: f32, // note(isak): 0.0 - 1.0 range
    pan: f32,
    time_at: f64,
}

Sound :: union {
    Sound_Stream,
    Sound_Channel,
}

// note(isak): BASS handled stream IO, suitable for large files
Sound_Stream :: struct {
    using base: Base_Sound,
    handle: bass.HSTREAM,
}

// note(isak): files held in memory, suitable for short repeating sounds
Sound_Channel :: struct {
    using base: Base_Sound,
    handle: bass.HCHANNEL,
}

// note(isak): sample held in memory with a fixed channel pool; use for fire-and-forget
// short sounds that may overlap (hitsounds)
Sample :: struct {
    handle:    bass.HSAMPLE,
    filepath:  string, // note(isak): filename only (no dir); join with mapset.folder_path for full path
    file_data: []byte, // note(isak): raw file bytes kept alive for in-memory stream creation
}

//////////////////////////////////////////////////////
// note(isak): audio engine api

when ODIN_OS == .Windows {
    // note: WASAPI output callback — BASS runs as a decode source, WASAPI pulls from it
    _bass_wasapi_proc :: proc "c" (buffer: rawptr, len: u32, user_data: rawptr) -> u32 {
        if audio.output_mixer != 0 {
            c := bass.ChannelGetData(audio.output_mixer, buffer, len)
            return max(c, 0)
        }
        return 0
    }
}

// todo(isak): should probably call this device_init() or something
// todo(isak): device selection
audio_init :: proc(device: Device = -1) -> bool {
    when ODIN_OS == .Windows {
        /*
        note(isak): we're using some flags that make BASS run very smoothly with WASAPI in windows' shared audio mode
        courtesy of LastExceed: https://github.com/ppy/osu-framework/pull/6651

        the following is the old osu lazer init that makes BASS run like ass, which are useful for provoking large
        interpolation deltas (for handling the music buffer granularity/play time discrepancy):

            device = -1,
            freq = 0,
            chans = 0,
            flags = 0,
            buffer = 0.02,
            period = 0,
            _proc = _bass_wasapi_proc,
            user = nil
        */
        bass.Init(device, 44100, bass.DEVICE_NOSPEAKER, nil, nil)

        if !bass.WASAPI_Init(
            device = -1,
            freq = 0,
            chans = 0,
            flags = bass.WASAPI_EVENT | bass.WASAPI_AUTOFORMAT,
            buffer = 0,
            period = 1.1920929e-07, // math.F32_EPSILON
            _proc = _bass_wasapi_proc,
            user = nil
        ) {
            log.error("BASS_WASAPI init error:", bass.ErrorGetCode())
            return false
        }

        bass.WASAPI_Start()

        wasapi_info: bass.WASAPI_INFO
        bass.WASAPI_GetInfo(&wasapi_info)
        audio.output_mixer = bass.Mixer_StreamCreate(wasapi_info.freq, wasapi_info.chans,
            bass.SAMPLE_FLOAT | bass.STREAM_DECODE | bass.MIXER_NONSTOP)
    } else {
        // note(isak): on linux/mac, BASS handles output via ALSA/PulseAudio directly.
        // these must be set before Init — CONFIG_BUFFER defaults to 500ms which causes
        // audible delay on pause/seek (buffer is already filled that far ahead).
        bass.SetConfig(bass.CONFIG_UPDATEPERIOD, 1)
        bass.SetConfig(bass.CONFIG_DEV_PERIOD, 10)
        bass.SetConfig(bass.CONFIG_BUFFER, 50)

        if !bass.Init(device, 44100, 0, nil, nil) {
            log.error("BASS init error:", bass.ErrorGetCode())
            return false
        }
        audio.output_mixer = bass.Mixer_StreamCreate(44100, 2,
            bass.SAMPLE_FLOAT | bass.MIXER_NONSTOP)
        if audio.output_mixer != 0 {
            bass.ChannelPlay(audio.output_mixer, false)
        }
    }

    if audio.output_mixer == 0 {
        log.error("BASS mixer init error:", bass.ErrorGetCode())
        return false
    }

    audio.ready = true
    return true
}

audio_cleanup :: proc() {
    when ODIN_OS == .Windows {
        bass.WASAPI_Free()
    } else {
        bass.Free()
    }
}

// note(isak): volume is a 0.0 - 1.0 range
audio_set_volume :: proc(volume: f32) {
    when ODIN_OS == .Windows {
        bass.WASAPI_SetVolume(bass.WASAPI_CURVE_WINDOWS | bass.WASAPI_VOL_SESSION, volume)
    } else {
        bass.SetVolume(volume)
    }
}

//////////////////////////////////////////////////////
// note(isak): sound api

sound_stream_init :: proc(path: string, prescan: bool = false, loop: bool = false) -> (result: Sound_Stream, ok: bool) {
    // bass.UNICODE for wstring
    init_flags: u32 = bass.STREAM_DECODE | bass.SAMPLE_FLOAT
    init_flags |= prescan ? bass.STREAM_PRESCAN : 0
    init_flags |= loop ? bass.SAMPLE_LOOP : 0
    
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    result.handle = bass.StreamCreateFile(0, rawptr(path_cstr), 0, 0, init_flags)
    if result.handle == 0 {
        log.error("BASS stream create error:", bass.ErrorGetCode(), "::", path)
        return result, false
    }
    
    result.handle = bass.FX_TempoCreate(result.handle, bass.FX_FREESOURCE | bass.STREAM_DECODE)
    
    bass.ChannelSetAttribute(result.handle, bass.ATTRIB_TEMPO_OPTION_USE_QUICKALGO, 1)
    bass.ChannelSetAttribute(result.handle, bass.ATTRIB_TEMPO_OPTION_OVERLAP_MS, 4.0)
    bass.ChannelSetAttribute(result.handle, bass.ATTRIB_TEMPO_OPTION_SEQUENCE_MS, 30.0)
    
    result.flags = { .STREAM, .TEMPO }
    result.flags |= prescan ? {.PRESCAN} : {}
    result.flags |= loop ? {.LOOP} : {}
    
    return result, true
}

sound_channel_init :: proc(s: ^Sample, loop: bool = false) -> (result: Sound_Channel, ok: bool) {
    if !audio.ready || s.handle == 0 do return
    channel := bass.SampleGetChannel(s.handle, (loop ? bass.SAMPLE_LOOP : 0) | bass.STREAM_DECODE)
    if channel == 0 {
        log.error("BASS sample get channel error:", bass.ErrorGetCode())
        return result, false
    }
    result.handle = channel
    if loop do result.flags |= {.LOOP}
    return result, true
}

// note(isak): creates a decode stream suitable for adding to the WASAPI mixer.
// use for managed looping sounds where a sample channel (SampleGetChannel) can't be
// used as a decode channel reliably.
sound_loop_stream_init :: proc(path: string) -> (result: Sound_Stream, ok: bool) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    result.handle = bass.StreamCreateFile(0, rawptr(path_cstr), 0, 0,
        bass.STREAM_DECODE | bass.SAMPLE_FLOAT | bass.SAMPLE_LOOP)
    if result.handle == 0 {
        log.error("BASS loop stream create error:", bass.ErrorGetCode())
        return result, false
    }
    result.flags = {.STREAM, .LOOP}
    return result, true
}

sound_stream_init_from_memory :: proc(data: []byte, loop: bool = false) -> (result: Sound_Stream, ok: bool) {
    flags: u32 = bass.STREAM_DECODE | bass.SAMPLE_FLOAT
    flags |= loop ? bass.SAMPLE_LOOP : 0
    result.handle = bass.StreamCreateFile(bass.FILE_MEM, raw_data(data), 0, u64(len(data)), flags)
    if result.handle == 0 {
        log.error("BASS stream from memory error:", bass.ErrorGetCode())
        return result, false
    }
    result.flags = {.STREAM}
    if loop do result.flags |= {.LOOP}
    return result, true
}

sound_destroy :: proc(sound: ^Sound) {
    switch s in sound {
    case Sound_Stream:  bass.StreamFree(s.handle)
    case Sound_Channel: bass.ChannelFree(s.handle)
    }
}

sound_is_playing :: proc(sound: ^Sound) -> (result: bool) {
    if audio.ready { 
        if sound_is_paused(sound) {
            result = false
        }
        else {
            switch s in sound {
            // todo(isak): overlayable stream is a bit more complicated but not implemented yet
            case Sound_Stream:  result = bass.ChannelIsActive(s.handle) == bass.ACTIVE_PLAYING
            case Sound_Channel: result = bass.ChannelIsActive(s.handle) == bass.ACTIVE_PLAYING
            }
        }
    }
    return result
}

sound_is_paused :: proc(sound: ^Sound) -> bool {
    base := cast(^Base_Sound)sound
    return .PAUSED in base.flags
}

sound_is_finished :: proc(sound: ^Sound) -> (result: bool) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        state := bass.ChannelIsActive(handle)
        result = state == bass.ACTIVE_STOPPED
    }
    return result
}

sound_get_length_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        length := bass.ChannelGetLength(handle, bass.POS_BYTE)
        result = bass.ChannelBytes2Seconds(handle, length) * 1000
    }
    return result
}

sound_get_position_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        pos := bass.ChannelGetPosition(handle, bass.POS_BYTE)
        result = bass.ChannelBytes2Seconds(handle, pos) * 1000
    }
    return result
}

sound_get_position_fract :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        
        pos := bass.ChannelGetPosition(handle, bass.POS_BYTE)
        length := bass.ChannelGetLength(handle, bass.POS_BYTE)
        
        result = f64(pos) / f64(length)
    }
    return result
}

sound_set_position_ms :: proc(sound: ^Sound, ms: f64) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        // note(isak): small epsilon here; setting the position to somewhere after this fails
        ms := clamp(ms, 0, sound_get_length_ms(sound) - 0.01)
        
        pos_bytes := bass.ChannelSeconds2Bytes(handle, ms / 1000)
        if !bass.Mixer_ChannelSetPosition(handle, pos_bytes, bass.POS_BYTE) {
            log.error("BASS channel set position error:", bass.ErrorGetCode())
        }
    }
}

sound_set_position_fract :: proc(sound: ^Sound, fract: f64) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        sound_length := sound_get_length_ms(sound)
        // note(isak): small epsilon here; setting the position to somewhere after this fails 
        ms := clamp(fract * sound_length, 0, sound_length - 0.01)
        
        pos_bytes := bass.ChannelSeconds2Bytes(handle, ms / 1000)
        if !bass.Mixer_ChannelSetPosition(handle, pos_bytes, bass.POS_BYTE) {
            log.error("BASS channel set position error:", bass.ErrorGetCode())
        }
    }
}

sound_set_volume :: proc(sound: ^Sound, volume: f32) {
    if audio.ready {
        handle := _sound_get_channel_handle(sound)
        bass.ChannelSetAttribute(handle, bass.ATTRIB_VOL, volume)
    }
}

sound_set_speed :: proc(sound: ^Sound, rate: f32) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        rate := clamp(rate, 1/50, 50)
        compensate_pitch := true
        
        freq: f32
        if !bass.ChannelGetAttribute(handle, bass.ATTRIB_FREQ, &freq) {
            log.error("BASS channel get freq error:", bass.ErrorGetCode())
        }
        
        freq_target := (compensate_pitch ? (rate-1.0) * 100.0 : rate * freq)
       	if !bass.ChannelSetAttribute(handle, (compensate_pitch ? bass.ATTRIB_TEMPO : bass.ATTRIB_TEMPO_FREQ), freq_target) {
            log.error("BASS channel set tempo error:", bass.ErrorGetCode(), compensate_pitch)
        }
    }
}

sound_play :: proc(sound: ^Sound, start_paused: bool = false, loop: bool = false, volume: f32 = 1.0) {
    if audio.ready {
        base := cast(^Base_Sound)sound
        handle := _sound_get_channel_handle(sound)

        bass.ChannelSetAttribute(handle, bass.ATTRIB_NORAMP, 1.0) // see https://github.com/ppy/osu-framework/pull/3146
        bass.ChannelSetAttribute(handle, bass.ATTRIB_VOL, volume)
        
        if bass.Mixer_ChannelGetMixer(handle) == 0 {
            flags: u32 = bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN
            flags |= (!loop && .STREAM in base.flags) ? bass.STREAM_AUTOFREE : 0
            flags |= start_paused ? bass.MIXER_CHAN_PAUSE : 0

            if !bass.Mixer_StreamAddChannel(audio.output_mixer, handle, flags) {
                log.error("BASS mixer add channel error:", bass.ErrorGetCode())
            }
        }
        
        if !start_paused && !sound_is_playing(sound) {
            if !bass.ChannelPlay(handle, true) {
                log.error("BASS channel play error:", bass.ErrorGetCode())
            }
        }
        
        if start_paused {
            base.flags |= {.PAUSED}
        }
        if loop {
            base.flags |= {.LOOP}
        }
    }
}

sound_resume :: proc(sound: ^Sound) {
    if audio.ready { 
        base := cast(^Base_Sound)sound
        handle := _sound_get_channel_handle(sound)
        bass.Mixer_ChannelFlags(handle, 0, bass.MIXER_CHAN_PAUSE)
        base.flags &= ~{.PAUSED}
    }
}

sound_pause :: proc(sound: ^Sound) {
    if audio.ready { 
        base := cast(^Base_Sound)sound
        handle := _sound_get_channel_handle(sound)
        bass.Mixer_ChannelFlags(handle, bass.MIXER_CHAN_PAUSE, bass.MIXER_CHAN_PAUSE)
        base.flags |= {.PAUSED}
    }
}

_sound_get_channel_handle :: proc(sound: ^Sound) -> (result: Sound_Handle) {
    switch s in sound {
    case Sound_Stream:  result = s.handle
    case Sound_Channel: result = s.handle
    }
    return result
}

//////////////////////////////////////////////////////
// note(isak): sample api

sample_load_file :: proc(path: string, max_simultaneous: int = 8) -> (result: Sample, ok: bool) {
    result.filepath = path

    file_data, file_err := os.read_entire_file(path, context.allocator)
    if file_err != nil {
        log.error("sample_load_file: could not read file:", path, file_err)
        return result, false
    }
    result.file_data = file_data

    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    
    // note(isak): SAMPLE_OVER_POS drops the oldest instance when the pool is exhausted
    result.handle = bass.SampleLoad(0, rawptr(path_cstr), 0, 0, u32(max_simultaneous),
        bass.SAMPLE_FLOAT | bass.SAMPLE_OVER_POS)
    if result.handle == 0 {
        err := bass.ErrorGetCode()        
        if err == bass.ERROR_EMPTY {
            log.warn("BASS sample load warning: no samples in file", path)
        } else {
            log.error("BASS sample load error:", bass.ErrorGetCode(), "::", path)
        }
        return result, false
    }
    return result, true
}

sample_load_memory :: proc(data: rawptr, max_simultaneous: int = 8) -> (result: Sample, ok: bool) {
    result.handle = bass.SampleLoad(bass.FILE_MEM, data, 0, 0, u32(max_simultaneous), 
        bass.SAMPLE_FLOAT | bass.SAMPLE_OVER_POS)
    if result.handle == 0 {
        log.error("BASS sample load error:", bass.ErrorGetCode())
        return result, false
    }
    return result, true
}

sample_play :: proc(s: ^Sample, volume: f32 = 1.0, pan: f32 = 0.0) {
    if !audio.ready || s.handle == 0 do return
    channel := bass.SampleGetChannel(s.handle, 0)
    if channel == 0 {
        log.error("BASS sample get channel error:", bass.ErrorGetCode())
        return
    }
    bass.ChannelSetAttribute(channel, bass.ATTRIB_NORAMP, 1.0)
    bass.ChannelSetAttribute(channel, bass.ATTRIB_VOL, volume)
    bass.ChannelSetAttribute(channel, bass.ATTRIB_PAN, pan)
    if !bass.ChannelPlay(channel, false) {
        log.error("BASS sample play error:", bass.ErrorGetCode())
    }
}

sample_destroy :: proc(s: ^Sample) {
    bass.SampleFree(s.handle)
    s.handle = 0
}
