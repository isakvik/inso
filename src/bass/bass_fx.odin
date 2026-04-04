/*===========================================================================
 FX 2.4 - Copyright (c) 2002-2018 (: JOBnik! :) [Arthur Aminov, ISRAEL]
                                                     [http://www.jobnik.org]

      bugs/suggestions/questions:
        forum  : http://www.un4seen.com/forum/?board=1
                 http://www.jobnik.org/forums
        e-mail : bass_fx@jobnik.org
     --------------------------------------------------

 NOTE: This header will work only with FX version 2.4.12
       Check www.un4seen.com or www.jobnik.org for any later versions.

 * Requires BASS 2.4 (available at http://www.un4seen.com)
===========================================================================*/
package bass

import "core:c"

FX_LIB :: "lib/bass_fx.lib" when ODIN_OS == .Windows else "system:bass_fx"
foreign import lib { FX_LIB }

// BASS_CHANNELINFO types
CTYPE_STREAM_TEMPO   :: 0x1f200
CTYPE_STREAM_REVERSE :: 0x1f201

// Tempo / Reverse / BPM / Beat flag
FX_FREESOURCE   :: 0x10000 // Free the source handle as well?

@(default_calling_convention="c")
foreign lib {
    // FX Version
    FX_GetVersion :: proc() -> DWORD ---
}

/*===========================================================================
DSP (Digital Signal Processing)
===========================================================================*/

/*
Multi-channel order of each channel is as follows:
3 channels       left-front, right-front, center.
4 channels       left-front, right-front, left-rear/side, right-rear/side.
5 channels       left-front, right-front, center, left-rear/side, right-rear/side.
6 channels (5.1) left-front, right-front, center, LFE, left-rear/side, right-rear/side.
8 channels (7.1) left-front, right-front, center, LFE, left-rear/side, right-rear/side, left-rear center, right-rear center.
*/

// DSP channels flags
BFX_CHANALL        :: -1  // all channels at once (as by default)
BFX_CHANNONE       :: 0   // disable an effect for all channels
BFX_CHAN1          :: 1   // left-front channel
BFX_CHAN2          :: 2   // right-front channel
BFX_CHAN3          :: 4   // see above info
BFX_CHAN4          :: 8   // see above info
BFX_CHAN5          :: 16  // see above info
BFX_CHAN6          :: 32  // see above info
BFX_CHAN7          :: 64  // see above info
BFX_CHAN8          :: 128 // see above info
FX_BFX_CHORUS      :: 65549
FX_BFX_APF         :: 65550
FX_BFX_COMPRESSOR  :: 65551
FX_BFX_DISTORTION  :: 65552
FX_BFX_COMPRESSOR2 :: 65553
FX_BFX_VOLUME_ENV  :: 65554
FX_BFX_BQF         :: 65555
FX_BFX_ECHO4       :: 65556
FX_BFX_PITCHSHIFT  :: 65557
FX_BFX_ECHO2       :: 65546
FX_BFX_DAMP        :: 65544
FX_BFX_MIX         :: 65543
FX_BFX_AUTOWAH     :: 65545
FX_BFX_PHASER      :: 65547
FX_BFX_PEAKEQ      :: 65540
FX_BFX_VOLUME      :: 65539
FX_BFX_REVERB      :: 65541
FX_BFX_ECHO        :: 65537
FX_BFX_ROTATE      :: 65536
FX_BFX_FLANGER     :: 65538
FX_BFX_LPF         :: 65542
FX_BFX_ECHO3       :: 65548
FX_BFX_FREEVERB    :: 65558

// Rotate
BFX_ROTATE :: struct {
    fRate:    f32, // rotation rate/speed in Hz (A negative rate can be used for reverse direction)
    lChannel: i32, // BFX_CHANxxx flag/s (supported only even number of channels)
}

// Echo (deprecated)
BFX_ECHO :: struct {
    fLevel: f32, // [0....1....n] linear
    lDelay: i32, // [1200..30000]
}

