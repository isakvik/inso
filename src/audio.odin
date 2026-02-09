package notosu

import "core:strings"
import "core:fmt"
import "core:math"

import "bass"


audio: struct {
    ready: bool,
    wasapi_info: bass.WASAPI_INFO,
    wasapi_output_mixer: bass.HSTREAM
}

Device :: i32
Sound_Handle :: bass.DWORD

Sound_Flags :: distinct bit_set[Sound_Flag; u32]
Sound_Flag :: enum u32 {
    STREAM,
    LOOP,
    PRESCAN,
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

Sound_Stream :: struct {
    using base: Base_Sound,
    handle: bass.HSTREAM,
}

Sound_Channel :: struct {
    using base: Base_Sound,
    handle: bass.HCHANNEL,
}

//////////////////////////////////////////////////////
// note(isak): audio engine api

bass_wasapi_proc :: proc "c" (buffer: rawptr, len: u32, user_data: rawptr) -> u32 {
    if audio.wasapi_output_mixer != 0 {
		c := bass.ChannelGetData(audio.wasapi_output_mixer, buffer, len)
		return max(c, 0)
	}
	return 0
}

// todo(isak): should probably call this device_init() or something
audio_init :: proc(device: Device = -1) -> bool {
    init := bass.Init(device, 44100, bass.DEVICE_NOSPEAKER, nil, nil);

    if !bass.WASAPI_Init(
        device = -1,
        freq = 0,
        chans = 0,
        flags = bass.WASAPI_EVENT | bass.WASAPI_AUTOFORMAT,
        buffer = 0,
        period = math.F32_EPSILON,
        _proc = bass_wasapi_proc,
        user = nil
    ) {
        fmt.printfln("BASS_WASAPI init error: {}", bass.ErrorGetCode())
        return false
    }
    
    bass.WASAPI_Start()
    
    bass.WASAPI_GetInfo(&audio.wasapi_info)
    audio.wasapi_output_mixer = bass.Mixer_StreamCreate(audio.wasapi_info.freq, audio.wasapi_info.chans, 
        bass.SAMPLE_FLOAT | bass.STREAM_DECODE | bass.MIXER_NONSTOP)
    
    if audio.wasapi_output_mixer == 0 {
        fmt.printfln("BASS WASAPI mixer init error: {}", bass.ErrorGetCode())
        return false
    }
    
    audio.ready = true
    return true
}

audio_cleanup :: proc() {
    bass.WASAPI_Free()
}

// note(isak): volume is a 0.0 - 1.0 range
audio_set_volume :: proc(volume: f32) {
    bass.WASAPI_SetVolume(bass.WASAPI_CURVE_WINDOWS | bass.WASAPI_VOL_SESSION, volume)
}

//////////////////////////////////////////////////////
// note(isak): sound api

sound_stream_init :: proc(path: string, prescan: bool = false) -> (result: Sound_Stream) {
    // bass.UNICODE for wstring
    init_flags: u32 = bass.STREAM_DECODE | bass.SAMPLE_FLOAT | (prescan ? bass.STREAM_PRESCAN : 0)
    
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    result.handle = bass.StreamCreateFile(0, rawptr(path_cstr), 0, 0, init_flags)
    if result.handle == 0 {
        fmt.printfln("BASS stream create error: {}", bass.ErrorGetCode())
    }
    
    //bass.ChannelSetAttribute(m_HSTREAM, bass.ATTRIB_TEMPO_OPTION_USE_QUICKALGO, true)
	//bass.ChannelSetAttribute(m_HSTREAM, bass.ATTRIB_TEMPO_OPTION_OVERLAP_MS, 4.0)
	//bass.ChannelSetAttribute(m_HSTREAM, bass.ATTRIB_TEMPO_OPTION_SEQUENCE_MS, 30.0)
    
    //tempo_flags := bass.STREAM_DECODE

    result.flags = { .STREAM }
    result.flags |= prescan ? {.PRESCAN} : {}
    
    return result
}

sound_stream_cleanup :: proc(sound: ^Sound) {
    switch s in sound {
    case Sound_Stream:  bass.StreamFree(s.handle)
    case Sound_Channel: bass.ChannelFree(s.handle)
    }
}

sound_is_playing :: proc(sound: ^Sound) -> (result: bool) {
    if audio.ready { 
        switch s in sound {
        // todo(isak): overlayable stream is a bit more complicated but not implemented yet
        case Sound_Stream:  result = bass.ChannelIsActive(s.handle) == bass.ACTIVE_PLAYING
        case Sound_Channel: result = bass.ChannelIsActive(s.handle) == bass.ACTIVE_PLAYING
        }
    }
    return result
}

sound_is_finished :: proc(sound: ^Sound) -> (result: bool) {
    if audio.ready { 
        handle := _sound_get_handle(sound)
        result = bass.ChannelIsActive(handle) == bass.ACTIVE_STOPPED
    }
    return result
}

sound_get_position_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready { 
        handle := _sound_get_handle(sound)
        length := bass.ChannelGetPosition(handle, bass.POS_BYTE)
        result = bass.ChannelBytes2Seconds(handle, length) * 1000
    }
    return result
}

sound_set_position_ms :: proc(sound: ^Sound, ms: f64) {
    if audio.ready { 
        handle := _sound_get_handle(sound)
        
        pos_bytes := bass.ChannelSeconds2Bytes(handle, ms / 1000)
        err := bass.ChannelSetPosition(handle, pos_bytes, bass.POS_BYTE)
        if err {
            fmt.println("BASS ChannelSetPosition error:", bass.ErrorGetCode())
        }
    }
}

sound_get_length_ms :: proc(sound: ^Sound) -> (result: f64) {
    if audio.ready { 
        handle := _sound_get_handle(sound)
        length := bass.ChannelGetLength(handle, bass.POS_BYTE)
        result = bass.ChannelBytes2Seconds(handle, length) * 1000
    }
    return result
}

sound_play :: proc(sound: ^Sound) {
    base := transmute(^Base_Sound)sound
    handle := _sound_get_handle(sound)
    
    bass.ChannelSetAttribute(handle, bass.ATTRIB_NORAMP, 1.0) // see https://github.com/ppy/osu-framework/pull/3146
    
    if bass.Mixer_ChannelGetMixer(handle) == 0 {
        flags: u32 = bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN
        flags |= (Sound_Flag.STREAM in base.flags ? bass.STREAM_AUTOFREE : 0)
        
        ok := bass.Mixer_StreamAddChannel(audio.wasapi_output_mixer, handle, flags)
        if ok == false {
            fmt.printfln("sound_play :: BASS mixer add channel error: {}", bass.ErrorGetCode())
        }
    }
    
    if !sound_is_playing(sound) {
        ok := bass.ChannelPlay(handle, true)
        if ok == false {
            fmt.printfln("sound_play :: BASS mixer play error: {}", bass.ErrorGetCode())
        }
    }
}


_sound_get_handle :: proc(sound: ^Sound) -> (result: Sound_Handle) {
    switch s in sound {
    case Sound_Stream:  result = s.handle
    case Sound_Channel: result = s.handle
    }
    return result
}
