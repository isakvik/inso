package inso

import "base:intrinsics"
import "core:strings"
import "core:log"
import os "core:os"

import "dep:bass"


Sound_Category :: enum { MUSIC, HITSOUND }

Audio_Device_Info :: struct {
    index:  Audio_Device, // note(isak): bass device index; -1 = the default device
    name:   string,
    driver: string,
    flags:  bass.DWORD,
    // note(isak): index into the wasapi endpoint list, precomputed at enumeration time so a
    // switch never has to walk WASAPI_GetDeviceInfo. -1 = unresolved (use the OS default)
    wasapi_index: i32,
}

audio: struct {
    ready: bool,
    device_reinit_requested: bool,
    device_list_rebuild_requested: bool,
    device_index: Audio_Device,
    devices: [dynamic]Audio_Device_Info,
    default_device_name: string,
    // note(isak): linux only. bass is initialized only once, so a reinit to another device is deferred
    bass_init_done: bool,
    output_mixer, music_mixer, hitsound_mixer: bass.HSTREAM,
    // note(isak): wasapi device buffer in ms; decode positions lead the speakers by this much.
    // 0 on the linux dev path (BASS's own output buffering, uncompensated)
    output_latency_ms: f64,
}

Audio_Device :: i32
DEVICE_DEFAULT :: Audio_Device(-1)

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
    expires_at_ms: f64, // note(isak): 0 = no expiry
    rate_trim: f64,
    rate_trim_base_freq: f32, // note: captured on first trim; 0 = not yet read
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

// note(isak): sample held in memory with a fixed channel pool. use for short sounds that may overlap
Sample :: struct {
    handle:    bass.HSAMPLE,
    filepath:  string, // note(isak): filename only; join with mapset.folder_path for full path
    file_data: []byte, // note(isak): raw file bytes kept alive for in-memory stream creation
}

// note(isak): how the master output mixer is driven
Mixer_Chain_Kind :: enum {
    DECODE, // decode source for WASAPI audioclient
    LIVE,   // stream playing directly to device
}

//////////////////////////////////////////////////////
// note(isak): audio engine api

audio_init :: proc() -> bool {
    _audio_enumerate_devices()

    when ODIN_OS == .Windows {
        // note(isak): device 0 is BASS's "no sound" device; it only hosts decode streams and
        // samples here, all actual output goes through WASAPI.
        // freq 0 (device's own rate) fails on the no-sound device and leaves BASS
        // in a half-initialized state where Mixer_StreamCreate then fails with
        // BASS_ERROR_INIT, so we set a sane default
        if !bass.Init(0, 44100, 0, nil, nil) {
            log.error("BASS init error:", bass.ErrorGetCode())
            return false
        }
        // note(isak): the bass->wasapi index map is only trustworthy once BASS is up; the wasapi
        // enumeration shares state with the initialized output. run it here, not in enumerate
        _platform_audio_resolve_wasapi_indices()
    }

    audio.ready = _audio_init_on_valid_device()

    when ODIN_OS == .Windows {
        if audio.ready {
            bass.WASAPI_SetNotify(_bass_wasapi_notify_proc, nil)
        }
    }
    return audio.ready
}

audio_cleanup :: proc() {
    when ODIN_OS == .Windows {
        _platform_audio_cleanup()
    }
    bass.Free()

    _set_default_device_name("")
    for i in 0..<len(audio.devices) {
        delete(audio.devices[i].name)
        delete(audio.devices[i].driver)
    }
    delete(audio.devices)
}

_set_default_device_name :: proc(name: string) {
    if audio.default_device_name == name do return
    delete(audio.default_device_name)
    audio.default_device_name = strings.clone(name, context.allocator) if len(name) > 0 else ""
}

