import os
import platform
import re
import subprocess
import sys


IS_WIN = platform.system() == "Windows"


KEY_LEFT = -1
KEY_RIGHT = -2
KEY_UP = -3
KEY_DOWN = -4
KEY_HOME = -5
KEY_END = -6
KEY_PAGEUP = -7
KEY_PAGEDOWN = -8
KEY_BACKSPACE = -9
KEY_DELETE = -10
KEY_LF = -11
KEY_CR = -12
KEY_TAB = -13
KEY_ESC = -14

KEY_CTRL_A = -101
KEY_CTRL_B = -102
KEY_CTRL_C = -103
KEY_CTRL_D = -104
KEY_CTRL_E = -105
KEY_CTRL_F = -106
KEY_CTRL_G = -107
KEY_CTRL_H = -108
KEY_CTRL_I = -109
KEY_CTRL_J = -110
KEY_CTRL_K = -111
KEY_CTRL_L = -112
KEY_CTRL_M = -113
KEY_CTRL_N = -114
KEY_CTRL_O = -115
KEY_CTRL_P = -116
KEY_CTRL_Q = -117
KEY_CTRL_R = -118
KEY_CTRL_S = -119
KEY_CTRL_T = -120
KEY_CTRL_U = -121
KEY_CTRL_V = -122
KEY_CTRL_W = -123
KEY_CTRL_X = -124
KEY_CTRL_Y = -125
KEY_CTRL_Z = -126


cwd = "."

history = []
history_index = -1
history_current = ""


class RawInput:
    def __init__(self):
        self.iswin = IS_WIN
        if self.iswin:
            import msvcrt
            self.msvcrt = msvcrt
        else:
            import tty
            import termios
            self.old_settings = termios.tcgetattr(sys.stdin)

    def getch(self):
        if self.iswin:
            ch = self.msvcrt.getwch()
            n = ord(ch)
            if n in [0x0, 0xe0]:
                n = ord(self.msvcrt.getwch())
                if n == 0x4b: return KEY_LEFT
                elif n == 0x4d: return KEY_RIGHT
                elif n == 0x48: return KEY_UP
                elif n == 0x50: return KEY_DOWN
                elif n == 0x53: return KEY_DELETE
                elif n == 0x47: return KEY_HOME
                elif n == 0x4f: return KEY_END
                elif n == 0x51: return KEY_PAGEDOWN
                elif n == 0x49: return KEY_PAGEUP
                else:
                    print(hex(n))
            elif n == 0x8:
                return KEY_BACKSPACE
            elif n == 0x9:
                return KEY_TAB
            elif n == 0xa:
                return KEY_LF
            elif n == 0xd:
                return KEY_CR
            elif n == 0x1b:
                return KEY_ESC
            elif n <= 26:
                return -100 - n  # implicitly map to KEY_CTRL_*
            else:
                return ch
        else:
            # TODO parse codes...
            return sys.stdin.read(1)

    def __enter__(self):
        tty.setraw(sys.stdin)
        return self

    def __exit__(self, type, value, traceback):
        if not self.iswin:
            termios.tcsetattr(
                sys.stdin,
                termios.TCSADRAIN,
                self.old_settings,
            )