// Flanger (deprecated)
BFX_FLANGER :: struct {
    fWetDry:  f32, // [0....1....n] linear
    fSpeed:   f32, // [0......0.09]
    lChannel: i32, // BFX_CHANxxx flag/s
}

// Volume
BFX_VOLUME :: struct {
    lChannel: i32, // BFX_CHANxxx flag/s or 0 for global volume control
    fVolume:  f32, // [0....1....n] linear
}

// Peaking Equalizer
BFX_PEAKEQ :: struct {
    lBand:      i32, // [0...............n] more bands means more memory & cpu usage
    fBandwidth: f32, // [0.1...........<10] in octaves - fQ is not in use (Bandwidth has a priority over fQ)
    fQ:         f32, // [0...............1] the EE kinda definition (linear) (if Bandwidth is not in use)
    fCenter:    f32, // [1Hz..<info.freq/2] in Hz
    fGain:      f32, // [-15dB...0...+15dB] in dB (can be above/below these limits)
    lChannel:   i32, // BFX_CHANxxx flag/s
}

// Reverb (deprecated)
BFX_REVERB :: struct {
    fLevel: f32, // [0....1....n] linear
    lDelay: i32, // [1200..10000]
}

// Low Pass Filter (deprecated)
BFX_LPF :: struct {
    fResonance:  f32, // [0.01...........10]
    fCutOffFreq: f32, // [1Hz...info.freq/2] cutoff frequency
    lChannel:    i32, // BFX_CHANxxx flag/s
}

// Swap, remap and mix
BFX_MIX :: struct {
    lChannel: ^i32, // an array of channels to mix using BFX_CHANxxx flag/s (lChannel[0] is left channel...)
}

// Dynamic Amplification
BFX_DAMP :: struct {
    fTarget:  f32, // target volume level                        [0<......1] linear
    fQuiet:   f32, // quiet  volume level                        [0.......1] linear
    fRate:    f32, // amp adjustment rate                        [0.......1] linear
    fGain:    f32, // amplification level                        [0...1...n] linear
    fDelay:   f32, // delay in seconds before increasing level    [0.......n] linear
    lChannel: i32, // BFX_CHANxxx flag/s
}

// Auto Wah
BFX_AUTOWAH :: struct {
    fDryMix:   f32, // dry (unaffected) signal mix                [-2......2]
    fWetMix:   f32, // wet (affected) signal mix                [-2......2]
    fFeedback: f32, // output signal to feed back into input    [-1......1]
    fRate:     f32, // rate of sweep in cycles per second        [0<....<10]
    fRange:    f32, // sweep range in octaves                    [0<....<10]
    fFreq:     f32, // base frequency of sweep Hz                [0<...1000]
    lChannel:  i32, // BFX_CHANxxx flag/s
}

// Echo 2 (deprecated)
BFX_ECHO2 :: struct {
    fDryMix:   f32, // dry (unaffected) signal mix                [-2......2]
    fWetMix:   f32, // wet (affected) signal mix                [-2......2]
    fFeedback: f32, // output signal to feed back into input    [-1......1]
    fDelay:    f32, // delay sec                                [0<......n]
    lChannel:  i32, // BFX_CHANxxx flag/s
}

// Phaser
BFX_PHASER :: struct {
    fDryMix:   f32, // dry (unaffected) signal mix                [-2......2]
    fWetMix:   f32, // wet (affected) signal mix                [-2......2]
    fFeedback: f32, // output signal to feed back into input    [-1......1]
    fRate:     f32, // rate of sweep in cycles per second        [0<....<10]
    fRange:    f32, // sweep range in octaves                    [0<....<10]
    fFreq:     f32, // base frequency of sweep                    [0<...1000]
    lChannel:  i32, // BFX_CHANxxx flag/s
}

