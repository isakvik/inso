/*
    BASS 2.4 C/C++ header file
    Copyright (c) 1999-2025 Un4seen Developments Ltd.

    See the BASS.CHM file for more detailed documentation
*/
package bass

LIB :: "lib/bass.lib" when ODIN_OS == .Windows else "system:bass"
foreign import lib { LIB }

// note: these mirror the windows types BASS was designed around, but map to portable equivalents
HWND  :: rawptr // null on non-windows
BOOL  :: b32    // 32-bit bool, equivalent to windows BOOL / C int
BYTE  :: u8
WORD  :: u16
DWORD :: u32
QWORD :: u64


BASSVERSION     :: 0x204 // API version
BASSVERSIONTEXT  :: "2.4"

HMUSIC   :: DWORD // MOD music handle
HSAMPLE  :: DWORD // sample handle
HCHANNEL :: DWORD // sample playback handle
HSTREAM  :: DWORD // sample stream handle
HRECORD  :: DWORD // recording handle
HSYNC    :: DWORD // synchronizer handle
HDSP     :: DWORD // DSP handle
HFX      :: DWORD // effect handle
HPLUGIN  :: DWORD // plugin handle

// Error codes returned by ErrorGetCode
OK                 :: 0  // all is OK
ERROR_MEM          :: 1  // memory error
ERROR_FILEOPEN     :: 2  // can't open the file
ERROR_DRIVER       :: 3  // can't find a free/valid driver
ERROR_BUFLOST      :: 4  // the sample buffer was lost
ERROR_HANDLE       :: 5  // invalid handle
ERROR_FORMAT       :: 6  // unsupported sample format
ERROR_POSITION     :: 7  // invalid position
ERROR_INIT         :: 8  // Init has not been successfully called
ERROR_START        :: 9  // Start has not been successfully called
ERROR_SSL          :: 10 // SSL/HTTPS support isn't available
ERROR_REINIT       :: 11 // device needs to be reinitialized
ERROR_TRACK        :: 13 // invalid track number
ERROR_ALREADY      :: 14 // already initialized/paused/whatever
ERROR_NOTAUDIO     :: 17 // file does not contain audio
ERROR_NOCHAN       :: 18 // can't get a free channel
ERROR_ILLTYPE      :: 19 // an illegal type was specified
ERROR_ILLPARAM     :: 20 // an illegal parameter was specified
ERROR_NO3D         :: 21 // no 3D support
ERROR_NOEAX        :: 22 // no EAX support
ERROR_DEVICE       :: 23 // illegal device number
ERROR_NOPLAY       :: 24 // not playing
ERROR_FREQ         :: 25 // illegal sample rate
ERROR_NOTFILE      :: 27 // the stream is not a file stream
ERROR_NOHW         :: 29 // no hardware voices available
ERROR_EMPTY        :: 31 // the file has no sample data
ERROR_NONET        :: 32 // no internet connection could be opened
ERROR_CREATE       :: 33 // couldn't create the file
ERROR_NOFX         :: 34 // effects are not available
ERROR_NOTAVAIL     :: 37 // requested data/action is not available
ERROR_DECODE       :: 38 // the channel is/isn't a "decoding channel"
ERROR_DX           :: 39 // a sufficient DirectX version is not installed
ERROR_TIMEOUT      :: 40 // connection timedout
ERROR_FILEFORM     :: 41 // unsupported file format
ERROR_SPEAKER      :: 42 // unavailable speaker
ERROR_VERSION      :: 43 // invalid BASS version (used by add-ons)
ERROR_CODEC        :: 44 // codec is not available/supported
ERROR_ENDED        :: 45 // the channel/file has ended
ERROR_BUSY         :: 46 // the device is busy
ERROR_UNSTREAMABLE :: 47 // unstreamable file
ERROR_PROTOCOL     :: 48 // unsupported protocol
ERROR_DENIED       :: 49 // access denied
ERROR_FREEING      :: 50 // being freed
ERROR_CANCEL       :: 51 // cancelled
ERROR_UNKNOWN      :: -1 // some other mystery problem

// SetConfig options
CONFIG_BUFFER             :: 0
CONFIG_UPDATEPERIOD       :: 1
CONFIG_GVOL_SAMPLE        :: 4
CONFIG_GVOL_STREAM        :: 5
CONFIG_GVOL_MUSIC         :: 6
CONFIG_CURVE_VOL          :: 7
CONFIG_CURVE_PAN          :: 8
CONFIG_FLOATDSP           :: 9
CONFIG_3DALGORITHM        :: 10
CONFIG_NET_TIMEOUT        :: 11
CONFIG_NET_BUFFER         :: 12
CONFIG_PAUSE_NOPLAY       :: 13
CONFIG_NET_PREBUF         :: 15
CONFIG_NET_PASSIVE        :: 18
CONFIG_REC_BUFFER         :: 19
CONFIG_NET_PLAYLIST       :: 21
CONFIG_MUSIC_VIRTUAL      :: 22
CONFIG_VERIFY             :: 23
CONFIG_UPDATETHREADS      :: 24
CONFIG_DEV_BUFFER         :: 27
CONFIG_REC_LOOPBACK       :: 28
CONFIG_IOS_SESSION        :: 34
CONFIG_IOS_MIXAUDIO       :: 34
CONFIG_DEV_DEFAULT        :: 36
CONFIG_NET_READTIMEOUT    :: 37
CONFIG_VISTA_SPEAKERS     :: 38
CONFIG_IOS_SPEAKER        :: 39
CONFIG_MF_DISABLE         :: 40
CONFIG_HANDLES            :: 41
CONFIG_UNICODE            :: 42
CONFIG_SRC                :: 43
CONFIG_SRC_SAMPLE         :: 44
CONFIG_ASYNCFILE_BUFFER   :: 45
CONFIG_OGG_PRESCAN        :: 47
CONFIG_VIDEO              :: 48
CONFIG_MF_VIDEO           :: CONFIG_VIDEO
CONFIG_AIRPLAY            :: 49
CONFIG_DEV_NONSTOP        :: 50
CONFIG_IOS_NOCATEGORY     :: 51
CONFIG_VERIFY_NET         :: 52
CONFIG_DEV_PERIOD         :: 53
CONFIG_FLOAT              :: 54
CONFIG_NET_SEEK           :: 56
CONFIG_AM_DISABLE         :: 58
CONFIG_NET_PLAYLIST_DEPTH :: 59
CONFIG_NET_PREBUF_WAIT    :: 60
CONFIG_ANDROID_SESSIONID  :: 62
CONFIG_WASAPI_PERSIST     :: 65
CONFIG_REC_WASAPI         :: 66
CONFIG_ANDROID_AAUDIO     :: 67
CONFIG_SAMPLE_ONEHANDLE   :: 69
CONFIG_NET_META           :: 71
CONFIG_NET_RESTRATE       :: 72
CONFIG_REC_DEFAULT        :: 73
CONFIG_NORAMP             :: 74
CONFIG_NOSOUND_MAXDELAY   :: 76
CONFIG_STACKALLOC         :: 79
CONFIG_DOWNMIX            :: 80

