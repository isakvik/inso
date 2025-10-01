package notosu

import "core:fmt"
import "core:os"

read_entire_file :: proc(path: string) -> ([]u8, os.Error) {
    result: []u8
    err: os.Error
    for len(result) == 0 && err == 0 {
        result, err = os.read_entire_file_or_err(path)
    }
    return result, err
}
