package inso

import "base:intrinsics"
import "core:strings"
import "core:log"
import "core:fmt"
import os "core:os"

import "dep:bass"


Sound_Group :: enum { MUSIC, HITSOUND }

Audio_Device_Info :: struct {
    index:  Audio_Device, // note(isak): bass device index; -1 = the default device
    name:   string,
    driver: string,
    flags:  bass.DWORD,
}

audio: struct {
    ready: bool,
    device_reinit_requested: bool,
    device_list_rebuild_requested: bool,
    device_index: Audio_Device,
    devices: [dynamic]Audio_Device_Info,
    default_device_name: string,
    output_mixer: bass.HSTREAM,
    group_mixers: [Sound_Group]bass.HSTREAM,
    // note(isak): wasapi device buffer in ms; decode positions lead the speakers by this much
    output_latency_ms: f64,
}

Audio_Device :: i32
DEVICE_DEFAULT :: Audio_Device(-1)

Sound_Handle :: bass.DWORD

Sound :: struct {
    handle:   Sound_Handle,
    paused:   bool, // note(isak): mirrors the mixer channel pause flag
    volume:   f32, // note(isak): 0.0 - 1.0 range
    expires_at_ms: f64, // note(isak): 0 = no expiry
    rate_trim: f64,
    rate_trim_base_freq: f32, // note(isak): captured on first trim; 0 = not yet read
    group: Sound_Group, // note(isak): which decode mixer the sound belongs to
}

// note(isak): sample held in memory with a fixed channel pool. use for short sounds that may overlap
Sample :: struct {
    handle:    bass.HSAMPLE,
    filepath:  string, // note(isak): filename only; join with mapset.folder_path for full path
    file_data: []byte, // note(isak): raw file bytes kept alive for in-memory stream creation
}

//////////////////////////////////////////////////////
// note(isak): audio engine api

audio_init :: proc() -> bool {
    _audio_enumerate_devices()

    // note(isak): device 0 is BASS's "no sound" device; every sound source (music stream, loop
    // streams, sample channels, samples) refers to it and survives output device teardowns, since
    // a reinit only ever frees the current output device. actual output goes through the device
    // the platform backend inits
    // freq 0 (use device config) doesn't work with our mixers, so we have to set a default
    if !bass.Init(0, 44100, 0, nil, nil) {
        log.error("BASS init error:", bass.ErrorGetCode())
        return false
    }
    bass.SetDevice(0)

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
        bass.WASAPI_Free()
    }
    // note(isak): the current device is normally the host (device 0) these days - Free frees
    // whatever is current, so point it at the output device first
    if audio.output_mixer != 0 {
        dev := bass.ChannelGetDevice(audio.output_mixer)
        if dev != 0 && dev != 0xFFFFFFFF {
            bass.SetDevice(dev)
        }
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
        })
    }
}

