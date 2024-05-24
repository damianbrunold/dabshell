import datetime
import glob
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import tomllib


max_line_length = 80

esc = "\u001b"

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


def find_executable_(path, executable):
    fullpath = os.path.join(path, executable)
    if IS_WIN and not os.path.exists(fullpath):
        fullpath = os.path.join(path, executable + ".exe")
    if not os.path.exists(fullpath):
        fullpath = os.path.join(path, executable + ".dsh")
    if not os.path.exists(fullpath):
        fullpath = None
    return fullpath


def find_executable(cwd, executable):
    scriptfolder = "Scripts" if IS_WIN else "bin"
    venv = os.path.join(cwd, "venv", scriptfolder)
    result = find_executable_(venv, executable)
    if not result:
        venv = os.path.join(cwd, ".venv", scriptfolder)
        result = find_executable_(venv, executable)
    if not result:
        result = find_executable_(cwd, executable)
    if not result:
        result = shutil.which(executable)
    return result


def collect_partial_executables(path, word, results):
    if not os.path.isdir(path):
        return
    for fname in os.listdir(path):
        if fname.startswith(word):
            if fname.endswith(".exe") or fname.endswith(".dsh"):
                fname = fname[:-4]
            results.append(fname)


def find_partial_executable(cwd, word):
    results = []
    scriptfolder = "Scripts" if IS_WIN else "bin"
    venv = os.path.join(cwd, "venv", scriptfolder)
    if os.path.isdir(venv):
        collect_partial_executables(venv, word, results)
    if not results:
        venv = os.path.join(cwd, ".venv", scriptfolder)
        collect_partial_executables(venv, word, results)
    if not results:
        for path in os.environ.get("PATH", "").split(os.pathsep):
            if not os.path.exists(path):
                continue
            collect_partial_executables(path, word, results)
    return sorted(results)


def split_command_quoted(line):
    parts = []
    current_part = ""
    in_quote = False
    for idx in range(len(line)):
        ch = line[idx]
        if ch == "\"" and not in_quote:
            if current_part:
                parts.append(current_part)
                current_part = "\""
            in_quote = True
        elif (
            ch == "\\"
            and idx < len(line) - 1
            and line[idx+1] == "\""
            and in_quote
        ):
            current_part += "\\\""
            idx += 1
        elif (
            ch == "\\"
            and idx < len(line) - 1
            and line[idx+1] == "\\"
            and in_quote
        ):
            current_part += "\\\\"
            idx += 1
        elif ch =="\"" and in_quote:
            in_quote = False
            parts.append(current_part + "\"")
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
    return parts


def replace_vars(s, env):
    in_single_quote = False
    in_var = False
    result = ""
    var = ""
    for ch in s:
        if ch == "{" and not in_single_quote:
            in_var = True
        elif ch != "}" and in_var:
            var += ch
        elif ch == "}" and in_var:
            result += str(env.get(var, "{" + var + "}"))
            var = ""
            in_var = False
        elif ch == "'":
            in_single_quote = not in_single_quote
            result += ch
        else:
            result += ch
    return result