_audio_enumerate_devices :: proc() {
    _set_default_device_name("")

    for _, i in audio.devices {
        delete(audio.devices[i].name)
        delete(audio.devices[i].driver)
    }
    clear(&audio.devices)
    
    when ODIN_OS == .Windows {
        bass.SetConfig(bass.CONFIG_UNICODE, 1) // device name strings in unicode instead of ansi
        bass.SetConfig(bass.CONFIG_DEV_DEFAULT, 1) // inserts default into device list at index 1
    }

    for i in 0..<256 {
        info: bass.DEVICEINFO
        if !bass.GetDeviceInfo(device = bass.DWORD(i), info = &info) do break
        if i <= 1 do continue
        if info.flags & bass.DEVICE_ENABLED == 0 do continue

        if len(audio.default_device_name) == 0 && info.flags & bass.DEVICE_DEFAULT != 0 &&
                len(string(info.name)) > 0 && string(info.name) != "Default" {
            _set_default_device_name(string(info.name))
        }

        append(&audio.devices, Audio_Device_Info{
            index  = Audio_Device(i),
            name   = strings.clone(string(info.name), context.allocator),
            driver = strings.clone(string(info.driver), context.allocator),
            flags  = info.flags,
            wasapi_index = i32(DEVICE_DEFAULT),
        })
    }
}

_audio_init_mixers :: proc(freq: bass.DWORD, chans: bass.DWORD, kind: Mixer_Chain_Kind) -> bool {
    // note(isak): a 0 channel or 0 freq from a backend means it didn't configure right, so
    // set a sane default
    freq, chans := freq, chans
    if chans == 0 do chans = 2
    if freq == 0 do freq = 44100

    output_flags: u32 = bass.SAMPLE_FLOAT | bass.MIXER_NONSTOP
    if kind == .DECODE {
        output_flags |= bass.STREAM_DECODE
    }

    if audio.output_mixer != 0 {
        mixer_info: bass.CHANNELINFO
        if bass.ChannelGetInfo(audio.output_mixer, &mixer_info) &&
                freq == mixer_info.freq && chans == mixer_info.chans {
            return true
        }

        // note(isak): format changed; rebuild the chain
        bass.Mixer_ChannelRemove(audio.music_mixer)
        bass.Mixer_ChannelRemove(audio.hitsound_mixer)
        bass.StreamFree(audio.output_mixer)
        audio.output_mixer = 0
    }

    audio.output_mixer = bass.Mixer_StreamCreate(freq, chans, output_flags)
    if audio.output_mixer == 0 {
        log.error("BASS mixer init error:", bass.ErrorGetCode(), "(freq", freq, "chans", chans, ")")
        return false
    }
    audio.music_mixer = bass.Mixer_StreamCreate(freq, chans,
        bass.SAMPLE_FLOAT | bass.STREAM_DECODE | bass.MIXER_NONSTOP)
    audio.hitsound_mixer = bass.Mixer_StreamCreate(freq, chans,
        bass.SAMPLE_FLOAT | bass.STREAM_DECODE | bass.MIXER_NONSTOP)
    bass.Mixer_StreamAddChannel(audio.output_mixer, audio.music_mixer,    bass.MIXER_DOWNMIX)
    bass.Mixer_StreamAddChannel(audio.output_mixer, audio.hitsound_mixer, bass.MIXER_DOWNMIX)

    if kind == .LIVE {
        bass.ChannelPlay(audio.output_mixer, false)
    }
    return true
}

_audio_init_on_valid_device :: proc() -> bool {
    configured := game.user_config.audio_device

    if configured != DEVICE_DEFAULT && _platform_audio_init(configured) {
        log.infof("audio: using configured device %v", configured)
        return true
    }

    if _platform_audio_init(DEVICE_DEFAULT) {
        if configured != DEVICE_DEFAULT {
            log.warnf("audio: configured device %v failed, using default", configured)
        }
        return true
    }

    for dev in audio.devices {
        if _platform_audio_init(dev.index) {
            log.infof("audio: fell back to device %v (%s)", dev.index, dev.name)
            return true
        }
    }
    return false
}

