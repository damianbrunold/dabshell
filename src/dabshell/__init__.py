import ctypes
import datetime
import difflib
import glob
import io
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import tomllib


esc = "\u001b"

IS_WIN = platform.system() == "Windows"


def _enable_win_vt_processing():
    """Enable ANSI/VT escape-code processing on Windows consoles.

    On Windows 10 v1511+ the console supports VT sequences, but the mode flag
    must be set explicitly.  This is a no-op on Linux/macOS.
    Returns True if VT processing is available (always True on non-Windows).
    """
    if not IS_WIN:
        return True
    try:
        kernel32 = ctypes.windll.kernel32
        # STD_OUTPUT_HANDLE = -11
        handle = kernel32.GetStdHandle(-11)
        if handle == -1:          # INVALID_HANDLE_VALUE
            return False
        mode = ctypes.c_ulong(0)
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return False
        ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        new_mode = mode.value | ENABLE_VIRTUAL_TERMINAL_PROCESSING
        return bool(kernel32.SetConsoleMode(handle, new_mode))
    except Exception:
        return False


_VT_ENABLED = _enable_win_vt_processing()

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
KEY_CTRL_LEFT = -15
KEY_CTRL_RIGHT = -16
KEY_CTRL_UP = -17
KEY_CTRL_DOWN = -18

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
    def __init__(self):
        # On Linux we put the terminal into raw mode once and leave it there
        # for the whole session, rather than toggling on every keypress.
        if not IS_WIN:
            self._old_settings = termios.tcgetattr(sys.stdin)
            tty.setraw(sys.stdin)

    def close(self):
        """Restore the terminal to its original settings (Linux only)."""
        if not IS_WIN:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self._old_settings)

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
                elif n == 0x73: return KEY_CTRL_LEFT
                elif n == 0x74: return KEY_CTRL_RIGHT
                elif n == 0x8d: return KEY_CTRL_UP
                elif n == 0x91: return KEY_CTRL_DOWN
                # Unknown extended key — consume it and return None
                return None
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
            elif 1 <= n <= 26:   # Ctrl+A .. Ctrl+Z  (exclude 0 = Ctrl+Space)
                return -100 - n
            else:
                return ch
        else:
            return self._getch_linux()

    def _getch_linux(self):
        ch = sys.stdin.read(1)
        n = ord(ch)

        if n == 0x1b:
            # Check if more bytes follow within a short timeout.
            # A lone ESC has no follow-up; an escape sequence does.
            ready = select.select([sys.stdin], [], [], 0.05)[0]
            if not ready:
                return KEY_ESC

            ch = sys.stdin.read(1)
            n = ord(ch)

            if n == 0x1b:
                # Double-ESC → treat as ESC
                return KEY_ESC

            elif n == 0x4f:
                # SS3 sequences:  ESC O X
                ch = sys.stdin.read(1)
                n = ord(ch)
                if n == 0x41: return KEY_UP
                elif n == 0x42: return KEY_DOWN
                elif n == 0x43: return KEY_RIGHT
                elif n == 0x44: return KEY_LEFT
                elif n == 0x46: return KEY_END
                elif n == 0x48: return KEY_HOME
                # F1-F4 (ESC O P/Q/R/S) and any other SS3 byte —
                # unrecognised but fully consumed; return ESC so the
                # caller gets something sensible.
                return KEY_ESC

            elif n == 0x5b:
                # CSI sequences:  ESC [ ...
                ch = sys.stdin.read(1)
                n = ord(ch)

                # Simple one-byte CSI finals
                if n == 0x41: return KEY_UP
                elif n == 0x42: return KEY_DOWN
                elif n == 0x43: return KEY_RIGHT
                elif n == 0x44: return KEY_LEFT
                elif n == 0x46: return KEY_END
                elif n == 0x48: return KEY_HOME

                # Tilde-terminated sequences:  ESC [ N ~
                # Also used for Home/End on some terminals:
                #   ESC [ 1 ~  →  Home
                #   ESC [ 4 ~  →  End
                elif n == 0x31:
                    next_ch = sys.stdin.read(1)
                    next_n  = ord(next_ch)
                    if next_n == 0x7e:          # ESC [ 1 ~  →  Home
                        return KEY_HOME
                    elif next_n == 0x3b:        # ESC [ 1 ;  →  modifier sequence
                        mod  = ord(sys.stdin.read(1))
                        final = ord(sys.stdin.read(1))
                        if mod == 0x35:         # Ctrl  (modifier 5)
                            if final == 0x41: return KEY_CTRL_UP
                            elif final == 0x42: return KEY_CTRL_DOWN
                            elif final == 0x43: return KEY_CTRL_RIGHT
                            elif final == 0x44: return KEY_CTRL_LEFT
                        # Other modifiers (Shift=2, Alt=3, Shift+Alt=4,
                        # Shift+Ctrl=6, Alt+Ctrl=7, Shift+Alt+Ctrl=8):
                        # consume and return ESC — don't leak bytes.
                        return KEY_ESC
                    # Any other byte after ESC [ 1 — consume and return ESC
                    return KEY_ESC
                elif n == 0x32:
                    sys.stdin.read(1)           # consume trailing ~
                    return KEY_ESC              # Insert key — not used, return ESC
                elif n == 0x33:
                    sys.stdin.read(1)           # consume trailing ~
                    return KEY_DELETE
                elif n == 0x34:
                    sys.stdin.read(1)           # consume trailing ~  →  End
                    return KEY_END
                elif n == 0x35:
                    sys.stdin.read(1)           # consume trailing ~
                    return KEY_PAGEUP
                elif n == 0x36:
                    sys.stdin.read(1)           # consume trailing ~
                    return KEY_PAGEDOWN
                elif n == 0x37:
                    sys.stdin.read(1)           # consume trailing ~  →  Home
                    return KEY_HOME
                elif n == 0x38:
                    sys.stdin.read(1)           # consume trailing ~  →  End
                    return KEY_END

                # Unknown CSI sequence — the final byte is already consumed;
                # return ESC so the caller gets a safe non-None value.
                return KEY_ESC

            # Unknown byte after ESC — return ESC, byte already consumed.
            return KEY_ESC

        elif n == 0x7f:
            return KEY_BACKSPACE
        elif n == 0x9:
            return KEY_TAB
        elif n == 0xa:
            return KEY_LF   # also Ctrl+J — intentional
        elif n == 0xd:
            return KEY_CR
        elif 1 <= n <= 26:  # Ctrl+A .. Ctrl+Z  (exclude 0 = Ctrl+Space)
            return -100 - n
        else:
            return ch


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


def find_executable_venv(venvdir, executable):
    scriptfolder = "Scripts" if IS_WIN else "bin"
    venv = os.path.join(venvdir, scriptfolder)
    return find_executable_(venv, executable)


def collect_partial_executables(path, word, results):
    if not os.path.isdir(path):
        return
    for fname in os.listdir(path):
        if fname.startswith(word):
            fullpath = os.path.join(path, fname)
            if fname.endswith(".exe") or fname.endswith(".dsh"):
                fname = fname[:-4]
            elif not IS_WIN and not os.access(fullpath, os.X_OK):
                continue
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


def shell_exec(s, shell):
    scriptshell = Dabshell(shell)
    scriptshell.env = Env(shell.env)
    scriptshell.outs = StringOutput()
    try:
        scriptshell.execute(s)
    except CommandFailedException:
        pass
    return scriptshell.outs.value().strip()


def replace_vars(s, shell):
    env = shell.env
    in_single_quote = False
    in_var = False
    result = ""
    var = ""
    level = 0
    for ch in s:
        if ch == "{" and not in_single_quote:
            if level == 0:
                in_var = True
                level += 1
            else:
                var += ch
                level += 1
        elif ch != "}" and in_var:
            var += ch
        elif ch == "}" and in_var:
            level -= 1
            if level == 0:
                if var.startswith("!"):
                    result += shell_exec(var[1:], shell)
                else:
                    result += str(env.get(var, "{" + var + "}"))
                var = ""
                in_var = False
            else:
                var += ch
        elif ch == "'":
            in_single_quote = not in_single_quote
            result += ch
        else:
            result += ch
    return result


def split_command(line, shell, with_vars=True):
    if with_vars:
        line = replace_vars(line, shell)
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
        elif ch == "\"" and in_quote:
            in_quote = False
            parts.append(current_part)
            current_part = ""
        elif ch == "~" and not in_quote:
            if "user-home" in shell.options:
                current_part += shell.options.get("user-home")
            else:
                current_part += os.path.expanduser("~")
        elif ch == " " and not in_quote:
            if current_part:
                parts.append(current_part)
                current_part = ""
        else:
            current_part += ch
        idx += 1
    if current_part:
        parts.append(current_part)
    if not parts:
        return "", []
    return parts[0], parts[1:]


def quote_arg(arg):
    if " " in arg or "\"" in arg or "\'" in arg:
        arg = arg.replace("\\", "\\\\")
        arg = arg.replace("\"", "\\\"")
        return "\"" + arg + "\""
    elif arg == "":
        return "\"\""
    else:
        return arg


def quote_args(args):
    return " ".join([quote_arg(arg) for arg in args])


class Stage:
    """One command in a pipeline, with its redirect annotations stripped out."""
    __slots__ = (
        "raw",
        "stdout_file", "stdout_append",
        "stderr_file", "stderr_append",
        "both_file",   "both_append",
    )

    def __init__(self, raw):
        self.raw = raw.strip()
        self.stdout_file   = None
        self.stdout_append = False
        self.stderr_file   = None
        self.stderr_append = False
        self.both_file     = None   # &>  / &>>  (stdout + stderr together)
        self.both_append   = False


def _tokenize_unquoted(s):
    """Yield (token_string, is_quoted) pairs by scanning s character by char.

    Tokens are separated by unquoted whitespace.  Quoted spans are kept
    together with neighbouring unquoted characters as a single token, e.g.
    foo"bar baz" → one token 'foobar baz'.  The is_quoted flag is True when
    the token contained at least one quoted section (used so that a lone ""
    is preserved as an empty-string argument).
    """
    tokens = []
    current = []
    current_quoted = False
    in_quote = False
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == '"' and not in_quote:
            in_quote = True
            current_quoted = True
        elif ch == '"' and in_quote:
            in_quote = False
        elif ch == '\\' and in_quote and i + 1 < len(s) and s[i+1] in ('"', '\\'):
            current.append(s[i+1])
            i += 2
            continue
        elif ch == ' ' and not in_quote:
            if current or current_quoted:
                tokens.append((''.join(current), current_quoted))
                current = []
                current_quoted = False
        else:
            current.append(ch)
        i += 1
    if current or current_quoted:
        tokens.append((''.join(current), current_quoted))
    return tokens


def _split_pipe(s):
    """Split s on unquoted '|' characters that are NOT part of '||' or '|&'.

    Returns a list of raw stage strings.
    """
    stages = []
    current = []
    in_quote = False
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == '"' and not in_quote:
            in_quote = True
            current.append(ch)
        elif ch == '"' and in_quote:
            in_quote = False
            current.append(ch)
        elif not in_quote and ch == '|':
            # peek ahead: || is boolean-OR (reserved), not a pipe
            if i + 1 < len(s) and s[i + 1] == '|':
                # keep both characters as-is
                current.append(ch)
                current.append(s[i + 1])
                i += 2
                continue
            else:
                stages.append(''.join(current))
                current = []
                i += 1
                continue
        else:
            current.append(ch)
        i += 1
    stages.append(''.join(current))
    return stages


# Redirect token patterns, ordered longest-first so >> beats >
_REDIRECT_OPS = ["&>>", "&>", "2>>", "2>", ">>", ">"]