def split_command(line, env):
    line = replace_vars(line, env)
    parts = []
    current_part = ""
    in_quote = False
    idx = 0
    while idx < len(line):
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
            current_part += "\""
            idx += 1
        elif (
            ch == "\\"
            and idx < len(line) - 1
            and line[idx+1] == "\\"
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


class Env:
    def __init__(self, parent=None):
        self.mappings = {}
        self.parent = parent

    def names(self):
        result = list(self.mappings.keys())
        if self.parent:
            result += self.parent.names()
        return sorted(set(result))

    def get(self, name, default=None):
        if name in self.mappings:
            return self.mappings[name]
        if self.parent:
            return self.parent.get(name, default)
        else:
            return default

    def set(self, name, value):
        self.mappings[name] = value

    def update(self, name, value):
        if self.get(name):
            if name in self.mappings:
                self.mappings[name] = value
            if self.parent:
                self.parent.update(name, value)
        else:
            self.set(name, value)


class StdOutput:
    def __init__(self):
        self.out = sys.stdout

    def write(self, s):
        self.out.write(s)
        self.out.flush()

    def print(self, s=""):
        print(s, file=self.out)


class StdError:
    def __init__(self):
        self.out = sys.stderr

    def write(self, s):
        self.out.write(s)
        self.out.flush()

    def print(self, s=""):
        print(s, file=self.out)


class FileOutput:
    def __init__(self, filename, encoding="utf8", append=False):
        mode = "w"
        if append:
            mode = "a+"
        self.out = open(filename, mode, encoding=encoding)

    def write(self, s):
        self.out.write(s)

    def print(self, s=""):
        print(s, file=self.out)


class StringOutput:
    def __init__(self):
        self.out = ""

    def write(self, s):
        self.out += s

    def print(self, s=""):
        self.out += s
        self.out += "\n"

    def value(self):
        return self.out


class CommandFailedException(Exception):
    pass


class Dabshell:
    def __init__(self, parent_shell=None):
        if parent_shell:
            self.cwd = parent_shell.cwd
            self.env = Env(parent_shell.env)
            self.outp = parent_shell.outp
            self.outs = parent_shell.outs
            self.oute = parent_shell.oute
            self.outs_old = parent_shell.outs_old
            self.oute_old = parent_shell.oute_old
        else:
            self.cwd = self.canon(".")
            self.env = Env()
            self.outp = StdOutput()
            self.outs = StdOutput()
            self.oute = StdError()
            self.outs_old = None
            self.oute_old = None
            for name in os.environ:
                self.env.set("env:" + name, os.environ.get(name, ""))
            self.init_cmd(CmdRun())
            self.init_cmd(CmdExpr())
            self.init_cmd(CmdScript())
            self.init_cmd(CmdSource())
            self.init_cmd(CmdCd())
            self.init_cmd(CmdLs())
            self.init_cmd(CmdPwd())
            self.init_cmd(CmdSet())
            self.init_cmd(CmdGet())
            self.init_cmd(CmdCat())
            self.init_cmd(CmdHead())
            self.init_cmd(CmdTail())
            self.init_cmd(CmdEcho())
            self.init_cmd(CmdGrep())
            self.init_cmd(CmdCp())
            self.init_cmd(CmdMv())
            self.init_cmd(CmdRm())
            self.init_cmd(CmdRmdir())
            self.init_cmd(CmdMkdir())
            self.init_cmd(CmdTouch())
            self.init_cmd(CmdTree())
            self.init_cmd(CmdDirname())
            self.init_cmd(CmdBasename())
            self.init_cmd(CmdRedirect())
            self.init_cmd(CmdHistory())
            self.init_cmd(CmdDate())
            self.init_cmd(CmdWhich())
            self.init_cmd(CmdTitle())
            self.init_cmd(CmdHelp())
            self.init_cmd(CmdOptions())
        self.history = []
        self.history_index = -1
        self.history_current = ""
        os.system("")
        self.inp = RawInput()
        self.line = ""
        self.index = 0
        self.options = {
            "echo": "off",
        }
        self.info_pythonproj_cwd = None
        self.info_pythonproj_s = ""
        self.info_git_cwd = None
        self.info_git_s = ""
        self.info_venv_cwd = None
        self.info_venv_s = ""

    def init_cmd(self, cmd):
        self.env.set(cmd.name, cmd)

    def option_set(self, name):
        return self.options.get(name) in ["on", "yes", "y", "1", "true"]

    def prompt(self):
        s = ""
        clean_s = ""
        venv = self.info_venv()
        if venv:
            s += venv + " "
            clean_s += venv + " "
        pyproj = self.info_pythonproj()
        if pyproj:
            s += pyproj + " "
            clean_s += pyproj + " "
        branch, modified = self.info_git()
        if branch:
            if modified:
                s += f"{esc}[31m" + branch + "*" + f"{esc}[0m"
                clean_s += branch + "*"
            else:
                s += f"{esc}[32m" + branch + f"{esc}[0m"
                clean_s += branch
            s += " "
            clean_s += " "
        result = s + self.cwd
        if len(result) > max_line_length:
            avail = max_line_length - len(clean_s) - 3
            if avail > 0:
                idx = len(self.cwd) - avail
                truncated = self.cwd[idx:]
                result = s + "..." + truncated
        return result

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
        while not os.path.ismount(wd):
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
                    "status", "-s", "-b",
                ],
                capture_output=True,
                cwd=self.cwd,
            )
            lines = p.stdout.decode("utf8").splitlines()
            if lines:
                if lines[0].startswith("## No commits yet on"):
                    branch = lines[0][2:].strip().split(" ")[-1]
                else:
                    branch = lines[0][2:].strip().split(".")[0]
                modified = lines[1:] != []
                self.info_git_s = branch, modified
        return self.info_git_s

    def info_venv(self):
        if self.info_venv_cwd == self.cwd:
            return self.info_venv_s
        self.info_venv_cwd = self.cwd
        self.info_venv_s = ""
        wd = self.cwd
        while not os.path.ismount(wd):
            venvdir = os.path.join(wd, "venv")
            if os.path.isdir(venvdir):
                break
            venvdir = os.path.join(wd, ".venv")
            if os.path.isdir(venvdir):
                break
            wd = os.path.dirname(wd)
        else:
            venvdir = None
        if venvdir:
            program = find_executable(venvdir, "python")
            if program:
                self.info_venv_s = "venv"
        return self.info_venv_s

    def canon(self, path):
        if path is None:
            return None
        return os.path.normpath(os.path.abspath(path))

    def complete_word(self, word):
        potentials = []
        for cname in self.env.names():
            if cname.startswith(word):
                potentials.append(cname)
        for fname in os.listdir(self.cwd):
            if fname.startswith(word):
                potentials.append(fname)
        if not potentials:
            # find completions for relative paths
            pathfile = os.path.join(self.cwd, word)
            path = os.path.dirname(pathfile)
            file = os.path.basename(pathfile)
            if os.path.isdir(path):
                for fname in os.listdir(path):
                    if fname.startswith(file):
                        potentials.append(
                            self.canon(os.path.join(path, fname))
                        )
        if not potentials:
            # find completions for executables in e.g. venv and PATH
            cmds = find_partial_executable(self.cwd, word)
            if cmds:
                potentials += cmds
        if not potentials:
            return None
        if len(potentials) == 1:
            return potentials[0]
        # find common prefix
        prefix = word
        prefix_len = len(word)
        max_len = min([len(w) for w in potentials])
        for idx in range(prefix_len+1, max_len+1):
            prefixes = set([w[0:idx] for w in potentials])
            if len(prefixes) > 1:
                break
            prefix = list(prefixes)[0]
            prefix_len = len(prefix)
        return prefix

    def run(self):
        self.outp.write(self.prompt() + "\n")
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
                    self.outs.print()
                    try:
                        if not self.execute(self.line):
                            break
                    except CommandFailedException:
                        pass
                    self.outp.write(self.prompt() + "\n")
                    self.line = ""
                    self.index = 0
            elif key == KEY_TAB:
                if self.line.strip() and self.index == len(self.line):
                    parts = split_command_quoted(self.line)
                    word = parts[-1]
                    completed = self.complete_word(word)
                    if completed:
                        parts[-1] = completed
                        self.line = " ".join(parts)
                        self.index = len(self.line)
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
                        self.index = len(self.line)
                    elif self.history_index > 0:
                        self.history_index -= 1
                        self.line = self.history[self.history_index]
                        self.index = len(self.line)
            elif key == KEY_DOWN:
                if self.history and self.history_index != -1:
                    if self.history_index < len(self.history)-1:
                        self.history_index += 1
                        self.line = self.history[self.history_index]
                        self.index = len(self.line)
                    else:
                        self.line = self.history_current
                        self.history_index = -1
                        self.history_current = ""
                        self.index = len(self.line)
            elif type(key) == str:
                pre = self.line[:self.index]
                post = self.line[self.index:]
                self.line = pre + key + post
                self.index += 1

            # Move all the way left
            self.outp.out.write(f"{esc}[1000D")
            line = self.line
            index = self.index
            if len(line) > max_line_length:
                start = index - max_line_length // 2
                end = index + max_line_length // 2
                if start < 0:
                    start = 0
                    end = max_line_length
                elif end > len(line):
                    end = len(line)
                    start = end - max_line_length
                index -= start
                line = line[start:end]
            self.outp.out.write(line)
            self.outp.out.write(f"{esc}[0K")
            if self.index < len(self.line):
                # Move all the way left
                self.outp.out.write(f"{esc}[1000D")
                if index > 0:
                    # Move cursor to index
                    self.outp.out.write(f"{esc}[{index}C")
            self.outp.out.flush()

    def execute(self, line):
        line = line.strip()
        if not line:
            return True
        cmd, args = split_command(line, self.env)
        if cmd != "history":
            self.history.append(line)
            self.history_index = -1
            self.history_current = ""
        if self.option_set("echo"):
            self.outs.print(f":: {cmd} {args}")
        # trigger prompt info update
        self.info_pythonproj_cwd = None
        self.info_git_cwd = None
        self.info_venv_cwd = None
        cmd_ = self.env.get(cmd)
        if cmd_ and isinstance(cmd_, Cmd):
            cmd_.execute(self, args)
        elif cmd == "exit":
            return False
        elif cmd.endswith(".dsh"):
            self.env.get("script").execute(self, [cmd, *args])
        else:
            self.env.get("run").execute(self, [cmd, *args])
        return True