// SetConfigPtr options
CONFIG_NET_AGENT      :: 16
CONFIG_NET_PROXY      :: 17
CONFIG_DEV_NOTIFY     :: 33
CONFIG_IOS_NOTIFY     :: 46
CONFIG_ANDROID_JAVAVM :: 63
CONFIG_LIBSSL         :: 64
CONFIG_FILENAME       :: 75
CONFIG_FILEOPENPROCS  :: 77
CONFIG_THREAD         :: 0x40000000 // flag: thread-specific setting

// CONFIG_IOS_SESSION flags
IOS_SESSION_MIX        :: 1
IOS_SESSION_DUCK       :: 2
IOS_SESSION_AMBIENT    :: 4
IOS_SESSION_SPEAKER    :: 8
IOS_SESSION_DISABLE    :: 0x10
IOS_SESSION_DEACTIVATE :: 0x20
IOS_SESSION_AIRPLAY    :: 0x40
IOS_SESSION_BTHFP      :: 0x80
IOS_SESSION_BTA2DP     :: 0x100

// Init flags
DEVICE_8BITS      :: 1        // unused
DEVICE_MONO       :: 2        // mono
DEVICE_3D         :: 4        // unused
DEVICE_16BITS     :: 8        // limit output to 16-bit
DEVICE_REINIT     :: 0x80     // reinitialize
DEVICE_LATENCY    :: 0x100    // unused
DEVICE_CPSPEAKERS :: 0x400    // unused
DEVICE_SPEAKERS   :: 0x800    // force enabling of speaker assignment
DEVICE_NOSPEAKER  :: 0x1000   // ignore speaker arrangement
DEVICE_DMIX       :: 0x2000   // use ALSA "dmix" plugin
DEVICE_FREQ       :: 0x4000   // set device sample rate
DEVICE_STEREO     :: 0x8000   // limit output to stereo
DEVICE_HOG        :: 0x10000  // hog/exclusive mode
DEVICE_AUDIOTRACK :: 0x20000  // use AudioTrack output
DEVICE_DSOUND     :: 0x40000  // use DirectSound output
DEVICE_SOFTWARE   :: 0x80000  // disable hardware/fastpath output
DEVICE_OPENSLES   :: 0x100000 // use OpenSLES output
DEVICE_APPLEVOICE :: 0x200000 // use Apple voice processing

// DirectSound interfaces (for use with GetDSoundObject)
OBJECT_DS    :: 1 // IDirectSound
OBJECT_DS3DL :: 2 // IDirectSound3DListener

// Device info structure
DEVICEINFO :: struct {
    name:   cstring, // description
    driver: cstring, // driver
    flags:  DWORD,
}

// DEVICEINFO flags
DEVICE_ENABLED          :: 1
DEVICE_DEFAULT          :: 2
DEVICE_INIT             :: 4
DEVICE_LOOPBACK         :: 8
DEVICE_DEFAULTCOM       :: 0x80
DEVICE_TYPE_MASK        :: 0xff000000
DEVICE_TYPE_NETWORK     :: 0x01000000
DEVICE_TYPE_SPEAKERS    :: 0x02000000
DEVICE_TYPE_LINE        :: 0x03000000
DEVICE_TYPE_HEADPHONES  :: 0x04000000
DEVICE_TYPE_MICROPHONE  :: 0x05000000
DEVICE_TYPE_HEADSET     :: 0x06000000
DEVICE_TYPE_HANDSET     :: 0x07000000
DEVICE_TYPE_DIGITAL     :: 0x08000000
DEVICE_TYPE_SPDIF       :: 0x09000000
DEVICE_TYPE_HDMI        :: 0x0a000000
DEVICE_TYPE_DISPLAYPORT :: 0x40000000

// GetDeviceInfo flags
DEVICES_AIRPLAY :: 0x1000000

// Output device info structure
INFO :: struct {
    flags:     DWORD, // DirectSound capabilities (DSCAPS_xxx flags)
    reserved:  [7]DWORD,
    minbuf:    DWORD, // recommended minimum buffer length in ms
    dsver:     DWORD, // DirectSound version
    latency:   DWORD, // average delay (in ms) before start of playback
    initflags: DWORD, // Init "flags" parameter
    speakers:  DWORD, // number of speakers available
    freq:      DWORD, // current output rate
}

// INFO flags (from DSOUND.H)
DSCAPS_EMULDRIVER  :: 0x00000020 // device does not have hardware DirectSound support
DSCAPS_CERTIFIED  :: 0x00000040  // device driver has been certified by Microsoft
DSCAPS_HARDWARE   :: 0x80000000  // hardware mixed

// Recording device info structure
RECORDINFO :: struct {
    flags:    DWORD, // DirectSound capabilities (DSCCAPS_xxx flags)
    formats:  DWORD, // number of channels (in high 8 bits)
    inputs:   DWORD, // number of inputs
    singlein: BOOL,  // TRUE = only 1 input can be set at a time
    freq:     DWORD, // current sample rate
}

// RECORDINFO flags (from DSOUND.H)
DSCCAPS_EMULDRIVER  :: DSCAPS_EMULDRIVER // device does not have hardware DirectSound recording support
DSCCAPS_CERTIFIED  :: DSCAPS_CERTIFIED   // device driver has been certified by Microsoft

// filetypes
FILE_NAME    :: 0  // filename
FILE_MEM     :: 1  // memory
FILE_MEMCOPY  :: 3 // memory to copy
FILE_HANDLE  :: 4  // handle/descriptor

// Sample info structure
SAMPLE :: struct {
    freq:     DWORD, // default playback rate
    volume:   f32,   // default volume (0-1)
    pan:      f32,   // default pan (-1=left, 0=middle, 1=right)
    flags:    DWORD, // SAMPLE_xxx flags
    length:   DWORD, // length (in bytes)
    max:      DWORD, // maximum simultaneous playbacks
    origres:  DWORD, // original resolution
    chans:    DWORD, // number of channels
    mingap:   DWORD, // minimum gap (ms) between creating channels
    mode3d:   DWORD, // 3DMODE_xxx mode
    mindist:  f32,   // minimum distance
    maxdist:  f32,   // maximum distance
    iangle:   DWORD, // angle of inside projection cone
    oangle:   DWORD, // angle of outside projection cone
    outvol:   f32,   // delta-volume outside the projection cone
    reserved: [2]DWORD,
}