def dabshell():
    global history
    global history_index
    global history_current
    esc = "\u001b"
    os.system("")
    inp = RawInput()
    outp = sys.stdout
    outp.write("> ")
    outp.flush()
    line = ""
    indent = 2
    index = 0
    log = False
    while True:
        key = inp.getch()
        if key == KEY_CTRL_C:
            break
        elif key == KEY_LF or key == KEY_CR:
            if re.match("^![0-9]+$", line):
                hidx = int(line[1:])
                if 0 <= hidx <= len(history)-1:
                    line = history[hidx]
                    index = len(line)
            else:
                print()
                execute(line)
                outp.write("> ")
                outp.flush()
                line = ""
                index = 0
        elif key == KEY_ESC:
            line = ""
            index = 0
        elif key == KEY_BACKSPACE:
            if index > 0:
                line = line[:index-1] + line[index:]
                index -= 1
        elif key == KEY_LEFT:
            index = max(0, index-1)
        elif key == KEY_RIGHT:
            index = min(len(line), index+1)
        elif key == KEY_DELETE:
            if index < len(line):
                line = line[:index] + line[index+1:]
        elif key == KEY_HOME:
            index = 0
        elif key == KEY_END:
            index = len(line)
        elif key == KEY_PAGEDOWN:
            index = len(line)
        elif key == KEY_PAGEUP:
            index = 0
        elif key == KEY_UP:
            if history:
                if history_index == -1:
                    history_current = line
                    history_index = len(history)-1
                    line = history[history_index]
                elif history_index > 0:
                    history_index -= 1
                    line = history[history_index]
        elif key == KEY_DOWN:
            if history and history_index != -1:
                if history_index < len(history)-1:
                    history_index += 1
                    line = history[history_index]
                else:
                    line = history_current
                    history_index = -1
                    history_current = ""
        elif type(key) == str:
            line = line[:index] + key + line[index:]
            index += 1

        # Print current input-string
        outp.write(f"{esc}[1000D")  # Move all the way left
        outp.write("> " + line)
        outp.write(f"{esc}[0K")
        if index < len(line):
            outp.write(f"{esc}[1000D")  # Move all the way left
            pos = indent + index
            outp.write(f"{esc}[{pos}C")  # Move cursor to index
        outp.flush()


def find_executable(executable):
    if IS_WIN:
        venv = "venv/Scripts"
        if os.path.exists(os.path.join(venv, executable)):
            return os.path.join(venv, executable)
        if os.path.exists(os.path.join(venv, executable+".exe")):
            return os.path.join(venv, executable+".exe")
        # TODO search PATH
        return executable
    else:
        venv = "venv/bin"
        if os.path.exists(os.path.join(venv, executable)):
            return os.path.join(venv, executable)
        # TODO search PATH
        return executable


def split_command(line):
    # TODO handle escapes and quotes
    parts = line.split(" ")
    return parts[0], parts[1:]


def cmd_ls(args):
    if len(args) == 0:
        path = cwd
    else:
        path = args[0]
    for fname in os.listdir(path):
        print(fname)


def cmd_cd(args):
    global cwd
    if len(args) == 0:
        cwd = "."
    else:
        path = args[0]
        if os.path.isabs(path):
            cwd = path
        else:
            cwd = os.path.normpath(os.path.join(cwd, path))


def cmd_cwd(args):
    print(cwd)


def cmd_cat(args):
    for filename in args:
        if not os.path.isabs(filename):
            filename = os.path.normpath(os.path.join(cwd, filename))
        if os.path.exists(filename):
            with open(filename, encoding="utf_8") as infile:
                for line in infile:
                    print(line, end="")


def cmd_tail(args):
    n = 20
    filenames = []
    after_args = False
    for arg in args:
        if not after_args and (arg.startswith("-") or arg.startswith("--")):
            if arg == "--":
                after_args = True
            elif arg.startswith("-n="):
                n = int(arg[len("-n="):])
            elif arg.startwith("--lines="):
                n = int(arg[len("--lines=")])
        else:
            filenames.append(arg)

    for filename in filenames:
        if not os.path.isabs(filename):
            filename = os.path.normpath(os.path.join(cwd, filename))
        if os.path.exists(filename):
            with open(filename, encoding="utf_8") as infile:
                # TODO for now, we read everything, later, optimize
                lines = infile.readlines()
                for line in lines[-n:]:
                    print(line, end="")


def cmd_history(args):
    if not args:
        for index, line in enumerate(history):
            print(index, line)
    else:
        query = args[0].lower()
        for index, line in enumerate(history):
            if line.lower().find(query) != -1:
                print(index, line)


def execute(line):
    if not line.startswith("history "):
        history.append(line)
    cmd, args = split_command(line)
    print("::", cmd, args)
    if cmd == "ls":
        cmd_ls(args)
    elif cmd == "cd":
        cmd_cd(args)
    elif cmd == "cwd":
        cmd_cwd(args)
    elif cmd == "cat":
        cmd_cat(args)
    elif cmd == "tail":
        cmd_tail(args)
    elif cmd == "history":
        cmd_history(args)
    else:
        try:
            executable = find_executable(cmd)
            print("::", executable)
            subprocess.run(
                [
                    executable,
                    *args,
                ],
            )
        except Exception as e:
            print(e)


if __name__ == "__main__":
    dabshell()