// Echo 3 (deprecated)
BFX_ECHO3 :: struct {
    fDryMix:  f32, // dry (unaffected) signal mix                [-2......2]
    fWetMix:  f32, // wet (affected) signal mix                [-2......2]
    fDelay:   f32, // delay sec                                [0<......n]
    lChannel: i32, // BFX_CHANxxx flag/s
}

// Chorus/Flanger
BFX_CHORUS :: struct {
    fDryMix:   f32, // dry (unaffected) signal mix                [-2......2]
    fWetMix:   f32, // wet (affected) signal mix                [-2......2]
    fFeedback: f32, // output signal to feed back into input    [-1......1]
    fMinSweep: f32, // minimal delay ms                            [0<...6000]
    fMaxSweep: f32, // maximum delay ms                            [0<...6000]
    fRate:     f32, // rate ms/s                                [0<...1000]
    lChannel:  i32, // BFX_CHANxxx flag/s
}

// All Pass Filter (deprecated)
BFX_APF :: struct {
    fGain:    f32, // reverberation time                        [-1=<..<=1]
    fDelay:   f32, // delay sec                                [0<....<=n]
    lChannel: i32, // BFX_CHANxxx flag/s
}

// Compressor (deprecated)
BFX_COMPRESSOR :: struct {
    fThreshold:   f32, // compressor threshold                        [0<=...<=1]
    fAttacktime:  f32, // attack time ms                            [0<.<=1000]
    fReleasetime: f32, // release time ms                            [0<.<=5000]
    lChannel:     i32, // BFX_CHANxxx flag/s
}

// Distortion
BFX_DISTORTION :: struct {
    fDrive:    f32, // distortion drive                            [0<=...<=5]
    fDryMix:   f32, // dry (unaffected) signal mix                [-5<=..<=5]
    fWetMix:   f32, // wet (affected) signal mix                [-5<=..<=5]
    fFeedback: f32, // output signal to feed back into input    [-1<=..<=1]
    fVolume:   f32, // distortion volume                        [0=<...<=2]
    lChannel:  i32, // BFX_CHANxxx flag/s
}

// Compressor 2
BFX_COMPRESSOR2 :: struct {
    fGain:      f32, // output gain of signal after compression    [-60....60] in dB
    fThreshold: f32, // point at which compression begins        [-60.....0] in dB
    fRatio:     f32, // compression ratio                        [1.......n]
    fAttack:    f32, // attack time in ms                        [0.01.1000]
    fRelease:   f32, // release time in ms                        [0.01.5000]
    lChannel:   i32, // BFX_CHANxxx flag/s
}

// Volume envelope
BFX_VOLUME_ENV :: struct {
    lChannel:   i32,                // BFX_CHANxxx flag/s
    lNodeCount: i32,                // number of nodes
    pNodes:     ^BFX_ENV_NODE, // the nodes
    bFollow:    BOOL,               // follow source position
}

BFX_ENV_NODE :: struct {
    pos: f64, // node position in seconds (1st envelope node must be at position 0)
    val: f32, // node value
}

BFX_BQF_LOWPASS    :: 0
BFX_BQF_LOWSHELF   :: 7
BFX_BQF_PEAKINGEQ  :: 6
BFX_BQF_HIGHSHELF  :: 8
BFX_BQF_NOTCH      :: 4
BFX_BQF_BANDPASS   :: 2
BFX_BQF_HIGHPASS   :: 1
BFX_BQF_BANDPASS_Q :: 3
BFX_BQF_ALLPASS    :: 5