_audio_init_mixers :: proc(freq: bass.DWORD, chans: bass.DWORD) -> bool {
    // note(isak): a 0 channel or 0 freq from a backend means it didn't configure right, so
    // set a sane default
    freq, chans := freq, chans
    if chans == 0 do chans = 2
    if freq == 0 do freq = 44100

    // note(isak): mixers are attached to devices, so we have to rebuild the chain on reinit.
    // the source channels are kept alive on device 0, so it's just a matter of redirecting the
    // mixers to the platform output, and attaching the channels to the new chain here (keeping
    // playback position and pause state)
    output_flags: u32 = bass.SAMPLE_FLOAT | bass.MIXER_NONSTOP
    when ODIN_OS == .Windows {
        // note(isak): wasapi reads the output mixer to its own audio client
        output_flags |= bass.STREAM_DECODE
    }

    audio.output_mixer = bass.Mixer_StreamCreate(freq, chans, output_flags)
    if audio.output_mixer == 0 {
        log.error("BASS mixer init error:", bass.ErrorGetCode(), "(freq", freq, "chans", chans, ")")
        return false
    }
    
    for group in Sound_Group {
        audio.group_mixers[group] = bass.Mixer_StreamCreate(freq, chans,
            bass.SAMPLE_FLOAT | bass.STREAM_DECODE | bass.MIXER_NONSTOP)
        bass.Mixer_StreamAddChannel(audio.output_mixer, audio.group_mixers[group], bass.MIXER_DOWNMIX)
    }

    when ODIN_OS == .Linux {
        bass.ChannelPlay(audio.output_mixer, false)
    }
    bass.ChannelSetAttribute(audio.output_mixer, bass.ATTRIB_VOL, game.user_config.master_volume)
    _audio_chain_reintegrate_handles()
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

        // note(isak): the bass list is a snapshot from the last enumeration, so a device
        // appearing means the dropdown is stale
        if rebuild_list {
            _audio_enumerate_devices()
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
    if _platform_audio_init(device) {
        audio.ready = true
        return true
    }

    audio.ready = false
    notify_error("audio device '%s' failed to initialize", audio_device_name(device))
    return false
}

audio_device_name :: proc(device: Audio_Device) -> string {
    if device == DEVICE_DEFAULT {
        return "default"
    }
    for dev in audio.devices {
        if dev.index == device {
            return dev.name
        }
    }
    return fmt.tprint(device)
}

// note(isak): reinits the output on the current device, e.g. after a buffer-size
// setting change. config like CONFIG_DEV_BUFFER only binds on the next Init/REINIT
audio_reopen :: proc() -> bool {
    if !audio_set_device(audio.device_index) do return false
    audio_apply_config_volumes()
    return true
}

// note(isak): volume is a 0.0 - 1.0 range
audio_set_volume :: proc(volume: f32) {
    when ODIN_OS == .Windows {
        // note(isak): session volume is the program entry in the windows volume mixer
        bass.WASAPI_SetVolume(bass.WASAPI_CURVE_WINDOWS | bass.WASAPI_VOL_SESSION, volume)
    } else {
        // note(isak): BASS_SetVolume moves the system mixer's PCM control on linux, which is
        // visible to other apps; apply master volume inside our own chain instead
        if audio.output_mixer != 0 {
            bass.ChannelSetAttribute(audio.output_mixer, bass.ATTRIB_VOL, volume)
        }
    }
}

audio_group_set_volume :: proc(group: Sound_Group, volume: f32) {
    bass.ChannelSetAttribute(audio.group_mixers[group], bass.ATTRIB_VOL, volume)
}

audio_apply_config_volumes :: proc() {
    effective_hitsound_volume :: proc() -> f32 {
        cfg := &game.user_config
        return cfg.music_volume if cfg.hitsound_volume_follows_music else cfg.hitsound_volume
    }
    
    audio_set_volume(game.user_config.master_volume)
    audio_group_set_volume(.MUSIC, game.user_config.music_volume)
    audio_group_set_volume(.HITSOUND, effective_hitsound_volume())
}

//////////////////////////////////////////////////////
// note(isak): sound api

sound_stream_init :: proc(path: string, prescan: bool = false, loop: bool = false) -> (result: Sound, ok: bool) {
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
    
    return result, true
}

// note(isak): creates a decode stream suitable for adding to the WASAPI mixer.
// use for managed looping sounds where a sample channel (SampleGetChannel) can't be
// used as a decode channel reliably.
sound_loop_stream_init :: proc(path: string) -> (result: Sound, ok: bool) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    result.handle = bass.StreamCreateFile(0, rawptr(path_cstr), 0, 0,
        bass.STREAM_DECODE | bass.SAMPLE_FLOAT | bass.SAMPLE_LOOP)
    if result.handle == 0 {
        log.error("BASS loop stream create error:", bass.ErrorGetCode())
        return result, false
    }
    return result, true
}

sound_stream_init_from_memory :: proc(data: []byte, loop: bool = false) -> (result: Sound, ok: bool) {
    flags: u32 = bass.STREAM_DECODE | bass.SAMPLE_FLOAT
    flags |= loop ? bass.SAMPLE_LOOP : 0
    result.handle = bass.StreamCreateFile(bass.FILE_MEM, raw_data(data), 0, u64(len(data)), flags)
    if result.handle == 0 {
        log.error("BASS stream from memory error:", bass.ErrorGetCode())
        return result, false
    }
    return result, true
}

sound_destroy :: proc(sound: ^Sound) {
    bass.StreamFree(sound.handle)
}

sound_is_playing :: proc(sound: ^Sound) -> (result: bool) {
    if audio.ready && !sound.paused {
        result = bass.ChannelIsActive(sound.handle) == bass.ACTIVE_PLAYING
    }
    return result
}

sound_is_paused :: proc(sound: ^Sound) -> bool {
    return sound.paused
}

sound_is_finished :: proc(sound: ^Sound) -> (result: bool) {
    if audio.ready {
        result = bass.ChannelIsActive(sound.handle) == bass.ACTIVE_STOPPED
    }
    return result
}

