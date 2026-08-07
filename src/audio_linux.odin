#+build linux
package inso

import "core:log"

import "dep:bass"

_platform_audio_init :: proc(device: Audio_Device) -> b32 {
    // note(isak): BASS handles output via ALSA/PulseAudio directly
    _platform_audio_cleanup()

    // note(isak): period (how often the device buffer refills) is derived at half of buffer size; 
    // buffer gets rounded up by the driver when needed.
    buffer_ms := i32(clamp(game.user_config.linux_audio_buffer_ms, AUDIO_BUFFER_MS_MIN, AUDIO_BUFFER_MS_MAX))
    period_ms := max(1, buffer_ms / 2)
    bass.SetConfig(bass.CONFIG_UPDATEPERIOD, 1)
    bass.SetConfig(bass.CONFIG_DEV_PERIOD,   u32(period_ms))
    bass.SetConfig(bass.CONFIG_DEV_BUFFER,   u32(buffer_ms))
    bass.SetConfig(bass.CONFIG_BUFFER,       u32(max(period_ms + 1, buffer_ms)))

    if !bass.Init(device, 0, 0, nil, nil) {
        log.error("BASS init error (device", device, "):", bass.ErrorGetCode())
        return false
    }

    info: bass.INFO
    if !bass.GetInfo(&info) {
        log.error("BASS GetInfo error:", bass.ErrorGetCode())
        return false
    }
    freq := info.freq
    if freq == 0 {
        log.warn("BASS output reported 0 sample rate; falling back to 44100")
        freq = 44100
    }

    // note(isak): device buffer rounds up on the driver side too, so latency reports the
    // playhead offset into the buffer on top of that. track the real figure the way the
    // wasapi path does so sound_get_position_ms compensates on linux too
    device_latency_ms := f64(info.latency) + f64(info.minbuf) / 2

    audio.device_index = device
    audio.output_latency_ms = device_latency_ms
    log.infof("BASS output: device %v @ %vhz, device buffer %vms -> %.1fms effective",
        device, freq, buffer_ms, device_latency_ms)
    return true if _audio_init_mixers(freq, 2, .LIVE) else false
}

_platform_audio_cleanup :: proc() {
    bass.Free()
}