class Cmd:
    def __init__(self, name):
        self.name = name

    def canon(self, path):
        if path is None:
            return None
        return os.path.normpath(os.path.abspath(path))

    def __repr__(self):
        return f"<{self.name}>"

    def __str__(self):
        return self.name


class CmdOptions(Cmd):
    def __init__(self):
         Cmd.__init__(self, "option")

    def help(self):
        return "<option> [<value>]   : gets/sets options"

    def execute(self, shell, args):
        option = args[0]
        if len(args) > 1:
            value = args[1]
            if value in ["on", "1", "yes", "y", "true"]:
                value = "on"
            else:
                value = "off"
            shell.options[option] = value
        else:
            shell.outs.print(shell.options.get(option, ""))


class CmdRun(Cmd):
    def __init__(self):
         Cmd.__init__(self, "run")

    def help(self):
        return "<cmd> [<arg>...]   : runs the external command"

    def execute(self, shell, args):
        cmd = args[0]
        args = args[1:]
        try:
            executable = shell.canon(find_executable(shell.cwd, cmd))
            if executable is None:
                shell.oute.print(f"ERR: {cmd} not found")
                raise CommandFailedException()
            elif executable.endswith(".dsh"):
                shell.env.get("script").execute(shell, [executable, *args])
            else:
                if shell.option_set("echo"):
                    # TODO properly quote args if necessary
                    shell.outs.print(f":: {executable} {' '.join(args)}")
                p = subprocess.run(
                    [
                        executable,
                        *args,
                    ],
                    cwd=shell.cwd,
                    stdout=shell.outs.out,
                    stderr=shell.oute.out,
                )
                if p.returncode != 0:
                    raise CommandFailedException()
        except CommandFailedException:
            raise
        except KeyboardInterrupt:
            pass
        except Exception as e:
            shell.oute.print(e)


