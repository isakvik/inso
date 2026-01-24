/*
	BASSWASAPI 2.4 C/C++ header file
	Copyright (c) 2009-2020 Un4seen Developments Ltd.

	See the BASSWASAPI.CHM file for more detailed documentation
*/
package bass

WASAPI_LIB :: "lib/basswasapi.lib" when ODIN_OS == .Windows else "lib/basswasapi.a"
foreign import lib { WASAPI_LIB }

// Additional error codes returned by BASS_ErrorGetCode
BASS_ERROR_WASAPI          :: 5000 // no WASAPI
BASS_ERROR_WASAPI_BUFFER   :: 5001 // buffer size is invalid
BASS_ERROR_WASAPI_CATEGORY :: 5002 // can't set category
BASS_ERROR_WASAPI_DENIED   :: 5003 // access denied

// Device info structure
BASS_WASAPI_DEVICEINFO :: struct {
	name:      cstring,
	id:        cstring,
	type:      DWORD,
	flags:     DWORD,
	minperiod: f32,
	defperiod: f32,
	mixfreq:   DWORD,
	mixchans:  DWORD,
}

BASS_WASAPI_INFO :: struct {
	initflags: DWORD,
	freq:      DWORD,
	chans:     DWORD,
	format:    DWORD,
	buflen:    DWORD,
	volmax:    f32,
	volmin:    f32,
	volstep:   f32,
}

// BASS_WASAPI_DEVICEINFO "type"
BASS_WASAPI_TYPE_NETWORKDEVICE :: 0
BASS_WASAPI_TYPE_SPEAKERS      :: 1
BASS_WASAPI_TYPE_LINELEVEL     :: 2
BASS_WASAPI_TYPE_HEADPHONES    :: 3
BASS_WASAPI_TYPE_MICROPHONE    :: 4
BASS_WASAPI_TYPE_HEADSET       :: 5
BASS_WASAPI_TYPE_HANDSET       :: 6
BASS_WASAPI_TYPE_DIGITAL       :: 7
BASS_WASAPI_TYPE_SPDIF         :: 8
BASS_WASAPI_TYPE_HDMI          :: 9
BASS_WASAPI_TYPE_UNKNOWN       :: 10

// BASS_WASAPI_DEVICEINFO flags
BASS_DEVICE_INPUT     :: 16
BASS_DEVICE_UNPLUGGED :: 32
BASS_DEVICE_DISABLED  :: 64

// BASS_WASAPI_Init flags
BASS_WASAPI_EXCLUSIVE                       :: 1
BASS_WASAPI_AUTOFORMAT                      :: 2
BASS_WASAPI_BUFFER                          :: 4
BASS_WASAPI_EVENT                           :: 16
BASS_WASAPI_SAMPLES                         :: 32
BASS_WASAPI_DITHER                          :: 64
BASS_WASAPI_RAW                             :: 128
BASS_WASAPI_ASYNC                           :: 0x100
BASS_WASAPI_CATEGORY_MASK                   :: 0xf000
BASS_WASAPI_CATEGORY_OTHER                  :: 0x0000
BASS_WASAPI_CATEGORY_FOREGROUNDONLYMEDIA    :: 0x1000
BASS_WASAPI_CATEGORY_BACKGROUNDCAPABLEMEDIA :: 0x2000
BASS_WASAPI_CATEGORY_COMMUNICATIONS         :: 0x3000
BASS_WASAPI_CATEGORY_ALERTS                 :: 0x4000
BASS_WASAPI_CATEGORY_SOUNDEFFECTS           :: 0x5000
BASS_WASAPI_CATEGORY_GAMEEFFECTS            :: 0x6000
BASS_WASAPI_CATEGORY_GAMEMEDIA              :: 0x7000
BASS_WASAPI_CATEGORY_GAMECHAT               :: 0x8000
BASS_WASAPI_CATEGORY_SPEECH                 :: 0x9000
BASS_WASAPI_CATEGORY_MOVIE                  :: 0xa000
BASS_WASAPI_CATEGORY_MEDIA                  :: 0xb000

