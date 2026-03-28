#+build windows
package notosu

import "core:sys/windows"

_platform_dpi_init :: proc() {
    windows.SetProcessDPIAware()
}