def evaluate_expression(expr, env, cwd):
    # TODO this is rather kludgy, need to implement proper interpreter
    a, b = split_command(expr, env)
    parts = [a, *b]
    if len(parts) == 3:
        lhs = evaluate_expression(parts[0], env)
        op = parts[1]
        rhs = evaluate_expression(parts[2], env)
        if op == "<":
            return int(lhs) < int(rhs)
        elif op == "<=":
            return int(lhs) <= int(rhs)
        elif op == ">":
            return int(lhs) > int(rhs)
        elif op == ">=":
            return int(lhs) >= int(rhs)
        elif op == "==":
            return str(lhs) == str(rhs)
        elif op == "!=":
            return str(lhs) != str(rhs)
        elif op == "+":
            return int(lhs) + int(rhs)
        elif op == "-":
            return int(lhs) - int(rhs)
        elif op == "*":
            return int(lhs) * int(rhs)
        elif op == "/":
            return int(lhs) // int(rhs)
    elif len(parts) == 2:
        predicate = parts[0]
        value = parts[1]
        if predicate == "exists":
            if not os.path.isabs(value):
                value = os.path.join(cwd, value)
            if os.path.exists(value):
                return "yes"
            else:
                return ""
        elif predicate == "isfile":
            if not os.path.isabs(value):
                value = os.path.join(cwd, value)
            if os.path.isfile(value):
                return "yes"
            else:
                return ""
        elif predicate == "isdir":
            if not os.path.isabs(value):
                value = os.path.join(cwd, value)
            if os.path.isdir(value):
                return "yes"
            else:
                return ""
        elif predicate == "nexists":
            if not os.path.isabs(value):
                value = os.path.join(cwd, value)
            if not os.path.exists(value):
                return "yes"
            else:
                return ""
    elif len(parts) == 1:
        arg = parts[0]
        if (
            'A' <= arg[0] <= 'Z'
            or 'a' <= arg[0] <= 'z'
            or arg[0] == '_'
        ):
            return env.get(arg)
        elif arg.startswith("\"") or arg.startswith("'"):
            return arg[1:-1]
        else:
            return int(arg)
    raise ValueError(f"cannot evaluate {expr}")


class CmdExpr(Cmd):
    def __init__(self):
         Cmd.__init__(self, "expr")

    def help(self):
        return "<arg> <op> <arg>   : Evaluates the expression"

    def execute(self, shell, args):
        print("EXPR", args)
        return evalute_expression(" ".join(args))