sound_get_length_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready {
        length := bass.ChannelGetLength(sound.handle, bass.POS_BYTE)
        result = bass.ChannelBytes2Seconds(sound.handle, length) * 1000
    }
    return result
}

sound_get_audible_position_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready {
        pos := bass.ChannelGetPosition(sound.handle, bass.POS_BYTE)
        result = max(0, bass.ChannelBytes2Seconds(sound.handle, pos) * 1000 - audio.output_latency_ms)
    }
    return result
}

sound_get_position_fract :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready {
        pos := bass.ChannelGetPosition(sound.handle, bass.POS_BYTE)
        length := bass.ChannelGetLength(sound.handle, bass.POS_BYTE)
        result = f64(pos) / f64(length)
    }
    return result
}

sound_set_position_ms :: proc(sound: ^Sound, ms: f64) {
    if audio.ready {
        // note(isak): small epsilon here; setting the position to somewhere after this fails
        ms := clamp(ms, 0, sound_get_length_ms(sound) - 0.01)
        pos_bytes := bass.ChannelSeconds2Bytes(sound.handle, ms / 1000)
        if !bass.Mixer_ChannelSetPosition(sound.handle, pos_bytes, bass.POS_BYTE) {
            log.error("BASS channel set position error:", bass.ErrorGetCode())
        }
    }
}

sound_set_position_fract :: proc(sound: ^Sound, fract: f64) {
    if audio.ready {
        sound_length := sound_get_length_ms(sound)
        // note(isak): small epsilon here; setting the position to somewhere after this fails 
        ms := clamp(fract * sound_length, 0, sound_length - 0.01)
        pos_bytes := bass.ChannelSeconds2Bytes(sound.handle, ms / 1000)
        if !bass.Mixer_ChannelSetPosition(sound.handle, pos_bytes, bass.POS_BYTE) {
            log.error("BASS channel set position error:", bass.ErrorGetCode())
        }
    }
}

sound_set_volume :: proc(sound: ^Sound, volume: f32) {
    if audio.ready {
        sound.volume = volume
        bass.ChannelSetAttribute(sound.handle, bass.ATTRIB_VOL, volume)
    }
}

sound_set_speed :: proc(sound: ^Sound, rate: f32, compensate_pitch: bool = true) {
    if audio.ready {
        rate := clamp(rate, 1/50, 50)
        
        freq: f32
        if !bass.ChannelGetAttribute(sound.handle, bass.ATTRIB_FREQ, &freq) {
            log.error("BASS channel get freq error:", bass.ErrorGetCode())
        }
        
        freq_target := (compensate_pitch ? (rate-1.0) * 100.0 : rate * freq)
        if !bass.ChannelSetAttribute(sound.handle, (compensate_pitch ? bass.ATTRIB_TEMPO : bass.ATTRIB_TEMPO_FREQ), freq_target) {
            log.error("BASS channel set tempo error:", bass.ErrorGetCode(), compensate_pitch)
        }
    }
}

// note(isak): nudges playback rate by a fraction. continuous resample-ratio change
sound_set_rate_trim :: proc(sound: ^Sound, trim: f64) {
    if !audio.ready || sound.rate_trim == trim do return
    if sound.rate_trim_base_freq == 0 {
        if !bass.ChannelGetAttribute(sound.handle, bass.ATTRIB_FREQ, &sound.rate_trim_base_freq) do return
    }
    bass.ChannelSetAttribute(sound.handle, bass.ATTRIB_FREQ, sound.rate_trim_base_freq * f32(1 + trim))
    sound.rate_trim = trim
}

// note(isak): looping is decided at creation (SAMPLE_LOOP on the BASS handle); this proc never
// autofrees the channel. managed sounds are destroyed by their owner (expiry loop,
// game_sound_stop, teardown) - letting BASS autofree an ended stream first would make our
// destroy path hit a dead handle that BASS may have recycled for a new channel
sound_play :: proc(sound: ^Sound, start_paused: bool = false, volume: f32 = 1.0, group: Sound_Group = .MUSIC) {
    if !audio.ready do return
    sound.paused = start_paused
    sound.volume = volume
    sound.group = group

    bass.ChannelSetAttribute(sound.handle, bass.ATTRIB_VOL, volume)

    if bass.Mixer_ChannelGetMixer(sound.handle) == 0 {
        mixer := audio.group_mixers[group]
        _sound_add_to_mixer(sound.handle, mixer, start_paused)
    }
    
    if !start_paused && !sound_is_playing(sound) {
        if !bass.ChannelPlay(sound.handle, true) {
            log.error("BASS channel play error:", bass.ErrorGetCode())
        }
    }
}