def _parse_redirects(raw):
    """Strip redirect tokens from *raw* and return (clean_raw, Stage-fields).

    Scans the token list produced by _tokenize_unquoted.  Any unquoted token
    that matches a redirect operator is consumed together with the following
    filename token.  Everything else is kept.

    Returns a Stage with .raw set to the cleaned command string and all
    redirect fields populated.
    """
    stage = Stage(raw)
    tokens = _tokenize_unquoted(raw)
    kept = []
    i = 0
    while i < len(tokens):
        tok, tok_quoted = tokens[i]
        if tok_quoted:
            kept.append(quote_arg(tok))   # re-quote so split_command sees one token
            i += 1
            continue
        matched_op = None
        for op in _REDIRECT_OPS:
            if tok == op:
                matched_op = op
                break
        if matched_op and i + 1 < len(tokens):
            filename, _ = tokens[i + 1]
            if matched_op == "&>>":
                stage.both_file   = filename
                stage.both_append = True
            elif matched_op == "&>":
                stage.both_file   = filename
                stage.both_append = False
            elif matched_op == "2>>":
                stage.stderr_file   = filename
                stage.stderr_append = True
            elif matched_op == "2>":
                stage.stderr_file   = filename
                stage.stderr_append = False
            elif matched_op == ">>":
                stage.stdout_file   = filename
                stage.stdout_append = True
            elif matched_op == ">":
                stage.stdout_file   = filename
                stage.stdout_append = False
            i += 2
        else:
            # Re-quote the token if it was originally bare (no quoting needed
            # here — we just rebuild the raw command from kept tokens).
            kept.append(quote_arg(tok) if ' ' in tok else tok)
            i += 1
    stage.raw = ' '.join(kept)
    return stage


def parse_pipeline(segment):
    """Parse one &&-segment into a list of Stage objects.

    Each Stage has its redirect annotations extracted and its .raw set to the
    clean command string (operators and filenames removed).
    """
    raw_stages = _split_pipe(segment)
    return [_parse_redirects(r) for r in raw_stages]


def get_os_env(env):
    result = {}
    result.update(os.environ)
    for name in env.names():
        if not name.startswith("env:"):
            continue
        value = env.get(name)
        name = name[len("env:"):]
        if value is not None:
            result[name] = str(value)
    return result


# ── Text-file encoding/line-ending helpers ────────────────────────────────────

def _detect_file_encoding(raw):
    """Return (encoding, has_bom) for a bytes object.

    Checks for UTF-8 BOM, UTF-16 LE/BE BOMs, then tries UTF-8,
    then falls back to Latin-1 (which never raises).
    UTF-16 files are flagged but not supported for conversion.
    """
    if raw[:3] == b"\xef\xbb\xbf":
        return "utf-8-sig", True      # utf-8-sig strips the BOM on decode
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16", True
    try:
        raw.decode("utf-8")
        return "utf-8", False
    except UnicodeDecodeError:
        return "latin-1", False


def _is_binary(raw):
    """Return True if *raw* looks like binary data (>10 % non-text bytes)."""
    if not raw:
        return False
    non_text = sum(
        1 for b in raw[:8192]
        if b < 0x09 or (0x0e <= b <= 0x1f) or b == 0x7f
    )
    return non_text / min(len(raw), 8192) > 0.10


def _collect_files(shell, args):
    """Expand args (with glob support) into a list of absolute file paths."""
    files = []
    for arg in args:
        if not os.path.isabs(arg):
            arg = os.path.join(shell.cwd, arg)
        matched = sorted(glob.glob(arg))
        if matched:
            files.extend(matched)
        else:
            files.append(arg)
    return files


class Env:
    def __init__(self, parent=None):
        self.mappings = {}
        self.parent = parent

    def names(self):
        result = set(self.mappings.keys())
        if self.parent:
            result |= set(self.parent.names())
        return sorted(result)

    def get(self, name, default=None):
        if name in self.mappings:
            return self.mappings[name]
        if self.parent:
            return self.parent.get(name, default)
        else:
            return default

    def set(self, name, value):
        self.mappings[name] = value

    def remove(self, name):
        if name in self.mappings:
            del self.mappings[name]
        elif self.parent:
            self.parent.remove(name)

    def update(self, name, value):
        # Update the variable in whichever scope first defines it.
        # Uses 'name in mappings' rather than self.get() so that falsy
        # values (empty string, 0) are updated rather than creating a
        # new local binding.
        if name in self.mappings:
            self.mappings[name] = value
        elif self.parent and self.parent.get(name) is not None:
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
        mode = "a+" if append else "w"
        self.out = open(filename, mode, encoding=encoding)

    def write(self, s):
        self.out.write(s)

    def print(self, s=""):
        print(s, file=self.out)

    def close(self):
        if self.out and not self.out.closed:
            self.out.close()

    def __del__(self):
        self.close()


class StringOutput:
    def __init__(self):
        self.out = io.StringIO()

    def write(self, s):
        self.out.write(s)

    def print(self, s=""):
        self.out.write(s)
        self.out.write("\n")

    def value(self):
        return self.out.getvalue()


class StringInput:
    """Wraps a string so internal commands can read it as line-by-line stdin."""
    def __init__(self, data=""):
        self._lines = data.splitlines(keepends=True)
        self._idx = 0

    def readline(self):
        if self._idx < len(self._lines):
            line = self._lines[self._idx]
            self._idx += 1
            return line
        return ""

    def readlines(self):
        rest = self._lines[self._idx:]
        self._idx = len(self._lines)
        return rest

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if line == "":
            raise StopIteration
        return line


class CommandFailedException(Exception):
    pass