BFX_BQF :: struct {
    lFilter:    i32, // BFX_BQF_xxx filter types
    fCenter:    f32, // [1Hz..<info.freq/2] Cutoff (central) frequency in Hz
    fGain:      f32, // [-15dB...0...+15dB] Used only for PEAKINGEQ and Shelving filters in dB (can be above/below these limits)
    fBandwidth: f32, // [0.1...........<10] Bandwidth in octaves (fQ is not in use (fBandwidth has a priority over fQ))

    //                         (between -3 dB frequencies for BANDPASS and NOTCH or between midpoint
    //                         (fGgain/2) gain frequencies for PEAKINGEQ)
    fQ: f32, // [0.1.............1] The EE kinda definition (linear) (if fBandwidth is not in use)
    fS: f32, // [0.1.............1] A "shelf slope" parameter (linear) (used only with Shelving filters)

    //                         when fS = 1, the shelf slope is as steep as you can get it and remain monotonically
    //                         increasing or decreasing gain with frequency.
    lChannel: i32, // BFX_CHANxxx flag/s
}

// Echo 4
BFX_ECHO4 :: struct {
    fDryMix:   f32,  // dry (unaffected) signal mix                [-2.......2]
    fWetMix:   f32,  // wet (affected) signal mix                [-2.......2]
    fFeedback: f32,  // output signal to feed back into input    [-1.......1]
    fDelay:    f32,  // delay sec                                [0<.......n]
    bStereo:   BOOL, // echo adjoining channels to each other    [TRUE/FALSE]
    lChannel:  i32,  // BFX_CHANxxx flag/s
}

// Pitch shift (not available on mobile)
BFX_PITCHSHIFT :: struct {
    fPitchShift: f32, // A factor value which is between 0.5 (one octave down) and 2 (one octave up) (1 won't change the pitch) [1 default]

    // (fSemitones is not in use, fPitchShift has a priority over fSemitones)
    fSemitones: f32,    // Semitones (0 won't change the pitch) [0 default]
    lFFTsize:   c.long, // Defines the FFT frame size used for the processing. Typical values are 1024, 2048 and 4096 [2048 default]

    // It may be any value <= 8192 but it MUST be a power of 2
    lOsamp: c.long, // Is the STFT oversampling factor which also determines the overlap between adjacent STFT frames [8 default]

    // It should at least be 4 for moderate scaling ratios. A value of 32 is recommended for best quality (better quality = higher CPU usage)
    lChannel: i32, // BFX_CHANxxx flag/s
}

// Freeverb
BFX_FREEVERB_MODE_FREEZE :: 1

BFX_FREEVERB :: struct {
    fDryMix:   f32,   // dry (unaffected) signal mix                [0........1], def. 0
    fWetMix:   f32,   // wet (affected) signal mix                [0........3], def. 1.0f
    fRoomSize: f32,   // room size                                [0........1], def. 0.5f
    fDamp:     f32,   // damping                                    [0........1], def. 0.5f
    fWidth:    f32,   // stereo width                                [0........1], def. 1
    lMode:     DWORD, // 0 or BFX_FREEVERB_MODE_FREEZE, def. 0 (no freeze)
    lChannel:  i32,   // BFX_CHANxxx flag/s
}

ATTRIB_TEMPO_FREQ                    :: 65538
ATTRIB_TEMPO                         :: 65536
ATTRIB_TEMPO_PITCH                   :: 65537
ATTRIB_TEMPO_OPTION_USE_QUICKALGO    :: 65554
ATTRIB_TEMPO_OPTION_AA_FILTER_LENGTH :: 65553
ATTRIB_TEMPO_OPTION_SEQUENCE_MS      :: 65555
ATTRIB_TEMPO_OPTION_USE_AA_FILTER    :: 65552
ATTRIB_TEMPO_OPTION_SEEKWINDOW_MS    :: 65556
ATTRIB_TEMPO_OPTION_OVERLAP_MS       :: 65557
ATTRIB_TEMPO_OPTION_PREVENT_CLICK    :: 65558

// tempo algorithm flags
FX_TEMPO_ALGO_LINEAR  :: 0x200
FX_TEMPO_ALGO_CUBIC   :: 0x400 // default
FX_TEMPO_ALGO_SHANNON  :: 0x800