// BASS_WASAPI_INFO "format"
BASS_WASAPI_FORMAT_FLOAT :: 0
BASS_WASAPI_FORMAT_8BIT  :: 1
BASS_WASAPI_FORMAT_16BIT :: 2
BASS_WASAPI_FORMAT_24BIT :: 3
BASS_WASAPI_FORMAT_32BIT :: 4

// BASS_WASAPI_Set/GetVolume modes
BASS_WASAPI_CURVE_DB      :: 0
BASS_WASAPI_CURVE_LINEAR  :: 1
BASS_WASAPI_CURVE_WINDOWS :: 2
BASS_WASAPI_VOL_SESSION   :: 8

WASAPIPROC :: proc "c" (rawptr, DWORD, rawptr) -> DWORD

/* WASAPI callback function.
buffer : Buffer containing the sample data
length : Number of bytes
user   : The 'user' parameter given when calling BASS_WASAPI_Init
RETURN : The number of bytes written (output devices), 0/1 = stop/continue (input devices) */

// Special WASAPIPROCs
WASAPIPROC_PUSH  :: 0  // push output
WASAPIPROC_BASS  :: -1 // BASS channel

@(default_calling_convention="c")
foreign lib {
	WASAPINOTIFYPROC :: proc(DWORD, DWORD, rawptr) ---
}

/* WASAPI device notification callback function.
notify : The notification (BASS_WASAPI_NOTIFY_xxx)
device : Device that the notification applies to
user   : The 'user' parameter given when calling BASS_WASAPI_SetNotify */

// Device notifications
BASS_WASAPI_NOTIFY_ENABLED   :: 0
BASS_WASAPI_NOTIFY_DISABLED  :: 1
BASS_WASAPI_NOTIFY_DEFOUTPUT :: 2
BASS_WASAPI_NOTIFY_DEFINPUT  :: 3
BASS_WASAPI_NOTIFY_FAIL      :: 0x100

@(default_calling_convention="c",link_prefix="BASS_")
foreign lib {
	WASAPI_GetVersion     :: proc() -> DWORD ---
	WASAPI_SetNotify      :: proc(_proc: proc "c" (), user: rawptr) -> BOOL ---
	WASAPI_GetDeviceInfo  :: proc(device: DWORD, info: ^BASS_WASAPI_DEVICEINFO) -> BOOL ---
	WASAPI_GetDeviceLevel :: proc(device: DWORD, chan: i32) -> f32 ---
	WASAPI_SetDevice      :: proc(device: DWORD) -> BOOL ---
	WASAPI_GetDevice      :: proc() -> DWORD ---
	WASAPI_CheckFormat    :: proc(device: DWORD, freq: DWORD, chans: DWORD, flags: DWORD) -> DWORD ---
	WASAPI_Init           :: proc(device: i32, freq: DWORD, chans: DWORD, flags: DWORD, buffer: f32, period: f32, _proc: WASAPIPROC, user: rawptr) -> BOOL ---
	WASAPI_Free           :: proc() -> BOOL ---
	WASAPI_GetInfo        :: proc(info: ^BASS_WASAPI_INFO) -> BOOL ---
	WASAPI_GetCPU         :: proc() -> f32 ---
	WASAPI_Lock           :: proc(lock: BOOL) -> BOOL ---
	WASAPI_Start          :: proc() -> BOOL ---
	WASAPI_Stop           :: proc(reset: BOOL) -> BOOL ---
	WASAPI_IsStarted      :: proc() -> BOOL ---
	WASAPI_SetVolume      :: proc(mode: DWORD, volume: f32) -> BOOL ---
	WASAPI_GetVolume      :: proc(mode: DWORD) -> f32 ---
	WASAPI_SetMute        :: proc(mode: DWORD, mute: BOOL) -> BOOL ---
	WASAPI_GetMute        :: proc(mode: DWORD) -> BOOL ---
	WASAPI_PutData        :: proc(buffer: rawptr, length: DWORD) -> DWORD ---
	WASAPI_GetData        :: proc(buffer: rawptr, length: DWORD) -> DWORD ---
	WASAPI_GetLevel       :: proc() -> DWORD ---
	WASAPI_GetLevelEx     :: proc(levels: ^f32, length: f32, flags: DWORD) -> BOOL ---
}