class Dabshell:
    def __init__(self, parent_shell=None, init_shell=False):
        if parent_shell:
            self.title = parent_shell.title
            self.cwd = parent_shell.cwd
            self.env = Env(parent_shell.env)
            self.outp = parent_shell.outp
            self.outs = parent_shell.outs
            self.oute = parent_shell.oute
            self.options = {}
            self.options.update(parent_shell.options)
        else:
            self.cwd = self.canon(".")
            self.title = "dabshell"
            self._set_title(self.title)
            self.env = Env()
            self.outp = StdOutput()
            self.outs = StdOutput()
            self.oute = StdError()
            self.options = {
                "echo": "off",
                "stop-on-error": "on",
            }
            for name in os.environ:
                self.env.set("env:" + name, os.environ.get(name, ""))
            self.init_cmd(CmdRun())
            self.init_cmd(CmdEval())
            self.init_cmd(CmdScript())
            self.init_cmd(CmdSource())
            self.init_cmd(CmdAlias())
            self.init_cmd(CmdCd())
            self.init_cmd(CmdLs())
            self.init_cmd(CmdPwd())
            self.init_cmd(CmdSet())
            self.init_cmd(CmdGet())
            self.init_cmd(CmdCat())
            self.init_cmd(CmdHead())
            self.init_cmd(CmdTail())
            self.init_cmd(CmdWc())
            self.init_cmd(CmdDiff())
            self.init_cmd(CmdEcho())
            self.init_cmd(CmdPrint())
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
            self.init_cmd(CmdRemoveExt())
            self.init_cmd(CmdGetExt())
            self.init_cmd(CmdHistory())
            self.init_cmd(CmdLHistory())
            self.init_cmd(CmdDate())
            self.init_cmd(CmdWhich())
            self.init_cmd(CmdTitle())
            self.init_cmd(CmdHelp())
            self.init_cmd(CmdFile())
            self.init_cmd(CmdOption())
            self.init_cmd(CmdOptions())
            self.init_cmd(CmdResetTerm())
            self.init_cmd(CmdToCrlf())
            self.init_cmd(CmdToLf())
            self.init_cmd(CmdToUtf8())
            self.init_cmd(CmdToUtf8Bom())
            self.init_cmd(CmdToLatin1())
            self.init_cmd(CmdWatch())
            self.init_cmd(CmdTime())
        self.history = []
        self.history_index = -1
        self.history_current = ""
        self.local_history = {}
        self.max_line_length = shutil.get_terminal_size().columns - 1
        self.current_stdin = None   # set transiently during pipeline dispatch
        os.system("")
        self.inp = RawInput()
        self.line = ""
        self.index = 0
        self._search_active = False   # True while Ctrl+R search mode is on
        self._search_query  = ""      # characters typed so far in search
        self._search_pos    = -1      # index into local_history list of current match
        self.info_pythonproj_cwd = None
        self.info_pythonproj_s = ""
        self.info_git_cwd = None
        self.info_git_s = ("", False)
        self.info_venv_cwd = None
        self.info_venv_s = ""
        self._git_executable = shutil.which("git")
        if init_shell:
            cfg = os.path.expanduser("~/.dabshell")
            if os.path.isfile(cfg):
                self.execute(f"source \"{cfg}\"", history=False)
        self.load_history()

    def init_cmd(self, cmd):
        self.env.set(cmd.name, cmd)

    def _set_title(self, title):
        """Set the terminal window title on all platforms."""
        if _VT_ENABLED:
            # OSC 0 sequence: works on Linux/macOS terminals and
            # Windows 10+ console with VT processing enabled.
            sys.stdout.write(f"\033]0;{title}\007")
            sys.stdout.flush()
        elif IS_WIN:
            os.system("title " + title)

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
        result = s + f"{esc}[38;5;87m" + self.cwd + f"{esc}[0m"
        clean_result = s + self.cwd
        if len(clean_result) > self.max_line_length:
            avail = self.max_line_length - len(clean_s) - 3
            if avail > 0:
                idx = len(self.cwd) - avail
                truncated = self.cwd[idx:]
                result = s + f"{esc}[38;5;87m..." + truncated + f"{esc}[0m"
        return result

    def info_pythonproj(self):
        if self.info_pythonproj_cwd == self.cwd:
            return self.info_pythonproj_s
        self.info_pythonproj_cwd = self.cwd
        self.info_pythonproj_s = ""
        if tomllib is None:
            return self.info_pythonproj_s
        projfile = os.path.join(self.cwd, "pyproject.toml")
        if os.path.exists(projfile):
            with open(projfile, "rb") as infile:
                cfg = tomllib.load(infile)
                proj = cfg.get("project")
                if proj:
                    self.info_pythonproj_s = "pr=" + proj.get("version", "")
        return self.info_pythonproj_s

    def info_git(self):
        if self.info_git_cwd == self.cwd:
            return self.info_git_s
        self.info_git_cwd = self.cwd
        self.info_git_s = ("", False)
        wd = self.cwd
        while not os.path.ismount(wd):
            gitdir = os.path.join(wd, ".git")
            if os.path.isdir(gitdir):
                break
            wd = os.path.dirname(wd)
        else:
            gitdir = None
        if gitdir and self._git_executable:
            p = subprocess.run(
                [
                    self._git_executable,
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
                self.info_git_s = (branch, modified)
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
            program = find_executable_venv(venvdir, "python")
            if program:
                p = subprocess.run(
                    [program, "--version"],
                    capture_output=True,
                    cwd=self.cwd,
                )
                pyver = p.stdout.decode("utf8").strip().split(" ")[1]
                self.info_venv_s = "py=" + pyver
        return self.info_venv_s

    def canon(self, path):
        if path is None:
            return None
        return os.path.normpath(os.path.abspath(path))

    def complete_word(self, word, only_dir=False):
        if word.startswith("\"") and word.endswith("\""):
            word = word[1:-1]
        potentials = []
        if not only_dir:
            for cname in self.env.names():
                if cname.startswith(word):
                    potentials.append(cname)
        for fname in os.listdir(self.cwd):
            if fname.startswith(word):
                if only_dir:
                    if os.path.isdir(os.path.join(self.cwd, fname)):
                        potentials.append(fname)
                else:
                    potentials.append(fname)
        if not potentials:
            # find completions for relative paths
            if os.path.isabs(word):
                pathfile = word
                path = os.path.dirname(pathfile)
                partial_path = path
            else:
                pathfile = os.path.join(self.cwd, word)
                path = os.path.dirname(pathfile)
                partial_path = path[len(self.cwd)+1:]
            file = os.path.basename(pathfile)
            try:
                if os.path.isdir(path):
                    for fname in os.listdir(path):
                        if fname.startswith(file):
                            if only_dir:
                                if os.path.isdir(os.path.join(path, fname)):
                                    potentials.append(
                                        os.path.join(partial_path, fname)
                                    )
                            else:
                                potentials.append(
                                    os.path.join(partial_path, fname)
                                )
            except Exception:
                pass  # ignore errors
        if not potentials and not only_dir:
            # find completions for executables in e.g. venv and PATH
            cmds = find_partial_executable(self.cwd, word)
            if cmds:
                potentials += cmds
        if not potentials:
            return None, []
        if len(potentials) == 1:
            return potentials[0], []
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
        return prefix, potentials

    def _search_match(self, query, from_pos):
        """Return (position, command) of the nearest match at or before from_pos.

        Searches self.local_history[self.cwd] in reverse (most-recent first).
        from_pos is an index into that list; pass -1 to start from the end.
        Returns (pos, cmd) or (None, None) when nothing matches.
        """
        entries = self.local_history.get(self.cwd, [])
        if not entries:
            return None, None
        if from_pos == -1 or from_pos >= len(entries):
            from_pos = len(entries) - 1
        for i in range(from_pos, -1, -1):
            _, cmd = entries[i]
            if query.lower() in cmd.lower():
                return i, cmd
        return None, None

    def _search_redraw(self, query, match):
        """Render the reverse-i-search prompt on the current terminal line."""
        match_str = match if match is not None else ""
        # Highlight the matching substring in the result
        if match is not None and query:
            idx = match.lower().find(query.lower())
            if idx >= 0:
                before = match[:idx]
                hit    = match[idx:idx+len(query)]
                after  = match[idx+len(query):]
                match_str = (
                    before
                    + f"{esc}[1m{esc}[4m" + hit + f"{esc}[0m"
                    + after
                )
        prefix = f"(reverse-i-search)`{query}': "
        # Truncate the visible part so the line never exceeds terminal width.
        # match_str may contain ANSI escapes; measure by visible length of match.
        visible_match = match if match is not None else ""
        avail = max(0, self.max_line_length - len(prefix))
        if len(visible_match) > avail:
            # Trim the un-highlighted match_str to the available space
            match_str = visible_match[:avail]
        prompt = prefix + match_str
        self.outp.out.write(f"{esc}[1000D")   # move to column 0
        self.outp.out.write(prompt)
        self.outp.out.write(f"{esc}[0K")       # erase to end of line
        self.outp.out.flush()

    def _redraw_line(self):
        """Write the current self.line to the terminal at the cursor position."""
        self.outp.out.write(f"{esc}[1000D")
        line = self.line
        index = self.index
        if len(line) > self.max_line_length:
            start = index - self.max_line_length // 2
            end = index + self.max_line_length // 2
            if start < 0:
                start = 0
                end = self.max_line_length
            elif end > len(line):
                end = len(line)
                start = end - self.max_line_length
            index -= start
            line = line[start:end]
        self.outp.out.write(line)
        self.outp.out.write(f"{esc}[0K")
        if self.index < len(self.line):
            self.outp.out.write(f"{esc}[1000D")
            if index > 0:
                self.outp.out.write(f"{esc}[{index}C")
        self.outp.out.flush()

    def run(self):
        self.outp.write(self.prompt() + "\n")
        tabbed = False
        try:
            while True:
                self.max_line_length = shutil.get_terminal_size().columns - 1
                key = self.inp.getch()
                if key is None:
                    continue   # unrecognised escape sequence — ignore silently

                # ── Reverse-i-search mode ────────────────────────────────────
                if self._search_active:
                    if key == KEY_CTRL_R:
                        # Cycle to the next older match
                        next_pos = self._search_pos - 1 if self._search_pos > 0 else -1
                        pos, match = self._search_match(self._search_query, next_pos)
                        if pos is not None:
                            self._search_pos = pos
                        self._search_redraw(
                            self._search_query,
                            match if pos is not None else None,
                        )
                        continue

                    elif key == KEY_BACKSPACE:
                        self._search_query = self._search_query[:-1]
                        pos, match = self._search_match(
                            self._search_query, -1
                        )
                        self._search_pos = pos if pos is not None else -1
                        self._search_redraw(self._search_query, match)
                        continue

                    elif key in (KEY_LF, KEY_CR):
                        # Accept: load match into line buffer ready for editing.
                        # Overwrite the search prompt in place — no new line needed.
                        entries = self.local_history.get(self.cwd, [])
                        if self._search_pos is not None and 0 <= self._search_pos < len(entries):
                            _, matched_cmd = entries[self._search_pos]
                        else:
                            matched_cmd = ""
                        self._search_active = False
                        self._search_query  = ""
                        self._search_pos    = -1
                        self.line  = matched_cmd
                        self.index = len(self.line)
                        self._redraw_line()
                        continue

                    elif key == KEY_UP:
                        # Cycle to the next older match (same as Ctrl+R)
                        next_pos = self._search_pos - 1 if self._search_pos > 0 else -1
                        pos, match = self._search_match(self._search_query, next_pos)
                        if pos is not None:
                            self._search_pos = pos
                        self._search_redraw(
                            self._search_query,
                            match if pos is not None else None,
                        )
                        continue

                    elif key == KEY_DOWN:
                        # Cycle to the next newer match
                        entries = self.local_history.get(self.cwd, [])
                        if self._search_pos is not None and self._search_pos < len(entries) - 1:
                            start = self._search_pos + 1
                            # Search forward from start toward the newest entry
                            match_found = None
                            pos_found = None
                            for i in range(start, len(entries)):
                                _, cmd = entries[i]
                                if self._search_query.lower() in cmd.lower():
                                    pos_found = i
                                    match_found = cmd
                                    break
                            if pos_found is not None:
                                self._search_pos = pos_found
                            self._search_redraw(self._search_query, match_found)
                        else:
                            # Already at newest match — nothing to do
                            entries = self.local_history.get(self.cwd, [])
                            match = None
                            if self._search_pos is not None and 0 <= self._search_pos < len(entries):
                                _, match = entries[self._search_pos]
                            self._search_redraw(self._search_query, match)
                        continue

                    elif key in (KEY_ESC, KEY_CTRL_C):
                        # Cancel: restore the line that was active before search
                        self._search_active = False
                        self._search_query  = ""
                        self._search_pos    = -1
                        self.outp.out.write(f"{esc}[1000D{esc}[0K")
                        self.outp.out.flush()
                        # self.line is unchanged — it held the pre-search content
                        self.index = len(self.line)
                        # Fall through to normal line-redraw

                    else:
                        # Printable character: refine the search query
                        if isinstance(key, str):
                            self._search_query += key
                            pos, match = self._search_match(self._search_query, -1)
                            self._search_pos = pos if pos is not None else -1
                            self._search_redraw(self._search_query, match)
                            continue
                        # Any other key (arrows, function keys, etc.): accept
                        # current match, exit search, then handle key normally.
                        entries = self.local_history.get(self.cwd, [])
                        if self._search_pos is not None and 0 <= self._search_pos < len(entries):
                            _, matched_cmd = entries[self._search_pos]
                        else:
                            matched_cmd = self.line  # nothing found — keep current
                        self._search_active = False
                        self._search_query  = ""
                        self._search_pos    = -1
                        self.outp.out.write(f"{esc}[1000D{esc}[0K")
                        self.outp.out.flush()
                        self.line  = matched_cmd
                        self.index = len(self.line)
                        # Do NOT continue — fall through so the key is processed

                # ── Normal editing mode ──────────────────────────────────────
                if key == KEY_CTRL_R:
                    # Enter search mode, saving whatever is in the line buffer
                    self._search_active = True
                    self._search_query  = ""
                    self._search_pos    = -1
                    self._search_redraw("", None)
                    continue

                if key == KEY_TAB:
                    cmd = None
                    rest = ""
                    if self.line.strip() and self.index == len(self.line):
                        cmd, args = split_command(
                            self.line,
                            self,
                            with_vars=False,
                        )
                    elif self.line.strip() and self.index < len(self.line) and self.line[self.index] == " ":
                        rest = self.line[self.index:]
                        cmd, args = split_command(
                            self.line[:self.index],
                            self,
                            with_vars=False,
                        )
                    if cmd:
                        parts = [cmd, *args]
                        word = parts[-1]
                        only_dir = cmd in ["cd"]
                        completed, potentials = self.complete_word(
                            word,
                            only_dir=only_dir,
                        )
                        if completed and parts[-1] != completed:
                            parts[-1] = completed
                            self.line = quote_args(parts) + rest
                            self.index = len(self.line)
                        elif tabbed:
                            if potentials:
                                self.outp.print()
                                s = " ".join([
                                    os.path.basename(p)
                                    for p in potentials
                                ])
                                if len(s) > self.max_line_length - 1:
                                    s = s[:self.max_line_length-4] + "..."
                                self.outp.print(s)
                            tabbed = False
                        else:
                            tabbed = True
                else:
                    tabbed = False

                if key == KEY_CTRL_C:
                    if self.line == "":
                        break
                    else:
                        os.system("")
                        self.outp.write("\n" + self.prompt() + "\n")
                        self.line = ""
                        self.index = 0
                        continue
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
                        except Exception as e:
                            self.oute.print(str(e))
                        os.system("")
                        self.outp.write(self.prompt() + "\n")
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
                    while idx >= 0 and self.line[idx] == " ":
                        idx -= 1
                    while idx >= 0 and self.line[idx] != " ":
                        idx -= 1
                    # idx is now -1 (delete to start) or pointing at a space
                    idx += 1
                    self.line = self.line[0:idx] + self.line[self.index:]
                    self.index = idx
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
                elif key == KEY_CTRL_LEFT:
                    if self.index == 0:
                        pass   # already at start, nothing to do
                    else:
                        new_idx = self.index - 1
                        while new_idx > 0 and self.line[new_idx] == ' ':
                            new_idx -= 1
                        while new_idx > 0 and self.line[new_idx] != ' ':
                            new_idx -= 1
                        # If we stopped at a space, step forward one to the word start
                        if new_idx > 0:
                            new_idx += 1
                        self.index = new_idx
                elif key == KEY_CTRL_RIGHT:
                    new_idx = self.index + 1
                    while new_idx < len(self.line) and self.line[new_idx] != ' ':
                        new_idx += 1
                    while new_idx < len(self.line) and self.line[new_idx] == ' ':
                        new_idx += 1
                    if new_idx < len(self.line):
                        self.index = new_idx
                    else:
                        self.index = len(self.line)
                elif isinstance(key, str):
                    pre = self.line[:self.index]
                    post = self.line[self.index:]
                    self.line = pre + key + post
                    self.index += 1

                self._redraw_line()

        finally:
            self.inp.close()

    def load_history(self):
        self.history = []
        self.history_index = -1
        self.history_current = ""
        self.local_history = {}
        fname = os.path.expanduser("~/.dabshell-history")
        if os.path.isfile(fname):
            entries = []
            with open(fname, encoding="utf8") as infile:
                for raw in infile:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        rec = raw.split("\t", 1)
                        if len(rec) == 2:
                            entries.append((rec[0], rec[1]))
                    except Exception:
                        pass
            if len(entries) > 1000:
                # compress older entries
                idx = len(entries) - 1000
                older = entries[0:idx]
                newer = entries[idx:]
                older = list(sorted(set(older)))
                entries = older + newer
                # write compressed entries to file
                with open(fname, "w", encoding="utf8") as outfile:
                    for path, command in entries:
                        outfile.write(
                            path.replace("\t", " ") + "\t"
                            + command.replace("\n", " ") + "\n"
                        )
            for idx, entry in enumerate(entries):
                path, command = entry
                self.history.append(command)
                if path not in self.local_history:
                    self.local_history[path] = []
                self.local_history[path].append((idx, command))

    def append_history(self, path, command):
        fname = os.path.expanduser("~/.dabshell-history")
        with open(fname, "a+", encoding="utf8") as outfile:
            # Use tab-separated path/command; strip embedded tabs/newlines
            safe_path = path.replace("\t", " ")
            safe_cmd = command.replace("\n", " ")
            outfile.write(safe_path + "\t" + safe_cmd + "\n")

    def execute(self, line, history=True):
        line = line.strip()
        if not line:
            return True
        cmd, args = split_command(line, self)
        if history and cmd != "history" and cmd != "lhistory":
            if not self.history or self.history[-1] != line:
                idx = len(self.history)
                self.history.append(line)
                if self.cwd not in self.local_history:
                    self.local_history[self.cwd] = []
                self.local_history[self.cwd].append((idx, line))
                self.append_history(self.cwd, line)
            self.history_index = -1
            self.history_current = ""
        if self.option_set("echo"):
            self.outs.print(
                f":: {cmd} {' '.join([quote_arg(a) for a in args])}"
            )
        # trigger prompt info update
        self.info_pythonproj_cwd = None
        self.info_git_cwd = None
        self.info_venv_cwd = None
        # Split on && only when not inside a quoted argument
        def split_and_and(line):
            parts = []
            current = ""
            in_quote = False
            i = 0
            while i < len(line):
                ch = line[i]
                if ch == '"' and not in_quote:
                    in_quote = True
                    current += ch
                elif ch == '"' and in_quote:
                    in_quote = False
                    current += ch
                elif (
                    not in_quote
                    and ch == "&"
                    and i + 1 < len(line)
                    and line[i + 1] == "&"
                ):
                    parts.append(current)
                    current = ""
                    i += 2
                    # skip optional surrounding spaces
                    while i < len(line) and line[i] == " ":
                        i += 1
                    continue
                else:
                    current += ch
                i += 1
            parts.append(current)
            return parts

        cmds = split_and_and(line)
        for cmd_segment in cmds:
            # Handle 'exit' before pipeline parsing so it returns False cleanly
            if cmd_segment.strip() == "exit":
                return False
            stages = parse_pipeline(cmd_segment)
            try:
                self.execute_pipeline(stages, history=history)
            except CommandFailedException:
                if self.option_set("stop-on-error"):
                    raise
            except KeyboardInterrupt:
                pass
        return True

    # ------------------------------------------------------------------
    # Pipeline execution
    # ------------------------------------------------------------------

    def execute_pipeline(self, stages, history=True):
        """Execute a list of Stage objects connected by pipes.

        Strategy:
        - Single stage: run directly against the shell's current outs/oute.
        - Multi-stage:  run all but the last stage with stdout captured into a
          StringOutput (internal) or a PIPE (external-only fast path when both
          adjacent stages are external), then feed the captured bytes/string as
          stdin to the next stage.  The last stage writes to the shell's real
          outs/oute, subject to any redirects on that stage.
        """
        if len(stages) == 1:
            self._run_stage(stages[0], stdin_data=None, history=history)
            return

        stdin_data = None   # str fed into the next stage
        for i, stage in enumerate(stages):
            is_last = (i == len(stages) - 1)
            if is_last:
                self._run_stage(stage, stdin_data=stdin_data, history=history)
            else:
                # Capture this stage's stdout into a string
                captured = StringOutput()
                saved_outs = self.outs
                self.outs = captured
                try:
                    self._run_stage(
                        stage, stdin_data=stdin_data, history=history,
                        # Ignore stop-on-error for intermediate stages so the
                        # pipe keeps flowing; errors still go to oute.
                        ignore_stop_on_error=True,
                    )
                except CommandFailedException:
                    pass
                finally:
                    self.outs = saved_outs
                stdin_data = captured.value()

    def _resolve_stage_outputs(self, stage):
        """Return (outs, oute, files_to_close) for the given Stage redirects.

        Opens any required FileOutput objects and returns the output objects to
        use for this stage, plus a list of FileOutput objects to close when done.
        """
        outs = self.outs
        oute = self.oute
        to_close = []

        if stage.both_file is not None:
            path = stage.both_file
            if not os.path.isabs(path):
                path = os.path.join(self.cwd, path)
            fo = FileOutput(path, append=stage.both_append)
            to_close.append(fo)
            outs = fo
            oute = fo
        else:
            if stage.stdout_file is not None:
                path = stage.stdout_file
                if not os.path.isabs(path):
                    path = os.path.join(self.cwd, path)
                fo = FileOutput(path, append=stage.stdout_append)
                to_close.append(fo)
                outs = fo
            if stage.stderr_file is not None:
                path = stage.stderr_file
                if not os.path.isabs(path):
                    path = os.path.join(self.cwd, path)
                fo = FileOutput(path, append=stage.stderr_append)
                to_close.append(fo)
                oute = fo

        return outs, oute, to_close

    def _run_stage(self, stage, stdin_data, history, ignore_stop_on_error=False):
        """Execute one Stage, applying its redirects and routing stdin_data."""
        outs, oute, to_close = self._resolve_stage_outputs(stage)
        saved_outs, saved_oute = self.outs, self.oute
        self.outs = outs
        self.oute = oute
        try:
            self._dispatch_stage(stage, stdin_data, history)
        except CommandFailedException:
            if not ignore_stop_on_error and self.option_set("stop-on-error"):
                raise
        finally:
            self.outs = saved_outs
            self.oute = saved_oute
            for fo in to_close:
                fo.close()

    def _dispatch_stage(self, stage, stdin_data, history):
        """Resolve aliases and dispatch a single stage to the right handler."""
        if not stage.raw:
            return
        cmd, args = split_command(stage.raw, self)
        if not cmd:
            return

        # Expand aliases
        cmd_ = self.env.get(cmd)
        if isinstance(cmd_, CmdAliasDefinition):
            cmd, args = split_command(
                cmd_.value + " " + quote_args(args), self,
            )
            cmd_ = self.env.get(cmd)

        if cmd_ and isinstance(cmd_, Cmd):
            # Internal command — pass stdin_data via shell.current_stdin
            self.current_stdin = (
                StringInput(stdin_data) if stdin_data is not None else None
            )
            try:
                cmd_.execute(self, args)
            finally:
                self.current_stdin = None
        elif cmd == "exit":
            # Handled at a higher level; returning False from execute() exits.
            # Inside a pipeline we just treat it as a no-op to keep things
            # simple — exit in a pipe is a degenerate case.
            pass
        elif cmd.endswith(".dsh"):
            self.current_stdin = (
                StringInput(stdin_data) if stdin_data is not None else None
            )
            try:
                self.env.get("script").execute(self, [cmd, *args])
            finally:
                self.current_stdin = None
        else:
            self._run_external(cmd, args, stdin_data, history)

    def _run_external(self, cmd, args, stdin_data, history):
        """Run an external process, wiring stdin/stdout/stderr correctly.

        - stdin_data: str or None.  When not None, it is passed to the process
          as its standard input.
        - stdout/stderr are routed to the current shell.outs/oute.
          If those are StringOutput or FileOutput we capture/pipe; if they are
          StdOutput/StdError we pass the underlying file object directly so that
          the process output streams straight to the terminal without buffering.
        """
        try:
            executable = self.canon(find_executable(self.cwd, cmd))
            if executable is None:
                self.oute.print(f"ERR: {cmd} not found")
                raise CommandFailedException()
            if executable.endswith(".dsh"):
                self.current_stdin = (
                    StringInput(stdin_data) if stdin_data is not None else None
                )
                try:
                    self.env.get("script").execute(self, [executable, *args])
                finally:
                    self.current_stdin = None
                return

            stdin_bytes = (
                stdin_data.encode("utf-8") if stdin_data is not None else None
            )

            # Determine whether we can hand the OS file handle directly to
            # the subprocess (fast path) or must capture (StringOutput /
            # FileOutput without a raw OS handle, or stdin_data present).
            outs_direct = isinstance(self.outs, (StdOutput, FileOutput))
            oute_direct = isinstance(self.oute, (StdError, StdOutput, FileOutput))
            use_capture = (not outs_direct) or (not oute_direct)

            if use_capture:
                p = subprocess.run(
                    [executable, *args],
                    cwd=self.cwd,
                    env=get_os_env(self.env),
                    input=stdin_bytes,
                    capture_output=True,
                )
                self.outs.write(p.stdout.decode("utf-8", errors="replace"))
                self.oute.write(p.stderr.decode("utf-8", errors="replace"))
            else:
                p = subprocess.run(
                    [executable, *args],
                    cwd=self.cwd,
                    env=get_os_env(self.env),
                    input=stdin_bytes,
                    stdout=self.outs.out,
                    stderr=self.oute.out,
                )
            if p.returncode != 0:
                raise CommandFailedException()
            if history:
                shell._set_title(shell.title)
        except CommandFailedException:
            raise
        except Exception as e:
            self.oute.print(str(e))


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


class CmdConvertBase(Cmd):
    """Shared implementation for in-place text-file conversion commands."""

    def _convert(self, shell, args, transform):
        """Read each file, apply *transform(raw) -> (new_raw, reason)*, write back.

        *transform* receives the raw bytes and returns (new_bytes, skipped_reason)
        where skipped_reason is None on success or a string explaining why the
        file was skipped unchanged.
        """
        if not args:
            shell.oute.print(f"ERR: {self.name} requires at least one file")
            return
        files = _collect_files(shell, args)
        for path in files:
            if not os.path.exists(path):
                shell.oute.print(f"ERR: {path} not found")
                continue
            if os.path.isdir(path):
                shell.oute.print(f"ERR: {path} is a directory")
                continue
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
            except OSError as e:
                shell.oute.print(f"ERR: {path}: {e}")
                continue
            if _is_binary(raw):
                shell.oute.print(f"skipped {path}: binary file")
                continue
            new_raw, reason = transform(raw)
            if reason:
                shell.outs.print(f"skipped {path}: {reason}")
            elif new_raw == raw:
                shell.outs.print(f"unchanged {path}")
            else:
                try:
                    with open(path, "wb") as fh:
                        fh.write(new_raw)
                    shell.outs.print(f"converted {path}")
                except OSError as e:
                    shell.oute.print(f"ERR: {path}: {e}")


class CmdAliasDefinition(Cmd):
    def __init__(self, name, value):
        Cmd.__init__(self, name)
        self.value = value

    def __repr__(self):
        return f"{self.name}={self.value}"

    def __str__(self):
        return self.name


class CmdAlias(Cmd):
    def __init__(self):
         Cmd.__init__(self, "alias")

    def help(self):
        return "[<name> [<value> | -]]   : set, list or remove alias"

    def execute(self, shell, args):
        if not args:
            for name in shell.env.names():
                alias = shell.env.get(name)
                if isinstance(alias, CmdAliasDefinition):
                    shell.outs.print(f"{alias.name} = {alias.value}")
        else:
            name = args[0]
            value = quote_args(args[1:]) if len(args) > 1 else None
            if value == "-":
                alias = shell.env.get(name)
                if isinstance(alias, CmdAliasDefinition):
                    shell.env.remove(name)
            elif value is None:
                alias = shell.env.get(name)
                if isinstance(alias, CmdAliasDefinition):
                    shell.outs.print(f"{alias.name} = {alias.value}")
            else:
                existing = shell.env.get(name)
                if isinstance(existing, Cmd) and not isinstance(existing, CmdAliasDefinition):
                    shell.oute.print(f"ERR: {name} is a builtin command and cannot be aliased")
                else:
                    alias = CmdAliasDefinition(name, value)
                    shell.env.set(name, alias)


class CmdOptions(Cmd):
    def __init__(self):
         Cmd.__init__(self, "options")

    def help(self):
        return "<options>   : list currently active options"

    def execute(self, shell, args):
        for option, value in shell.options.items():
            shell.outs.print(f"{option} {value}")


class CmdOption(Cmd):
    def __init__(self):
         Cmd.__init__(self, "option")

    def help(self):
        return "<option> [<value>]   : gets/sets options"

    def execute(self, shell, args):
        option = args[0]
        if len(args) > 1:
            value = args[1]
            if option in ["echo", "stop-on-error"]:
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
        stdin_data = None
        if shell.current_stdin is not None:
            stdin_data = "".join(shell.current_stdin.readlines())
        shell._run_external(cmd, args, stdin_data, history=True)


def evaluate_expression(expr, shell):
    a, b = split_command(expr, shell)
    parts = [a, *b]
    if len(parts) == 3:
        lhs = parts[0]
        op = parts[1]
        rhs = parts[2]
        if op == "<":
            return int(lhs) < int(rhs)
        elif op == "<=":
            return int(lhs) <= int(rhs)
        elif op == ">":
            return int(lhs) > int(rhs)
        elif op == ">=":
            return int(lhs) >= int(rhs)
        elif op == "+":
            return int(lhs) + int(rhs)
        elif op == "-":
            return int(lhs) - int(rhs)
        elif op == "*":
            return int(lhs) * int(rhs)
        elif op == "/":
            return int(lhs) // int(rhs)
        elif op == "%":
            return int(lhs) % int(rhs)
        elif op == "**":
            return int(lhs) ** int(rhs)
        elif op == "==":
            return lhs == rhs
        elif op == "!=":
            return lhs != rhs
        elif op == "==|ci":
            lhs = lhs.lower()
            rhs = rhs.lower()
            return lhs == rhs
        elif op == "!=|ci":
            lhs = lhs.lower()
            rhs = rhs.lower()
            return lhs != rhs
        elif op == "*=":
            return lhs.endswith(rhs) or rhs.endswith(lhs)
        elif op == "=*":
            return lhs.startswith(rhs) or rhs.startswith(lhs)
        elif op == "*=|ci":
            lhs = lhs.lower()
            rhs = rhs.lower()
            return lhs.endswith(rhs) or rhs.endswith(lhs)
        elif op == "=*|ci":
            lhs = lhs.lower()
            rhs = rhs.lower()
            return lhs.startswith(rhs) or rhs.startswith(lhs)
        else:
            raise ValueError(f"unknown operator {op}")
    elif len(parts) == 2:
        pred = parts[0]
        value = parts[1]
        if pred == "exists":
            if not os.path.isabs(value):
                value = os.path.join(shell.cwd, value)
            if os.path.exists(value):
                return "yes"
            else:
                return ""
        elif pred == "not-exists" or pred == "exists-not":
            if not os.path.isabs(value):
                value = os.path.join(shell.cwd, value)
            if not os.path.exists(value):
                return "yes"
            else:
                return ""
        elif pred == "is-file":
            if not os.path.isabs(value):
                value = os.path.join(shell.cwd, value)
            if os.path.isfile(value):
                return "yes"
            else:
                return ""
        elif pred == "not-is-file" or pred == "is-not-file":
            if not os.path.isabs(value):
                value = os.path.join(shell.cwd, value)
            if os.path.isfile(value):
                return ""
            else:
                return "yes"
        elif pred == "is-dir":
            if not os.path.isabs(value):
                value = os.path.join(shell.cwd, value)
            if os.path.isdir(value):
                return "yes"
            else:
                return ""
        elif pred in ("not-is-dir", "is-not-dir"):
            if not os.path.isabs(value):
                value = os.path.join(shell.cwd, value)
            if os.path.isdir(value):
                return ""
            else:
                return "yes"
        elif pred == "has-extension":
            base, ext = os.path.splitext(value)
            if ext == value:
                return "yes"
            else:
                return ""
        elif pred in ("not-has-extension", "has-not-extension"):
            base, ext = os.path.splitext(value)
            if ext == value:
                return ""
            else:
                return "yes"
        elif pred == "is-empty":
            if value == "":
                return "yes"
            else:
                return ""
        elif pred == "not-is-empty" or pred == "is-not-empty":
            if value == "":
                return ""
            else:
                return "yes"
        else:
            raise ValueError(f"unknown pred {pred}")
    elif len(parts) == 1:
        arg = parts[0]
        try:
            return int(arg)
        except Exception:
            return arg
    raise ValueError(f"cannot evaluate {expr}")


class CmdEval(Cmd):
    def __init__(self):
         Cmd.__init__(self, "eval")

    def help(self):
        return (
            "(<arg> <op> <arg> | <predicate> <arg>  | <arg>)   "
            ": Evaluates the expression"
        )

    def execute(self, shell, args):
        result = evaluate_expression(quote_args(args), shell)
        shell.outs.print(result)


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
        scriptshell.env.set("args", quote_args(args))
        with open(scriptfile, encoding="utf8") as infile:
            try:
                self.execute_lines(scriptshell, infile.readlines())
            except KeyboardInterrupt:
                pass

    def execute_lines(self, shell, lines):
        lines = [line.strip() for line in lines]
        lines = [line for line in lines if line and not line.startswith("#")]
        stmt, stmt_lines, idx = self.get_statement(lines, 0)
        while stmt:
            if stmt == "single":
                try:
                    shell.execute(stmt_lines[0], history=False)
                except CommandFailedException:
                    if shell.option_set("stop-on-error"):
                        break
            elif stmt == "if":
                condition = stmt_lines[0][len("if "):].strip()
                body = stmt_lines[1:]
                value = evaluate_expression(condition, shell)
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
                value = evaluate_expression(condition, shell)
                while value:
                    if not self.execute_lines(shell, body):
                        break
                    value = evaluate_expression(condition, shell)
            elif stmt == "def":
                params = [
                    name.strip()
                    for name in stmt_lines[0][len("def "):].split(" ")
                    if name.strip()
                ]
                name = params[0]
                params = params[1:]
                body = stmt_lines[1:]
                proc = CmdProcedure(name, params, body, shell.env)
                shell.env.set(name, proc)
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
                    or line.startswith("def ")
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
                    or line.startswith("def ")
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
                    or line.startswith("def ")
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
        elif line.startswith("def "):
            stmt = "def"
            stmt_lines = [line]
            idx += 1
            depth = 0
            while idx < len(lines):
                line = lines[idx]
                if (
                    line.startswith("if ")
                    or line.startswith("for ")
                    or line.startswith("while ")
                    or line.startswith("def ")
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


class CmdProcedure(CmdScript):
    def __init__(self, name, params, body, lexenv):
         Cmd.__init__(self, name)
         self.lexenv = lexenv
         self.params = params
         self.body = body

    def help(self):
        return f"{self.name} {' '.join(self.args)}  : custom procedure"

    def execute(self, shell, args):
        env = Env(self.lexenv)
        for idx, name in enumerate(self.params):
            arg = args[idx] if idx < len(args) else ""
            env.set(name, arg)
        procshell = Dabshell(shell)
        procshell.env = env
        self.execute_lines(procshell, self.body)


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
        opts = []
        dirs = []
        for arg in args:
            if arg.startswith("-"):
                opts_ = list(arg[1:])
                opts += opts_
            else:
                dirs.append(arg)
        opts = set(opts)
        if len(dirs) == 0:
            self.ls(shell, shell.canon(shell.cwd), opts)
            return
        files = []
        for filename in dirs:
            allfiles = glob.glob(filename)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(filename)
        for path in files:
            if os.path.isabs(path):
                path = shell.canon(path)
            else:
                path = shell.canon(os.path.join(shell.cwd, path))
            self.ls(shell, path, opts)

    def get_entry(self, shell, path, opts):
        entry = {
            "name": os.path.basename(path),
            "path": path,
            "timestamp": "",
            "size": 0,
        }
        try:
            s = os.lstat(path)
            t = time.gmtime(s.st_mtime)
            entry["timestamp"] = (
                f"{t.tm_year}-{t.tm_mon:02}-{t.tm_mday:02} "
                f"{t.tm_hour:02}:{t.tm_min:02}:{t.tm_sec:02}"
            )
            entry["size"] = s.st_size
        except OSError:
            pass  # broken symlink or race condition; leave defaults
        return entry

    def ls(self, shell, path, opts):
        entries = []
        if os.path.isdir(path):
            for fname in os.listdir(path):
                fpath = os.path.join(path, fname)
                entries.append(self.get_entry(shell, fpath, opts))
        elif os.path.isfile(path):
            entries.append(self.get_entry(shell, path, opts))
        else:
            if not os.path.exists(path):
                shell.oute.print(f"ERR: {path} not found")
            else:
                shell.oute.print(f"ERR: {path} is not a directory")

        if "t" in opts:
            if "r" in opts:
                entries.sort(key=lambda x: x["timestamp"])
            else:
                entries.sort(key=lambda x: x["timestamp"], reverse=True)
        elif "S" in opts:
            if "r" in opts:
                entries.sort(key=lambda x: x["size"])
            else:
                entries.sort(key=lambda x: x["size"], reverse=True)
        else:
            if "r" in opts:
                entries.sort(key=lambda x: x["name"], reverse=True)
            else:
                entries.sort(key=lambda x: x["name"])

        for entry in entries:
            fname = entry["name"]
            if isinstance(shell.outs, StdOutput):
                if os.path.isdir(entry["path"]):
                    pname = f"{esc}[34m{fname}{esc}[0m"
                else:
                    pname = fname
            else:
                pname = fname
            if "l" in opts:
                shell.outs.print(
                    f"{entry['size']:10} {entry['timestamp']} {pname}",
                )
            else:
                shell.outs.print(pname)


class CmdCd(Cmd):
    def __init__(self):
        Cmd.__init__(self, "cd")

    def help(self):
        return "<dir>   : changes the current directory"

    def execute(self, shell, args):
        if len(args) == 0:
            shell.cwd = shell.canon(os.path.expanduser("~"))
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
        if len(args) < 2:
            shell.oute.print("ERR: set requires a name and a value")
            return
        name = args[0]
        if args[1] == "exec":
            value = shell_exec(quote_args(args[2:]), shell)
        elif args[1] == "eval":
            value = evaluate_expression(quote_args(args[2:]), shell)
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
            if not args:
                for name in shell.env.names():
                    shell.outs.print(
                        f"{name}={shell.env.get(name)}"
                    )
            else:
                shell.outs.print(shell.env.get(args[0]))
        except ValueError:
            pass


class CmdCat(Cmd):
    def __init__(self):
        Cmd.__init__(self, "cat")

    def help(self):
        return "[<file> ...]   : prints the contents of the files"

    def execute(self, shell, args):
        # If no files given and we have piped stdin, pass it through
        if not args and shell.current_stdin is not None:
            for line in shell.current_stdin:
                shell.outs.write(line)
            return
        files = []
        for filename in args:
            if not os.path.isabs(filename):
                filename = os.path.normpath(os.path.join(shell.cwd, filename))
            allfiles = glob.glob(filename)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(filename)
        for filename in files:
            if not os.path.exists(filename):
                shell.oute.print(f"ERR: {filename} not found")
                continue
            if os.path.isdir(filename):
                shell.oute.print(f"ERR: {filename}: is a directory")
                continue
            with open(
                filename,
                "rb"
            ) as infile:
                encoding = "utf8"
                for line in infile:
                    try:
                        shell.outs.write(line.decode(encoding))
                    except Exception:
                        if encoding == "utf8":
                            encoding = "Latin1"
                        else:
                            encoding = "utf8"
                        try:
                            shell.outs.write(line.decode(encoding))
                        except Exception:
                            pass


class CmdDiff(Cmd):
    def __init__(self):
        Cmd.__init__(self, "diff")

    def help(self):
        return (
            "<file1> <file2>"
            " : shows the differences between the two text files"
        )

    def execute(self, shell, args):
        files = []
        for filename in args:
            if not os.path.isabs(filename):
                filename = shell.canon(os.path.join(shell.cwd, filename))
            allfiles = glob.glob(filename)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(filename)
        if len(files) < 2:
            shell.oute.print("ERR: diff requires two files")
            return
        cwd = shell.canon(shell.cwd)
        file1 = files[0]
        file2 = files[1]
        if not os.path.exists(file1):
            shell.oute.print(f"ERR: {file1} not found")
            return 
        if not os.path.exists(file2):
            shell.oute.print(f"ERR: {file2} not found")
            return
        lines1 = []
        with open(file1, "rb") as infile:
            encoding = "utf8"
            for line in infile:
                try:
                    lines1.append(line.decode(encoding))
                except Exception:
                    if encoding == "utf8":
                        encoding = "Latin1"
                    else:
                        encoding = "utf8"
                    try:
                        lines1.append(line.decode(encoding))
                    except Exception:
                        raise ValueError(f"ERR: {file1} unknown encoding")
        lines2 = []
        with open(file2, "rb") as infile:
            encoding = "utf8"
            for line in infile:
                try:
                    lines2.append(line.decode(encoding))
                except Exception:
                    if encoding == "utf8":
                        encoding = "Latin1"
                    else:
                        encoding = "utf8"
                    try:
                        lines2.append(line.decode(encoding))
                    except Exception:
                        raise ValueError(f"ERR: {file2} unknown encoding")
        shell.outs.print("".join(difflib.ndiff(lines1, lines2)))


class CmdWc(Cmd):
    def __init__(self):
        Cmd.__init__(self, "wc")

    def help(self):
        return (
            "<file> ... "
            " : returns the number of lines of the files"
        )

    def execute(self, shell, args):
        files = []
        for filename in args:
            if not os.path.isabs(filename):
                filename = shell.canon(os.path.join(shell.cwd, filename))
            allfiles = glob.glob(filename)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(filename)
        # If no files given and we have piped stdin, count that instead
        if not files and shell.current_stdin is not None:
            count = sum(1 for _ in shell.current_stdin)
            shell.outs.print(f"(stdin) {count}")
            return
        cwd = shell.canon(shell.cwd)
        total = 0
        counted = 0
        for filename in files:
            if not os.path.exists(filename):
                shell.oute.print(f"ERR: {filename} not found")
                continue
            if os.path.isdir(filename):
                continue  # silently skip directories
            fname = filename
            if fname.startswith(cwd):
                fname = fname[len(cwd)+1:]
            with open(filename, "rb") as infile:
                lines = infile.readlines()
                count = len(lines)
                shell.outs.print(f"{fname} {count}")
                total += count
                counted += 1
        if counted > 1:
            shell.outs.print(f"Total {total}")


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
                    n = int(arg[len("--lines="):])
            else:
                filenames.append(arg)
            idx += 1

        files = []
        for filename in filenames:
            if not os.path.isabs(filename):
                filename = shell.canon(os.path.join(shell.cwd, filename))
            allfiles = glob.glob(filename)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(filename)
        # If no files and we have piped stdin, buffer and tail it
        if not files and shell.current_stdin is not None:
            lines = list(shell.current_stdin)
            for line in lines[-n:]:
                shell.outs.write(line)
            return
        for filename in files:
            if not os.path.exists(filename):
                shell.oute.print(f"ERR: {filename} not found")
                continue
            if os.path.isdir(filename):
                continue  # silently skip directories
            with open(filename, "rb") as infile:
                tail_bytes = self._tail_bytes(infile, n)
                encoding = "utf8"
                try:
                    text = tail_bytes.decode(encoding)
                except UnicodeDecodeError:
                    encoding = "Latin1"
                    text = tail_bytes.decode(encoding)
                shell.outs.write(text)
                if "-f" in args or "--follow" in args:
                    while True:
                        try:
                            line = infile.readline()
                            if line:
                                try:
                                    shell.outs.write(line.decode(encoding))
                                except Exception:
                                    encoding = "Latin1" if encoding == "utf8" else "utf8"
                                    try:
                                        shell.outs.write(line.decode(encoding))
                                    except Exception:
                                        pass
                            else:
                                time.sleep(1)
                        except KeyboardInterrupt:
                            break

    def _tail_bytes(self, infile, n):
        """Return the raw bytes of the last *n* lines of *infile*.

        Seeks backwards through the file in chunks so that only a small
        portion of a large file is ever read into memory.  The file must
        be opened in binary mode and support seeking (regular files do).
        """
        if n == 0:
            return b""

        CHUNK = 1024 * 8

        infile.seek(0, 2)           # seek to end
        file_size = infile.tell()
        if file_size == 0:
            return b""

        # Determine the scan ceiling: if the file ends with '\n' that
        # newline terminates the last line but is not a separator before
        # more content, so we skip it when counting.  We still include
        # it in the final output.
        infile.seek(-1, 2)
        ends_with_nl = infile.read(1) == b"\n"
        scan_end = file_size - 1 if ends_with_nl else file_size

        # Scan backwards through the file counting newlines.
        # We need to find n newlines to isolate the last n lines.
        newlines_found = 0
        pos = scan_end          # current scan position (exclusive upper bound)
        start = 0               # byte offset of first desired line (default: whole file)

        while pos > 0:
            chunk_size = min(CHUNK, pos)
            pos -= chunk_size
            infile.seek(pos)
            chunk = infile.read(chunk_size)
            for i in range(len(chunk) - 1, -1, -1):
                if chunk[i] == ord(b"\n"):
                    newlines_found += 1
                    if newlines_found == n:
                        start = pos + i + 1
                        infile.seek(start)
                        return infile.read()
            # Haven't found enough newlines yet; keep going

        # Reached the beginning of the file before finding n newlines:
        # the file has fewer than n lines — return everything.
        infile.seek(0)
        return infile.read()


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
                    n = int(arg[len("--lines="):])
            else:
                filenames.append(arg)
            idx += 1

        files = []
        for filename in filenames:
            if not os.path.isabs(filename):
                filename = shell.canon(os.path.join(shell.cwd, filename))
            allfiles = glob.glob(filename)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(filename)
        # If no files and we have piped stdin, read from it
        if not files and shell.current_stdin is not None:
            encoding = "utf8"
            for i in range(n):
                line = shell.current_stdin.readline()
                if not line:
                    break
                shell.outs.write(line)
            return
        for filename in files:
            if not os.path.exists(filename):
                shell.oute.print(f"ERR: {filename} not found")
                continue
            if os.path.isdir(filename):
                shell.oute.print(f"ERR: {filename}: is a directory")
                continue
            with open(filename, "rb") as infile:
                encoding = "utf8"
                for i in range(n):
                    line = infile.readline()
                    if not line:
                        break
                    try:
                        shell.outs.write(line.decode(encoding))
                    except Exception:
                        if encoding == "utf8":
                            encoding = "Latin1"
                        else:
                            encoding = "utf8"
                        try:
                            shell.outs.write(line.decode(encoding))
                        except Exception:
                            pass


class CmdEcho(Cmd):
    def __init__(self):
        Cmd.__init__(self, "echo")

    def help(self):
        return "<value> : echoes the value"

    def execute(self, shell, args):
        shell.outs.print(quote_args(args))


class CmdPrint(Cmd):
    def __init__(self):
        Cmd.__init__(self, "print")

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
        if len(args) < 2:
            shell.oute.print("ERR: cp requires at least two arguments")
            return
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
        files = []
        for source in sources:
            if not os.path.isabs(source):
                source = os.path.join(shell.cwd, source)
            allfiles = glob.glob(source)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(source)
        for source in files:
            if not os.path.isfile(source):
                shell.oute.print(f"ERR: {source} not found")
                continue
            try:
                shutil.copy(source, dest)
            except Exception as e:
                shell.oute.print(str(e))
                raise CommandFailedException()


class CmdMv(Cmd):
    def __init__(self):
        Cmd.__init__(self, "mv")

    def help(self):
        return "<src>... <dest> : moves one or multiple files or dirs"

    def execute(self, shell, args):
        if len(args) < 2:
            shell.oute.print("ERR: mv requires at least two arguments")
            return
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
        files = []
        for source in sources:
            if not os.path.isabs(source):
                source = os.path.join(shell.cwd, source)
            allfiles = glob.glob(source)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(source)
        for source in files:
            if not os.path.exists(source):
                shell.oute.print(f"ERR: {source} not found")
                continue
            if os.path.isfile(source):
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
            elif os.path.isdir(source):
                try:
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
            try:
                for path_ in self.walk(path):
                    if filters:
                        fname = os.path.basename(path_)
                        for flt in filters:
                            if (
                                flt.startswith("*") and
                                fname.endswith(flt[1:])
                            ):
                                shell.outs.print(path_)
                                break
                            elif (
                                flt.endswith("*") and
                                fname.startswith(flt[:-1])
                            ):
                                shell.outs.print(path_)
                                break
                            elif flt == fname:
                                shell.outs.print(path_)
                                break
                    else:
                        shell.outs.print(path_)
            except KeyboardInterrupt:
                pass

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
        paths = []
        for path in args:
            if not os.path.isabs(path):
                path = os.path.join(shell.cwd, path)
            matched = glob.glob(path)
            if matched:
                paths.extend(matched)
            else:
                # No match: treat as a new file to create
                paths.append(path)
        for path in paths:
            if os.path.isdir(path):
                shell.oute.print(f"ERR: {path}: is a directory")
                continue
            try:
                if os.path.exists(path):
                    os.utime(path)
                else:
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
                if os.path.isdir(path):
                    shell.oute.print(f"ERR: {path}: is a directory")
                    continue
                if not os.path.isfile(path):
                    shell.oute.print(f"ERR: {path} not found")
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
        for path in args:
            if not os.path.isabs(path):
                path = os.path.join(shell.cwd, path)
            if os.path.isfile(path):
                shell.oute.print(f"ERR: {path} already exists")
                continue
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
        files = []
        for path in args:
            if not os.path.isabs(path):
                path = os.path.join(shell.cwd, path)
            allfiles = glob.glob(path)
            if allfiles:
                for file in allfiles:
                    files.append(file)
            else:
                files.append(path)
        for path in files:
            if os.path.isfile(path):
                shell.oute.print(f"ERR: {path} is a file")
                continue
            if not os.path.exists(path):
                shell.oute.print(f"ERR: {path} not found")
                continue
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


class CmdGetExt(Cmd):
    def __init__(self):
        Cmd.__init__(self, "get-ext")

    def help(self):
        return "<filename> : returns the file extension"

    def execute(self, shell, args):
        shell.outs.print(os.path.splitext(args[0])[1])


class CmdRemoveExt(Cmd):
    def __init__(self):
        Cmd.__init__(self, "remove-ext")

    def help(self):
        return "<filename> : returns the filename without extension"

    def execute(self, shell, args):
        shell.outs.print(os.path.splitext(args[0])[0])


class CmdHistory(Cmd):
    def __init__(self):
        Cmd.__init__(self, "history")

    def help(self):
        return (
            "[<filter>]   : shows the history of commands, optionally filtered"
        )

    def execute(self, shell, args):
        if not args:
            last = None
            for index, line in enumerate(shell.history):
                if line != last:
                    shell.outs.print(f"{index} {line}")
                    last = line
        else:
            query = " ".join(args).lower()
            last = None
            for index, line in enumerate(shell.history):
                if line != last and line.lower().find(query) != -1:
                    shell.outs.print(f"{index} {line}")
                    last = line


class CmdLHistory(Cmd):
    def __init__(self):
        Cmd.__init__(self, "lhistory")

    def help(self):
        return (
            "[<filter>]   : shows the history of commands, "
            "optionally filtered, only for the current directory"
        )

    def execute(self, shell, args):
        if shell.cwd not in shell.local_history:
            return
        if not args:
            last = None
            for index, line in shell.local_history[shell.cwd]:
                if line != last:
                    shell.outs.print(f"{index} {line}")
                    last = line
        else:
            query = " ".join(args).lower()
            last = None
            for index, line in shell.local_history[shell.cwd]:
                if line != last and line.lower().find(query) != -1:
                    shell.outs.print(f"{index} {line}")
                    last = line


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
                shell.outs.print(f"{arg}: internal command")
            location = find_executable(shell.cwd, arg)
            if location:
                shell.outs.print(shell.canon(location))


class CmdGrep(Cmd):
    def __init__(self):
        Cmd.__init__(self, "grep")

    def help(self):
        return (
            "<pattern> [-i] [-v] [-q] [<location>...]   : "
            "searches the pattern in the files at location"
        )

    def execute(self, shell, args):
        self.case_sensitive = True
        self.invert = False
        self.quiet = False
        args_ = []
        for arg in args:
            if arg == "-q":
                self.quiet = True
            elif arg == "-i":
                self.case_sensitive = False
            elif arg == "-v":
                self.invert = True
            else:
                args_.append(arg)
        pattern = args_[0]
        locations = args_[1:]
        # If no locations given and we have piped stdin, grep that instead
        if not locations and shell.current_stdin is not None:
            try:
                for linenr, line in enumerate(shell.current_stdin, 1):
                    line_stripped = line.rstrip("\n").rstrip("\r")
                    if self.case_sensitive:
                        match = re.match(f".*({pattern})", line_stripped)
                    else:
                        match = re.match(
                            f".*({pattern.lower()})", line_stripped.lower()
                        )
                    if self.invert:
                        match = not match
                    if match:
                        if self.quiet:
                            shell.outs.print(line_stripped)
                        else:
                            shell.outs.print(f"{linenr}: {line_stripped}")
            except KeyboardInterrupt:
                pass
            return
        if not locations:
            locations = ["."]
        try:
            files = []
            for path in self.walk(shell.cwd, locations):
                files.append(path)
            for path in files:
                self.grep(shell, pattern, path, len(files) == 1)
        except KeyboardInterrupt:
            pass

    def grep(self, shell, pattern, filepath, single_file):
        if not os.path.exists(filepath):
            return
        if filepath.startswith(shell.cwd):
            relpath = filepath[len(shell.cwd)+1:]
        else:
            relpath = filepath
        with open(filepath, encoding="utf8", errors="ignore") as infile:
            linenr = 1
            for line in infile:
                if self.case_sensitive:
                    match = re.match(f".*({pattern})", line)
                else:
                    match = re.match(f".*({pattern.lower()})", line.lower())
                if self.invert:
                    match = not match
                if match:
                    line = line.strip()
                    if self.quiet:
                        shell.outs.print(line)
                    elif single_file:
                        shell.outs.print(f"{linenr}: {line}")
                    else:
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
            "<title>   : sets the terminal window title"
        )

    def execute(self, shell, args):
        shell.title = " ".join(args)
        shell._set_title(shell.title)


class CmdResetTerm(Cmd):
    def __init__(self):
        Cmd.__init__(self, "reset-term")

    def help(self):
        return (
            "Resets the terminal"
        )

    def execute(self, shell, args):
        os.system("")


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

class CmdFile(Cmd):
    def __init__(self):
        Cmd.__init__(self, "file")

    def help(self):
        return "<file>...   : detect and describe the type of each file"

    # ── extension → label ────────────────────────────────────────────────
    _EXT = {
        # Python
        ".py": "Python source", ".pyi": "Python stub",
        # JavaScript / TypeScript
        ".js": "JavaScript source", ".mjs": "JavaScript source",
        ".cjs": "JavaScript source",
        ".ts": "TypeScript source", ".tsx": "TypeScript source",
        ".jsx": "React/JSX source",
        # JVM
        ".java": "Java source", ".kt": "Kotlin source",
        ".kts": "Kotlin script", ".scala": "Scala source",
        # C family
        ".c": "C source", ".h": "C header",
        ".cpp": "C++ source", ".cc": "C++ source",
        ".cxx": "C++ source", ".hpp": "C++ header",
        ".cs": "C# source",
        # Systems
        ".go": "Go source", ".rs": "Rust source",
        ".swift": "Swift source",
        # Dynamic / scripting
        ".rb": "Ruby source", ".php": "PHP source",
        ".lua": "Lua source", ".pl": "Perl source", ".pm": "Perl module",
        ".r": "R source", ".R": "R source",
        ".jl": "Julia source",
        # Functional
        ".hs": "Haskell source", ".lhs": "Haskell literate source",
        ".ml": "OCaml source", ".mli": "OCaml interface",
        ".fs": "F# source", ".fsi": "F# interface", ".fsx": "F# script",
        ".clj": "Clojure source", ".cljs": "ClojureScript source",
        ".ex": "Elixir source", ".exs": "Elixir script",
        ".erl": "Erlang source", ".hrl": "Erlang header",
        ".scm": "Scheme source", ".sld": "Scheme library definition",
        ".lsp": "Common Lisp source", ".lisp": "Common Lisp source",
        # Shell
        ".sh": "Shell script", ".bash": "Bash script",
        ".zsh": "Zsh script", ".fish": "Fish script",
        ".bat": "Windows batch script", ".cmd": "Windows batch script",
        ".ps1": "PowerShell script", ".psm1": "PowerShell module",
        ".dsh": "dabshell script",
        # Web / markup
        ".html": "HTML document", ".htm": "HTML document",
        ".css": "CSS stylesheet",
        ".scss": "SCSS stylesheet", ".sass": "Sass stylesheet",
        ".less": "Less stylesheet",
        ".xml": "XML document", ".xsd": "XML schema",
        ".xsl": "XML stylesheet", ".xslt": "XML stylesheet",
        ".svg": "SVG image",
        # Data
        ".json": "JSON data", ".jsonl": "JSON Lines data",
        ".ndjson": "JSON Lines data",
        ".yaml": "YAML data", ".yml": "YAML data",
        ".toml": "TOML config",
        ".ini": "INI config", ".cfg": "config file", ".conf": "config file",
        ".env": "environment file",
        ".csv": "CSV data", ".tsv": "TSV data",
        ".sql": "SQL script",
        ".graphql": "GraphQL document", ".gql": "GraphQL document",
        ".proto": "Protocol Buffers definition",
        # Infrastructure / build
        ".tf": "Terraform config", ".tfvars": "Terraform variables",
        ".nix": "Nix expression",
        ".vim": "Vim script", ".el": "Emacs Lisp",
        # Docs
        ".md": "Markdown document", ".markdown": "Markdown document",
        ".rst": "reStructuredText document",
        ".tex": "LaTeX document",
        ".po": "Gettext translation", ".pot": "Gettext template",
        # Misc text
        ".diff": "diff file", ".patch": "patch file",
        ".log": "log file", ".txt": "plain text",
        # Certs / keys
        ".pem": "PEM data", ".crt": "certificate",
        ".cer": "certificate", ".key": "private key",
    }

    # ── magic signatures: (offset, bytes, label) ─────────────────────────
    # Checked in order; first match wins.
    _MAGIC = [
        (0,   b"\x7fELF",              "ELF executable"),
        (0,   b"MZ",                   "PE executable (Windows)"),
        (0,   b"\xcf\xfa\xed\xfe",    "Mach-O 64-bit binary"),
        (0,   b"\xce\xfa\xed\xfe",    "Mach-O 32-bit binary"),
        (0,   b"\xca\xfe\xba\xbe",    "Java class file"),
        (0,   b"\x00asm",             "WebAssembly binary"),
        (0,   b"%PDF-",               "PDF document"),
        (0,   b"PK\x03\x04",          "ZIP archive"),
        (0,   b"\x1f\x8b",            "GZIP compressed data"),
        (0,   b"BZh",                  "BZIP2 compressed data"),
        (0,   b"\xfd7zXZ\x00",        "XZ compressed data"),
        (0,   b"7z\xbc\xaf\x27\x1c", "7-Zip archive"),
        (0,   b"Rar!\x1a\x07",        "RAR archive"),
        (0,   b"\x89PNG\r\n\x1a\n",  "PNG image"),
        (0,   b"\xff\xd8\xff",        "JPEG image"),
        (0,   b"GIF87a",              "GIF image"),
        (0,   b"GIF89a",              "GIF image"),
        (0,   b"BM",                   "BMP image"),
        (0,   b"fLaC",                "FLAC audio"),
        (0,   b"OggS",                "OGG container"),
        (0,   b"ID3",                  "MP3 audio"),
        (0,   b"\xff\xfb",            "MP3 audio"),
        (0,   b"\x1a\x45\xdf\xa3",   "Matroska/WebM container"),
        (0,   b"PAR1",                "Parquet columnar data"),
        (0,   b"SQLite format 3\x00", "SQLite database"),
        (0,   b"\xd0\xcf\x11\xe0",   "OLE2 compound document (legacy Office)"),
        # WAV / AVI / WEBP share RIFF header — disambiguate by bytes 8-12
        (0,   b"RIFF",                None),   # handled specially below
        # TAR ustar at offset 257
        (257, b"ustar",               "TAR archive"),
        # MP4/MOV ftyp at offset 4
        (4,   b"ftyp",                "MPEG-4 container"),
        # BOM markers (text)
        (0,   b"\xef\xbb\xbf",       "UTF-8 BOM text"),
        (0,   b"\xff\xfe",            "UTF-16 LE text"),
        (0,   b"\xfe\xff",            "UTF-16 BE text"),
    ]

    def execute(self, shell, args):
        if not args:
            shell.oute.print("ERR: file requires at least one argument")
            return
        paths = []
        for arg in args:
            if not os.path.isabs(arg):
                arg = os.path.join(shell.cwd, arg)
            matched = sorted(glob.glob(arg))
            paths.extend(matched if matched else [arg])
        for path in paths:
            label = os.path.basename(path)
            result = self._describe(path)
            shell.outs.print(f"{label}: {result}")

    def _describe(self, path):
        if not os.path.exists(path):
            return "ERROR: no such file or directory"
        if os.path.isdir(path):
            return "directory"
        if os.path.islink(path):
            target = os.readlink(path)
            return f"symbolic link to {target}"

        try:
            size = os.path.getsize(path)
        except OSError:
            return "ERROR: cannot stat file"

        if size == 0:
            return "empty file"

        # Read a header chunk for magic detection
        try:
            with open(path, "rb") as f:
                header = f.read(8192)
        except OSError as e:
            return f"ERROR: {e}"

        # ── 1. magic bytes ────────────────────────────────────────────────
        magic_result = self._check_magic(header, path)
        if magic_result is not None:
            return magic_result

        # ── 2. extension lookup ───────────────────────────────────────────
        _, ext = os.path.splitext(path)
        ext_lower = ext.lower()

        # Special-case: Dockerfile has no extension
        basename = os.path.basename(path).lower()
        if basename == "dockerfile" or basename.startswith("dockerfile."):
            return "Dockerfile"

        if ext_lower in self._EXT:
            label = self._EXT[ext_lower]
            enc, endings = self._text_info(header)
            return f"{label}, {enc}, {endings}"

        # ── 3. content heuristics (text) ──────────────────────────────────
        heuristic = self._content_heuristic(header)
        if heuristic is not None:
            enc, endings = self._text_info(header)
            return f"{heuristic}, {enc}, {endings}"

        # ── 4. fallback ───────────────────────────────────────────────────
        non_print = sum(
            1 for b in header
            if b < 0x09 or (0x0e <= b <= 0x1f) or b == 0x7f
        )
        ratio = non_print / len(header)
        if ratio > 0.10:
            return f"binary data ({100*ratio:.0f}% non-printable bytes)"
        enc, endings = self._text_info(header)
        return f"text, {enc}, {endings}"

    def _check_magic(self, header, path):
        """Return a description string if a magic signature matches, else None."""
        for offset, sig, label in self._MAGIC:
            end = offset + len(sig)
            if len(header) >= end and header[offset:end] == sig:
                if label is None:
                    # RIFF container — disambiguate by sub-type at offset 8
                    sub = header[8:12]
                    if sub == b"WAVE":
                        return "WAV audio"
                    elif sub == b"AVI ":
                        return "AVI video"
                    elif sub == b"WEBP":
                        dims = self._webp_dims(header)
                        return f"WebP image{dims}"
                    else:
                        return "RIFF container"
                # Image types with dimension support
                if label == "PNG image":
                    dims = self._png_dims(header)
                    return f"PNG image{dims}"
                if label == "JPEG image":
                    dims = self._jpeg_dims(path)
                    return f"JPEG image{dims}"
                if label in ("GIF image",):
                    dims = self._gif_dims(header)
                    return f"{label}{dims}"
                # ZIP: probe for Office Open XML formats
                if label == "ZIP archive":
                    return self._probe_zip(path)
                return label
        return None

    # ── image dimension helpers ───────────────────────────────────────────

    def _png_dims(self, header):
        # IHDR chunk starts at byte 16, width at 16, height at 20 (4 bytes each, big-endian)
        if len(header) >= 24:
            try:
                import struct
                w = struct.unpack(">I", header[16:20])[0]
                h = struct.unpack(">I", header[20:24])[0]
                return f", {w}x{h}"
            except Exception:
                pass
        return ""

    def _gif_dims(self, header):
        # Width at offset 6, height at 8, both little-endian uint16
        if len(header) >= 10:
            try:
                import struct
                w = struct.unpack("<H", header[6:8])[0]
                h = struct.unpack("<H", header[8:10])[0]
                return f", {w}x{h}"
            except Exception:
                pass
        return ""

    def _jpeg_dims(self, path):
        # Must scan for SOF markers; read more of the file
        try:
            import struct
            with open(path, "rb") as f:
                data = f.read(65536)
            i = 2  # skip initial SOI marker
            while i < len(data) - 8:
                if data[i] != 0xff:
                    break
                marker = data[i + 1]
                # SOF markers: 0xC0..0xC3, 0xC5..0xC7, 0xC9..0xCB, 0xCD..0xCF
                if marker in (
                    0xc0, 0xc1, 0xc2, 0xc3,
                    0xc5, 0xc6, 0xc7,
                    0xc9, 0xca, 0xcb,
                    0xcd, 0xce, 0xcf,
                ):
                    h = struct.unpack(">H", data[i + 5:i + 7])[0]
                    w = struct.unpack(">H", data[i + 7:i + 9])[0]
                    return f", {w}x{h}"
                # Advance by segment length (2 bytes at i+2, big-endian)
                if i + 4 > len(data):
                    break
                seg_len = struct.unpack(">H", data[i + 2:i + 4])[0]
                i += 2 + seg_len
        except Exception:
            pass
        return ""

    def _webp_dims(self, header):
        # WebP VP8 chunk: "VP8 " at offset 12, width/height in VP8 bitstream
        # VP8L chunk: "VP8L" at offset 12
        # VP8X chunk: "VP8X" at offset 12, width at 24 (24-bit LE), height at 27
        if len(header) < 30:
            return ""
        try:
            import struct
            chunk = header[12:16]
            if chunk == b"VP8X":
                # canvas width minus 1 at bytes 24-26, height minus 1 at 27-29
                w = struct.unpack("<I", header[24:27] + b"\x00")[0] + 1
                h = struct.unpack("<I", header[27:30] + b"\x00")[0] + 1
                return f", {w}x{h}"
            elif chunk == b"VP8 ":
                # VP8 bitstream starts at offset 20; width/height in frame tag
                if len(header) >= 30:
                    w = struct.unpack("<H", header[26:28])[0] & 0x3fff
                    h = struct.unpack("<H", header[28:30])[0] & 0x3fff
                    return f", {w}x{h}"
        except Exception:
            pass
        return ""

    # ── ZIP / Office Open XML probe ───────────────────────────────────────

    def _probe_zip(self, path):
        """Try to distinguish Office Open XML formats from a plain ZIP."""
        try:
            import zipfile
            with zipfile.ZipFile(path, "r") as zf:
                names = zf.namelist()
            if "word/document.xml" in names:
                return "Word document (.docx)"
            if "xl/workbook.xml" in names:
                return "Excel workbook (.xlsx)"
            if "ppt/presentation.xml" in names:
                return "PowerPoint presentation (.pptx)"
            if any(n.startswith("META-INF/") for n in names):
                return "Java archive (JAR)"
        except Exception:
            pass
        return "ZIP archive"

    # ── text analysis helpers ─────────────────────────────────────────────

    def _text_info(self, header):
        """Return (encoding_str, line_endings_str) for a text chunk."""
        # Encoding: BOM first
        if header[:3] == b"\xef\xbb\xbf":
            enc = "UTF-8 (BOM)"
        elif header[:2] == b"\xff\xfe":
            enc = "UTF-16 LE"
        elif header[:2] == b"\xfe\xff":
            enc = "UTF-16 BE"
        else:
            # Try UTF-8, fall back to Latin-1
            try:
                header.decode("utf-8")
                # Check if it's actually plain ASCII
                if all(b < 0x80 for b in header):
                    enc = "ASCII"
                else:
                    enc = "UTF-8"
            except UnicodeDecodeError:
                enc = "Latin-1"

        # Line endings
        crlf = header.count(b"\r\n")
        # Bare CR: \r not followed by \n
        bare_cr = sum(
            1 for i, b in enumerate(header)
            if b == 0x0d and (i + 1 >= len(header) or header[i + 1] != 0x0a)
        )
        # Bare LF: \n not preceded by \r
        bare_lf = sum(
            1 for i, b in enumerate(header)
            if b == 0x0a and (i == 0 or header[i - 1] != 0x0d)
        )

        types = []
        if crlf:
            types.append(("CRLF", crlf))
        if bare_lf:
            types.append(("LF", bare_lf))
        if bare_cr:
            types.append(("CR", bare_cr))

        if not types:
            endings = "no line endings"
        elif len(types) == 1:
            endings = f"{types[0][0]} line endings"
        else:
            parts = ", ".join(f"{name}: {count}" for name, count in types)
            endings = f"mixed line endings ({parts})"

        return enc, endings

    # ── content-based heuristics ──────────────────────────────────────────

    def _content_heuristic(self, header):
        """Return a type label if content clues identify the file, else None."""
        # Only attempt if the data looks like text
        non_print = sum(
            1 for b in header
            if b < 0x09 or (0x0e <= b <= 0x1f) or b == 0x7f
        )
        if non_print / max(len(header), 1) > 0.10:
            return None

        try:
            text = header.decode("utf-8", errors="replace")
        except Exception:
            return None

        first_line = text.splitlines()[0] if text.splitlines() else ""
        first_512 = text[:512].lower()

        # Shebang detection
        if first_line.startswith("#!"):
            shebang = first_line[2:].strip()
            for token, label in [
                ("python",     "Python script"),
                ("ruby",       "Ruby script"),
                ("perl",       "Perl script"),
                ("node",       "Node.js script"),
                ("/bash",      "Bash script"),
                ("/zsh",       "Zsh script"),
                ("/fish",      "Fish script"),
                ("/sh",        "Shell script"),
                ("env sh",     "Shell script"),
                ("env bash",   "Bash script"),
            ]:
                if token in shebang:
                    return label

        # Content patterns
        if first_line.strip().startswith("<?php"):
            return "PHP script"
        if "<!doctype html" in first_512 or "<html" in first_512:
            return "HTML document"
        if first_line.strip().startswith("<?xml"):
            return "XML document"
        if first_line.strip().startswith("-----begin"):
            return "PEM data"
        if first_line.strip().startswith("---") and ":" in text[:256]:
            return "YAML data"

        # JSON: first non-whitespace char is { or [
        stripped = text.lstrip()
        if stripped and stripped[0] in ("{", "["):
            try:
                import json
                json.loads(text)
                return "JSON data"
            except Exception:
                pass

        return None


class CmdToCrlf(CmdConvertBase):
    def __init__(self):
        Cmd.__init__(self, "to-crlf")

    def help(self):
        return "<file>...   : convert line endings to CRLF (Windows) in place"

    def execute(self, shell, args):
        def transform(raw):
            enc, _ = _detect_file_encoding(raw)
            if enc == "utf-16":
                return raw, "UTF-16 not supported"
            text = raw.decode(enc)
            # Normalise to bare LF first, then add CR
            normalised = text.replace("\r\n", "\n").replace("\r", "\n")
            converted = normalised.replace("\n", "\r\n")
            # Re-encode preserving the original encoding (utf-8-sig writes BOM)
            return converted.encode(enc), None
        self._convert(shell, args, transform)


class CmdToLf(CmdConvertBase):
    def __init__(self):
        Cmd.__init__(self, "to-lf")

    def help(self):
        return "<file>...   : convert line endings to LF (Unix) in place"

    def execute(self, shell, args):
        def transform(raw):
            enc, _ = _detect_file_encoding(raw)
            if enc == "utf-16":
                return raw, "UTF-16 not supported"
            text = raw.decode(enc)
            converted = text.replace("\r\n", "\n").replace("\r", "\n")
            return converted.encode(enc), None
        self._convert(shell, args, transform)


class CmdToUtf8(CmdConvertBase):
    def __init__(self):
        Cmd.__init__(self, "to-utf8")

    def help(self):
        return "<file>...   : convert encoding to UTF-8 (no BOM) in place"

    def execute(self, shell, args):
        def transform(raw):
            enc, _ = _detect_file_encoding(raw)
            if enc == "utf-16":
                return raw, "UTF-16 not supported"
            text = raw.decode(enc)
            return text.encode("utf-8"), None
        self._convert(shell, args, transform)


class CmdToUtf8Bom(CmdConvertBase):
    def __init__(self):
        Cmd.__init__(self, "to-utf8-bom")

    def help(self):
        return "<file>...   : convert encoding to UTF-8 with BOM in place"

    def execute(self, shell, args):
        def transform(raw):
            enc, _ = _detect_file_encoding(raw)
            if enc == "utf-16":
                return raw, "UTF-16 not supported"
            text = raw.decode(enc)
            return b"\xef\xbb\xbf" + text.encode("utf-8"), None
        self._convert(shell, args, transform)


class CmdToLatin1(CmdConvertBase):
    def __init__(self):
        Cmd.__init__(self, "to-latin1")

    def help(self):
        return "<file>...   : convert encoding to Latin-1 (ISO-8859-1) in place"

    def execute(self, shell, args):
        def transform(raw):
            enc, _ = _detect_file_encoding(raw)
            if enc == "utf-16":
                return raw, "UTF-16 not supported"
            text = raw.decode(enc)
            try:
                return text.encode("latin-1"), None
            except UnicodeEncodeError as e:
                return raw, f"contains characters not representable in Latin-1: {e}"
        self._convert(shell, args, transform)


class CmdWatch(Cmd):
    def __init__(self):
        Cmd.__init__(self, "watch")

    def help(self):
        return "[-n <seconds>] <cmd> [<arg>...]   : run a command repeatedly, refreshing the screen each time"

    def execute(self, shell, args):
        interval = 10
        cmd_args = []
        idx = 0
        while idx < len(args):
            arg = args[idx]
            if arg == "-n" and idx + 1 < len(args):
                try:
                    interval = float(args[idx + 1])
                except ValueError:
                    shell.oute.print(f"ERR: -n requires a numeric value")
                    return
                idx += 2
            else:
                cmd_args.append(arg)
                idx += 1

        if not cmd_args:
            shell.oute.print("ERR: watch requires a command to execute")
            return

        cmd_line = quote_args(cmd_args)
        try:
            while True:
                term_size = shutil.get_terminal_size()
                rows = term_size.lines
                cols = term_size.columns

                # Capture command output
                captured = StringOutput()
                saved_outs = shell.outs
                shell.outs = captured
                try:
                    shell.execute(cmd_line, history=False)
                except CommandFailedException:
                    pass
                finally:
                    shell.outs = saved_outs

                output = captured.value()

                # Build header line
                header = f"Every {interval:g}s: {cmd_line}"
                header = header[:cols]

                # Split output into lines and clamp to available rows
                # Reserve 2 rows: one for the header, one for the blank separator
                available_rows = max(1, rows - 2)
                lines = output.splitlines()
                # Truncate each line to terminal width
                lines = [line[:cols] for line in lines]
                # Keep only as many lines as fit on screen
                lines = lines[:available_rows]

                # Clear screen. On Windows we need VT processing enabled; if
                # that succeeded at import time we can use the same ANSI
                # sequence as on Linux/macOS.  If not (very old Windows), fall
                # back to the 'cls' system command.
                if _VT_ENABLED:
                    shell.outs.write("\033[2J\033[H")
                else:
                    os.system("cls")

                shell.outs.write(header + "\n")
                shell.outs.write("\n")
                for line in lines:
                    shell.outs.write(line + "\n")

                time.sleep(interval)
        except KeyboardInterrupt:
            pass


class CmdTime(Cmd):
    def __init__(self):
        Cmd.__init__(self, "time")

    def help(self):
        return "<cmd> [<arg>...]   : execute a command and print its elapsed time"

    def execute(self, shell, args):
        if not args:
            shell.oute.print("ERR: time requires a command to execute")
            return
        cmd_line = quote_args(args)
        start = time.perf_counter()
        try:
            shell.execute(cmd_line, history=False)
        except CommandFailedException:
            pass
        elapsed = time.perf_counter() - start
        minutes = int(elapsed // 60)
        seconds = elapsed - minutes * 60
        if minutes > 0:
            shell.oute.print(f"\nreal\t{minutes}m{seconds:.3f}s")
        else:
            shell.oute.print(f"\nreal\t{elapsed:.3f}s")


def dabshell():
    Dabshell(init_shell=True).run()


if __name__ == "__main__":
    dabshell()
