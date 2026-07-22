package inso_start

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:math/rand"
import "core:strconv"
import "core:time"

// conductor side of tournament sync (production pc): fires the go signal at every inso
// client listening on the subnet. wire format mirrors src/tournament_socket.odin; the
// version field guards against drift between the two.

TOURNAMENT_SYNC_PORT    :: 8727
TOURNAMENT_SYNC_MAGIC   :: u32(0x4F534E49) // "INSO" little-endian
TOURNAMENT_SYNC_VERSION :: u16(1)

Sync_Packet :: struct #packed {
    magic:       u32,
    version:     u16,
    kind:        Sync_Message_Kind,
    match_id:    u32,
    start_in_ms: u32,
}

Sync_Message_Kind :: enum u8 {
    START = 1,
}

RESEND_COUNT      :: 4
RESEND_SPACING_MS :: 30

main :: proc() {
    address  := net.IP4_Address{255, 255, 255, 255}
    slack_ms := u32(250)

    if len(os.args) > 1 {
        parsed, ok := net.parse_ip4_address(os.args[1])
        if !ok {
            fmt.eprintfln("usage: %s [broadcast ip] [slack ms]", os.args[0])
            os.exit(1)
        }
        address = parsed
    }
    if len(os.args) > 2 {
        parsed, ok := strconv.parse_uint(os.args[2])
        if !ok {
            fmt.eprintfln("usage: %s [broadcast ip] [slack ms]", os.args[0])
            os.exit(1)
        }
        slack_ms = u32(parsed)
    }

    socket, socket_err := net.make_unbound_udp_socket(.IP4)
    if socket_err != nil {
        fmt.eprintln("socket creation failed:", socket_err)
        os.exit(1)
    }
    if err := net.set_option(socket, .Broadcast, true); err != nil {
        fmt.eprintln("enabling broadcast failed:", err)
        os.exit(1)
    }

    packet := Sync_Packet{
        magic       = TOURNAMENT_SYNC_MAGIC,
        version     = TOURNAMENT_SYNC_VERSION,
        kind        = .START,
        match_id    = rand.uint32(),
        start_in_ms = slack_ms,
    }

    target := net.Endpoint{ address = address, port = TOURNAMENT_SYNC_PORT }
    // spaced resends so a single burst of loss can't eat the signal; receivers dedup via match_id
    for i in 0..<RESEND_COUNT {
        if i > 0 do time.sleep(RESEND_SPACING_MS * time.Millisecond)
        _, send_err := net.send_udp(socket, mem.ptr_to_bytes(&packet), target)
        if send_err != nil {
            fmt.eprintln("send failed:", send_err)
            os.exit(1)
        }
    }

    fmt.printfln("start signal sent to %s:%d (match %d, slack %dms)",
        net.address_to_string(address), TOURNAMENT_SYNC_PORT, packet.match_id, slack_ms)
}