SAMPLE_8BITS     :: 1                   // 8 bit
SAMPLE_MONO      :: 2                   // mono
SAMPLE_LOOP      :: 4                   // looped
SAMPLE_3D        :: 8                   // 3D functionality
SAMPLE_SOFTWARE  :: 0x10                // unused
SAMPLE_MUTEMAX   :: 0x20                // mute at max distance (3D only)
SAMPLE_NOREORDER :: 0x40                // don't reorder channels to match speakers
SAMPLE_FX        :: 0x80                // unused
SAMPLE_FLOAT     :: 0x100               // 32 bit floating-point
SAMPLE_OVER_VOL  :: 0x10000             // override lowest volume
SAMPLE_OVER_POS  :: 0x20000             // override longest playing
SAMPLE_OVER_DIST :: 0x30000             // override furthest from listener (3D only)
STREAM_PRESCAN   :: 0x20000             // scan file for accurate seeking and length
STREAM_AUTOFREE  :: 0x40000             // automatically free the stream when it stops/ends
STREAM_RESTRATE  :: 0x80000             // restrict the download rate of internet file stream
STREAM_BLOCK     :: 0x100000            // download internet file stream in small blocks
STREAM_DECODE    :: 0x200000            // don't play the stream, only decode
STREAM_STATUS    :: 0x800000            // give server status info (HTTP/ICY tags) in DOWNLOADPROC
MP3_IGNOREDELAY  :: 0x200               // ignore LAME/Xing/VBRI/iTunes delay & padding info
MP3_SETPOS       :: STREAM_PRESCAN
MUSIC_FLOAT      :: SAMPLE_FLOAT
MUSIC_MONO       :: SAMPLE_MONO
MUSIC_LOOP       :: SAMPLE_LOOP
MUSIC_3D         :: SAMPLE_3D
MUSIC_FX         :: SAMPLE_FX
MUSIC_AUTOFREE   :: STREAM_AUTOFREE
MUSIC_DECODE     :: STREAM_DECODE
MUSIC_PRESCAN    :: STREAM_PRESCAN // calculate playback length
MUSIC_CALCLEN    :: MUSIC_PRESCAN
MUSIC_RAMP       :: 0x200               // normal ramping
MUSIC_RAMPS      :: 0x400               // sensitive ramping
MUSIC_SURROUND   :: 0x800               // surround sound
MUSIC_SURROUND2  :: 0x1000              // surround sound (mode 2)
MUSIC_FT2PAN     :: 0x2000              // apply FastTracker 2 panning to XM files
MUSIC_FT2MOD     :: 0x2000              // play .MOD as FastTracker 2 does
MUSIC_PT1MOD     :: 0x4000              // play .MOD as ProTracker 1 does
MUSIC_NONINTER   :: 0x10000             // non-interpolated sample mixing
MUSIC_SINCINTER  :: 0x800000            // sinc interpolated sample mixing
MUSIC_POSRESET   :: 0x8000              // stop all notes when moving position
MUSIC_POSRESETEX :: 0x400000            // stop all notes and reset bmp/etc when moving position
MUSIC_STOPBACK   :: 0x80000             // stop the music on a backwards jump effect
MUSIC_NOSAMPLE   :: 0x100000            // don't load the samples

// Speaker assignment flags
SPEAKER_FRONT      :: 0x1000000  // front speakers
SPEAKER_REAR       :: 0x2000000  // rear speakers
SPEAKER_CENLFE     :: 0x3000000  // center & LFE speakers (5.1)
SPEAKER_SIDE       :: 0x4000000  // side speakers (7.1)
SPEAKER_LEFT       :: 0x10000000 // modifier: left
SPEAKER_RIGHT      :: 0x20000000 // modifier: right
SPEAKER_FRONTLEFT  :: SPEAKER_FRONT|SPEAKER_LEFT
SPEAKER_FRONTRIGHT :: SPEAKER_FRONT|SPEAKER_RIGHT
SPEAKER_REARLEFT   :: SPEAKER_REAR|SPEAKER_LEFT
SPEAKER_REARRIGHT  :: SPEAKER_REAR|SPEAKER_RIGHT
SPEAKER_CENTER     :: SPEAKER_CENLFE|SPEAKER_LEFT
SPEAKER_LFE        :: SPEAKER_CENLFE|SPEAKER_RIGHT
SPEAKER_SIDELEFT   :: SPEAKER_SIDE|SPEAKER_LEFT
SPEAKER_SIDERIGHT  :: SPEAKER_SIDE|SPEAKER_RIGHT
SPEAKER_REAR2      :: SPEAKER_SIDE
SPEAKER_REAR2LEFT  :: SPEAKER_SIDELEFT
SPEAKER_REAR2RIGHT :: SPEAKER_SIDERIGHT
ASYNCFILE          :: 0x40000000 // read file asynchronously
UNICODE            :: 0x80000000 // UTF-16
RECORD_OPENSLES    :: 0x1000     // use OpenSLES
RECORD_PAUSE       :: 0x8000     // start recording paused

// Channel info structure
CHANNELINFO :: struct {
    freq:     DWORD, // default playback rate
    chans:    DWORD, // channels
    flags:    DWORD,
    ctype:    DWORD, // type of channel
    origres:  DWORD, // original resolution
    plugin:   HPLUGIN,
    sample:   HSAMPLE,
    filename: cstring,
}

ORIGRES_FLOAT  :: 0x10000

// CHANNELINFO types
CTYPE_SAMPLE           :: 1
CTYPE_RECORD           :: 2
CTYPE_STREAM           :: 0x10000
CTYPE_STREAM_VORBIS    :: 0x10002
CTYPE_STREAM_OGG       :: 0x10002
CTYPE_STREAM_MP1       :: 0x10003
CTYPE_STREAM_MP2       :: 0x10004
CTYPE_STREAM_MP3       :: 0x10005
CTYPE_STREAM_AIFF      :: 0x10006
CTYPE_STREAM_CA        :: 0x10007
CTYPE_STREAM_MF        :: 0x10008
CTYPE_STREAM_AM        :: 0x10009
CTYPE_STREAM_SAMPLE    :: 0x1000a
CTYPE_STREAM_DUMMY     :: 0x18000
CTYPE_STREAM_DEVICE    :: 0x18001
CTYPE_STREAM_WAV       :: 0x40000 // WAVE flag (LOWORD=codec)
CTYPE_STREAM_WAV_PCM   :: 0x50001
CTYPE_STREAM_WAV_FLOAT :: 0x50003
CTYPE_MUSIC_MOD        :: 0x20000
CTYPE_MUSIC_MTM        :: 0x20001
CTYPE_MUSIC_S3M        :: 0x20002
CTYPE_MUSIC_XM         :: 0x20003
CTYPE_MUSIC_IT         :: 0x20004
CTYPE_MUSIC_MO3        :: 0x00100 // MO3 flag

// PluginLoad flags
PLUGIN_PROC  :: 1

PLUGINFORM :: struct {
    ctype: DWORD,   // channel type
    name:  cstring, // format description
    exts:  cstring, // file extension filter (*.ext1;*.ext2;etc...)
}

PLUGININFO :: struct {
    version: DWORD,            // version (same form as GetVersion)
    formatc: DWORD,            // number of formats
    formats: ^PLUGINFORM, // the array of formats
}

// 3D vector (for 3D positions/velocities/orientations)
BASS_3DVECTOR :: struct {
    x: f32, // +=right, -=left
    y: f32, // +=up, -=down
    z: f32, // +=front, -=behind
}

// 3D channel modes
BASS_3DMODE_NORMAL   :: 0 // normal 3D processing
BASS_3DMODE_RELATIVE :: 1 // position is relative to the listener
BASS_3DMODE_OFF      :: 2 // no 3D processing