class CmdScript(Cmd):
    def __init__(self):
         Cmd.__init__(self, "script")

    def help(self):
        return "<scriptfile> [<arg>...]   : runs a dabshell script"

    def execute(self, shell, args):
        scriptfile = args[0]
        if not os.path.isabs(scriptfile):
            scriptfile = os.path.join(shell.cwd, scriptfile)
        args = args[1:]
        scriptshell = Dabshell(shell)
        scriptshell.env.set("argc", len(args))
        for idx, arg in enumerate(args):
            scriptshell.env.set(f"arg{idx}", arg)
        with open(scriptfile, encoding="utf8") as infile:
            self.execute_lines(scriptshell, infile.readlines())
        CmdRedirect().execute(shell, ["off"])

    def execute_lines(self, shell, lines):
        lines = [line.strip() for line in lines]
        lines = [line for line in lines if line and not line.startswith("#")]
        stmt, stmt_lines, idx = self.get_statement(lines, 0)
        while stmt:
            if stmt == "single":
                try:
                    shell.execute(stmt_lines[0])
                except CommandFailedException:
                    break
            elif stmt == "if":
                condition = stmt_lines[0][len("if "):].strip()
                body = stmt_lines[1:]
                value = evaluate_expression(condition, shell.env, shell.cwd)
                if value:
                    if not self.execute_lines(shell, body):
                        break
            elif stmt == "for":
                parts = [part for part in stmt_lines[0].split(" ") if part]
                name = parts[1]
                elements = []
                for element in parts[3:]:
                    if "*" in element or "?" in element:
                        elements_ = glob.glob(
                            element,
                            root_dir=shell.cwd,
                            recursive=True,
                        )
                        elements += elements_
                    else:
                        elements.append(element)
                body = stmt_lines[1:]
                for element in elements:
                    shell.env.set(name, element)
                    if not self.execute_lines(shell, body):
                        break
            elif stmt == "while":
                condition = stmt_lines[0][len("while "):]
                body = stmt_lines[1:]
                value = evaluate_expression(condition, shell.env, shell.cwd)
                while value:
                    if not self.execute_lines(shell, body):
                        break
                    value = evaluate_expression(
                        condition,
                        shell.env,
                        shell.cwd,
                    )
            stmt, stmt_lines, idx = self.get_statement(lines, idx)
        else:
            return True

    def get_statement(self, lines, idx):
        if idx >= len(lines):
            return None, None, None
        line = lines[idx]
        if line.startswith("if "):
            stmt = "if"
            stmt_lines = [line]
            idx += 1
            depth = 0
            while idx < len(lines):
                line = lines[idx]
                if (
                    line.startswith("if ")
                    or line.startswith("for ")
                    or line.startswith("while ")
                ):
                    stmt_lines.append(line)
                    depth += 1
                elif line == "end":
                    if depth == 0:
                        break
                    else:
                        stmt_lines.append(line)
                        depth -= 1
                else:
                    stmt_lines.append(line)
                idx += 1
            return stmt, stmt_lines, idx + 1
        elif line.startswith("for "):
            stmt = "for"
            stmt_lines = [line]
            idx += 1
            depth = 0
            while idx < len(lines):
                line = lines[idx]
                if (
                    line.startswith("if ")
                    or line.startswith("for ")
                    or line.startswith("while ")
                ):
                    stmt_lines.append(line)
                    depth += 1
                elif line == "end":
                    if depth == 0:
                        break
                    else:
                        stmt_lines.append(line)
                        depth -= 1
                else:
                    stmt_lines.append(line)
                idx += 1
            return stmt, stmt_lines, idx + 1
        elif line.startswith("while "):
            stmt = "while"
            stmt_lines = [line]
            idx += 1
            depth = 0
            while idx < len(lines):
                line = lines[idx]
                if (
                    line.startswith("if ")
                    or line.startswith("for ")
                    or line.startswith("while ")
                ):
                    stmt_lines.append(line)
                    depth += 1
                elif line == "end":
                    if depth == 0:
                        break
                    else:
                        stmt_lines.append(line)
                        depth -= 1
                else:
                    stmt_lines.append(line)
                idx += 1
            return stmt, stmt_lines, idx + 1
        else:
            return "single", [line], idx + 1


class CmdSource(CmdScript):
    def __init__(self):
         Cmd.__init__(self, "source")

    def help(self):
        return "<scriptfile>   : sources a dabshell script"

    def execute(self, shell, args):
        scriptfile = args[0]
        if not os.path.isabs(scriptfile):
            scriptfile = os.path.join(shell.cwd, scriptfile)
        with open(scriptfile, encoding="utf8") as infile:
            self.execute_lines(shell, infile.readlines())


class CmdLs(Cmd):
    def __init__(self):
         Cmd.__init__(self, "ls")

    def help(self):
        return "[<dir>]   : lists the contents of the directory"

    def execute(self, shell, args):
        if len(args) == 0:
            path = shell.canon(shell.cwd)
        else:
            if os.path.isabs(args[0]):
                path = shell.canon(args[0])
            else:
                path = shell.canon(os.path.join(shell.cwd, args[0]))
        if os.path.exists(path):
            if isinstance(shell.outs, StdOutput):
                for fname in sorted(os.listdir(path)):
                    fpath = os.path.join(path, fname)
                    if os.path.isdir(fpath):
                        shell.outs.print(f"{esc}[34m{fname}{esc}[0m")
                    else:
                        shell.outs.print(fname)
            else:
                for fname in sorted(os.listdir(path)):
                    shell.outs.print(fname)


class CmdCd(Cmd):
    def __init__(self):
        Cmd.__init__(self, "cd")

    def help(self):
        return "<dir>   : changes the current directory"

    def execute(self, shell, args):
        if len(args) == 0:
            shell.cwd = shell.canon(".")
        else:
            path = args[0]
            if os.path.isabs(path):
                cwd_ = shell.canon(path)
            else:
                cwd_ = shell.canon(os.path.join(shell.cwd, path))
            if os.path.isdir(cwd_):
                shell.cwd = cwd_
            else:
                shell.oute.print(f"ERR: cannot cd to {cwd_}")


class CmdPwd(Cmd):
    def __init__(self):
        Cmd.__init__(self, "pwd")

    def help(self):
        return ": prints the current directory"

    def execute(self, shell, args):
       shell.outs.print(shell.cwd)