// note(isak): moves the output when windows reports the default device or the device list changed
audio_handle_device_change :: proc() -> (reinitialized: bool) {
    when ODIN_OS == .Windows {
        rebuild_list := intrinsics.atomic_exchange(&audio.device_list_rebuild_requested, false)
        reinit := intrinsics.atomic_exchange(&audio.device_reinit_requested, false)
        if !rebuild_list && !reinit do return false

        // note(isak): the bass list and the cached wasapi mapping are snapshots from the last
        // enumeration, so a device appearing means the dropdown and the mapping are both stale
        if rebuild_list {
            _audio_enumerate_devices()
            when ODIN_OS == .Windows {
                _platform_audio_resolve_wasapi_indices()
            }
            audio_device_dropdown_rebuild()
        }

        if reinit || !audio.ready {
            if _platform_audio_init(audio.device_index) {
                audio.ready = true
            } else {
                // note(isak): the selected device is gone; fall back the way startup does
                audio.ready = _audio_init_on_valid_device()
            }
            if audio.ready && audio.device_index == DEVICE_DEFAULT {
                // note(isak): while following the OS default, its name can change out from under us
                audio_device_dropdown_rebuild()
            }
            return audio.ready
        }
        return true
    } else {
        return false
    }
}

// note(isak): reinits audio and mixer chain on the new device
audio_set_device :: proc(device: Audio_Device) -> bool {
    if device == audio.device_index do return true
    audio.device_index = device

    if _platform_audio_init(device) {
        audio.ready = true
        return true
    }

    audio.ready = false
    notify_error("audio device %v failed to initialize", device)
    return false
}

// note(isak): reinits the audio chain on the current device, e.g. after a buffer-size
// setting change. config like CONFIG_DEV_BUFFER only binds on the next Init
audio_reopen :: proc() -> bool {
    if !_platform_audio_init(audio.device_index) {
        audio.ready = false
        notify_error("audio re-init on device %v failed", audio.device_index)
        return false
    }
    audio.ready = true
    audio_apply_config_volumes()
    return true
}

// note(isak): volume is a 0.0 - 1.0 range
audio_set_volume :: proc(volume: f32) {
    when ODIN_OS == .Windows {
        bass.WASAPI_SetVolume(bass.WASAPI_CURVE_WINDOWS | bass.WASAPI_VOL_SESSION, volume)
    } else {
        bass.SetVolume(volume)
    }
}

audio_set_category_volume :: proc(category: Sound_Category, volume: f32) {
    switch category {
    case .MUSIC:    bass.ChannelSetAttribute(audio.music_mixer,    bass.ATTRIB_VOL, volume)
    case .HITSOUND: bass.ChannelSetAttribute(audio.hitsound_mixer, bass.ATTRIB_VOL, volume)
    }
}

effective_hitsound_volume :: proc() -> f32 {
    cfg := &game.user_config
    return cfg.music_volume if cfg.hitsound_volume_follows_music else cfg.hitsound_volume
}