@(default_calling_convention="c",link_prefix="BASS_")
foreign lib {
    FX_TempoCreate       :: proc(chan: DWORD, flags: DWORD) -> HSTREAM ---
    FX_TempoGetSource    :: proc(chan: HSTREAM) -> DWORD ---
    FX_TempoGetRateRatio :: proc(chan: HSTREAM) -> f32 ---
}

/*===========================================================================
Reverse playback
===========================================================================*/

// NOTES: 1. MODs won't load without MUSIC_PRESCAN flag.
//          2. Enable Reverse supported flags in FX_ReverseCreate and the others to source handle.

// reverse attribute (ChannelSet/GetAttribute)
ATTRIB_REVERSE_DIR :: 0x11000

// playback directions
FX_RVS_REVERSE :: -1
FX_RVS_FORWARD :: 1

@(default_calling_convention="c",link_prefix="BASS_")
foreign lib {
    FX_ReverseCreate    :: proc(chan: DWORD, dec_block: f32, flags: DWORD) -> HSTREAM ---
    FX_ReverseGetSource :: proc(chan: HSTREAM) -> DWORD ---
}

/*===========================================================================
BPM (Beats Per Minute)
===========================================================================*/

// bpm flags
FX_BPM_BKGRND        :: 1 // if in use, then you can do other processing while detection's in progress. Available only in Windows platforms (BPM/Beat)
FX_BPM_MULT2         :: 2 // if in use, then will auto multiply bpm by 2 (if BPM < minBPM*2)
FX_BPM_TRAN_PERCENT2 :: 4
FX_BPM_TRAN_2PERCENT :: 3
FX_BPM_TRAN_X2       :: 0
FX_BPM_TRAN_2FREQ    :: 1
FX_BPM_TRAN_FREQ2    :: 2

@(default_calling_convention="c",link_prefix="BASS_")
foreign lib {
    BPMPROC                   :: proc(DWORD, f32, rawptr) ---
    BPMPROGRESSPROC           :: proc(DWORD, f32, rawptr) ---
    BPMPROCESSPROC            :: proc(DWORD, f32, rawptr) ---                                // back-compatibility
    FX_BPM_DecodeGet     :: proc(chan: DWORD, startSec: f64, endSec: f64, minMaxBPM: DWORD, flags: DWORD, _proc: proc "c" (), user: rawptr) -> f32 ---
    FX_BPM_CallbackSet   :: proc(handle: DWORD, _proc: proc "c" (), period: f64, minMaxBPM: DWORD, flags: DWORD, user: rawptr) -> BOOL ---
    FX_BPM_CallbackReset :: proc(handle: DWORD) -> BOOL ---
    FX_BPM_Translate     :: proc(handle: DWORD, val2tran: f32, trans: DWORD) -> f32 --- // deprecated
    FX_BPM_Free          :: proc(handle: DWORD) -> BOOL ---

    /*===========================================================================
    Beat position trigger
    ===========================================================================*/
    BPMBEATPROC                   :: proc(DWORD, f64, rawptr) ---
    FX_BPM_BeatCallbackSet   :: proc(handle: DWORD, _proc: proc "c" (), user: rawptr) -> BOOL ---
    FX_BPM_BeatCallbackReset :: proc(handle: DWORD) -> BOOL ---
    FX_BPM_BeatDecodeGet     :: proc(chan: DWORD, startSec: f64, endSec: f64, flags: DWORD, _proc: proc "c" (), user: rawptr) -> BOOL ---
    FX_BPM_BeatSetParameters :: proc(handle: DWORD, bandwidth: f32, centerfreq: f32, beat_rtime: f32) -> BOOL ---
    FX_BPM_BeatGetParameters :: proc(handle: DWORD, bandwidth: ^f32, centerfreq: ^f32, beat_rtime: ^f32) -> BOOL ---
    FX_BPM_BeatFree          :: proc(handle: DWORD) -> BOOL ---
}