sound_resume :: proc(sound: ^Sound) {
    if audio.ready {
        bass.Mixer_ChannelFlags(sound.handle, 0, bass.MIXER_CHAN_PAUSE)
        sound.paused = false
    }
}

sound_pause :: proc(sound: ^Sound) {
    if audio.ready {
        bass.Mixer_ChannelFlags(sound.handle, bass.MIXER_CHAN_PAUSE, bass.MIXER_CHAN_PAUSE)
        sound.paused = true
    }
}

// note(isak): attaches a source to a group mixer with the standard flags
_sound_add_to_mixer :: proc(handle: Sound_Handle, mixer: bass.HSTREAM, paused: bool) -> bool {
    flags: u32 = bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN
    flags |= paused ? bass.MIXER_CHAN_PAUSE : 0
    if !bass.Mixer_StreamAddChannel(mixer, handle, flags) {
        log.error("BASS mixer add channel error:", bass.ErrorGetCode())
        return false
    }
    // see https://github.com/ppy/osu-framework/pull/3146
    bass.ChannelSetAttribute(handle, bass.ATTRIB_NORAMP, 1.0)
    return true
}

// note(isak): needs to run even if reinit failed (audio.ready is false) because the mixer chain is rebuild
// regardless
_audio_chain_reintegrate_handles :: proc() {
    if audio.group_mixers[.MUSIC] == 0 || audio.group_mixers[.HITSOUND] == 0 do return
    
    // todo(isak): beatmap music is a special case all right, but relying on this being a complete list
    // is stupid and brittle
    _audio_chain_reattach(&game.beatmap.music, .MUSIC)
    for &sound in game.sounds.values {
        _audio_chain_reattach(&sound, sound.group)
    }
}

_audio_chain_reattach :: proc(sound: ^Sound, group: Sound_Group) {
    if sound.handle == 0 do return

    mixer := audio.group_mixers[group]
    if bass.Mixer_ChannelGetMixer(sound.handle) == mixer do return

    if bass.Mixer_ChannelGetMixer(sound.handle) != 0 {
        if !bass.Mixer_ChannelRemove(sound.handle) {
            log.error("BASS mixer remove error:", bass.ErrorGetCode())
            return
        }
    }
    
    if _sound_add_to_mixer(sound.handle, mixer, sound.paused) {
        bass.ChannelSetAttribute(sound.handle, bass.ATTRIB_VOL, sound.volume)
        
        if !sound.paused && bass.ChannelIsActive(sound.handle) == bass.ACTIVE_STOPPED {
            if !bass.ChannelPlay(sound.handle, false) {
                log.error("BASS channel play error:", bass.ErrorGetCode())
            }
        }
        log.info("audio: reattached sound to", group, "mixer (handle", sound.handle, ")")
    }
}

//////////////////////////////////////////////////////
// note(isak): sample api

sample_load_file :: proc(
    path: cstring, max_simultaneous: int = 8, alloc := context.allocator
) -> (result: Sample, ok: bool) {
    result.filepath = string(path)

    file_data, file_err := os.read_entire_file(string(path), alloc)
    if file_err != nil {
        log.error("sample_load_file: could not read file:", path, file_err)
        return result, false
    }
    result.file_data = file_data

    if len(file_data) == 0 {
        return result, true
    }

    // note(isak): SAMPLE_OVER_POS drops the oldest instance when the pool is exhausted
    result.handle = bass.SampleLoad(0, rawptr(path), 0, 0, u32(max_simultaneous),
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
    mixer := audio.group_mixers[.HITSOUND]
    bass.ChannelSetAttribute(channel, bass.ATTRIB_NORAMP, 1.0)
    bass.ChannelSetAttribute(channel, bass.ATTRIB_VOL, volume)
    bass.ChannelSetAttribute(channel, bass.ATTRIB_PAN, pan)
    
    if !bass.Mixer_StreamAddChannel(mixer, channel,
        bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN | bass.STREAM_AUTOFREE) {
        log.error("BASS mixer add channel error:", bass.ErrorGetCode())
    }
}

sample_destroy :: proc(s: ^Sample) {
    bass.SampleFree(s.handle)
    s.handle = 0
}
