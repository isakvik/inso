/*
	BASS 2.4 C/C++ header file
	Copyright (c) 1999-2025 Un4seen Developments Ltd.

	See the BASS.CHM file for more detailed documentation
*/
package bass

import "core:sys/windows"

LIB :: "lib/bass.lib" when ODIN_OS == .Windows else "lib/bass.a"
foreign import lib { LIB }

HWND :: windows.HWND
BOOL :: windows.BOOL
BYTE :: windows.BYTE
WORD :: windows.WORD
DWORD :: windows.DWORD
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

// Error codes returned by BASS_ErrorGetCode
BASS_OK                 :: 0  // all is OK
BASS_ERROR_MEM          :: 1  // memory error
BASS_ERROR_FILEOPEN     :: 2  // can't open the file
BASS_ERROR_DRIVER       :: 3  // can't find a free/valid driver
BASS_ERROR_BUFLOST      :: 4  // the sample buffer was lost
BASS_ERROR_HANDLE       :: 5  // invalid handle
BASS_ERROR_FORMAT       :: 6  // unsupported sample format
BASS_ERROR_POSITION     :: 7  // invalid position
BASS_ERROR_INIT         :: 8  // BASS_Init has not been successfully called
BASS_ERROR_START        :: 9  // BASS_Start has not been successfully called
BASS_ERROR_SSL          :: 10 // SSL/HTTPS support isn't available
BASS_ERROR_REINIT       :: 11 // device needs to be reinitialized
BASS_ERROR_TRACK        :: 13 // invalid track number
BASS_ERROR_ALREADY      :: 14 // already initialized/paused/whatever
BASS_ERROR_NOTAUDIO     :: 17 // file does not contain audio
BASS_ERROR_NOCHAN       :: 18 // can't get a free channel
BASS_ERROR_ILLTYPE      :: 19 // an illegal type was specified
BASS_ERROR_ILLPARAM     :: 20 // an illegal parameter was specified
BASS_ERROR_NO3D         :: 21 // no 3D support
BASS_ERROR_NOEAX        :: 22 // no EAX support
BASS_ERROR_DEVICE       :: 23 // illegal device number
BASS_ERROR_NOPLAY       :: 24 // not playing
BASS_ERROR_FREQ         :: 25 // illegal sample rate
BASS_ERROR_NOTFILE      :: 27 // the stream is not a file stream
BASS_ERROR_NOHW         :: 29 // no hardware voices available
BASS_ERROR_EMPTY        :: 31 // the file has no sample data
BASS_ERROR_NONET        :: 32 // no internet connection could be opened
BASS_ERROR_CREATE       :: 33 // couldn't create the file
BASS_ERROR_NOFX         :: 34 // effects are not available
BASS_ERROR_NOTAVAIL     :: 37 // requested data/action is not available
BASS_ERROR_DECODE       :: 38 // the channel is/isn't a "decoding channel"
BASS_ERROR_DX           :: 39 // a sufficient DirectX version is not installed
BASS_ERROR_TIMEOUT      :: 40 // connection timedout
BASS_ERROR_FILEFORM     :: 41 // unsupported file format
BASS_ERROR_SPEAKER      :: 42 // unavailable speaker
BASS_ERROR_VERSION      :: 43 // invalid BASS version (used by add-ons)
BASS_ERROR_CODEC        :: 44 // codec is not available/supported
BASS_ERROR_ENDED        :: 45 // the channel/file has ended
BASS_ERROR_BUSY         :: 46 // the device is busy
BASS_ERROR_UNSTREAMABLE :: 47 // unstreamable file
BASS_ERROR_PROTOCOL     :: 48 // unsupported protocol
BASS_ERROR_DENIED       :: 49 // access denied
BASS_ERROR_FREEING      :: 50 // being freed
BASS_ERROR_CANCEL       :: 51 // cancelled
BASS_ERROR_UNKNOWN      :: -1 // some other mystery problem

// BASS_SetConfig options
BASS_CONFIG_BUFFER             :: 0
BASS_CONFIG_UPDATEPERIOD       :: 1
BASS_CONFIG_GVOL_SAMPLE        :: 4
BASS_CONFIG_GVOL_STREAM        :: 5
BASS_CONFIG_GVOL_MUSIC         :: 6
BASS_CONFIG_CURVE_VOL          :: 7
BASS_CONFIG_CURVE_PAN          :: 8
BASS_CONFIG_FLOATDSP           :: 9
BASS_CONFIG_3DALGORITHM        :: 10
BASS_CONFIG_NET_TIMEOUT        :: 11
BASS_CONFIG_NET_BUFFER         :: 12
BASS_CONFIG_PAUSE_NOPLAY       :: 13
BASS_CONFIG_NET_PREBUF         :: 15
BASS_CONFIG_NET_PASSIVE        :: 18
BASS_CONFIG_REC_BUFFER         :: 19
BASS_CONFIG_NET_PLAYLIST       :: 21
BASS_CONFIG_MUSIC_VIRTUAL      :: 22
BASS_CONFIG_VERIFY             :: 23
BASS_CONFIG_UPDATETHREADS      :: 24
BASS_CONFIG_DEV_BUFFER         :: 27
BASS_CONFIG_REC_LOOPBACK       :: 28
BASS_CONFIG_IOS_SESSION        :: 34
BASS_CONFIG_IOS_MIXAUDIO       :: 34
BASS_CONFIG_DEV_DEFAULT        :: 36
BASS_CONFIG_NET_READTIMEOUT    :: 37
BASS_CONFIG_VISTA_SPEAKERS     :: 38
BASS_CONFIG_IOS_SPEAKER        :: 39
BASS_CONFIG_MF_DISABLE         :: 40
BASS_CONFIG_HANDLES            :: 41
BASS_CONFIG_UNICODE            :: 42
BASS_CONFIG_SRC                :: 43
BASS_CONFIG_SRC_SAMPLE         :: 44
BASS_CONFIG_ASYNCFILE_BUFFER   :: 45
BASS_CONFIG_OGG_PRESCAN        :: 47
BASS_CONFIG_VIDEO              :: 48
BASS_CONFIG_MF_VIDEO           :: BASS_CONFIG_VIDEO
BASS_CONFIG_AIRPLAY            :: 49
BASS_CONFIG_DEV_NONSTOP        :: 50
BASS_CONFIG_IOS_NOCATEGORY     :: 51
BASS_CONFIG_VERIFY_NET         :: 52
BASS_CONFIG_DEV_PERIOD         :: 53
BASS_CONFIG_FLOAT              :: 54
BASS_CONFIG_NET_SEEK           :: 56
BASS_CONFIG_AM_DISABLE         :: 58
BASS_CONFIG_NET_PLAYLIST_DEPTH :: 59
BASS_CONFIG_NET_PREBUF_WAIT    :: 60
BASS_CONFIG_ANDROID_SESSIONID  :: 62
BASS_CONFIG_WASAPI_PERSIST     :: 65
BASS_CONFIG_REC_WASAPI         :: 66
BASS_CONFIG_ANDROID_AAUDIO     :: 67
BASS_CONFIG_SAMPLE_ONEHANDLE   :: 69
BASS_CONFIG_NET_META           :: 71
BASS_CONFIG_NET_RESTRATE       :: 72
BASS_CONFIG_REC_DEFAULT        :: 73
BASS_CONFIG_NORAMP             :: 74
BASS_CONFIG_NOSOUND_MAXDELAY   :: 76
BASS_CONFIG_STACKALLOC         :: 79
BASS_CONFIG_DOWNMIX            :: 80

