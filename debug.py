import win32gui
import win32con
import sys
import subprocess

window_list = []
program_name = "raddbg.exe"
executable_path = "raddbg"

def enum_callback(hwnd, param):
    if "The RAD Debugger".lower() in win32gui.GetWindowText(hwnd).lower():
        window_list.append(hwnd)

win32gui.EnumWindows(enum_callback, None)

if len(window_list) == 0:
    subprocess.Popen(executable_path)
else:
    win32gui.ShowWindow(window_list[0], win32con.SW_RESTORE)
    win32gui.SetForegroundWindow(window_list[0])
