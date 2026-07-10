/*
    BASSmix 2.4 C/C++ header file
    Copyright (c) 2005-2022 Un4seen Developments Ltd.

    See the BASSMIX.CHM file for more detailed documentation
*/
package bass

MIX_LIB :: "lib/bassmix.lib" when ODIN_OS == .Windows else "system:bassmix"
foreign import lib { MIX_LIB }

// Additional SetConfig options
CONFIG_MIXER_BUFFER :: 0x10601
CONFIG_MIXER_POSEX  :: 0x10602
CONFIG_SPLIT_BUFFER :: 0x10610

// Mixer_StreamCreate flags
MIXER_RESUME    :: 0x1000  // resume stalled immediately upon new/unpaused source
MIXER_POSEX     :: 0x2000  // enable Mixer_ChannelGetPositionEx support
MIXER_NOSPEAKER  :: 0x4000 // ignore speaker arrangement
MIXER_QUEUE     :: 0x8000  // queue sources
MIXER_END       :: 0x10000 // end the stream when there are no sources
MIXER_NONSTOP   :: 0x20000 // don't stall when there are no sources

// Mixer_StreamAddChannel/Ex flags
MIXER_CHAN_ABSOLUTE :: 0x1000   // start is an absolute position
MIXER_CHAN_BUFFER   :: 0x2000   // buffer data for Mixer_ChannelGetData/Level
MIXER_CHAN_LIMIT    :: 0x4000   // limit mixer processing to the amount available from this source
MIXER_CHAN_MATRIX   :: 0x10000  // matrix mixing
MIXER_CHAN_PAUSE    :: 0x20000  // don't process the source
MIXER_CHAN_DOWNMIX  :: 0x400000 // downmix to stereo/mono
MIXER_CHAN_NORAMPIN :: 0x800000 // don't ramp-in the start
MIXER_BUFFER        :: MIXER_CHAN_BUFFER
MIXER_LIMIT         :: MIXER_CHAN_LIMIT
MIXER_MATRIX        :: MIXER_CHAN_MATRIX
MIXER_PAUSE         :: MIXER_CHAN_PAUSE
MIXER_DOWNMIX       :: MIXER_CHAN_DOWNMIX
MIXER_NORAMPIN      :: MIXER_CHAN_NORAMPIN

// Mixer attributes
ATTRIB_MIXER_LATENCY :: 0x15000
ATTRIB_MIXER_THREADS :: 0x15001
ATTRIB_MIXER_VOL     :: 0x15002

// Additional Mixer_ChannelIsActive return values
ACTIVE_WAITING   :: 5
ACTIVE_QUEUED   :: 6

// Split_StreamCreate flags
SPLIT_SLAVE  :: 0x1000 // only read buffered data
SPLIT_POS   :: 0x2000

// Splitter attributes
ATTRIB_SPLIT_ASYNCBUFFER  :: 0x15010
ATTRIB_SPLIT_ASYNCPERIOD  :: 0x15011

// Envelope node
MIXER_NODE :: struct {
    pos:   QWORD,
    value: f32,
}

// Envelope types
MIXER_ENV_FREQ   :: 1
MIXER_ENV_VOL    :: 2
MIXER_ENV_PAN    :: 3
MIXER_ENV_LOOP   :: 0x10000 // flag: loop
MIXER_ENV_REMOVE :: 0x20000 // flag: remove at end

// Additional sync types
SYNC_MIXER_ENVELOPE      :: 0x10200
SYNC_MIXER_ENVELOPE_NODE :: 0x10201
SYNC_MIXER_QUEUE         :: 0x10202

// Additional Mixer_ChannelSetPosition flag
POS_MIXER_RESET :: 0x10000 // flag: clear mixer's playback buffer

// Additional Mixer_ChannelGetPosition mode
POS_MIXER_DELAY :: 5

// CHANNELINFO types
CTYPE_STREAM_MIXER :: 0x10800
CTYPE_STREAM_SPLIT :: 0x10801

@(default_calling_convention="c",link_prefix="BASS_")
foreign lib {
    Mixer_GetVersion            :: proc() -> DWORD ---
    Mixer_StreamCreate          :: proc(freq: DWORD, chans: DWORD, flags: DWORD) -> HSTREAM ---
    Mixer_StreamAddChannel      :: proc(handle: HSTREAM, channel: DWORD, flags: DWORD) -> BOOL ---
    Mixer_StreamAddChannelEx    :: proc(handle: HSTREAM, channel: DWORD, flags: DWORD, start: QWORD, length: QWORD) -> BOOL ---
    Mixer_StreamGetChannels     :: proc(handle: HSTREAM, channels: ^DWORD, count: DWORD) -> DWORD ---
    Mixer_ChannelGetMixer       :: proc(handle: DWORD) -> HSTREAM ---
    Mixer_ChannelIsActive       :: proc(handle: DWORD) -> DWORD ---
    Mixer_ChannelFlags          :: proc(handle: DWORD, flags: DWORD, mask: DWORD) -> DWORD ---
    Mixer_ChannelRemove         :: proc(handle: DWORD) -> BOOL ---
    Mixer_ChannelSetPosition    :: proc(handle: DWORD, pos: QWORD, mode: DWORD) -> BOOL ---
    Mixer_ChannelGetPosition    :: proc(handle: DWORD, mode: DWORD) -> QWORD ---
    Mixer_ChannelGetPositionEx  :: proc(channel: DWORD, mode: DWORD, delay: DWORD) -> QWORD ---
    Mixer_ChannelGetLevel       :: proc(handle: DWORD) -> DWORD ---
    Mixer_ChannelGetLevelEx     :: proc(handle: DWORD, levels: ^f32, length: f32, flags: DWORD) -> BOOL ---
    Mixer_ChannelGetData        :: proc(handle: DWORD, buffer: rawptr, length: DWORD) -> DWORD ---
    Mixer_ChannelSetSync        :: proc(handle: DWORD, type: DWORD, param: QWORD, _proc: SYNCPROC, user: rawptr) -> HSYNC ---
    Mixer_ChannelRemoveSync     :: proc(channel: DWORD, sync: HSYNC) -> BOOL ---
    Mixer_ChannelSetMatrix      :: proc(handle: DWORD, _matrix: rawptr) -> BOOL ---
    Mixer_ChannelSetMatrixEx    :: proc(handle: DWORD, _matrix: rawptr, time: f32) -> BOOL ---
    Mixer_ChannelGetMatrix      :: proc(handle: DWORD, _matrix: rawptr) -> BOOL ---
    Mixer_ChannelSetEnvelope    :: proc(handle: DWORD, type: DWORD, nodes: ^MIXER_NODE, count: DWORD) -> BOOL ---
    Mixer_ChannelSetEnvelopePos :: proc(handle: DWORD, type: DWORD, pos: QWORD) -> BOOL ---
    Mixer_ChannelGetEnvelopePos :: proc(handle: DWORD, type: DWORD, value: ^f32) -> QWORD ---
    Split_StreamCreate          :: proc(channel: DWORD, flags: DWORD, chanmap: ^i32) -> HSTREAM ---
    Split_StreamGetSource       :: proc(handle: HSTREAM) -> DWORD ---
    Split_StreamGetSplits       :: proc(handle: DWORD, splits: ^HSTREAM, count: DWORD) -> DWORD ---
    Split_StreamReset           :: proc(handle: DWORD) -> BOOL ---
    Split_StreamResetEx         :: proc(handle: DWORD, offset: DWORD) -> BOOL ---
    Split_StreamGetAvailable    :: proc(handle: DWORD) -> DWORD ---
}
