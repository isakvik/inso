#+build linux
package inso

import "core:log"
import "core:mem"
import "core:net"
import "core:math/rand"

TOURNAMENT_SYNC_PORT    :: 42069
TOURNAMENT_SYNC_MAGIC   :: u32(0x4F534E49) // "INSO" little-endian
TOURNAMENT_SYNC_VERSION :: u16(1)

// note(isak): fixed-width, #packed so the byte layout is identical regardless of how the
// compiler would otherwise pad it. every box runs the same x86 binary so endianness is moot.
Sync_Packet :: struct #packed {
    magic:       u32,
    version:     u16,
    kind:        Sync_Message_Kind,
    match_id:    u32,
    start_in_ms: u32, // schedule offset from receipt, absorbs delivery jitter
    seek_ms:     i32, // forwarded straight to game_switch_mode (negative = lead-in)
}

Sync_Message_Kind :: enum u8 {
    START = 1,
}

Tournament_Sync :: struct {
    socket:           net.UDP_Socket,
    active:           bool,
    last_match_id:    u32, // dedup: repeated START broadcasts + our own echoed packet
    start_deadline_s: f64, // 0 = nothing pending
    pending_seek_ms:  f64,
}

tournament_sync_init :: proc() {
    socket, bind_err := net.make_bound_udp_socket(net.IP4_Any, TOURNAMENT_SYNC_PORT)
    if bind_err != nil {
        log.error("tournament sync: bind failed:", bind_err)
        return
    }

    if err := net.set_option(socket, .Broadcast, true); err != nil {
        log.error("tournament sync: enabling broadcast failed:", err)
        net.close(socket)
        return
    }
    net.set_blocking(socket, false)

    game.tournament_sync = { socket = socket, active = true }
    log.info("tournament sync: listening on udp", TOURNAMENT_SYNC_PORT)
}

// note(isak): drained once per frame like the raw-input queue; non-blocking recv returns
// .Would_Block once the socket is empty, which ends the loop.
tournament_sync_poll :: proc() {
    sync := &game.tournament_sync
    if !sync.active do return

    buf: [size_of(Sync_Packet)]byte
    for {
        bytes_read, _, err := net.recv_udp(sync.socket, buf[:])
        if err != nil do break
        if bytes_read != size_of(Sync_Packet) do continue

        packet := (^Sync_Packet)(&buf[0])^
        if packet.magic != TOURNAMENT_SYNC_MAGIC do continue
        if packet.version != TOURNAMENT_SYNC_VERSION do continue
        if packet.match_id == sync.last_match_id do continue

        sync.last_match_id = packet.match_id
        switch packet.kind {
        case .START:
            sync.start_deadline_s = game.frame_clock_s + f64(packet.start_in_ms) / 1000
            sync.pending_seek_ms = f64(packet.seek_ms)
        }
    }
}

// conductor side (production PC): fire the go signal to the whole subnet. start_in_ms is slack
// so the packet lands on every stage box before the shared deadline it schedules.
tournament_sync_send_start :: proc(start_in_ms: u32 = 250, seek_ms: i32 = 0) {
    sync := &game.tournament_sync
    if !sync.active do return

    packet := Sync_Packet{
        magic       = TOURNAMENT_SYNC_MAGIC,
        version     = TOURNAMENT_SYNC_VERSION,
        kind        = .START,
        match_id    = rand.uint32(),
        start_in_ms = start_in_ms,
        seek_ms     = seek_ms,
    }

    broadcast := net.Endpoint{ address = net.IP4_Address{255, 255, 255, 255}, port = TOURNAMENT_SYNC_PORT }
    for _ in 0..<4 { // resend a handful of times; START is idempotent via match_id
        net.send_udp(sync.socket, mem.ptr_to_bytes(&packet), broadcast)
    }
}