// software 3D mixing algorithms (used with CONFIG_3DALGORITHM)
BASS_3DALG_DEFAULT :: 0
BASS_3DALG_OFF     :: 1

// SampleGetChannel flags
SAMCHAN_NEW    :: 1  // get a new playback channel
SAMCHAN_STREAM  :: 2 // create a stream

@(default_calling_convention="c")
foreign lib {
    STREAMPROC :: proc(HSTREAM, rawptr, DWORD, rawptr) -> DWORD ---
}

/* User stream callback function.
handle : The stream that needs writing
buffer : Buffer to write the samples in
length : Number of bytes to write
user   : The 'user' parameter value given when calling StreamCreate
RETURN : Number of bytes written and STREAMPROC_xxx flags */
STREAMPROC_AGAIN :: 0x40000000 // call again for remainder
STREAMPROC_END   :: 0x80000000 // end the stream

// Special STREAMPROCs
STREAMPROC_DUMMY     :: 0  // "dummy" stream
STREAMPROC_PUSH      :: -1 // push stream
STREAMPROC_DEVICE    :: -2 // device mix stream
STREAMPROC_DEVICE_3D :: -3 // device 3D mix stream

// StreamCreateFileUser file systems
STREAMFILE_NOBUFFER   :: 0
STREAMFILE_BUFFER     :: 1
STREAMFILE_BUFFERPUSH :: 2

@(default_calling_convention="c")
foreign lib {
    // User file callback functions
    FILECLOSEPROC :: proc(rawptr) ---
    FILELENPROC   :: proc(rawptr) -> QWORD ---
    FILEREADPROC  :: proc(rawptr, DWORD, rawptr) -> DWORD ---
    FILESEEKPROC  :: proc(QWORD, rawptr) -> BOOL ---
    FILEOPENPROC  :: proc(cstring, DWORD) -> rawptr ---
}

FILEPROCS :: struct {
    close:  proc "c" (),
    length: proc "c" () -> QWORD,
    read:   proc "c" () -> DWORD,
    seek:   proc "c" () -> BOOL,
}

FILEOPENPROCS :: struct {
    close:  proc "c" (),
    length: proc "c" () -> QWORD,
    read:   proc "c" () -> DWORD,
    seek:   proc "c" () -> BOOL,
    open:   proc "c" () -> rawptr,
}

// StreamPutFileData options
FILEDATA_END  :: 0 // end & close the file

// StreamGetFilePosition modes
FILEPOS_CURRENT   :: 0
FILEPOS_DECODE    :: FILEPOS_CURRENT
FILEPOS_DOWNLOAD  :: 1
FILEPOS_END       :: 2
FILEPOS_START     :: 3
FILEPOS_CONNECTED :: 4
FILEPOS_BUFFER    :: 5
FILEPOS_SOCKET    :: 6
FILEPOS_ASYNCBUF  :: 7
FILEPOS_SIZE      :: 8
FILEPOS_BUFFERING :: 9
FILEPOS_AVAILABLE :: 10
FILEPOS_ASYNCSIZE :: 12

@(default_calling_convention="c")
foreign lib {
    DOWNLOADPROC :: proc(rawptr, DWORD, rawptr) ---
}

/* Internet stream download callback function.
buffer : Buffer containing the downloaded data... NULL=end of download
length : Number of bytes in the buffer
user   : The 'user' parameter value given when calling StreamCreateURL */

// ChannelSetSync types
SYNC_POS        :: 0
SYNC_END        :: 2
SYNC_META       :: 4
SYNC_SLIDE      :: 5
SYNC_STALL      :: 6
SYNC_DOWNLOAD   :: 7
SYNC_FREE       :: 8
SYNC_SETPOS     :: 11
SYNC_MUSICPOS   :: 10
SYNC_MUSICINST  :: 1
SYNC_MUSICFX    :: 3
SYNC_OGG_CHANGE :: 12
SYNC_ATTRIB     :: 13
SYNC_DEV_FAIL   :: 14
SYNC_DEV_FORMAT :: 15
SYNC_POS_RAW    :: 16
SYNC_THREAD     :: 0x20000000 // flag: call sync in other thread
SYNC_MIXTIME    :: 0x40000000 // flag: sync at mixtime, else at playtime
SYNC_ONETIME    :: 0x80000000 // flag: sync only once, else continuously

@(default_calling_convention="c")
foreign lib {
    SYNCPROC :: proc(HSYNC, DWORD, DWORD, rawptr) ---

    /* Sync callback function.
    handle : The sync that has occured
    channel: Channel that the sync occured in
    data   : Additional data associated with the sync's occurance
    user   : The 'user' parameter given when calling ChannelSetSync */
    DSPPROC :: proc(HDSP, DWORD, rawptr, DWORD, rawptr) ---

    /* DSP callback function.
    handle : The DSP handle
    channel: Channel that the DSP is being applied to
    buffer : Buffer to apply the DSP to
    length : Number of bytes in the buffer
    user   : The 'user' parameter given when calling ChannelSetDSP */
    RECORDPROC :: proc(HRECORD, rawptr, DWORD, rawptr) -> BOOL ---
}

/* Recording callback function.
handle : The recording handle
buffer : Buffer containing the recorded sample data
length : Number of bytes
user   : The 'user' parameter value given when calling RecordStart
RETURN : TRUE = continue recording, FALSE = stop */

// Special RECORDPROCs
RECORDPROC_NONE   :: 0  // no RECORDPROC
RECORDPROC_TRUE   :: -1 // only "return true"

// ChannelIsActive return values
ACTIVE_STOPPED       :: 0
ACTIVE_PLAYING       :: 1
ACTIVE_STALLED       :: 2
ACTIVE_PAUSED        :: 3
ACTIVE_PAUSED_DEVICE :: 4

// Channel attributes
ATTRIB_FREQ             :: 1
ATTRIB_VOL              :: 2
ATTRIB_PAN              :: 3
ATTRIB_EAXMIX           :: 4
ATTRIB_NOBUFFER         :: 5
ATTRIB_VBR              :: 6
ATTRIB_CPU              :: 7
ATTRIB_SRC              :: 8
ATTRIB_NET_RESUME       :: 9
ATTRIB_SCANINFO         :: 10
ATTRIB_NORAMP           :: 11
ATTRIB_BITRATE          :: 12
ATTRIB_BUFFER           :: 13
ATTRIB_GRANULE          :: 14
ATTRIB_USER             :: 15
ATTRIB_TAIL             :: 16
ATTRIB_PUSH_LIMIT       :: 17
ATTRIB_DOWNLOADPROC     :: 18
ATTRIB_VOLDSP           :: 19
ATTRIB_VOLDSP_PRIORITY  :: 20
ATTRIB_DOWNMIX          :: 21
ATTRIB_MUSIC_AMPLIFY    :: 0x100
ATTRIB_MUSIC_PANSEP     :: 0x101
ATTRIB_MUSIC_PSCALER    :: 0x102
ATTRIB_MUSIC_BPM        :: 0x103
ATTRIB_MUSIC_SPEED      :: 0x104
ATTRIB_MUSIC_VOL_GLOBAL :: 0x105
ATTRIB_MUSIC_ACTIVE     :: 0x106
ATTRIB_MUSIC_VOL_CHAN   :: 0x200 // + channel #
ATTRIB_MUSIC_VOL_INST   :: 0x300 // + instrument #

