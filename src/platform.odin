package notosu

import "core:log"
import os "core:os/os2"
import "core:path/filepath"


app: struct {
    base_dir: string,
    logger: log.Logger,
}

app_init :: proc() {
    app.logger = log.create_console_logger()
    
    err: os.Error
    app.base_dir, err = os.get_working_directory(context.allocator)
    if err != os.General_Error.None {
        log.panic("couldn't fetch working directory:", err)
    }
    
    if "build" == filepath.base(app.base_dir) {
        app.base_dir = filepath.dir(app.base_dir)
        os.set_working_directory(app.base_dir)
    }
}

app_cleanup :: proc() {
    log.destroy_console_logger(app.logger)
}

//////////////////////////////////////////////////////
// note(isak): io api

read_entire_file :: proc(path: string, allocator := context.allocator) -> ([]u8, os.Error) {
    result: []u8
    err: os.Error = os.General_Error.None
    for len(result) == 0 && err == os.General_Error.None {
        result, err = os.read_entire_file_from_path(path, allocator)
    }
    null_guard := new(u8, allocator)
    return result, err
}

read_entire_file_to_string :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
    data, err := read_entire_file(path, allocator)
    return string(data), err
}