class CmdSet(Cmd):
    def __init__(self):
        Cmd.__init__(self, "set")

    def help(self):
        return "<name> <value>   : sets a variable"

    def execute(self, shell, args):
        name = args[0]
        if args[1] == "eval":
            scriptshell = Dabshell(shell)
            scriptshell.env.set("argc", 0)
            scriptshell.outs = StringOutput()
            try:
                scriptshell.execute(" ".join(args[2:]))
            except CommandFailedException:
                pass
            value = scriptshell.outs.value().strip()
        elif args[1] == "expr":
            value = evaluate_expression(
                " ".join(args[2:]),
                shell.env,
                shell.cwd,
            )
        else:
            value = " ".join(args[1:])
        shell.env.set(name, value)


class CmdGet(Cmd):
    def __init__(self):
        Cmd.__init__(self, "get")

    def help(self):
        return "<name>   : prints the value of a variable"

    def execute(self, shell, args):
        try:
            shell.outs.print(shell.env.get(args[0]))
        except ValueError:
            pass


class CmdCat(Cmd):
    def __init__(self):
        Cmd.__init__(self, "cat")

    def help(self):
        return "[<file> ...]   : prints the contents of the files"

    def execute(self, shell, args):
        for filename in args:
            if not os.path.isabs(filename):
                filename = os.path.normpath(os.path.join(shell.cwd, filename))
            if os.path.exists(filename):
                with open(filename, encoding="utf_8") as infile:
                    for line in infile:
                        shell.outs.write(line)


class CmdTail(Cmd):
    def __init__(self):
        Cmd.__init__(self, "tail")

    def help(self):
        return (
            "[-n <lines>] [--lines=<lines>] [-f] <file> ... "
            " : prints the last lines of each file"
        )

    def execute(self, shell, args):
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
                filename = shell.canon(os.path.join(shell.cwd, filename))
            if os.path.exists(filename):
                with open(filename, encoding="utf_8") as infile:
                    # TODO for now, we read everything, later, optimize
                    lines = infile.readlines()
                    for line in lines[-n:]:
                        shell.outs.write(line)
                    if "-f" in args or "--follow" in args:
                        while True:
                            try:
                                line = infile.readline()
                                if line:
                                    shell.outs.write(line)
                                else:
                                    time.sleep(1)
                            except KeyboardInterrupt:
                                break


class CmdHead(Cmd):
    def __init__(self):
        Cmd.__init__(self, "head")

    def help(self):
        return (
            "[-n <lines>] [--lines=<lines>] <file> ... "
            " : prints the first lines of each file"
        )

    def execute(self, shell, args):
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
                filename = shell.canon(os.path.join(shell.cwd, filename))
            if os.path.exists(filename):
                with open(filename, encoding="utf_8") as infile:
                    for i in range(n):
                        line = infile.readline()
                        if not line:
                            break
                        shell.outs.write(line)


class CmdEcho(Cmd):
    def __init__(self):
        Cmd.__init__(self, "echo")

    def help(self):
        return "<value> : prints the value"

    def execute(self, shell, args):
        shell.outs.print(" ".join(args))


class CmdCp(Cmd):
    def __init__(self):
        Cmd.__init__(self, "cp")

    def help(self):
        return "<srcfiles>... <dest> : copies one or multiple files"

    def execute(self, shell, args):
        sources = args[:-1]
        dest = args[-1]
        if not os.path.isabs(dest):
            dest = os.path.join(shell.cwd, dest)
        if (
            (not os.path.exists(dest) or os.path.isfile(dest))
            and len(sources) > 1
        ):
            shell.oute.print("ERR: cannot copy multiple files to a file")
            raise CommandFailedException()
        for source in sources:
            if not os.path.isabs(source):
                source = os.path.join(shell.cwd, source)
            try:
                shutil.copy(source, dest)
            except Exception as e:
                shell.oute.print(str(e))
                raise CommandFailedException()


class CmdMv(Cmd):
    def __init__(self):
        Cmd.__init__(self, "mv")

    def help(self):
        return "<srcfiles>... <dest> : moves one or multiple files"

    def execute(self, shell, args):
        sources = args[:-1]
        dest = args[-1]
        if not os.path.isabs(dest):
            dest = os.path.join(shell.cwd, dest)
        if (
            (not os.path.exists(dest) or os.path.isfile(dest))
            and len(sources) > 1
        ):
            shell.oute.print("ERR: cannot move multiple files to a file")
            raise CommandFailedException()
        for source in sources:
            if not os.path.isabs(source):
                source = os.path.join(shell.cwd, source)
            try:
                if (
                    os.path.isdir(dest)
                    and os.path.isfile(
                        os.path.join(dest, os.path.basename(source))
                    )
                ):
                    os.remove(os.path.join(dest, os.path.basename(source)))
                shutil.move(source, dest)
            except Exception as e:
                shell.oute.print(str(e))
                raise CommandFailedException()


