#+build linux
package inso

import "core:log"

import "dep:bass"

// note(isak): BASS handles output via ALSA/PulseAudio directly. every reinit follows the same
// recipe, verified in the audio harness: free the old output device, init the target fresh
// (which binds the buffer config), rebuild the mixer chain on it, and reattach every sound.
// the sources themselves (music stream, loop streams, sample channels, samples) live on the
// no-sound host device 0 initialized at startup, so they survive the teardown with their
// positions frozen and just get reattached to the new chain.
_platform_audio_init :: proc(device: Audio_Device) -> b32 {
    // note(isak): BASS has no -1 once a device is up; on linux the "Default" device is hardcoded
    // to device number 1, which is what -1 maps to (and what startup inits when unconfigured)
    target := device
    if target == DEVICE_DEFAULT do target = 1

    // note(isak): period (how often the device buffer refills) is derived at half of buffer size;
    // buffer gets rounded up by the driver when needed. the configs bind on the next Init
    buffer_ms := clamp(game.user_config.linux_audio_buffer_ms, AUDIO_BUFFER_MS_MIN, AUDIO_BUFFER_MS_MAX)
    period_ms := max(1, buffer_ms / 2)
    bass.SetConfig(bass.CONFIG_UPDATEPERIOD, 1)
    bass.SetConfig(bass.CONFIG_DEV_PERIOD,   u32(period_ms))
    bass.SetConfig(bass.CONFIG_DEV_BUFFER,   u32(buffer_ms))
    bass.SetConfig(bass.CONFIG_BUFFER,       u32(max(period_ms + 1, buffer_ms)))

    if audio.output_mixer != 0 {
        // note(isak): free the old output device. the mixer chain dies with it (handles included),
        // the host-owned sources survive; the chain is rebuilt below
        old_dev := bass.ChannelGetDevice(audio.output_mixer)
        if old_dev != 0 && old_dev != 0xFFFFFFFF {
            if !bass.SetDevice(old_dev) || !bass.Free() {
                log.error("BASS free error (device", device, "):", bass.ErrorGetCode())
                return false
            }
        }
        audio.output_mixer = 0
        audio.music_mixer = 0
        audio.hitsound_mixer = 0
    } else if bass.GetDevice() != 0 {
        // note(isak): a zombie device from a failed init attempt - the chain never came up, so
        // there is no mixer to read the device from; free whatever is current instead
        if !bass.Free() {
            log.error("BASS free error (device", device, "):", bass.ErrorGetCode())
            return false
        }
    }

    if !bass.Init(target, 44100, 0, nil, nil) {
        log.error("BASS init error (device", device, "):", bass.ErrorGetCode())
        return false
    }
    // note(isak): the mixer chain must land on the output device
    bass.SetDevice(bass.DWORD(target))

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
    audio.output_latency_ms = f64(info.latency) + f64(info.minbuf) / 2

    audio.device_index = device
    log.infof("BASS output: device %v @ %vhz, device buffer %vms -> %.1fms effective",
        device, freq, buffer_ms, audio.output_latency_ms)

    ok := _audio_init_mixers(freq, 2, .LIVE)
    if !ok do return false

    // note(isak): back to the host so everything created from here on (sounds, samples, sample
    // channels) is pinned to device 0 and survives the next teardown. playing channels are
    // unaffected - output runs on the mixer's own device
    bass.SetDevice(0)
    return true
}