// BASS_SetConfigPtr options
BASS_CONFIG_NET_AGENT      :: 16
BASS_CONFIG_NET_PROXY      :: 17
BASS_CONFIG_DEV_NOTIFY     :: 33
BASS_CONFIG_IOS_NOTIFY     :: 46
BASS_CONFIG_ANDROID_JAVAVM :: 63
BASS_CONFIG_LIBSSL         :: 64
BASS_CONFIG_FILENAME       :: 75
BASS_CONFIG_FILEOPENPROCS  :: 77
BASS_CONFIG_THREAD         :: 0x40000000 // flag: thread-specific setting

// BASS_CONFIG_IOS_SESSION flags
BASS_IOS_SESSION_MIX        :: 1
BASS_IOS_SESSION_DUCK       :: 2
BASS_IOS_SESSION_AMBIENT    :: 4
BASS_IOS_SESSION_SPEAKER    :: 8
BASS_IOS_SESSION_DISABLE    :: 0x10
BASS_IOS_SESSION_DEACTIVATE :: 0x20
BASS_IOS_SESSION_AIRPLAY    :: 0x40
BASS_IOS_SESSION_BTHFP      :: 0x80
BASS_IOS_SESSION_BTA2DP     :: 0x100

// BASS_Init flags
BASS_DEVICE_8BITS      :: 1        // unused
BASS_DEVICE_MONO       :: 2        // mono
BASS_DEVICE_3D         :: 4        // unused
BASS_DEVICE_16BITS     :: 8        // limit output to 16-bit
BASS_DEVICE_REINIT     :: 0x80     // reinitialize
BASS_DEVICE_LATENCY    :: 0x100    // unused
BASS_DEVICE_CPSPEAKERS :: 0x400    // unused
BASS_DEVICE_SPEAKERS   :: 0x800    // force enabling of speaker assignment
BASS_DEVICE_NOSPEAKER  :: 0x1000   // ignore speaker arrangement
BASS_DEVICE_DMIX       :: 0x2000   // use ALSA "dmix" plugin
BASS_DEVICE_FREQ       :: 0x4000   // set device sample rate
BASS_DEVICE_STEREO     :: 0x8000   // limit output to stereo
BASS_DEVICE_HOG        :: 0x10000  // hog/exclusive mode
BASS_DEVICE_AUDIOTRACK :: 0x20000  // use AudioTrack output
BASS_DEVICE_DSOUND     :: 0x40000  // use DirectSound output
BASS_DEVICE_SOFTWARE   :: 0x80000  // disable hardware/fastpath output
BASS_DEVICE_OPENSLES   :: 0x100000 // use OpenSLES output
BASS_DEVICE_APPLEVOICE :: 0x200000 // use Apple voice processing

// DirectSound interfaces (for use with BASS_GetDSoundObject)
BASS_OBJECT_DS    :: 1 // IDirectSound
BASS_OBJECT_DS3DL :: 2 // IDirectSound3DListener

// Device info structure
BASS_DEVICEINFO :: struct {
	name:   cstring, // description
	driver: cstring, // driver
	flags:  DWORD,
}

// BASS_DEVICEINFO flags
BASS_DEVICE_ENABLED          :: 1
BASS_DEVICE_DEFAULT          :: 2
BASS_DEVICE_INIT             :: 4
BASS_DEVICE_LOOPBACK         :: 8
BASS_DEVICE_DEFAULTCOM       :: 0x80
BASS_DEVICE_TYPE_MASK        :: 0xff000000
BASS_DEVICE_TYPE_NETWORK     :: 0x01000000
BASS_DEVICE_TYPE_SPEAKERS    :: 0x02000000
BASS_DEVICE_TYPE_LINE        :: 0x03000000
BASS_DEVICE_TYPE_HEADPHONES  :: 0x04000000
BASS_DEVICE_TYPE_MICROPHONE  :: 0x05000000
BASS_DEVICE_TYPE_HEADSET     :: 0x06000000
BASS_DEVICE_TYPE_HANDSET     :: 0x07000000
BASS_DEVICE_TYPE_DIGITAL     :: 0x08000000
BASS_DEVICE_TYPE_SPDIF       :: 0x09000000
BASS_DEVICE_TYPE_HDMI        :: 0x0a000000
BASS_DEVICE_TYPE_DISPLAYPORT :: 0x40000000

// BASS_GetDeviceInfo flags
BASS_DEVICES_AIRPLAY :: 0x1000000

// Output device info structure
BASS_INFO :: struct {
	flags:     DWORD, // DirectSound capabilities (DSCAPS_xxx flags)
	reserved:  [7]DWORD,
	minbuf:    DWORD, // recommended minimum buffer length in ms
	dsver:     DWORD, // DirectSound version
	latency:   DWORD, // average delay (in ms) before start of playback
	initflags: DWORD, // BASS_Init "flags" parameter
	speakers:  DWORD, // number of speakers available
	freq:      DWORD, // current output rate
}

// BASS_INFO flags (from DSOUND.H)
DSCAPS_EMULDRIVER  :: 0x00000020 // device does not have hardware DirectSound support
DSCAPS_CERTIFIED  :: 0x00000040  // device driver has been certified by Microsoft
DSCAPS_HARDWARE   :: 0x80000000  // hardware mixed