class CmdTree(Cmd):
    def __init__(self):
        Cmd.__init__(self, "tree")

    def help(self):
        return "<dir> <filter>... : displays file tree"

    def execute(self, shell, args):
        if not args:
            args = ["."]
        path = args[0]
        filters = args[1:]
        if not os.path.isabs(path):
            path = os.path.join(shell.cwd, path)
        if not os.path.isdir(path):
            filters = [path, *args]
            path = "."
        if not os.path.isabs(path):
            path = os.path.join(shell.cwd, path)
        if os.path.isdir(path):
            for path_ in self.walk(path):
                if filters:
                    fname = os.path.basename(path_)
                    for flt in filters:
                        if flt.startswith("*") and fname.endswith(flt[1:]):
                            print(path_)
                            break
                        elif flt.endswith("*") and fname.startswith(flt[:-1]):
                            print(path_)
                            break
                else:
                    print(path_)

    def walk(self, path):
        for fname in os.listdir(path):
            if fname in [".git", "venv", ".env", "__pycache__"]:
                continue
            if fname.endswith(".egg-info"):
                continue
            fpath = os.path.normpath(os.path.join(path, fname))
            if os.path.isdir(fpath):
                yield from self.walk(fpath)
            else:
                yield fpath


class CmdTouch(Cmd):
    def __init__(self):
        Cmd.__init__(self, "touch")

    def help(self):
        return "<filename>... : creates/changes the files"

    def execute(self, shell, args):
        for path in args:
            if not os.path.isabs(path):
                path = os.path.join(shell.cwd, path)
            if os.path.isdir(path):
                continue
            try:
                print(path)
                try:
                    os.utime(path)
                except OSError:
                    open(path, "a").close()
            except Exception as e:
                shell.oute.print(str(e))
                raise CommandFailedException()


class CmdRm(Cmd):
    def __init__(self):
        Cmd.__init__(self, "rm")

    def help(self):
        return "<filename>... : deletes the files"

    def execute(self, shell, args):
        for arg in args:
            path = arg
            if not os.path.isabs(path):
                path = os.path.join(shell.cwd, path)
            for path in glob.glob(path):
                if not os.path.isfile(path):
                    continue
                try:
                    os.remove(path)
                except Exception as e:
                    shell.oute.print(str(e))
                    raise CommandFailedException()


class CmdMkdir(Cmd):
    def __init__(self):
        Cmd.__init__(self, "mkdir")

    def help(self):
        return "<dir> : creates the directory"

    def execute(self, shell, args):
        path = args[0]
        if not os.path.isabs(path):
            path = os.path.join(shell.cwd, path)
        if not os.path.exists(path):
            try:
                os.makedirs(path, exist_ok=True)
            except Exception as e:
                shell.oute.print(str(e))
                raise CommandFailedException()


class CmdRmdir(Cmd):
    def __init__(self):
        Cmd.__init__(self, "rmdir")

    def help(self):
        return "<dir> : deletes the directory"

    def execute(self, shell, args):
        path = args[0]
        if not os.path.isabs(path):
            path = os.path.join(shell.cwd, path)
        if os.path.isdir(path):
            try:
                # TODO only delete if empty? otherwise require -rf option?
                shutil.rmtree(path)
            except Exception as e:
                shell.oute.print(str(e))
                raise CommandFailedException()


class CmdBasename(Cmd):
    def __init__(self):
        Cmd.__init__(self, "basename")

    def help(self):
        return "<path> : returns the basename of the path"

    def execute(self, shell, args):
        shell.outs.print(os.path.basename(args[0]))


class CmdDirname(Cmd):
    def __init__(self):
        Cmd.__init__(self, "dirname")

    def help(self):
        return "<path> : returns the dirname part of the path"

    def execute(self, shell, args):
        shell.outs.print(os.path.dirname(args[0]))


class CmdRedirect(Cmd):
    def __init__(self):
        Cmd.__init__(self, "redirect")

    def help(self):
        return (
            "out|err|all|off [filename [--append]]: "
            "enable/disable output redirection"
        )

    def execute(self, shell, args):
        if args[0] == "off":
            if not isinstance(shell.outs, StdOutput):
                shell.outs.out.close()
                if shell.outs_old:
                    shell.outs = shell.outs_old
                    shell.outs_old = None
                else:
                    shell.oupt = StdOutput()
            if not isinstance(shell.oute, StdError):
                shell.oute.out.close()
                if shell.oute_old:
                    shell.oute = shell.oute_old
                    shell.oute_old = None
                else:
                    shell.oute = StdError()
        else:
            out = FileOutput(
                args[1],
                encoding="utf8",
                append="--append" in args,
            )
            # We set the new output, but retain the old one
            # in the out*_old variable. But we do this only
            # once. That means, that if we redirect twice,
            # we retain the original output and close the
            # first redirected output before installing the
            # second one.
            if args[0] == "out" or args[0] == "all":
                if not shell.outs_old:
                    shell.outs_old = shell.outs
                elif isinstance(shell.outs, FileOutput):
                    shell.outs.out.close()
                shell.outs = out
            if args[0] == "err" or args[0] == "all":
                if not shell.oute_old:
                    shell.oute_old = shell.oute
                elif isinstance(shell.oute, FileOutput):
                    shell.oute.out.close()
                shell.oute = out


