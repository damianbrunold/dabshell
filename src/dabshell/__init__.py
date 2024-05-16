import os
import platform
import re
import shutil
import subprocess
import sys
import time
import tomllib


IS_WIN = platform.system() == "Windows"

if IS_WIN:
    import msvcrt
else:
    import tty
    import termios
    import select

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


class RawInput:
    def getch(self):
        if IS_WIN:
            ch = msvcrt.getwch()
            n = ord(ch)
            if n in [0x0, 0xe0]:
                n = ord(msvcrt.getwch())
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
            self.init()
            try:
                ch = sys.stdin.read(1)
                n = ord(ch)
                if n == 0x1b:
                    ch = sys.stdin.read(1)
                    n = ord(ch)
                    if n == 0x1b:
                        return KEY_ESC
                    elif n == 0x5b:
                        ch = sys.stdin.read(1)
                        n = ord(ch)
                        if n == 0x44: return KEY_LEFT
                        elif n == 0x43: return KEY_RIGHT
                        elif n == 0x41: return KEY_UP
                        elif n == 0x42: return KEY_DOWN
                        elif n == 0x48: return KEY_HOME
                        elif n == 0x46: return KEY_END
                        elif n == 0x33:
                            sys.stdin.read(1)  # skip 0x7e
                            return KEY_DELETE
                        elif n == 0x35:
                            sys.stdin.read(1)  # skip 0x7e
                            return KEY_PAGEUP
                        elif n == 0x36:
                            sys.stdin.read(1)  # skip 0x7e
                            return KEY_PAGEDOWN
                        else:
                            print(hex(n))
                elif n == 0x7f:
                    return KEY_BACKSPACE
                elif n == 0x9:
                    return KEY_TAB
                elif n == 0xa:
                    return KEY_LF
                elif n == 0xd:
                    return KEY_CR
                elif n <= 26:
                    return -100 - n  # implicitly map to KEY_CTRL_*
                else:
                    return ch
            finally:
                self.restore()

    def init(self):
        self.old_settings = termios.tcgetattr(sys.stdin)
        tty.setraw(sys.stdin)

    def restore(self):
        termios.tcsetattr(
            sys.stdin,
            termios.TCSADRAIN,
            self.old_settings,
        )


def find_executable(cwd, executable):
    if IS_WIN:
        venv = os.path.join(cwd, "venv/Scripts")
        if os.path.exists(os.path.join(venv, executable)):
            return os.path.join(venv, executable)
        if os.path.exists(os.path.join(venv, executable+".exe")):
            return os.path.join(venv, executable+".exe")
        return shutil.which(executable)
    else:
        venv = os.path.join(cwd, "venv/bin")
        if os.path.exists(os.path.join(venv, executable)):
            return os.path.join(venv, executable)
        return shutil.which(executable)


def split_command(line):
    parts = []
    current_part = ""
    in_quote = False
    for idx in range(len(line)):
        ch = line[idx]
        if ch == "\"" and not in_quote:
            if current_part:
                parts.append(current_part)
                current_part = ""
            in_quote = True
        elif (
            ch == "\\"
            and idx < len(line) - 1
            and line[idx+1] == "\""
            and in_quote
        ):
            current_part += "\\"
            idx += 1
        elif ch =="\"" and in_quote:
            in_quote = False
            parts.append(current_part)
            current_part = ""
        elif ch == " " and not in_quote:
            if current_part:
                parts.append(current_part)
                current_part = ""
        else:
            current_part += ch
        idx += 1
    if current_part:
        parts.append(current_part)
    return parts[0], parts[1:]