// Recording device info structure
BASS_RECORDINFO :: struct {
	flags:    DWORD, // DirectSound capabilities (DSCCAPS_xxx flags)
	formats:  DWORD, // number of channels (in high 8 bits)
	inputs:   DWORD, // number of inputs
	singlein: BOOL,  // TRUE = only 1 input can be set at a time
	freq:     DWORD, // current sample rate
}

// BASS_RECORDINFO flags (from DSOUND.H)
DSCCAPS_EMULDRIVER  :: DSCAPS_EMULDRIVER // device does not have hardware DirectSound recording support
DSCCAPS_CERTIFIED  :: DSCAPS_CERTIFIED   // device driver has been certified by Microsoft

// filetypes
BASS_FILE_NAME    :: 0  // filename
BASS_FILE_MEM     :: 1  // memory
BASS_FILE_MEMCOPY  :: 3 // memory to copy
BASS_FILE_HANDLE  :: 4  // handle/descriptor

// Sample info structure
BASS_SAMPLE :: struct {
	freq:     DWORD, // default playback rate
	volume:   f32,   // default volume (0-1)
	pan:      f32,   // default pan (-1=left, 0=middle, 1=right)
	flags:    DWORD, // BASS_SAMPLE_xxx flags
	length:   DWORD, // length (in bytes)
	max:      DWORD, // maximum simultaneous playbacks
	origres:  DWORD, // original resolution
	chans:    DWORD, // number of channels
	mingap:   DWORD, // minimum gap (ms) between creating channels
	mode3d:   DWORD, // BASS_3DMODE_xxx mode
	mindist:  f32,   // minimum distance
	maxdist:  f32,   // maximum distance
	iangle:   DWORD, // angle of inside projection cone
	oangle:   DWORD, // angle of outside projection cone
	outvol:   f32,   // delta-volume outside the projection cone
	reserved: [2]DWORD,
}

BASS_SAMPLE_8BITS     :: 1                   // 8 bit
BASS_SAMPLE_MONO      :: 2                   // mono
BASS_SAMPLE_LOOP      :: 4                   // looped
BASS_SAMPLE_3D        :: 8                   // 3D functionality
BASS_SAMPLE_SOFTWARE  :: 0x10                // unused
BASS_SAMPLE_MUTEMAX   :: 0x20                // mute at max distance (3D only)
BASS_SAMPLE_NOREORDER :: 0x40                // don't reorder channels to match speakers
BASS_SAMPLE_FX        :: 0x80                // unused
BASS_SAMPLE_FLOAT     :: 0x100               // 32 bit floating-point
BASS_SAMPLE_OVER_VOL  :: 0x10000             // override lowest volume
BASS_SAMPLE_OVER_POS  :: 0x20000             // override longest playing
BASS_SAMPLE_OVER_DIST :: 0x30000             // override furthest from listener (3D only)
BASS_STREAM_PRESCAN   :: 0x20000             // scan file for accurate seeking and length
BASS_STREAM_AUTOFREE  :: 0x40000             // automatically free the stream when it stops/ends
BASS_STREAM_RESTRATE  :: 0x80000             // restrict the download rate of internet file stream
BASS_STREAM_BLOCK     :: 0x100000            // download internet file stream in small blocks
BASS_STREAM_DECODE    :: 0x200000            // don't play the stream, only decode
BASS_STREAM_STATUS    :: 0x800000            // give server status info (HTTP/ICY tags) in DOWNLOADPROC
BASS_MP3_IGNOREDELAY  :: 0x200               // ignore LAME/Xing/VBRI/iTunes delay & padding info
BASS_MP3_SETPOS       :: BASS_STREAM_PRESCAN
BASS_MUSIC_FLOAT      :: BASS_SAMPLE_FLOAT
BASS_MUSIC_MONO       :: BASS_SAMPLE_MONO
BASS_MUSIC_LOOP       :: BASS_SAMPLE_LOOP
BASS_MUSIC_3D         :: BASS_SAMPLE_3D
BASS_MUSIC_FX         :: BASS_SAMPLE_FX
BASS_MUSIC_AUTOFREE   :: BASS_STREAM_AUTOFREE
BASS_MUSIC_DECODE     :: BASS_STREAM_DECODE
BASS_MUSIC_PRESCAN    :: BASS_STREAM_PRESCAN // calculate playback length
BASS_MUSIC_CALCLEN    :: BASS_MUSIC_PRESCAN
BASS_MUSIC_RAMP       :: 0x200               // normal ramping
BASS_MUSIC_RAMPS      :: 0x400               // sensitive ramping
BASS_MUSIC_SURROUND   :: 0x800               // surround sound
BASS_MUSIC_SURROUND2  :: 0x1000              // surround sound (mode 2)
BASS_MUSIC_FT2PAN     :: 0x2000              // apply FastTracker 2 panning to XM files
BASS_MUSIC_FT2MOD     :: 0x2000              // play .MOD as FastTracker 2 does
BASS_MUSIC_PT1MOD     :: 0x4000              // play .MOD as ProTracker 1 does
BASS_MUSIC_NONINTER   :: 0x10000             // non-interpolated sample mixing
BASS_MUSIC_SINCINTER  :: 0x800000            // sinc interpolated sample mixing
BASS_MUSIC_POSRESET   :: 0x8000              // stop all notes when moving position
BASS_MUSIC_POSRESETEX :: 0x400000            // stop all notes and reset bmp/etc when moving position
BASS_MUSIC_STOPBACK   :: 0x80000             // stop the music on a backwards jump effect
BASS_MUSIC_NOSAMPLE   :: 0x100000            // don't load the samples

