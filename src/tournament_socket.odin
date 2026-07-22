package inso

import "core:log"
import "core:net"

// note(isak): receive side only - the go signal comes from the conductor tool in tools/inso_start,
// which mirrors this wire format. the version field guards against drift between the two.

TOURNAMENT_SYNC_PORT    :: 8727
TOURNAMENT_SYNC_MAGIC   :: u32(0x4F534E49) // "INSO" little-endian
TOURNAMENT_SYNC_VERSION :: u16(1)

// note(isak): fixed-width, #packed so the byte layout is identical regardless of how the
// compiler would otherwise pad it. every box runs x86 binaries from the same compiler so
// endianness is moot.
Sync_Packet :: struct #packed {
    magic:       u32,
    version:     u16,
    kind:        Sync_Message_Kind,
    match_id:    u32,
    start_in_ms: u32, // schedule slack from receipt; the lead-in itself is baked at arm time
}

Sync_Message_Kind :: enum u8 {
    START = 1,
}

tournament_socket:        net.UDP_Socket
tournament_socket_active: bool
tournament_last_match_id: u32 // dedup the conductor's spaced resends

tournament_socket_init :: proc() {
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

    tournament_socket = socket
    tournament_socket_active = true
    log.info("tournament sync: listening on udp", TOURNAMENT_SYNC_PORT)
}

// note(isak): non-blocking recv errors with .Would_Block once the socket is empty, ending the drain.
tournament_socket_poll :: proc() {
    if !tournament_socket_active do return

    buf: [size_of(Sync_Packet)]byte
    for {
        bytes_read, _, err := net.recv_udp(tournament_socket, buf[:])
        if err != nil do break
        if bytes_read != size_of(Sync_Packet) do continue

        packet := (^Sync_Packet)(&buf[0])^
        if packet.magic != TOURNAMENT_SYNC_MAGIC do continue
        if packet.version != TOURNAMENT_SYNC_VERSION do continue
        if packet.match_id == tournament_last_match_id do continue

        tournament_last_match_id = packet.match_id
        switch packet.kind {
        case .START:
            tournament_request_start(f64(packet.start_in_ms))
        }
    }
}