// Channel attribute types
ATTRIBTYPE_FLOAT  :: -1
ATTRIBTYPE_INT   :: -2

// ChannelSlideAttribute flags
SLIDE_LOG    :: 0x1000000

// ChannelGetData flags
DATA_AVAILABLE      :: 0          // query how much data is buffered
DATA_NOREMOVE       :: 0x10000000 // flag: don't remove data from recording buffer
DATA_FIXED          :: 0x20000000 // unused
DATA_FLOAT          :: 0x40000000 // flag: return floating-point sample data
DATA_FFT256         :: 0x80000000 // 256 sample FFT
DATA_FFT512         :: 0x80000001 // 512 FFT
DATA_FFT1024        :: 0x80000002 // 1024 FFT
DATA_FFT2048        :: 0x80000003 // 2048 FFT
DATA_FFT4096        :: 0x80000004 // 4096 FFT
DATA_FFT8192        :: 0x80000005 // 8192 FFT
DATA_FFT16384       :: 0x80000006 // 16384 FFT
DATA_FFT32768       :: 0x80000007 // 32768 FFT
DATA_FFT_INDIVIDUAL :: 0x10       // FFT flag: FFT for each channel, else all combined
DATA_FFT_NOWINDOW   :: 0x20       // FFT flag: no Hanning window
DATA_FFT_REMOVEDC   :: 0x40       // FFT flag: pre-remove DC bias
DATA_FFT_COMPLEX    :: 0x80       // FFT flag: return complex data
DATA_FFT_NYQUIST    :: 0x100      // FFT flag: return extra Nyquist value

// ChannelGetLevelEx flags
LEVEL_MONO     :: 1    // get mono level
LEVEL_STEREO   :: 2    // get stereo level
LEVEL_RMS      :: 4    // get RMS levels
LEVEL_VOLPAN   :: 8    // apply VOL/PAN attributes to the levels
LEVEL_NOREMOVE :: 0x10 // don't remove data from recording buffer

// ChannelGetTags types : what's returned
TAG_ID3            :: 0          // ID3v1 tags : TAG_ID3 structure
TAG_ID3V2          :: 1          // ID3v2 tags : variable length block
TAG_OGG            :: 2          // OGG comments : series of null-terminated UTF-8 strings
TAG_HTTP           :: 3          // HTTP headers : series of null-terminated ASCII strings
TAG_ICY            :: 4          // ICY headers : series of null-terminated ANSI strings
TAG_META           :: 5          // ICY metadata : ANSI string
TAG_APE            :: 6          // APE tags : series of null-terminated UTF-8 strings
TAG_MP4            :: 7          // MP4/iTunes metadata : series of null-terminated UTF-8 strings
TAG_WMA            :: 8          // WMA tags : series of null-terminated UTF-8 strings
TAG_VENDOR         :: 9          // OGG encoder : UTF-8 string
TAG_LYRICS3        :: 10         // Lyric3v2 tag : ASCII string
TAG_CA_CODEC       :: 11         // CoreAudio codec info : TAG_CA_CODEC structure
TAG_MF             :: 13         // Media Foundation tags : series of null-terminated UTF-8 strings
TAG_WAVEFORMAT     :: 14         // WAVE format : WAVEFORMATEEX structure
TAG_AM_NAME        :: 16         // Android Media codec name : ASCII string
TAG_ID3V2_2        :: 17         // ID3v2 tags (2nd block) : variable length block
TAG_AM_MIME        :: 18         // Android Media MIME type : ASCII string
TAG_LOCATION       :: 19         // redirected URL : ASCII string
TAG_ID3V2_BINARY   :: 20         // ID3v2 tags : TAB_BINARY
TAG_ID3V2_2_BINARY :: 21         // ID3v2 tags (2nd block) : TAB_BINARY
TAG_RIFF_INFO      :: 0x100      // RIFF "INFO" tags : series of null-terminated ANSI strings
TAG_RIFF_BEXT      :: 0x101      // RIFF/BWF "bext" tags : TAG_BEXT structure
TAG_RIFF_CART      :: 0x102      // RIFF/BWF "cart" tags : TAG_CART structure
TAG_RIFF_DISP      :: 0x103      // RIFF "DISP" text tag : ANSI string
TAG_RIFF_CUE       :: 0x104      // RIFF "cue " chunk : TAG_CUE structure
TAG_RIFF_SMPL      :: 0x105      // RIFF "smpl" chunk : TAG_SMPL structure
TAG_APE_BINARY     :: 0x1000     // + index #, binary APE tag : TAG_APE_BINARY structure
TAG_MP4_COVERART   :: 0x1400     // + index #, MP4 cover art : TAG_BINARY structure
TAG_MUSIC_NAME     :: 0x10000    // MOD music name : ANSI string
TAG_MUSIC_MESSAGE  :: 0x10001    // MOD message : ANSI string
TAG_MUSIC_ORDERS   :: 0x10002    // MOD order list : BYTE array of pattern numbers
TAG_MUSIC_AUTH     :: 0x10003    // MOD author : UTF-8 string
TAG_MUSIC_INST     :: 0x10100    // + instrument #, MOD instrument name : ANSI string
TAG_MUSIC_CHAN     :: 0x10200    // + channel #, MOD channel name : ANSI string
TAG_MUSIC_SAMPLE   :: 0x10300    // + sample #, MOD sample name : ANSI string
TAG_INCREF         :: 0x20000000 // flag: increment channel's reference count

// ID3v1 tag structure
_TAG_ID3 :: struct {
    id:      [3]i8,
    title:   [30]i8,
    artist:  [30]i8,
    album:   [30]i8,
    year:    [4]i8,
    comment: [30]i8,
    genre:   BYTE,
}

// Binary tag structure
_TAG_BINARY :: struct {
    data:   rawptr,
    length: DWORD,
}

// Binary APE tag structure
_TAG_APE_BINARY :: struct {
    key:    cstring,
    data:   rawptr,
    length: DWORD,
}

_TAG_BEXT :: struct {
    Description:         [256]i8,  // description
    Originator:          [32]i8,   // name of the originator
    OriginatorReference: [32]i8,   // reference of the originator
    OriginationDate:     [10]i8,   // date of creation (yyyy-mm-dd)
    OriginationTime:     [8]i8,    // time of creation (hh-mm-ss)
    TimeReference:       QWORD,    // first sample count since midnight (little-endian)
    Version:             WORD,     // BWF version (little-endian)
    UMID:                [64]BYTE, // SMPTE UMID
    Reserved:            [190]BYTE,
    CodingHistory:       [^]i8,    // history
}

// BWF "cart" tag structures
_TAG_CART_TIMER :: struct {
    dwUsage: DWORD, // FOURCC timer usage ID
    dwValue: DWORD, // timer value in samples from head
}