// Speaker assignment flags
BASS_SPEAKER_FRONT      :: 0x1000000  // front speakers
BASS_SPEAKER_REAR       :: 0x2000000  // rear speakers
BASS_SPEAKER_CENLFE     :: 0x3000000  // center & LFE speakers (5.1)
BASS_SPEAKER_SIDE       :: 0x4000000  // side speakers (7.1)
BASS_SPEAKER_LEFT       :: 0x10000000 // modifier: left
BASS_SPEAKER_RIGHT      :: 0x20000000 // modifier: right
BASS_SPEAKER_FRONTLEFT  :: BASS_SPEAKER_FRONT|BASS_SPEAKER_LEFT
BASS_SPEAKER_FRONTRIGHT :: BASS_SPEAKER_FRONT|BASS_SPEAKER_RIGHT
BASS_SPEAKER_REARLEFT   :: BASS_SPEAKER_REAR|BASS_SPEAKER_LEFT
BASS_SPEAKER_REARRIGHT  :: BASS_SPEAKER_REAR|BASS_SPEAKER_RIGHT
BASS_SPEAKER_CENTER     :: BASS_SPEAKER_CENLFE|BASS_SPEAKER_LEFT
BASS_SPEAKER_LFE        :: BASS_SPEAKER_CENLFE|BASS_SPEAKER_RIGHT
BASS_SPEAKER_SIDELEFT   :: BASS_SPEAKER_SIDE|BASS_SPEAKER_LEFT
BASS_SPEAKER_SIDERIGHT  :: BASS_SPEAKER_SIDE|BASS_SPEAKER_RIGHT
BASS_SPEAKER_REAR2      :: BASS_SPEAKER_SIDE
BASS_SPEAKER_REAR2LEFT  :: BASS_SPEAKER_SIDELEFT
BASS_SPEAKER_REAR2RIGHT :: BASS_SPEAKER_SIDERIGHT
BASS_ASYNCFILE          :: 0x40000000 // read file asynchronously
BASS_UNICODE            :: 0x80000000 // UTF-16
BASS_RECORD_OPENSLES    :: 0x1000     // use OpenSLES
BASS_RECORD_PAUSE       :: 0x8000     // start recording paused

// Channel info structure
BASS_CHANNELINFO :: struct {
	freq:     DWORD, // default playback rate
	chans:    DWORD, // channels
	flags:    DWORD,
	ctype:    DWORD, // type of channel
	origres:  DWORD, // original resolution
	plugin:   HPLUGIN,
	sample:   HSAMPLE,
	filename: cstring,
}

BASS_ORIGRES_FLOAT  :: 0x10000

// BASS_CHANNELINFO types
BASS_CTYPE_SAMPLE           :: 1
BASS_CTYPE_RECORD           :: 2
BASS_CTYPE_STREAM           :: 0x10000
BASS_CTYPE_STREAM_VORBIS    :: 0x10002
BASS_CTYPE_STREAM_OGG       :: 0x10002
BASS_CTYPE_STREAM_MP1       :: 0x10003
BASS_CTYPE_STREAM_MP2       :: 0x10004
BASS_CTYPE_STREAM_MP3       :: 0x10005
BASS_CTYPE_STREAM_AIFF      :: 0x10006
BASS_CTYPE_STREAM_CA        :: 0x10007
BASS_CTYPE_STREAM_MF        :: 0x10008
BASS_CTYPE_STREAM_AM        :: 0x10009
BASS_CTYPE_STREAM_SAMPLE    :: 0x1000a
BASS_CTYPE_STREAM_DUMMY     :: 0x18000
BASS_CTYPE_STREAM_DEVICE    :: 0x18001
BASS_CTYPE_STREAM_WAV       :: 0x40000 // WAVE flag (LOWORD=codec)
BASS_CTYPE_STREAM_WAV_PCM   :: 0x50001
BASS_CTYPE_STREAM_WAV_FLOAT :: 0x50003
BASS_CTYPE_MUSIC_MOD        :: 0x20000
BASS_CTYPE_MUSIC_MTM        :: 0x20001
BASS_CTYPE_MUSIC_S3M        :: 0x20002
BASS_CTYPE_MUSIC_XM         :: 0x20003
BASS_CTYPE_MUSIC_IT         :: 0x20004
BASS_CTYPE_MUSIC_MO3        :: 0x00100 // MO3 flag

// BASS_PluginLoad flags
BASS_PLUGIN_PROC  :: 1

BASS_PLUGINFORM :: struct {
	ctype: DWORD,   // channel type
	name:  cstring, // format description
	exts:  cstring, // file extension filter (*.ext1;*.ext2;etc...)
}

