package notosu

import "core:log"
import os "core:os"

// note(isak): release builds are packaged with -subsystem:windows (see package.bat), so there's
// no attached console and anything printed to stdout/stderr is lost. when we can't rely on a
// console we write logs to a file instead, so mappers and crash reports have something to read.
// debug builds keep the colored console logger.
//
// the default follows the build mode (release -> file, debug -> console), but it can be forced
// either way at build time with -define:LOG_TO_FILE=true / -define:LOG_TO_FILE=false
LOG_TO_FILE   :: #config(LOG_TO_FILE, !ODIN_DEBUG)
LOG_FILE_PATH :: "notosu.log"

logging: struct {
    file: ^os.File,
}

logging_create_logger :: proc() -> log.Logger {
    when LOG_TO_FILE {
        file, err := os.create(LOG_FILE_PATH)
        if err == nil {
            logging.file = file
            return log.create_file_logger(file)
        }
        // note(isak): couldn't open the log file, fall back to the console so we don't lose logs
        // entirely. on a no-console release build this means the logs vanish, but that beats crashing
    }
    return log.create_console_logger()
}

logging_destroy_logger :: proc(logger: log.Logger) {
    if logging.file != nil {
        log.destroy_file_logger(logger) // note(isak): also closes the underlying file
    } else {
        log.destroy_console_logger(logger)
    }
}