_TAG_CART :: struct {
    Version:            [4]i8,             // version of the data structure
    Title:              [64]i8,            // title of cart audio sequence
    Artist:             [64]i8,            // artist or creator name
    CutID:              [64]i8,            // cut number identification
    ClientID:           [64]i8,            // client identification
    Category:           [64]i8,            // category ID, PSA, NEWS, etc
    Classification:     [64]i8,            // classification or auxiliary key
    OutCue:             [64]i8,            // out cue text
    StartDate:          [10]i8,            // yyyy-mm-dd
    StartTime:          [8]i8,             // hh:mm:ss
    EndDate:            [10]i8,            // yyyy-mm-dd
    EndTime:            [8]i8,             // hh:mm:ss
    ProducerAppID:      [64]i8,            // name of vendor or application
    ProducerAppVersion: [64]i8,            // version of producer application
    UserDef:            [64]i8,            // user defined text
    dwLevelReference:   DWORD,             // sample value for 0 dB reference
    PostTimer:          [8]_TAG_CART_TIMER, // 8 time markers after head
    Reserved:           [276]i8,
    URL:                [1024]i8,          // uniform resource locator
    TagText:            [^]i8,             // free form text for scripts or tags
}

// RIFF "cue " tag structures
_TAG_CUE_POINT :: struct {
    dwName:         DWORD,
    dwPosition:     DWORD,
    fccChunk:       DWORD,
    dwChunkStart:   DWORD,
    dwBlockStart:   DWORD,
    dwSampleOffset: DWORD,
}

_TAG_CUE :: struct {
    dwCuePoints: DWORD,
    CuePoints:   [^]_TAG_CUE_POINT,
}

// RIFF "smpl" tag structures
_TAG_SMPL_LOOP :: struct {
    dwIdentifier: DWORD,
    dwType:       DWORD,
    dwStart:      DWORD,
    dwEnd:        DWORD,
    dwFraction:   DWORD,
    dwPlayCount:  DWORD,
}

_TAG_SMPL :: struct {
    dwManufacturer:      DWORD,
    dwProduct:           DWORD,
    dwSamplePeriod:      DWORD,
    dwMIDIUnityNote:     DWORD,
    dwMIDIPitchFraction: DWORD,
    dwSMPTEFormat:       DWORD,
    dwSMPTEOffset:       DWORD,
    cSampleLoops:        DWORD,
    cbSamplerData:       DWORD,
    SampleLoops:         [^]_TAG_SMPL_LOOP,
}

// CoreAudio codec info structure
_TAG_CA_CODEC :: struct {
    ftype: DWORD,   // file format
    atype: DWORD,   // audio format
    name:  cstring, // description
}

// ChannelGetLength/GetPosition/SetPosition modes
POS_BYTE        :: 0          // byte position
POS_MUSIC_ORDER :: 1          // order.row position, MAKELONG(order,row)
POS_OGG         :: 3          // OGG bitstream number
POS_TRACK       :: 4          // track number
POS_RAW         :: 6          // monotonic byte position
POS_END         :: 0x10       // trimmed end position
POS_LOOP        :: 0x11       // loop start positiom
POS_DSP         :: 0x800000   // flag: get the DSP position
POS_FLUSH       :: 0x1000000  // flag: flush decoder/FX buffers
POS_RESET       :: 0x2000000  // flag: reset user file buffers
POS_RELATIVE    :: 0x4000000  // flag: seek relative to the current position
POS_INEXACT     :: 0x8000000  // flag: allow seeking to inexact position
POS_DECODE      :: 0x10000000 // flag: get the decoding (not playing) position
POS_DECODETO    :: 0x20000000 // flag: decode to the position instead of seeking
POS_SCAN        :: 0x40000000 // flag: scan to the position

// ChannelSetDevice/GetDevice option
NODEVICE  :: 0x20000

// RecordSetInput flags
INPUT_OFF          :: 0x10000
INPUT_ON           :: 0x20000
INPUT_TYPE_MASK    :: 0xff000000
INPUT_TYPE_UNDEF   :: 0x00000000
INPUT_TYPE_DIGITAL  :: 0x01000000
INPUT_TYPE_LINE    :: 0x02000000
INPUT_TYPE_MIC     :: 0x03000000
INPUT_TYPE_SYNTH   :: 0x04000000
INPUT_TYPE_CD      :: 0x05000000
INPUT_TYPE_PHONE   :: 0x06000000
INPUT_TYPE_SPEAKER  :: 0x07000000
INPUT_TYPE_WAVE    :: 0x08000000
INPUT_TYPE_AUX     :: 0x09000000
INPUT_TYPE_ANALOG  :: 0x0a000000

// ChannelSetDSPEx flags
DSP_READONLY   :: 1
DSP_FLOAT    :: 2
DSP_FREECALL   :: 4
DSP_BYPASS    :: 0x400000

// ChannelSetFX effect types
FX_DX8_CHORUS      :: 0
FX_DX8_COMPRESSOR  :: 1
FX_DX8_DISTORTION  :: 2
FX_DX8_ECHO        :: 3
FX_DX8_FLANGER     :: 4
FX_DX8_GARGLE      :: 5
FX_DX8_I3DL2REVERB  :: 6
FX_DX8_PARAMEQ     :: 7
FX_DX8_REVERB      :: 8
FX_VOLUME          :: 9

DX8_CHORUS :: struct {
    fWetDryMix: f32,
    fDepth:     f32,
    fFeedback:  f32,
    fFrequency: f32,
    lWaveform:  DWORD, // 0=triangle, 1=sine
    fDelay:     f32,
    lPhase:     DWORD, // DX8_PHASE_xxx
}

DX8_COMPRESSOR :: struct {
    fGain:      f32,
    fAttack:    f32,
    fRelease:   f32,
    fThreshold: f32,
    fRatio:     f32,
    fPredelay:  f32,
}

DX8_DISTORTION :: struct {
    fGain:                  f32,
    fEdge:                  f32,
    fPostEQCenterFrequency: f32,
    fPostEQBandwidth:       f32,
    fPreLowpassCutoff:      f32,
}

DX8_ECHO :: struct {
    fWetDryMix:  f32,
    fFeedback:   f32,
    fLeftDelay:  f32,
    fRightDelay: f32,
    lPanDelay:   BOOL,
}

DX8_FLANGER :: struct {
    fWetDryMix: f32,
    fDepth:     f32,
    fFeedback:  f32,
    fFrequency: f32,
    lWaveform:  DWORD, // 0=triangle, 1=sine
    fDelay:     f32,
    lPhase:     DWORD, // DX8_PHASE_xxx
}

DX8_GARGLE :: struct {
    dwRateHz:    DWORD, // Rate of modulation in hz
    dwWaveShape: DWORD, // 0=triangle, 1=square
}