BASS_PLUGININFO :: struct {
	version: DWORD,            // version (same form as BASS_GetVersion)
	formatc: DWORD,            // number of formats
	formats: ^BASS_PLUGINFORM, // the array of formats
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

// software 3D mixing algorithms (used with BASS_CONFIG_3DALGORITHM)
BASS_3DALG_DEFAULT :: 0
BASS_3DALG_OFF     :: 1

// BASS_SampleGetChannel flags
BASS_SAMCHAN_NEW    :: 1  // get a new playback channel
BASS_SAMCHAN_STREAM  :: 2 // create a stream

@(default_calling_convention="c")
foreign lib {
	STREAMPROC :: proc(HSTREAM, rawptr, DWORD, rawptr) -> DWORD ---
}

/* User stream callback function.
handle : The stream that needs writing
buffer : Buffer to write the samples in
length : Number of bytes to write
user   : The 'user' parameter value given when calling BASS_StreamCreate
RETURN : Number of bytes written and BASS_STREAMPROC_xxx flags */
BASS_STREAMPROC_AGAIN :: 0x40000000 // call again for remainder
BASS_STREAMPROC_END   :: 0x80000000 // end the stream

// Special STREAMPROCs
STREAMPROC_DUMMY     :: 0  // "dummy" stream
STREAMPROC_PUSH      :: -1 // push stream
STREAMPROC_DEVICE    :: -2 // device mix stream
STREAMPROC_DEVICE_3D :: -3 // device 3D mix stream

// BASS_StreamCreateFileUser file systems
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

BASS_FILEPROCS :: struct {
	close:  proc "c" (),
	length: proc "c" () -> QWORD,
	read:   proc "c" () -> DWORD,
	seek:   proc "c" () -> BOOL,
}

BASS_FILEOPENPROCS :: struct {
	close:  proc "c" (),
	length: proc "c" () -> QWORD,
	read:   proc "c" () -> DWORD,
	seek:   proc "c" () -> BOOL,
	open:   proc "c" () -> rawptr,
}

// BASS_StreamPutFileData options
BASS_FILEDATA_END  :: 0 // end & close the file

// BASS_StreamGetFilePosition modes
BASS_FILEPOS_CURRENT   :: 0
BASS_FILEPOS_DECODE    :: BASS_FILEPOS_CURRENT
BASS_FILEPOS_DOWNLOAD  :: 1
BASS_FILEPOS_END       :: 2
BASS_FILEPOS_START     :: 3
BASS_FILEPOS_CONNECTED :: 4
BASS_FILEPOS_BUFFER    :: 5
BASS_FILEPOS_SOCKET    :: 6
BASS_FILEPOS_ASYNCBUF  :: 7
BASS_FILEPOS_SIZE      :: 8
BASS_FILEPOS_BUFFERING :: 9
BASS_FILEPOS_AVAILABLE :: 10
BASS_FILEPOS_ASYNCSIZE :: 12

@(default_calling_convention="c")
foreign lib {
	DOWNLOADPROC :: proc(rawptr, DWORD, rawptr) ---
}

/* Internet stream download callback function.
buffer : Buffer containing the downloaded data... NULL=end of download
length : Number of bytes in the buffer
user   : The 'user' parameter value given when calling BASS_StreamCreateURL */

// BASS_ChannelSetSync types
BASS_SYNC_POS        :: 0
BASS_SYNC_END        :: 2
BASS_SYNC_META       :: 4
BASS_SYNC_SLIDE      :: 5
BASS_SYNC_STALL      :: 6
BASS_SYNC_DOWNLOAD   :: 7
BASS_SYNC_FREE       :: 8
BASS_SYNC_SETPOS     :: 11
BASS_SYNC_MUSICPOS   :: 10
BASS_SYNC_MUSICINST  :: 1
BASS_SYNC_MUSICFX    :: 3
BASS_SYNC_OGG_CHANGE :: 12
BASS_SYNC_ATTRIB     :: 13
BASS_SYNC_DEV_FAIL   :: 14
BASS_SYNC_DEV_FORMAT :: 15
BASS_SYNC_POS_RAW    :: 16
BASS_SYNC_THREAD     :: 0x20000000 // flag: call sync in other thread
BASS_SYNC_MIXTIME    :: 0x40000000 // flag: sync at mixtime, else at playtime
BASS_SYNC_ONETIME    :: 0x80000000 // flag: sync only once, else continuously

@(default_calling_convention="c")
foreign lib {
	SYNCPROC :: proc(HSYNC, DWORD, DWORD, rawptr) ---

	/* Sync callback function.
	handle : The sync that has occured
	channel: Channel that the sync occured in
	data   : Additional data associated with the sync's occurance
	user   : The 'user' parameter given when calling BASS_ChannelSetSync */
	DSPPROC :: proc(HDSP, DWORD, rawptr, DWORD, rawptr) ---

	/* DSP callback function.
	handle : The DSP handle
	channel: Channel that the DSP is being applied to
	buffer : Buffer to apply the DSP to
	length : Number of bytes in the buffer
	user   : The 'user' parameter given when calling BASS_ChannelSetDSP */
	RECORDPROC :: proc(HRECORD, rawptr, DWORD, rawptr) -> BOOL ---
}

/* Recording callback function.
handle : The recording handle
buffer : Buffer containing the recorded sample data
length : Number of bytes
user   : The 'user' parameter value given when calling BASS_RecordStart
RETURN : TRUE = continue recording, FALSE = stop */

// Special RECORDPROCs
RECORDPROC_NONE   :: 0  // no RECORDPROC
RECORDPROC_TRUE   :: -1 // only "return true"

// BASS_ChannelIsActive return values
BASS_ACTIVE_STOPPED       :: 0
BASS_ACTIVE_PLAYING       :: 1
BASS_ACTIVE_STALLED       :: 2
BASS_ACTIVE_PAUSED        :: 3
BASS_ACTIVE_PAUSED_DEVICE :: 4

// Channel attributes
BASS_ATTRIB_FREQ             :: 1
BASS_ATTRIB_VOL              :: 2
BASS_ATTRIB_PAN              :: 3
BASS_ATTRIB_EAXMIX           :: 4
BASS_ATTRIB_NOBUFFER         :: 5
BASS_ATTRIB_VBR              :: 6
BASS_ATTRIB_CPU              :: 7
BASS_ATTRIB_SRC              :: 8
BASS_ATTRIB_NET_RESUME       :: 9
BASS_ATTRIB_SCANINFO         :: 10
BASS_ATTRIB_NORAMP           :: 11
BASS_ATTRIB_BITRATE          :: 12
BASS_ATTRIB_BUFFER           :: 13
BASS_ATTRIB_GRANULE          :: 14
BASS_ATTRIB_USER             :: 15
BASS_ATTRIB_TAIL             :: 16
BASS_ATTRIB_PUSH_LIMIT       :: 17
BASS_ATTRIB_DOWNLOADPROC     :: 18
BASS_ATTRIB_VOLDSP           :: 19
BASS_ATTRIB_VOLDSP_PRIORITY  :: 20
BASS_ATTRIB_DOWNMIX          :: 21
BASS_ATTRIB_MUSIC_AMPLIFY    :: 0x100
BASS_ATTRIB_MUSIC_PANSEP     :: 0x101
BASS_ATTRIB_MUSIC_PSCALER    :: 0x102
BASS_ATTRIB_MUSIC_BPM        :: 0x103
BASS_ATTRIB_MUSIC_SPEED      :: 0x104
BASS_ATTRIB_MUSIC_VOL_GLOBAL :: 0x105
BASS_ATTRIB_MUSIC_ACTIVE     :: 0x106
BASS_ATTRIB_MUSIC_VOL_CHAN   :: 0x200 // + channel #
BASS_ATTRIB_MUSIC_VOL_INST   :: 0x300 // + instrument #

// Channel attribute types
BASS_ATTRIBTYPE_FLOAT  :: -1
BASS_ATTRIBTYPE_INT   :: -2

// BASS_ChannelSlideAttribute flags
BASS_SLIDE_LOG    :: 0x1000000

// BASS_ChannelGetData flags
BASS_DATA_AVAILABLE      :: 0          // query how much data is buffered
BASS_DATA_NOREMOVE       :: 0x10000000 // flag: don't remove data from recording buffer
BASS_DATA_FIXED          :: 0x20000000 // unused
BASS_DATA_FLOAT          :: 0x40000000 // flag: return floating-point sample data
BASS_DATA_FFT256         :: 0x80000000 // 256 sample FFT
BASS_DATA_FFT512         :: 0x80000001 // 512 FFT
BASS_DATA_FFT1024        :: 0x80000002 // 1024 FFT
BASS_DATA_FFT2048        :: 0x80000003 // 2048 FFT
BASS_DATA_FFT4096        :: 0x80000004 // 4096 FFT
BASS_DATA_FFT8192        :: 0x80000005 // 8192 FFT
BASS_DATA_FFT16384       :: 0x80000006 // 16384 FFT
BASS_DATA_FFT32768       :: 0x80000007 // 32768 FFT
BASS_DATA_FFT_INDIVIDUAL :: 0x10       // FFT flag: FFT for each channel, else all combined
BASS_DATA_FFT_NOWINDOW   :: 0x20       // FFT flag: no Hanning window
BASS_DATA_FFT_REMOVEDC   :: 0x40       // FFT flag: pre-remove DC bias
BASS_DATA_FFT_COMPLEX    :: 0x80       // FFT flag: return complex data
BASS_DATA_FFT_NYQUIST    :: 0x100      // FFT flag: return extra Nyquist value

// BASS_ChannelGetLevelEx flags
BASS_LEVEL_MONO     :: 1    // get mono level
BASS_LEVEL_STEREO   :: 2    // get stereo level
BASS_LEVEL_RMS      :: 4    // get RMS levels
BASS_LEVEL_VOLPAN   :: 8    // apply VOL/PAN attributes to the levels
BASS_LEVEL_NOREMOVE :: 0x10 // don't remove data from recording buffer

// BASS_ChannelGetTags types : what's returned
BASS_TAG_ID3            :: 0          // ID3v1 tags : TAG_ID3 structure
BASS_TAG_ID3V2          :: 1          // ID3v2 tags : variable length block
BASS_TAG_OGG            :: 2          // OGG comments : series of null-terminated UTF-8 strings
BASS_TAG_HTTP           :: 3          // HTTP headers : series of null-terminated ASCII strings
BASS_TAG_ICY            :: 4          // ICY headers : series of null-terminated ANSI strings
BASS_TAG_META           :: 5          // ICY metadata : ANSI string
BASS_TAG_APE            :: 6          // APE tags : series of null-terminated UTF-8 strings
BASS_TAG_MP4            :: 7          // MP4/iTunes metadata : series of null-terminated UTF-8 strings
BASS_TAG_WMA            :: 8          // WMA tags : series of null-terminated UTF-8 strings
BASS_TAG_VENDOR         :: 9          // OGG encoder : UTF-8 string
BASS_TAG_LYRICS3        :: 10         // Lyric3v2 tag : ASCII string
BASS_TAG_CA_CODEC       :: 11         // CoreAudio codec info : TAG_CA_CODEC structure
BASS_TAG_MF             :: 13         // Media Foundation tags : series of null-terminated UTF-8 strings
BASS_TAG_WAVEFORMAT     :: 14         // WAVE format : WAVEFORMATEEX structure
BASS_TAG_AM_NAME        :: 16         // Android Media codec name : ASCII string
BASS_TAG_ID3V2_2        :: 17         // ID3v2 tags (2nd block) : variable length block
BASS_TAG_AM_MIME        :: 18         // Android Media MIME type : ASCII string
BASS_TAG_LOCATION       :: 19         // redirected URL : ASCII string
BASS_TAG_ID3V2_BINARY   :: 20         // ID3v2 tags : TAB_BINARY
BASS_TAG_ID3V2_2_BINARY :: 21         // ID3v2 tags (2nd block) : TAB_BINARY
BASS_TAG_RIFF_INFO      :: 0x100      // RIFF "INFO" tags : series of null-terminated ANSI strings
BASS_TAG_RIFF_BEXT      :: 0x101      // RIFF/BWF "bext" tags : TAG_BEXT structure
BASS_TAG_RIFF_CART      :: 0x102      // RIFF/BWF "cart" tags : TAG_CART structure
BASS_TAG_RIFF_DISP      :: 0x103      // RIFF "DISP" text tag : ANSI string
BASS_TAG_RIFF_CUE       :: 0x104      // RIFF "cue " chunk : TAG_CUE structure
BASS_TAG_RIFF_SMPL      :: 0x105      // RIFF "smpl" chunk : TAG_SMPL structure
BASS_TAG_APE_BINARY     :: 0x1000     // + index #, binary APE tag : TAG_APE_BINARY structure
BASS_TAG_MP4_COVERART   :: 0x1400     // + index #, MP4 cover art : TAG_BINARY structure
BASS_TAG_MUSIC_NAME     :: 0x10000    // MOD music name : ANSI string
BASS_TAG_MUSIC_MESSAGE  :: 0x10001    // MOD message : ANSI string
BASS_TAG_MUSIC_ORDERS   :: 0x10002    // MOD order list : BYTE array of pattern numbers
BASS_TAG_MUSIC_AUTH     :: 0x10003    // MOD author : UTF-8 string
BASS_TAG_MUSIC_INST     :: 0x10100    // + instrument #, MOD instrument name : ANSI string
BASS_TAG_MUSIC_CHAN     :: 0x10200    // + channel #, MOD channel name : ANSI string
BASS_TAG_MUSIC_SAMPLE   :: 0x10300    // + sample #, MOD sample name : ANSI string
BASS_TAG_INCREF         :: 0x20000000 // flag: increment channel's reference count

// ID3v1 tag structure
TAG_ID3 :: struct {
	id:      [3]i8,
	title:   [30]i8,
	artist:  [30]i8,
	album:   [30]i8,
	year:    [4]i8,
	comment: [30]i8,
	genre:   BYTE,
}

// Binary tag structure
TAG_BINARY :: struct {
	data:   rawptr,
	length: DWORD,
}

// Binary APE tag structure
TAG_APE_BINARY :: struct {
	key:    cstring,
	data:   rawptr,
	length: DWORD,
}

TAG_BEXT :: struct {
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
TAG_CART_TIMER :: struct {
	dwUsage: DWORD, // FOURCC timer usage ID
	dwValue: DWORD, // timer value in samples from head
}

TAG_CART :: struct {
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
	PostTimer:          [8]TAG_CART_TIMER, // 8 time markers after head
	Reserved:           [276]i8,
	URL:                [1024]i8,          // uniform resource locator
	TagText:            [^]i8,             // free form text for scripts or tags
}

// RIFF "cue " tag structures
TAG_CUE_POINT :: struct {
	dwName:         DWORD,
	dwPosition:     DWORD,
	fccChunk:       DWORD,
	dwChunkStart:   DWORD,
	dwBlockStart:   DWORD,
	dwSampleOffset: DWORD,
}

TAG_CUE :: struct {
	dwCuePoints: DWORD,
	CuePoints:   [^]TAG_CUE_POINT,
}

// RIFF "smpl" tag structures
TAG_SMPL_LOOP :: struct {
	dwIdentifier: DWORD,
	dwType:       DWORD,
	dwStart:      DWORD,
	dwEnd:        DWORD,
	dwFraction:   DWORD,
	dwPlayCount:  DWORD,
}

TAG_SMPL :: struct {
	dwManufacturer:      DWORD,
	dwProduct:           DWORD,
	dwSamplePeriod:      DWORD,
	dwMIDIUnityNote:     DWORD,
	dwMIDIPitchFraction: DWORD,
	dwSMPTEFormat:       DWORD,
	dwSMPTEOffset:       DWORD,
	cSampleLoops:        DWORD,
	cbSamplerData:       DWORD,
	SampleLoops:         [^]TAG_SMPL_LOOP,
}

// CoreAudio codec info structure
TAG_CA_CODEC :: struct {
	ftype: DWORD,   // file format
	atype: DWORD,   // audio format
	name:  cstring, // description
}

// BASS_ChannelGetLength/GetPosition/SetPosition modes
BASS_POS_BYTE        :: 0          // byte position
BASS_POS_MUSIC_ORDER :: 1          // order.row position, MAKELONG(order,row)
BASS_POS_OGG         :: 3          // OGG bitstream number
BASS_POS_TRACK       :: 4          // track number
BASS_POS_RAW         :: 6          // monotonic byte position
BASS_POS_END         :: 0x10       // trimmed end position
BASS_POS_LOOP        :: 0x11       // loop start positiom
BASS_POS_DSP         :: 0x800000   // flag: get the DSP position
BASS_POS_FLUSH       :: 0x1000000  // flag: flush decoder/FX buffers
BASS_POS_RESET       :: 0x2000000  // flag: reset user file buffers
BASS_POS_RELATIVE    :: 0x4000000  // flag: seek relative to the current position
BASS_POS_INEXACT     :: 0x8000000  // flag: allow seeking to inexact position
BASS_POS_DECODE      :: 0x10000000 // flag: get the decoding (not playing) position
BASS_POS_DECODETO    :: 0x20000000 // flag: decode to the position instead of seeking
BASS_POS_SCAN        :: 0x40000000 // flag: scan to the position

// BASS_ChannelSetDevice/GetDevice option
BASS_NODEVICE  :: 0x20000

// BASS_RecordSetInput flags
BASS_INPUT_OFF          :: 0x10000
BASS_INPUT_ON           :: 0x20000
BASS_INPUT_TYPE_MASK    :: 0xff000000
BASS_INPUT_TYPE_UNDEF   :: 0x00000000
BASS_INPUT_TYPE_DIGITAL  :: 0x01000000
BASS_INPUT_TYPE_LINE    :: 0x02000000
BASS_INPUT_TYPE_MIC     :: 0x03000000
BASS_INPUT_TYPE_SYNTH   :: 0x04000000
BASS_INPUT_TYPE_CD      :: 0x05000000
BASS_INPUT_TYPE_PHONE   :: 0x06000000
BASS_INPUT_TYPE_SPEAKER  :: 0x07000000
BASS_INPUT_TYPE_WAVE    :: 0x08000000
BASS_INPUT_TYPE_AUX     :: 0x09000000
BASS_INPUT_TYPE_ANALOG  :: 0x0a000000

// BASS_ChannelSetDSPEx flags
BASS_DSP_READONLY   :: 1
BASS_DSP_FLOAT    :: 2
BASS_DSP_FREECALL   :: 4
BASS_DSP_BYPASS    :: 0x400000

// BASS_ChannelSetFX effect types
BASS_FX_DX8_CHORUS      :: 0
BASS_FX_DX8_COMPRESSOR  :: 1
BASS_FX_DX8_DISTORTION  :: 2
BASS_FX_DX8_ECHO        :: 3
BASS_FX_DX8_FLANGER     :: 4
BASS_FX_DX8_GARGLE      :: 5
BASS_FX_DX8_I3DL2REVERB  :: 6
BASS_FX_DX8_PARAMEQ     :: 7
BASS_FX_DX8_REVERB      :: 8
BASS_FX_VOLUME          :: 9

BASS_DX8_CHORUS :: struct {
	fWetDryMix: f32,
	fDepth:     f32,
	fFeedback:  f32,
	fFrequency: f32,
	lWaveform:  DWORD, // 0=triangle, 1=sine
	fDelay:     f32,
	lPhase:     DWORD, // BASS_DX8_PHASE_xxx
}

BASS_DX8_COMPRESSOR :: struct {
	fGain:      f32,
	fAttack:    f32,
	fRelease:   f32,
	fThreshold: f32,
	fRatio:     f32,
	fPredelay:  f32,
}

BASS_DX8_DISTORTION :: struct {
	fGain:                  f32,
	fEdge:                  f32,
	fPostEQCenterFrequency: f32,
	fPostEQBandwidth:       f32,
	fPreLowpassCutoff:      f32,
}

BASS_DX8_ECHO :: struct {
	fWetDryMix:  f32,
	fFeedback:   f32,
	fLeftDelay:  f32,
	fRightDelay: f32,
	lPanDelay:   BOOL,
}

BASS_DX8_FLANGER :: struct {
	fWetDryMix: f32,
	fDepth:     f32,
	fFeedback:  f32,
	fFrequency: f32,
	lWaveform:  DWORD, // 0=triangle, 1=sine
	fDelay:     f32,
	lPhase:     DWORD, // BASS_DX8_PHASE_xxx
}

BASS_DX8_GARGLE :: struct {
	dwRateHz:    DWORD, // Rate of modulation in hz
	dwWaveShape: DWORD, // 0=triangle, 1=square
}

BASS_DX8_I3DL2REVERB :: struct {
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

BASS_DX8_PARAMEQ :: struct {
	fCenter:    f32,
	fBandwidth: f32,
	fGain:      f32,
}

BASS_DX8_REVERB :: struct {
	fInGain:          f32, // [-96.0,0.0]            default: 0.0 dB
	fReverbMix:       f32, // [-96.0,0.0]            default: 0.0 db
	fReverbTime:      f32, // [0.001,3000.0]         default: 1000.0 ms
	fHighFreqRTRatio: f32, // [0.001,0.999]          default: 0.001
}

BASS_DX8_PHASE_NEG_180        :: 0
BASS_DX8_PHASE_NEG_90         :: 1
BASS_DX8_PHASE_ZERO           :: 2
BASS_DX8_PHASE_90             :: 3
BASS_DX8_PHASE_180            :: 4

BASS_FX_VOLUME_PARAM :: struct {
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
notify : The notification (BASS_DEVICENOTIFY_xxx) */
BASS_DEVICENOTIFY_ENABLED        :: 0 // a device has been added or removed
BASS_DEVICENOTIFY_DEFAULT        :: 1 // the default output device has changed
BASS_DEVICENOTIFY_REC_DEFAULT    :: 2 // the default recording device has changed
BASS_DEVICENOTIFY_DEFAULTCOM     :: 3 // the default communication output device has changed
BASS_DEVICENOTIFY_REC_DEFAULTCOM :: 4 // the default communication recording device has changed

@(default_calling_convention="c")
foreign lib {
	IOSNOTIFYPROC :: proc(DWORD) ---
}

/* iOS notification callback function.
status : The notification (BASS_IOSNOTIFY_xxx) */
BASS_IOSNOTIFY_INTERRUPT     :: 1 // interruption started
BASS_IOSNOTIFY_INTERRUPT_END :: 2 // interruption ended

@(default_calling_convention="c", link_prefix="BASS_")
foreign lib {
	SetConfig              :: proc(option: DWORD, value: DWORD) -> BOOL ---
	GetConfig              :: proc(option: DWORD) -> DWORD ---
	SetConfigPtr           :: proc(option: DWORD, value: rawptr) -> BOOL ---
	GetConfigPtr           :: proc(option: DWORD) -> rawptr ---
	GetVersion             :: proc() -> DWORD ---
	ErrorGetCode           :: proc() -> i32 ---
	GetDeviceInfo          :: proc(device: DWORD, info: ^BASS_DEVICEINFO) -> BOOL ---
	Init                   :: proc(device: i32, freq: DWORD, flags: DWORD, win: HWND, dsguid: rawptr) -> BOOL ---
	Free                   :: proc() -> BOOL ---
	SetDevice              :: proc(device: DWORD) -> BOOL ---
	GetDevice              :: proc() -> DWORD ---
	GetInfo                :: proc(info: ^BASS_INFO) -> BOOL ---
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
	PluginGetInfo          :: proc(handle: HPLUGIN) -> ^BASS_PLUGININFO ---
	SampleLoad             :: proc(filetype: DWORD, file: rawptr, offset: QWORD, length: DWORD, max: DWORD, flags: DWORD) -> HSAMPLE ---
	SampleCreate           :: proc(length: DWORD, freq: DWORD, chans: DWORD, max: DWORD, flags: DWORD) -> HSAMPLE ---
	SampleFree             :: proc(handle: HSAMPLE) -> BOOL ---
	SampleSetData          :: proc(handle: HSAMPLE, buffer: rawptr) -> BOOL ---
	SampleGetData          :: proc(handle: HSAMPLE, buffer: rawptr) -> BOOL ---
	SampleGetInfo          :: proc(handle: HSAMPLE, info: ^BASS_SAMPLE) -> BOOL ---
	SampleSetInfo          :: proc(handle: HSAMPLE, info: ^BASS_SAMPLE) -> BOOL ---
	SampleGetChannel       :: proc(handle: HSAMPLE, flags: DWORD) -> DWORD ---
	SampleGetChannels      :: proc(handle: HSAMPLE, channels: ^HCHANNEL) -> DWORD ---
	SampleStop             :: proc(handle: HSAMPLE) -> BOOL ---
	StreamCreate           :: proc(freq: DWORD, chans: DWORD, flags: DWORD, _proc: proc "c" () -> DWORD, user: rawptr) -> HSTREAM ---
	StreamCreateFile       :: proc(filetype: DWORD, file: rawptr, offset: QWORD, length: QWORD, flags: DWORD) -> HSTREAM ---
	StreamCreateURL        :: proc(url: cstring, offset: DWORD, flags: DWORD, _proc: proc "c" (), user: rawptr) -> HSTREAM ---
	StreamCreateFileUser   :: proc(system: DWORD, flags: DWORD, _proc: ^BASS_FILEPROCS, user: rawptr) -> HSTREAM ---
	StreamCancel           :: proc(user: rawptr) -> BOOL ---
	StreamFree             :: proc(handle: HSTREAM) -> BOOL ---
	StreamGetFilePosition  :: proc(handle: HSTREAM, mode: DWORD) -> QWORD ---
	StreamPutData          :: proc(handle: HSTREAM, buffer: rawptr, length: DWORD) -> DWORD ---
	StreamPutFileData      :: proc(handle: HSTREAM, buffer: rawptr, length: DWORD) -> DWORD ---
	MusicLoad              :: proc(filetype: DWORD, file: rawptr, offset: QWORD, length: DWORD, flags: DWORD, freq: DWORD) -> HMUSIC ---
	MusicFree              :: proc(handle: HMUSIC) -> BOOL ---
	RecordGetDeviceInfo    :: proc(device: DWORD, info: ^BASS_DEVICEINFO) -> BOOL ---
	RecordInit             :: proc(device: i32) -> BOOL ---
	RecordFree             :: proc() -> BOOL ---
	RecordSetDevice        :: proc(device: DWORD) -> BOOL ---
	RecordGetDevice        :: proc() -> DWORD ---
	RecordGetInfo          :: proc(info: ^BASS_RECORDINFO) -> BOOL ---
	RecordGetInputName     :: proc(input: i32) -> cstring ---
	RecordSetInput         :: proc(input: i32, flags: DWORD, volume: f32) -> BOOL ---
	RecordGetInput         :: proc(input: i32, volume: ^f32) -> DWORD ---
	RecordStart            :: proc(freq: DWORD, chans: DWORD, flags: DWORD, _proc: proc "c" () -> BOOL, user: rawptr) -> HRECORD ---
	ChannelBytes2Seconds   :: proc(handle: DWORD, pos: QWORD) -> f64 ---
	ChannelSeconds2Bytes   :: proc(handle: DWORD, pos: f64) -> QWORD ---
	ChannelGetDevice       :: proc(handle: DWORD) -> DWORD ---
	ChannelSetDevice       :: proc(handle: DWORD, device: DWORD) -> BOOL ---
	ChannelIsActive        :: proc(handle: DWORD) -> DWORD ---
	ChannelGetInfo         :: proc(handle: DWORD, info: ^BASS_CHANNELINFO) -> BOOL ---
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