class Dabshell:
    def __init__(self):
        self.cwd = self.canon(".")
        self.history = []
        self.history_index = -1
        self.history_current = ""
        os.system("")
        self.inp = RawInput()
        self.outp = sys.stdout
        self.line = ""
        self.index = 0
        self.log = False
        self.info_pythonproj_cwd = None
        self.info_pythonproj_s = ""
        self.info_git_cwd = None
        self.info_git_s = ""

    def prompt(self):
        s = ""
        pyproj = self.info_pythonproj()
        if pyproj:
            s += pyproj + " "
        branch, modified = self.info_git()
        if branch:
            s += branch
            if modified:
                s += "*"
            s += " "
        return s + self.cwd + "> "

    def info_pythonproj(self):
        if self.info_pythonproj_cwd == self.cwd:
            return self.info_pythonproj_s
        self.info_pythonproj_cwd = self.cwd
        self.info_pythonproj_s = ""
        projfile = os.path.join(self.cwd, "pyproject.toml")
        if os.path.exists(projfile):
            with open(projfile, "rb") as infile:
                cfg = tomllib.load(infile)
                proj = cfg.get("project")
                if proj:
                    self.info_pythonproj_s = proj.get("version", "")
        return self.info_pythonproj_s

    def info_git(self):
        if self.info_git_cwd == self.cwd:
            return self.info_git_s
        self.info_git_cwd = self.cwd
        self.info_git_s = "", False
        wd = self.cwd
        while wd:
            gitdir = os.path.join(wd, ".git")
            if os.path.isdir(gitdir):
                break
            wd = os.path.dirname(wd)
        else:
            gitdir = None
        if gitdir:
            p = subprocess.run(
                [
                    shutil.which("git"),
                    "status",
                ],
                capture_output=True,
                cwd=self.cwd,
            )
            lines = p.stdout.decode("utf8").splitlines()
            if lines:
                branch = lines[0].split(" ")[2]
                modified = lines[-1] != "nothing to commit, working tree clean"
                self.info_git_s = branch, modified
        return self.info_git_s

    def canon(self, path):
        if path is None:
            return None
        return os.path.normpath(os.path.abspath(path))

    def run(self):
        esc = "\u001b"
        self.outp.write(self.prompt())
        self.outp.flush()
        while True:
            key = self.inp.getch()
            if key == KEY_CTRL_C:
                break
            elif key == KEY_LF or key == KEY_CR:
                if re.match("^![0-9]+$", self.line):
                    hidx = int(self.line[1:])
                    if 0 <= hidx <= len(self.history)-1:
                        self.line = self.history[hidx]
                        self.index = len(self.line)
                else:
                    print()
                    if not self.execute(self.line):
                        break
                    self.outp.write(self.prompt())
                    self.outp.flush()
                    self.line = ""
                    self.index = 0
            elif key == KEY_ESC:
                self.line = ""
                self.index = 0
                self.history_index = -1
                self.history_current = ""
            elif key == KEY_BACKSPACE:
                if self.index > 0:
                    pre = self.line[:self.index-1]
                    post = self.line[self.index:]
                    self.line = pre + post
                    self.index -= 1
            elif key == KEY_CTRL_W:
                idx = self.index - 1
                while idx > 0 and self.line[idx] == " ":
                    idx -= 1
                while idx > 0 and self.line[idx] != " ":
                    idx -= 1
                delta = self.index - idx
                self.line = self.line[0:idx] + self.line[self.index:]
                self.index -= delta
                self.index = min(len(self.line), self.index)
            elif key == KEY_LEFT:
                self.index = max(0, self.index-1)
            elif key == KEY_RIGHT:
                self.index = min(len(self.line), self.index+1)
            elif key == KEY_DELETE:
                if self.index < len(self.line):
                    pre = self.line[:self.index]
                    post = self.line[self.index+1:]
                    self.line = pre + post
            elif key == KEY_HOME:
                self.index = 0
            elif key == KEY_END:
                self.index = len(self.line)
            elif key == KEY_UP:
                if self.history:
                    if self.history_index == -1:
                        self.history_current = self.line
                        self.history_index = len(self.history)-1
                        self.line = self.history[self.history_index]
                    elif self.history_index > 0:
                        self.history_index -= 1
                        self.line = self.history[self.history_index]
            elif key == KEY_DOWN:
                if self.history and self.history_index != -1:
                    if self.history_index < len(self.history)-1:
                        self.history_index += 1
                        self.line = self.history[self.history_index]
                    else:
                        self.line = self.history_current
                        self.history_index = -1
                        self.history_current = ""
            elif type(key) == str:
                pre = self.line[:self.index]
                post = self.line[self.index:]
                self.line = pre + key + post
                self.index += 1

            self.outp.write(f"{esc}[1000D")  # Move all the way left
            self.outp.write(self.prompt() + self.line)
            self.outp.write(f"{esc}[0K")
            if self.index < len(self.line):
                self.outp.write(f"{esc}[1000D")  # Move all the way left
                pos = len(self.prompt()) + self.index
                self.outp.write(f"{esc}[{pos}C")  # Move cursor to index
            self.outp.flush()

    def cmd_ls(self, args):
        if len(args) == 0:
            path = self.canon(self.cwd)
        else:
            if os.path.isabs(args[0]):
                path = self.canon(args[0])
            else:
                path = self.canon(os.path.join(self.cwd, args[0]))
        if os.path.exists(path):
            for fname in os.listdir(path):
                print(fname)

    def cmd_cd(self, args):
        if len(args) == 0:
            self.cwd = self.canon(".")
        else:
            path = args[0]
            if os.path.isabs(path):
                cwd_ = self.canon(path)
            else:
                cwd_ = self.canon(os.path.join(self.cwd, path))
            if os.path.isdir(cwd_):
                self.cwd = cwd_
            else:
                print(f"ERR: cannot cd to {cwd_}")

    def cmd_pwd(self, args):
        print(self.cwd)

    def cmd_cat(self, args):
        for filename in args:
            if not os.path.isabs(filename):
                filename = os.path.normpath(os.path.join(self.cwd, filename))
            if os.path.exists(filename):
                with open(filename, encoding="utf_8") as infile:
                    for line in infile:
                        print(line, end="")

    def cmd_tail(self, args):
        n = 20
        filenames = []
        after_args = False
        idx = 0
        while idx < len(args):
            arg = args[idx]
            if (
                not after_args
                and (arg.startswith("-") or arg.startswith("--"))
            ):
                if arg == "--":
                    after_args = True
                elif arg == "-n":
                    n = int(args[idx+1])
                    idx += 1
                elif arg.startswith("--lines="):
                    n = int(arg[len("--lines=")])
            else:
                filenames.append(arg)
            idx += 1

        for filename in filenames:
            if not os.path.isabs(filename):
                filename = self.canon(os.path.join(self.cwd, filename))
            if os.path.exists(filename):
                with open(filename, encoding="utf_8") as infile:
                    # TODO for now, we read everything, later, optimize
                    lines = infile.readlines()
                    for line in lines[-n:]:
                        print(line, end="")

    def cmd_head(self, args):
        n = 20
        filenames = []
        after_args = False
        idx = 0
        while idx < len(args):
            arg = args[idx]
            if (
                not after_args
                and (arg.startswith("-") or arg.startswith("--"))
            ):
                if arg == "--":
                    after_args = True
                elif arg == "-n":
                    n = int(args[idx+1])
                    idx += 1
                elif arg.startswith("--lines="):
                    n = int(arg[len("--lines=")])
            else:
                filenames.append(arg)
            idx += 1

        for filename in filenames:
            if not os.path.isabs(filename):
                filename = self.canon(os.path.join(self.cwd, filename))
            if os.path.exists(filename):
                with open(filename, encoding="utf_8") as infile:
                    for i in range(n):
                        line = infile.readline()
                        if not line:
                            break
                        print(line, end="")

    def cmd_history(self, args):
        if not args:
            for index, line in enumerate(self.history):
                print(index, line)
        else:
            query = args[0].lower()
            for index, line in enumerate(self.history):
                if line.lower().find(query) != -1:
                    print(index, line)

    def execute(self, line):
        line = line.strip()
        cmd, args = split_command(line)
        if cmd != "history":
            self.history.append(line)
            self.history_index = -1
            self.history_current = ""
        if self.log:
            print("::", cmd, args)
        # trigger prompt info update
        self.info_pythonproj_cwd = None
        self.info_git_cwd = None
        if cmd == "ls":
            self.cmd_ls(args)
        elif cmd == "cd":
            self.cmd_cd(args)
        elif cmd == "pwd":
            self.cmd_pwd(args)
        elif cmd == "cat":
            self.cmd_cat(args)
        elif cmd == "tail":
            self.cmd_tail(args)
        elif cmd == "head":
            self.cmd_head(args)
        elif cmd == "history":
            self.cmd_history(args)
        elif cmd == "exit":
            return False
        else:
            try:
                executable = self.canon(find_executable(self.cwd, cmd))
                if executable is None:
                    print(f"ERR: {cmd} not found")
                else:
                    if self.log:
                        print("::", executable)
                    subprocess.run(
                        [
                            executable,
                            *args,
                        ],
                        cwd=self.cwd,
                    )
            except KeyboardInterrupt:
                pass
            except Exception as e:
                print(e)
        return True


def dabshell():
    Dabshell().run()


if __name__ == "__main__":
    dabshell()