DX8_I3DL2REVERB :: struct {
    lRoom:               i32, // [-10000, 0]      default: -1000 mB
    lRoomHF:             i32, // [-10000, 0]      default: 0 mB
    flRoomRolloffFactor: f32, // [0.0, 10.0]      default: 0.0
    flDecayTime:         f32, // [0.1, 20.0]      default: 1.49s
    flDecayHFRatio:      f32, // [0.1, 2.0]       default: 0.83
    lReflections:        i32, // [-10000, 1000]   default: -2602 mB
    flReflectionsDelay:  f32, // [0.0, 0.3]       default: 0.007 s
    lReverb:             i32, // [-10000, 2000]   default: 200 mB
    flReverbDelay:       f32, // [0.0, 0.1]       default: 0.011 s
    flDiffusion:         f32, // [0.0, 100.0]     default: 100.0 %
    flDensity:           f32, // [0.0, 100.0]     default: 100.0 %
    flHFReference:       f32, // [20.0, 20000.0]  default: 5000.0 Hz
}

DX8_PARAMEQ :: struct {
    fCenter:    f32,
    fBandwidth: f32,
    fGain:      f32,
}

DX8_REVERB :: struct {
    fInGain:          f32, // [-96.0,0.0]            default: 0.0 dB
    fReverbMix:       f32, // [-96.0,0.0]            default: 0.0 db
    fReverbTime:      f32, // [0.001,3000.0]         default: 1000.0 ms
    fHighFreqRTRatio: f32, // [0.001,0.999]          default: 0.001
}

DX8_PHASE_NEG_180        :: 0
DX8_PHASE_NEG_90         :: 1
DX8_PHASE_ZERO           :: 2
DX8_PHASE_90             :: 3
DX8_PHASE_180            :: 4

FX_VOLUME_PARAM :: struct {
    fTarget:  f32,
    fCurrent: f32,
    fTime:    f32,
    lCurve:   DWORD,
}

@(default_calling_convention="c")
foreign lib {
    DEVICENOTIFYPROC :: proc(DWORD) ---
}

/* Device notification callback function.
notify : The notification (DEVICENOTIFY_xxx) */
DEVICENOTIFY_ENABLED        :: 0 // a device has been added or removed
DEVICENOTIFY_DEFAULT        :: 1 // the default output device has changed
DEVICENOTIFY_REC_DEFAULT    :: 2 // the default recording device has changed
DEVICENOTIFY_DEFAULTCOM     :: 3 // the default communication output device has changed
DEVICENOTIFY_REC_DEFAULTCOM :: 4 // the default communication recording device has changed

@(default_calling_convention="c")
foreign lib {
    IOSNOTIFYPROC :: proc(DWORD) ---
}

/* iOS notification callback function.
status : The notification (IOSNOTIFY_xxx) */
IOSNOTIFY_INTERRUPT     :: 1 // interruption started
IOSNOTIFY_INTERRUPT_END :: 2 // interruption ended