audio_apply_config_volumes :: proc() {
    audio_set_volume(game.user_config.master_volume)
    audio_set_category_volume(.MUSIC, game.user_config.music_volume)
    audio_set_category_volume(.HITSOUND, effective_hitsound_volume())
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
    
    tempo_handle := bass.FX_TempoCreate(result.handle, bass.FX_FREESOURCE | bass.STREAM_DECODE)
    if tempo_handle == 0 {
        log.error("BASS tempo stream create error:", bass.ErrorGetCode(), "::", path)
        bass.StreamFree(result.handle)
        result.handle = 0
        return result, false
    }
    result.handle = tempo_handle

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
    // note(isak): STREAM_DECODE is only valid on sample channels together with SAMCHAN_STREAM
    channel := bass.SampleGetChannel(s.handle, (loop ? bass.SAMPLE_LOOP : 0) | bass.SAMCHAN_STREAM | bass.STREAM_DECODE)
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

// note: reports the audible position, not the decode position - the raw read leads the speakers
// by the output buffer. clamped so a fresh start reads 0 while the buffer first fills
sound_get_position_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready {
        handle := _sound_get_channel_handle(sound)
        pos := bass.ChannelGetPosition(handle, bass.POS_BYTE)
        result = max(0, bass.ChannelBytes2Seconds(handle, pos) * 1000 - audio.output_latency_ms)
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

sound_set_speed :: proc(sound: ^Sound, rate: f32, compensate_pitch: bool = true) {
    if audio.ready { 
        handle := _sound_get_channel_handle(sound)
        rate := clamp(rate, 1/50, 50)
        
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

// note(isak): nudges playback rate by a fraction. continuous resample-ratio change
sound_set_rate_trim :: proc(sound: ^Sound, trim: f64) {
    if !audio.ready do return
    base := cast(^Base_Sound)sound
    if base.rate_trim == trim do return

    handle := _sound_get_channel_handle(sound)
    if base.rate_trim_base_freq == 0 {
        if !bass.ChannelGetAttribute(handle, bass.ATTRIB_FREQ, &base.rate_trim_base_freq) do return
    }
    bass.ChannelSetAttribute(handle, bass.ATTRIB_FREQ, base.rate_trim_base_freq * f32(1 + trim))
    base.rate_trim = trim
}

sound_play :: proc(sound: ^Sound, start_paused: bool = false, loop: bool = false, volume: f32 = 1.0, category: Sound_Category = .MUSIC) {
    if audio.ready {
        base := cast(^Base_Sound)sound
        handle := _sound_get_channel_handle(sound)

        bass.ChannelSetAttribute(handle, bass.ATTRIB_NORAMP, 1.0) // see https://github.com/ppy/osu-framework/pull/3146
        bass.ChannelSetAttribute(handle, bass.ATTRIB_VOL, volume)

        if bass.Mixer_ChannelGetMixer(handle) == 0 {
            flags: u32 = bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN
            flags |= (!loop && .STREAM in base.flags) ? bass.STREAM_AUTOFREE : 0
            flags |= start_paused ? bass.MIXER_CHAN_PAUSE : 0

            mixer := audio.music_mixer if category == .MUSIC else audio.hitsound_mixer
            if !bass.Mixer_StreamAddChannel(mixer, handle, flags) {
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

    if len(file_data) == 0 {
        return result, true
    }

    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)

    // note(isak): SAMPLE_OVER_POS drops the oldest instance when the pool is exhausted
    result.handle = bass.SampleLoad(0, rawptr(path_cstr), 0, 0, u32(max_simultaneous),
        bass.SAMPLE_FLOAT | bass.SAMPLE_OVER_POS)
    if result.handle == 0 {
        err := bass.ErrorGetCode()
        if err == bass.ERROR_EMPTY {
            return result, true
        }
        log.error("BASS sample load error:", err, "::", path)
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

// note(isak): fire-and-forget playback through the hitsound mixer. the decode sample stream
// frees itself when it ends, and the mixer applies the hitsound category volume
sample_play :: proc(s: ^Sample, volume: f32 = 1.0, pan: f32 = 0.0) {
    if !audio.ready || s.handle == 0 do return
    channel := bass.SampleGetChannel(s.handle, bass.SAMCHAN_STREAM | bass.STREAM_DECODE)
    if channel == 0 {
        log.error("BASS sample get channel error:", bass.ErrorGetCode())
        return
    }
    bass.ChannelSetAttribute(channel, bass.ATTRIB_NORAMP, 1.0)
    bass.ChannelSetAttribute(channel, bass.ATTRIB_VOL, volume)
    bass.ChannelSetAttribute(channel, bass.ATTRIB_PAN, pan)
    if !bass.Mixer_StreamAddChannel(audio.hitsound_mixer, channel,
        bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN | bass.STREAM_AUTOFREE) {
        log.error("BASS mixer add channel error:", bass.ErrorGetCode())
    }
}

sample_destroy :: proc(s: ^Sample) {
    bass.SampleFree(s.handle)
    s.handle = 0
}
