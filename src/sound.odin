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
Sound_Handle :: bass.HSTREAM

Sound :: struct {
    handle: Sound_Handle,
    
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
    
    return true
}

audio_cleanup :: proc() {
    bass.WASAPI_Free()
}

// note(isak): volume is a 0.0 - 1.0 range
audio_set_volume :: proc(vol: f32) {
    bass.WASAPI_SetVolume(bass.WASAPI_CURVE_WINDOWS | bass.WASAPI_VOL_SESSION, vol)
}

//////////////////////////////////////////////////////
// note(isak): sound api

sound_init :: proc(path: string, prescan: bool = false) -> Sound {
    result: Sound
    // bass.UNICODE for wstring
    flags: u32 = (prescan ? bass.STREAM_PRESCAN : 0) | bass.STREAM_DECODE | bass.SAMPLE_FLOAT
    
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    result.handle = bass.StreamCreateFile(0, rawptr(path_cstr), 0, 0, flags)
    if result.handle == 0 {
        fmt.printfln("BASS stream create error: {}", bass.ErrorGetCode())
    }
    
    //bass.ChannelSetAttribute(m_HSTREAM, bass.ATTRIB_TEMPO_OPTION_USE_QUICKALGO, true)
	//bass.ChannelSetAttribute(m_HSTREAM, bass.ATTRIB_TEMPO_OPTION_OVERLAP_MS, 4.0)
	//bass.ChannelSetAttribute(m_HSTREAM, bass.ATTRIB_TEMPO_OPTION_SEQUENCE_MS, 30.0)
    
    //tempo_flags := bass.STREAM_DECODE

    return result
}

sound_play :: proc(using sound: ^Sound) {
    bass.ChannelSetAttribute(handle, bass.ATTRIB_NORAMP, 1.0)
    
    if bass.Mixer_ChannelGetMixer(handle) == 0 {
        // note(isak): might not want stream autofree based on if we use nonstream sounds
        flags: u32 = bass.STREAM_AUTOFREE | bass.MIXER_DOWNMIX | bass.MIXER_NORAMPIN
        ok := bass.Mixer_StreamAddChannel(audio.wasapi_output_mixer, handle, flags)
        if ok == false {
            fmt.printfln("BASS mixer add channel error: {}", bass.ErrorGetCode())
        }
    }
    
    if bass.ChannelIsActive(handle) != bass.ACTIVE_PLAYING {
        ok := bass.ChannelPlay(handle, true)
        if ok == false {
            fmt.printfln("BASS mixer play error: {}", bass.ErrorGetCode())
        }
    }
}

sound_cleanup :: proc(using sound: ^Sound) {
    bass.StreamFree(handle)
}