@(default_calling_convention="c",link_prefix="BASS_")
foreign lib {
    SetConfig              :: proc(option: DWORD, value: DWORD) -> BOOL ---
    GetConfig              :: proc(option: DWORD) -> DWORD ---
    SetConfigPtr           :: proc(option: DWORD, value: rawptr) -> BOOL ---
    GetConfigPtr           :: proc(option: DWORD) -> rawptr ---
    GetVersion             :: proc() -> DWORD ---
    ErrorGetCode           :: proc() -> i32 ---
    GetDeviceInfo          :: proc(device: DWORD, info: ^DEVICEINFO) -> BOOL ---
    Init                   :: proc(device: i32, freq: DWORD, flags: DWORD, win: HWND, dsguid: rawptr) -> BOOL ---
    Free                   :: proc() -> BOOL ---
    SetDevice              :: proc(device: DWORD) -> BOOL ---
    GetDevice              :: proc() -> DWORD ---
    GetInfo                :: proc(info: ^INFO) -> BOOL ---
    Start                  :: proc() -> BOOL ---
    Stop                   :: proc() -> BOOL ---
    Pause                  :: proc() -> BOOL ---
    IsStarted              :: proc() -> DWORD ---
    Update                 :: proc(length: DWORD) -> BOOL ---
    GetCPU                 :: proc() -> f32 ---
    SetVolume              :: proc(volume: f32) -> BOOL ---
    GetVolume              :: proc() -> f32 ---
    GetDSoundObject        :: proc(object: DWORD) -> rawptr ---
    Set3DFactors           :: proc(distf: f32, rollf: f32, doppf: f32) -> BOOL ---
    Get3DFactors           :: proc(distf: ^f32, rollf: ^f32, doppf: ^f32) -> BOOL ---
    Set3DPosition          :: proc(pos: ^BASS_3DVECTOR, vel: ^BASS_3DVECTOR, front: ^BASS_3DVECTOR, top: ^BASS_3DVECTOR) -> BOOL ---
    Get3DPosition          :: proc(pos: ^BASS_3DVECTOR, vel: ^BASS_3DVECTOR, front: ^BASS_3DVECTOR, top: ^BASS_3DVECTOR) -> BOOL ---
    Apply3D                :: proc() ---
    PluginLoad             :: proc(file: cstring, flags: DWORD) -> HPLUGIN ---
    PluginFree             :: proc(handle: HPLUGIN) -> BOOL ---
    PluginEnable           :: proc(handle: HPLUGIN, enable: BOOL) -> BOOL ---
    PluginGetInfo          :: proc(handle: HPLUGIN) -> ^PLUGININFO ---
    SampleLoad             :: proc(filetype: DWORD, file: rawptr, offset: QWORD, length: DWORD, max: DWORD, flags: DWORD) -> HSAMPLE ---
    SampleCreate           :: proc(length: DWORD, freq: DWORD, chans: DWORD, max: DWORD, flags: DWORD) -> HSAMPLE ---
    SampleFree             :: proc(handle: HSAMPLE) -> BOOL ---
    SampleSetData          :: proc(handle: HSAMPLE, buffer: rawptr) -> BOOL ---
    SampleGetData          :: proc(handle: HSAMPLE, buffer: rawptr) -> BOOL ---
    SampleGetInfo          :: proc(handle: HSAMPLE, info: ^SAMPLE) -> BOOL ---
    SampleSetInfo          :: proc(handle: HSAMPLE, info: ^SAMPLE) -> BOOL ---
    SampleGetChannel       :: proc(handle: HSAMPLE, flags: DWORD) -> DWORD ---
    SampleGetChannels      :: proc(handle: HSAMPLE, channels: ^HCHANNEL) -> DWORD ---
    SampleStop             :: proc(handle: HSAMPLE) -> BOOL ---
    StreamCreate           :: proc(freq: DWORD, chans: DWORD, flags: DWORD, _proc: proc "c" () -> DWORD, user: rawptr) -> HSTREAM ---
    StreamCreateFile       :: proc(filetype: DWORD, file: rawptr, offset: QWORD, length: QWORD, flags: DWORD) -> HSTREAM ---
    StreamCreateURL        :: proc(url: cstring, offset: DWORD, flags: DWORD, _proc: proc "c" (), user: rawptr) -> HSTREAM ---
    StreamCreateFileUser   :: proc(system: DWORD, flags: DWORD, _proc: ^FILEPROCS, user: rawptr) -> HSTREAM ---
    StreamCancel           :: proc(user: rawptr) -> BOOL ---
    StreamFree             :: proc(handle: HSTREAM) -> BOOL ---
    StreamGetFilePosition  :: proc(handle: HSTREAM, mode: DWORD) -> QWORD ---
    StreamPutData          :: proc(handle: HSTREAM, buffer: rawptr, length: DWORD) -> DWORD ---
    StreamPutFileData      :: proc(handle: HSTREAM, buffer: rawptr, length: DWORD) -> DWORD ---
    MusicLoad              :: proc(filetype: DWORD, file: rawptr, offset: QWORD, length: DWORD, flags: DWORD, freq: DWORD) -> HMUSIC ---
    MusicFree              :: proc(handle: HMUSIC) -> BOOL ---
    RecordGetDeviceInfo    :: proc(device: DWORD, info: ^DEVICEINFO) -> BOOL ---
    RecordInit             :: proc(device: i32) -> BOOL ---
    RecordFree             :: proc() -> BOOL ---
    RecordSetDevice        :: proc(device: DWORD) -> BOOL ---
    RecordGetDevice        :: proc() -> DWORD ---
    RecordGetInfo          :: proc(info: ^RECORDINFO) -> BOOL ---
    RecordGetInputName     :: proc(input: i32) -> cstring ---
    RecordSetInput         :: proc(input: i32, flags: DWORD, volume: f32) -> BOOL ---
    RecordGetInput         :: proc(input: i32, volume: ^f32) -> DWORD ---
    RecordStart            :: proc(freq: DWORD, chans: DWORD, flags: DWORD, _proc: proc "c" () -> BOOL, user: rawptr) -> HRECORD ---
    ChannelBytes2Seconds   :: proc(handle: DWORD, pos: QWORD) -> f64 ---
    ChannelSeconds2Bytes   :: proc(handle: DWORD, pos: f64) -> QWORD ---
    ChannelGetDevice       :: proc(handle: DWORD) -> DWORD ---
    ChannelSetDevice       :: proc(handle: DWORD, device: DWORD) -> BOOL ---
    ChannelIsActive        :: proc(handle: DWORD) -> DWORD ---
    ChannelGetInfo         :: proc(handle: DWORD, info: ^CHANNELINFO) -> BOOL ---
    ChannelGetTags         :: proc(handle: DWORD, tags: DWORD) -> cstring ---
    ChannelFlags           :: proc(handle: DWORD, flags: DWORD, mask: DWORD) -> DWORD ---
    ChannelLock            :: proc(handle: DWORD, lock: BOOL) -> BOOL ---
    ChannelRef             :: proc(handle: DWORD, inc: BOOL) -> BOOL ---
    ChannelFree            :: proc(handle: DWORD) -> BOOL ---
    ChannelPlay            :: proc(handle: DWORD, restart: BOOL) -> BOOL ---
    ChannelStart           :: proc(handle: DWORD) -> BOOL ---
    ChannelStop            :: proc(handle: DWORD) -> BOOL ---
    ChannelPause           :: proc(handle: DWORD) -> BOOL ---
    ChannelUpdate          :: proc(handle: DWORD, length: DWORD) -> BOOL ---
    ChannelSetAttribute    :: proc(handle: DWORD, attrib: DWORD, value: f32) -> BOOL ---
    ChannelGetAttribute    :: proc(handle: DWORD, attrib: DWORD, value: ^f32) -> BOOL ---
    ChannelSlideAttribute  :: proc(handle: DWORD, attrib: DWORD, value: f32, time: DWORD) -> BOOL ---
    ChannelIsSliding       :: proc(handle: DWORD, attrib: DWORD) -> BOOL ---
    ChannelSetAttributeEx  :: proc(handle: DWORD, attrib: DWORD, value: rawptr, typesize: DWORD) -> BOOL ---
    ChannelGetAttributeEx  :: proc(handle: DWORD, attrib: DWORD, value: rawptr, typesize: DWORD) -> DWORD ---
    ChannelSet3DAttributes :: proc(handle: DWORD, mode: i32, min: f32, max: f32, iangle: i32, oangle: i32, outvol: f32) -> BOOL ---
    ChannelGet3DAttributes :: proc(handle: DWORD, mode: ^DWORD, min: ^f32, max: ^f32, iangle: ^DWORD, oangle: ^DWORD, outvol: ^f32) -> BOOL ---
    ChannelSet3DPosition   :: proc(handle: DWORD, pos: ^BASS_3DVECTOR, orient: ^BASS_3DVECTOR, vel: ^BASS_3DVECTOR) -> BOOL ---
    ChannelGet3DPosition   :: proc(handle: DWORD, pos: ^BASS_3DVECTOR, orient: ^BASS_3DVECTOR, vel: ^BASS_3DVECTOR) -> BOOL ---
    ChannelGetLength       :: proc(handle: DWORD, mode: DWORD) -> QWORD ---
    ChannelSetPosition     :: proc(handle: DWORD, pos: QWORD, mode: DWORD) -> BOOL ---
    ChannelGetPosition     :: proc(handle: DWORD, mode: DWORD) -> QWORD ---
    ChannelGetLevel        :: proc(handle: DWORD) -> DWORD ---
    ChannelGetLevelEx      :: proc(handle: DWORD, levels: ^f32, length: f32, flags: DWORD) -> BOOL ---
    ChannelGetData         :: proc(handle: DWORD, buffer: rawptr, length: DWORD) -> DWORD ---
    ChannelSetSync         :: proc(handle: DWORD, type: DWORD, param: QWORD, _proc: proc "c" (), user: rawptr) -> HSYNC ---
    ChannelRemoveSync      :: proc(handle: DWORD, sync: HSYNC) -> BOOL ---
    ChannelSetLink         :: proc(handle: DWORD, chan: DWORD) -> BOOL ---
    ChannelRemoveLink      :: proc(handle: DWORD, chan: DWORD) -> BOOL ---
    ChannelSetDSP          :: proc(handle: DWORD, _proc: proc "c" (), user: rawptr, priority: i32) -> HDSP ---
    ChannelSetDSPEx        :: proc(handle: DWORD, _proc: proc "c" (), user: rawptr, priority: i32, flags: DWORD) -> HDSP ---
    ChannelRemoveDSP       :: proc(handle: DWORD, dsp: HDSP) -> BOOL ---
    ChannelSetFX           :: proc(handle: DWORD, type: DWORD, priority: i32) -> HFX ---
    ChannelRemoveFX        :: proc(handle: DWORD, fx: HFX) -> BOOL ---
    FXSetParameters        :: proc(handle: HFX, params: rawptr) -> BOOL ---
    FXGetParameters        :: proc(handle: HFX, params: rawptr) -> BOOL ---
    FXSetPriority          :: proc(handle: DWORD, priority: i32) -> BOOL ---
    FXSetBypass            :: proc(handle: DWORD, bypass: BOOL) -> BOOL ---
    FXReset                :: proc(handle: DWORD) -> BOOL ---
    FXFree                 :: proc(handle: DWORD) -> BOOL ---
}
