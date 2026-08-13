package inso_lan_broadcast

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:math/rand"
import "core:strconv"
import "core:time"

// note(isak): the broadcast client for the production team side of tournament.
// sends packets to clients on the subnet, receive code lies in src/tournament_socket.odin

TOURNAMENT_SYNC_VERSION :: u16(2) // increment this when changing packet format

TOURNAMENT_SYNC_PORT    :: 8727
TOURNAMENT_SYNC_MAGIC   :: u32(0x4F534E49) // "INSO" little-endian

Sync_Packet :: struct #packed {
    magic:       u32,
    version:     u16,
    kind:        Sync_Message_Kind,
    command_id:  u32,
    start_in_ms: u32,
}

Sync_Message_Kind :: enum u8 {
    START = 1,
    ABORT = 2,
}

RESEND_COUNT      :: 4
RESEND_SPACING_MS :: 30

print_usage_and_exit :: proc() -> ! {
    fmt.eprintfln("usage: %s [start|abort] [broadcast ip] [wait ms]", os.args[0])
    os.exit(1)
}

main :: proc() {
    address  := net.IP4_Address{255, 255, 255, 255}
    wait_ms := u32(250)
    kind     := Sync_Message_Kind.START

    arg_index := 1
    if len(os.args) > arg_index {
        switch os.args[arg_index] {
        case "start": arg_index += 1
        case "abort": kind = .ABORT; arg_index += 1
        }
    }
    if len(os.args) > arg_index {
        parsed, ok := net.parse_ip4_address(os.args[arg_index])
        if !ok do print_usage_and_exit()
        address = parsed
        arg_index += 1
    }
    if len(os.args) > arg_index {
        parsed, ok := strconv.parse_uint(os.args[arg_index])
        if !ok do print_usage_and_exit()
        wait_ms = u32(parsed)
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

    command_id := rand.uint32()
    if command_id == 0 do command_id = 1

    packet := Sync_Packet{
        magic       = TOURNAMENT_SYNC_MAGIC,
        version     = TOURNAMENT_SYNC_VERSION,
        kind        = kind,
        command_id  = command_id,
        start_in_ms = wait_ms if kind == .START else 0,
    }

    target := net.Endpoint{ address = address, port = TOURNAMENT_SYNC_PORT }
    // spaced resends so a single burst of loss can't eat the signal; receivers dedup via command_id
    for i in 0..<RESEND_COUNT {
        if i > 0 do time.sleep(RESEND_SPACING_MS * time.Millisecond)
        _, send_err := net.send_udp(socket, mem.ptr_to_bytes(&packet), target)
        if send_err != nil {
            fmt.eprintln("send failed:", send_err)
            os.exit(1)
        }
    }

    switch kind {
    case .START:
        fmt.printfln("start signal sent to %s:%d (command %d, wait %dms)",
            net.address_to_string(address), TOURNAMENT_SYNC_PORT, command_id, wait_ms)
    case .ABORT:
        fmt.printfln("abort signal sent to %s:%d (command %d)",
            net.address_to_string(address), TOURNAMENT_SYNC_PORT, command_id)
    }
}