class CmdHistory(Cmd):
    def __init__(self):
        Cmd.__init__(self, "history")

    def help(self):
        return (
            "[<filter>]   : shows the history of commands, optionally filtered"
        )

    def execute(self, shell, args):
        if not args:
            for index, line in enumerate(shell.history):
                shell.outs.print(f"{index} {line}")
        else:
            query = args[0].lower()
            for index, line in enumerate(shell.history):
                if line.lower().find(query) != -1:
                    shell.outs.print(f"{index} {line}")


class CmdWhich(Cmd):
    def __init__(self):
        Cmd.__init__(self, "which")

    def help(self):
        return (
            "<filename>   : searches filename in the "
            "PATH and shows the location"
        )

    def execute(self, shell, args):
        for arg in args:
            cmd = shell.env.get(arg)
            if cmd and isinstance(cmd, Cmd):
                print("(internal command)")
            location = find_executable(shell.cwd, arg)
            if location:
                shell.outs.print(shell.canon(location))


class CmdGrep(Cmd):
    def __init__(self):
        Cmd.__init__(self, "grep")

    def help(self):
        return (
            "<pattern> [<location>...]   : searches the pattern in the "
            "files at location"
        )

    def execute(self, shell, args):
        pattern = args[0]
        locations = args[1:]
        if not locations:
            locations = ["."]
        for path in self.walk(shell.cwd, locations):
            self.grep(shell, pattern, path)

    def grep(self, shell, pattern, filepath):
        if not os.path.exists(filepath):
            return
        if filepath.startswith(shell.cwd):
            relpath = filepath[len(shell.cwd)+1:]
        else:
            relpath = filepath
        with open(filepath, encoding="utf8", errors="ignore") as infile:
            linenr = 1
            for line in infile:
                if re.match(f".*({pattern})", line):
                    line = line.strip()
                    shell.outs.print(f"{relpath} {linenr}: {line}")
                linenr += 1

    def walk(self, cwd, locations):
        for location in locations:
            if "*" in location or "?" in location:
                locs = glob.glob(location)
                if not locs:
                    locs = glob.glob(
                        os.path.normpath(os.path.join(cwd, location))
                    )
                for loc in locs:
                    yield from self.walk_dir(loc)
            else:
                if not os.path.isabs(location):
                    location = os.path.normpath(os.path.join(cwd, location))
                yield from self.walk_dir(location)

    def walk_dir(self, path):
        if os.path.basename(path) not in [
            "venv",
            ".env",
            "__pycache__",
            ".git",
        ]:
            if os.path.isdir(path):
                for filename in os.listdir(path):
                    filepath = os.path.join(path, filename)
                    if os.path.isdir(filepath):
                        yield from self.walk_dir(filepath)
                    else:
                        yield filepath
            else:
                yield path


class CmdDate(Cmd):
    def __init__(self):
        Cmd.__init__(self, "date")

    def help(self):
        return (
            "[<offset>] [--terse] [--with-time] [--format <fmt>]  "
            ": shows the current date"
        )

    def execute(self, shell, args):
        terse = "--terse" in args
        with_time = "--with-time" in args
        if with_time:
            fmt = "%Y-%m-%dT%H:%M:%S"
        else:
            fmt = "%Y-%m-%d"
        if terse:
            fmt = fmt.replace("-", "").replace(":", "").replace("T", "-")
        for idx, arg in enumerate(args):
            if arg == "--format" or arg == "--fmt":
                if idx < len(args)-1:
                    fmt = args[idx+1]
                break
        offset = 0
        idx = 0
        while idx < len(args):
            arg = args[idx]
            if arg == "--format" or arg == "--fmt":
                idx += 2
            elif arg.startswith("--"):
                idx += 1
            else:
                offset = int(arg)
                break
        now = datetime.datetime.now()
        if offset != 0:
            now += datetime.timedelta(days=offset)
        shell.outs.print(now.strftime(fmt))


class CmdTitle(Cmd):
    def __init__(self):
        Cmd.__init__(self, "title")

    def help(self):
        return (
            "<title>   : sets the window title"
        )

    def execute(self, shell, args):
        if IS_WIN:
            os.system("title " + " ".join(args))


class CmdHelp(Cmd):
    def __init__(self):
        Cmd.__init__(self, "help")

    def help(self):
        return (
            "[<cmd>]   : shows the list of available command "
            "and optionally the description of a specific command"
        )

    def execute(self, shell, args):
        if not args:
            names = [
                name
                for name in shell.env.names()
                if isinstance(shell.env.get(name), Cmd)
            ]
            shell.outs.print(" ".join(names))
        else:
            name = args[0]
            obj = shell.env.get(name)
            if obj and isinstance(obj, Cmd):
                shell.outs.print(f"{obj.name} {obj.help()}")


def dabshell():
    Dabshell().run()


if __name__ == "__main__":
    dabshell()
