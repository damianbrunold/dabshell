"""A small full-screen text editor for dabshell with emacs key bindings.

Layers:
- Buffer:      the text model (lines, cursor, mark, undo, load/save).
- Editor:      the session (buffers, kill ring, prompts, rendering) and all
               editing commands as cmd_* methods.
- EmacsKeymap: maps keys to command names.  A vim keymap can be added later
               by mapping keys onto the same cmd_* methods.
"""

import os
import shutil
import tempfile

from . import (
    IS_WIN,
    KEY_BACKSPACE, KEY_CR, KEY_CTRL_A, KEY_CTRL_B, KEY_CTRL_C, KEY_CTRL_D,
    KEY_CTRL_E, KEY_CTRL_F, KEY_CTRL_G, KEY_CTRL_H, KEY_CTRL_K, KEY_CTRL_L,
    KEY_CTRL_LEFT, KEY_CTRL_N, KEY_CTRL_P, KEY_CTRL_R, KEY_CTRL_RIGHT,
    KEY_CTRL_S, KEY_CTRL_SPACE, KEY_CTRL_U, KEY_CTRL_UNDERSCORE, KEY_CTRL_V, KEY_CTRL_W,
    KEY_CTRL_X, KEY_CTRL_Y, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ESC, KEY_HOME, KEY_LEFT,
    KEY_LF, KEY_PAGEDOWN, KEY_PAGEUP, KEY_PASTE_END, KEY_PASTE_START,
    KEY_RIGHT, KEY_TAB, KEY_UP,
    _detect_file_encoding, _is_binary,
)

TAB_WIDTH = 8
INDENT_WIDTH = 4


class EditorError(Exception):
    """A user-facing error, shown in the message line."""


class EncodeError(EditorError):
    """The buffer text cannot be represented in the file's encoding."""


def _is_word(ch):
    return bool(ch) and (ch.isalnum() or ch == "_")


def _end_of(pos, text):
    """Position just after *text* inserted at *pos*."""
    r, c = pos
    lines = text.split("\n")
    if len(lines) == 1:
        return r, c + len(text)
    return r + len(lines) - 1, len(lines[-1])


def _first_nonblank(line):
    return len(line) - len(line.lstrip(" \t"))


def _display(text):
    """Expand tabs and make control characters single printable cells."""
    text = text.expandtabs(TAB_WIDTH)
    return "".join("?" if ord(ch) < 0x20 or ord(ch) == 0x7f else ch
                   for ch in text)


# ═════════════════════════════════════════════════════════════════════════════
# Buffer
# ═════════════════════════════════════════════════════════════════════════════

class Buffer:
    def __init__(self, name, path=None):
        self.name = name
        self.path = path
        self.lines = [""]
        self.row = 0
        self.col = 0
        self.goal_col = None
        self.mark = None
        self.top = 0
        self.left = 0
        self.encoding = "utf-8"
        self.newline = "\n"
        self.trailing_newline = True
        self.uses_tabs = False
        # Undo: list of groups {"id", "ops", "cursor", "kind"}; each op is
        # ("ins" | "del", (row, col), text).
        self.undo_stack = []
        self.redo_stack = []
        self.last_kind = None
        self._next_id = 1
        self.saved_id = None

    # ── loading / saving ─────────────────────────────────────────────────────

    @classmethod
    def from_file(cls, path, name):
        buf = cls(name, path)
        if not os.path.exists(path):
            return buf
        if os.path.isdir(path):
            raise EditorError(f"{path} is a directory")
        with open(path, "rb") as f:
            raw = f.read()
        if _is_binary(raw):
            raise EditorError(f"{path} looks like a binary file")
        encoding, _ = _detect_file_encoding(raw)
        if encoding == "utf-16":
            raise EditorError(f"{path}: UTF-16 files are not supported")
        text = raw.decode(encoding)
        buf.encoding = encoding
        first_nl = text.find("\n")
        if first_nl > 0 and text[first_nl - 1] == "\r":
            buf.newline = "\r\n"
        text = text.replace("\r\n", "\n")
        if text:
            buf.trailing_newline = text.endswith("\n")
            if buf.trailing_newline:
                text = text[:-1]
        buf.lines = text.split("\n")
        buf.uses_tabs = any(line.startswith("\t") for line in buf.lines)
        return buf

    def text(self):
        data = "\n".join(self.lines)
        if self.trailing_newline and self.lines != [""]:
            data += "\n"
        return data

    def save(self, path=None, encoding=None):
        path = path or self.path
        if path is None:
            raise EditorError("No file name")
        encoding = encoding or self.encoding
        self._write(path, encoding)
        self.path = path
        self.encoding = encoding
        self.saved_id = self._top_id()
        self.last_kind = None   # stop merging further typing into this group

    def write_copy(self, path):
        """Write the text to *path* without changing the buffer's file."""
        self._write(path, self.encoding)

    def _write(self, path, encoding):
        data = self.text()
        if self.newline != "\n":
            data = data.replace("\n", self.newline)
        try:
            raw = data.encode(encoding)
        except UnicodeEncodeError:
            raise EncodeError(f"Text cannot be encoded as {encoding}")
        target = os.path.realpath(path)
        directory = os.path.dirname(target) or "."
        fd, tmp = tempfile.mkstemp(
            dir=directory, prefix="." + os.path.basename(target) + ".",
            suffix=".tmp",
        )
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
            if os.path.exists(target):
                shutil.copymode(target, tmp)
            os.replace(tmp, target)
        except BaseException:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise

    @property
    def modified(self):
        return self._top_id() != self.saved_id

    # ── positions ────────────────────────────────────────────────────────────

    def clamp(self):
        self.row = max(0, min(self.row, len(self.lines) - 1))
        self.col = max(0, min(self.col, len(self.lines[self.row])))
        if self.mark is not None:
            r, c = self.mark
            r = max(0, min(r, len(self.lines) - 1))
            self.mark = (r, max(0, min(c, len(self.lines[r]))))

    def char_at(self, r, c):
        line = self.lines[r]
        return line[c] if c < len(line) else "\n"

    def next_pos(self, r, c):
        if c < len(self.lines[r]):
            return r, c + 1
        if r < len(self.lines) - 1:
            return r + 1, 0
        return None

    def prev_pos(self, r, c):
        if c > 0:
            return r, c - 1
        if r > 0:
            return r - 1, len(self.lines[r - 1])
        return None

    def end_pos(self):
        return len(self.lines) - 1, len(self.lines[-1])

    def word_forward(self, r, c):
        while not _is_word(self.char_at(r, c)):
            p = self.next_pos(r, c)
            if p is None:
                return r, c
            r, c = p
        while _is_word(self.char_at(r, c)):
            p = self.next_pos(r, c)
            if p is None:
                break
            r, c = p
        return r, c

    def word_backward(self, r, c):
        while True:
            p = self.prev_pos(r, c)
            if p is None:
                return r, c
            if _is_word(self.char_at(*p)):
                break
            r, c = p
        while True:
            p = self.prev_pos(r, c)
            if p is None or not _is_word(self.char_at(*p)):
                return r, c
            r, c = p

    def text_range(self, start, end):
        (r1, c1), (r2, c2) = sorted((start, end))
        if r1 == r2:
            return self.lines[r1][c1:c2]
        parts = [self.lines[r1][c1:]] + self.lines[r1 + 1:r2] + \
            [self.lines[r2][:c2]]
        return "\n".join(parts)

    # ── primitive edits (everything goes through these) ──────────────────────

    def insert(self, row, col, text, record=True):
        """Insert text at (row, col); return the position after it."""
        if not text:
            return row, col
        parts = text.split("\n")
        line = self.lines[row]
        before, after = line[:col], line[col:]
        if len(parts) == 1:
            self.lines[row] = before + text + after
            end = (row, col + len(text))
        else:
            new = [before + parts[0]] + parts[1:-1] + [parts[-1] + after]
            self.lines[row:row + 1] = new
            end = (row + len(parts) - 1, len(parts[-1]))
        if record:
            self._record(("ins", (row, col), text))
        return end

    def delete(self, start, end, record=True):
        """Delete the text between two positions and return it."""
        (r1, c1), (r2, c2) = sorted((start, end))
        text = self.text_range((r1, c1), (r2, c2))
        if not text:
            return ""
        self.lines[r1] = self.lines[r1][:c1] + self.lines[r2][c2:]
        del self.lines[r1 + 1:r2 + 1]
        if record:
            self._record(("del", (r1, c1), text))
        return text

    # ── undo ─────────────────────────────────────────────────────────────────

    def begin_group(self, kind=None):
        """Start an undo group for the next command.

        Commands with the same non-None *kind* (e.g. consecutive self-inserts)
        are merged into one group.
        """
        top = self.undo_stack[-1] if self.undo_stack else None
        if kind is not None and kind == self.last_kind and top and top["ops"]:
            return
        if top is not None and not top["ops"]:
            top["cursor"] = (self.row, self.col)
            top["kind"] = kind
        else:
            self.undo_stack.append({
                "id": self._next_id, "ops": [],
                "cursor": (self.row, self.col), "kind": kind,
            })
            self._next_id += 1
        self.last_kind = kind

    def break_group(self):
        self.last_kind = None

    def _record(self, op):
        if not self.undo_stack:
            self.begin_group()
        self.undo_stack[-1]["ops"].append(op)
        self.redo_stack.clear()

    def _top_id(self):
        for group in reversed(self.undo_stack):
            if group["ops"]:
                return group["id"]
        return None

    def undo(self):
        while self.undo_stack and not self.undo_stack[-1]["ops"]:
            self.undo_stack.pop()
        if not self.undo_stack:
            return False
        group = self.undo_stack.pop()
        for kind, pos, text in reversed(group["ops"]):
            if kind == "ins":
                self.delete(pos, _end_of(pos, text), record=False)
            else:
                self.insert(pos[0], pos[1], text, record=False)
        self.redo_stack.append(group)
        self.row, self.col = group["cursor"]
        self.mark = None
        self.last_kind = None
        self.clamp()
        return True

    def redo(self):
        if not self.redo_stack:
            return False
        group = self.redo_stack.pop()
        for kind, pos, text in group["ops"]:
            if kind == "ins":
                self.insert(pos[0], pos[1], text, record=False)
            else:
                self.delete(pos, _end_of(pos, text), record=False)
        self.undo_stack.append(group)
        self.row, self.col = group["ops"][0][1]
        self.mark = None
        self.last_kind = None
        self.clamp()
        return True

    # ── search ───────────────────────────────────────────────────────────────

    def search(self, query, row, col, forward=True, wrap=True):
        """Find *query*; return (row, col) of the match start or None.

        Forward finds matches starting at or after (row, col).  Backward finds
        matches that end at or before (row, col).  The search is
        case-insensitive when the query is all lowercase.
        """
        if not query:
            return None
        fold = query == query.lower()
        q = query.lower() if fold else query
        n = len(self.lines)

        def hay(r):
            return self.lines[r].lower() if fold else self.lines[r]

        steps = n + 1 if wrap else (n - row if forward else row + 1)
        for i in range(steps):
            if forward:
                r = (row + i) % n
                h = hay(r)
                if i == 0:
                    idx = h.find(q, col)
                elif i == n:
                    idx = h.find(q, 0, max(0, col + len(q) - 1))
                else:
                    idx = h.find(q)
            else:
                r = (row - i) % n
                h = hay(r)
                if i == 0:
                    idx = h.rfind(q, 0, col)
                elif i == n:
                    idx = h.rfind(q, col - len(q) + 1 if col else 0)
                else:
                    idx = h.rfind(q)
            if idx >= 0:
                return r, idx
        return None


# ═════════════════════════════════════════════════════════════════════════════
# Key maps
# ═════════════════════════════════════════════════════════════════════════════

def describe_key(key):
    names = {
        KEY_LEFT: "<left>", KEY_RIGHT: "<right>", KEY_UP: "<up>",
        KEY_DOWN: "<down>", KEY_HOME: "<home>", KEY_END: "<end>",
        KEY_PAGEUP: "<prior>", KEY_PAGEDOWN: "<next>",
        KEY_BACKSPACE: "DEL", KEY_DELETE: "<delete>", KEY_TAB: "TAB",
        KEY_CR: "RET", KEY_LF: "C-j", KEY_ESC: "ESC",
        KEY_CTRL_SPACE: "C-SPC", KEY_CTRL_UNDERSCORE: "C-_",
    }
    if isinstance(key, tuple):
        return "M-" + describe_key(key[1])
    if key in names:
        return names[key]
    if isinstance(key, int) and -126 <= key <= -101:
        return "C-" + chr(ord("a") + (-101 - key))
    if key == " ":
        return "SPC"
    return str(key)


class EmacsKeymap:
    name = "emacs"

    GLOBAL = {
        KEY_CTRL_F: "forward_char", KEY_RIGHT: "forward_char",
        KEY_CTRL_B: "backward_char", KEY_LEFT: "backward_char",
        KEY_CTRL_N: "next_line", KEY_DOWN: "next_line",
        KEY_CTRL_P: "previous_line", KEY_UP: "previous_line",
        KEY_CTRL_A: "beginning_of_line", KEY_HOME: "beginning_of_line",
        KEY_CTRL_E: "end_of_line", KEY_END: "end_of_line",
        KEY_CTRL_RIGHT: "forward_word", KEY_CTRL_LEFT: "backward_word",
        KEY_CTRL_V: "scroll_up", KEY_PAGEDOWN: "scroll_up",
        KEY_PAGEUP: "scroll_down",
        KEY_CTRL_L: "recenter",
        KEY_CR: "newline", KEY_LF: "newline",
        KEY_TAB: "tab",
        KEY_BACKSPACE: "delete_backward_char",
        KEY_CTRL_H: "delete_backward_char",
        KEY_CTRL_D: "delete_char", KEY_DELETE: "delete_char",
        KEY_CTRL_K: "kill_line",
        KEY_CTRL_Y: "yank",
        KEY_CTRL_SPACE: "set_mark",
        KEY_CTRL_W: "kill_region",
        KEY_CTRL_G: "keyboard_quit",
        KEY_CTRL_UNDERSCORE: "undo",
        KEY_CTRL_S: "isearch_forward",
        KEY_CTRL_R: "isearch_backward",
    }
    CTRL_X = {
        KEY_CTRL_S: "save",
        KEY_CTRL_W: "write_file",
        KEY_CTRL_F: "find_file",
        KEY_CTRL_C: "quit",
        KEY_CTRL_G: "keyboard_quit",
        "b": "switch_buffer",
        "k": "kill_buffer",
        "u": "undo",
        "h": "mark_whole_buffer",
        " ": "set_mark",
    }
    META = {
        "f": "forward_word",
        "b": "backward_word",
        "d": "kill_word",
        KEY_BACKSPACE: "backward_kill_word",
        "v": "scroll_down",
        "<": "beginning_of_buffer",
        ">": "end_of_buffer",
        "w": "copy_region",
        "%": "query_replace",
        "x": "execute_extended_command",
    }
    META_G = {
        "g": "goto_line",
        ("meta", "g"): "goto_line",
    }

    def __init__(self):
        self.prefix = None   # None | "C-x" | "M" | "M-g"

    def pending(self):
        return {"C-x": "C-x-", "M": "ESC-", "M-g": "M-g-"}.get(self.prefix)

    def status(self, editor):
        return ""

    def selection(self, editor):
        return None

    cursor_shape = "\033[0 q"

    def handle(self, editor, key):
        prefix, self.prefix = self.prefix, None
        if prefix is None:
            if key == KEY_ESC:
                self.prefix = "M"
                return
            if isinstance(key, tuple):
                prefix = "M"
        if prefix is None:
            if key == KEY_CTRL_X:
                self.prefix = "C-x"
                return
            name = self.GLOBAL.get(key)
            if name is None and isinstance(key, str) and key.isprintable():
                name = "self_insert"
            seq = describe_key(key)
        elif prefix == "C-x":
            name = self.CTRL_X.get(key)
            seq = "C-x " + describe_key(key)
        elif prefix == "M":
            if isinstance(key, tuple):
                key = key[1]
            if key == "g":
                self.prefix = "M-g"
                return
            name = self.META.get(key)
            seq = "M-" + describe_key(key)
        else:   # M-g
            name = self.META_G.get(key)
            seq = "M-g " + describe_key(key)
        if name is None:
            editor.message = f"{seq} is undefined"
            return
        editor.call(name, key)


# Commands that merge into the previous undo group when repeated.
_MERGEABLE = {"self_insert", "delete_backward_char", "delete_char"}
# Commands whose kills append to the previous kill.
_KILL_CMDS = {"kill_line", "kill_word", "backward_kill_word", "kill_region"}


# ═════════════════════════════════════════════════════════════════════════════
# Editor
# ═════════════════════════════════════════════════════════════════════════════

_AUTO = object()


class Editor:
    def __init__(self, shell, inp, out, size_fn=None, keymap="emacs"):
        self.shell = shell
        self.inp = inp
        self.out = out
        self.size_fn = size_fn or shutil.get_terminal_size
        self.buffers = []
        self.cur = None
        self.prev = None
        self.kill_text = ""
        self.kill_linewise = False   # vim: register holds whole lines
        self.last_search = ""
        self.last_cmd = None
        self.this_cmd = None
        self.message = ""
        self.minibuffer = None    # (label, text, cursor, extra) while prompting
        self.running = False
        self.pasting = False
        self.keymap = None
        self._undo_kind = None
        self.set_keymap(keymap, quiet=True)
        self.text_rows = 20
        self.width = 79
        self.last_frame = ""

    def set_keymap(self, name, quiet=False):
        if name == "vim":
            self.keymap = VimKeymap()
        elif name == "emacs":
            self.keymap = EmacsKeymap()
        else:
            raise EditorError(f"Unknown key bindings: {name}")
        if not quiet:
            self.message = f"Switched to {name} key bindings"

    # ── buffers ──────────────────────────────────────────────────────────────

    def resolve(self, path):
        path = os.path.expanduser(path)
        if not os.path.isabs(path):
            path = os.path.join(self.shell.cwd, path)
        return os.path.normpath(path)

    def _unique_name(self, base, exclude=None):
        names = {b.name for b in self.buffers if b is not exclude}
        name, n = base, 2
        while name in names:
            name = f"{base}<{n}>"
            n += 1
        return name

    def _add(self, buf):
        self.buffers.append(buf)
        self.select(buf)
        return buf

    def select(self, buf):
        if buf is not self.cur:
            self.prev = self.cur
            self.cur = buf

    def open_file(self, path):
        full = self.resolve(path)
        for buf in self.buffers:
            if buf.path and os.path.normcase(buf.path) == os.path.normcase(full):
                self.select(buf)
                return buf
        buf = Buffer.from_file(full, self._unique_name(os.path.basename(full)))
        if not os.path.exists(full):
            self.message = "(New file)"
        return self._add(buf)

    def new_buffer(self, name):
        return self._add(Buffer(self._unique_name(name)))

    # ── main loop ────────────────────────────────────────────────────────────

    def _emit(self, s):
        self.out.write(s)
        flush = getattr(getattr(self.out, "out", None), "flush", None)
        if flush:
            flush()

    def run(self):
        if not self.buffers:
            self.new_buffer("*scratch*")
        had_flag = getattr(self.inp, "editor_keys", False)
        try:
            self.inp.editor_keys = True
        except AttributeError:
            pass
        self._emit("\033[?1049h" + ("" if IS_WIN else "\033[?2004h"))
        self.running = True
        try:
            while self.running:
                self.render()
                self.dispatch(self.read_key())
        finally:
            self._emit(("" if IS_WIN else "\033[?2004l") +
                       "\033[0m\033[0 q\033[?25h\033[?1049l")
            try:
                self.inp.editor_keys = had_flag
            except AttributeError:
                pass

    def read_key(self):
        while True:
            try:
                key = self.inp.getch()
            except KeyboardInterrupt:
                return KEY_CTRL_G
            if key is None:
                continue
            if key == "\x00":
                return KEY_CTRL_SPACE
            if key == "\x1f":
                return KEY_CTRL_UNDERSCORE
            if key == KEY_PASTE_START:
                self.pasting = True
                hook = getattr(self.keymap, "paste_start", None)
                if hook and self.minibuffer is None:
                    hook(self)
                continue
            if key == KEY_PASTE_END:
                self.pasting = False
                hook = getattr(self.keymap, "paste_end", None)
                if hook and self.minibuffer is None:
                    hook(self)
                continue
            return key

    def dispatch(self, key):
        self.message = ""
        try:
            self.keymap.handle(self, key)
        except EditorError as e:
            self.minibuffer = None
            self.message = str(e)
        except Exception as e:   # never take the shell down
            self.minibuffer = None
            self.message = f"Error: {e}"
        pending = self.keymap.pending()
        if pending:
            self.message = pending

    def call(self, name, key=None, kind=_AUTO):
        """Run the command cmd_<name> as one undoable step."""
        if kind is _AUTO:
            kind = name if name in _MERGEABLE else None
        fn = getattr(self, "cmd_" + name)
        self.execute(lambda: fn(key), kind, name)

    def execute(self, fn, kind=None, name=None):
        """Run *fn* as a command.  Commands with the same non-None *kind*
        in a row share one undo group."""
        self.cur.begin_group(kind)
        self._undo_kind = kind
        self.this_cmd = name
        try:
            fn()
        finally:
            self.last_cmd = self.this_cmd
            if self.cur is not None:
                self.cur.clamp()

    # ── prompts ──────────────────────────────────────────────────────────────

    def prompt(self, label, default="", completer=None):
        text = default
        pos = len(text)
        extra = ""
        try:
            while True:
                self.minibuffer = (label, text, pos, extra)
                self.render()
                key = self.read_key()
                extra = ""
                if key in (KEY_CR, KEY_LF):
                    return text
                if key in (KEY_CTRL_G, KEY_ESC):
                    raise EditorError("Quit")
                if key in (KEY_BACKSPACE, KEY_CTRL_H):
                    if pos > 0:
                        text = text[:pos - 1] + text[pos:]
                        pos -= 1
                elif key in (KEY_DELETE, KEY_CTRL_D):
                    text = text[:pos] + text[pos + 1:]
                elif key in (KEY_LEFT, KEY_CTRL_B):
                    pos = max(0, pos - 1)
                elif key in (KEY_RIGHT, KEY_CTRL_F):
                    pos = min(len(text), pos + 1)
                elif key in (KEY_HOME, KEY_CTRL_A):
                    pos = 0
                elif key in (KEY_END, KEY_CTRL_E):
                    pos = len(text)
                elif key == KEY_CTRL_K:
                    text = text[:pos]
                elif key == KEY_TAB and completer:
                    matches = completer(text)
                    if matches:
                        common = os.path.commonprefix(matches)
                        if len(common) > len(text):
                            text = common
                            pos = len(text)
                        if len(matches) > 1:
                            extra = "  {" + " | ".join(
                                os.path.basename(m.rstrip("/\\")) or m
                                for m in matches[:20]) + "}"
                    else:
                        extra = "  [No match]"
                elif isinstance(key, str) and key.isprintable():
                    text = text[:pos] + key + text[pos:]
                    pos += len(key)
        finally:
            self.minibuffer = None

    def ask(self, question, choices):
        """Ask for a single key out of *choices*; C-g raises Quit."""
        try:
            while True:
                self.minibuffer = (question, "", 0, "")
                self.render()
                key = self.read_key()
                if key in (KEY_CTRL_G, KEY_ESC):
                    raise EditorError("Quit")
                if isinstance(key, str) and key.lower() in choices:
                    return key.lower()
        finally:
            self.minibuffer = None

    def _complete_file(self, text):
        out = []
        for path, is_dir in self.shell._complete_path(text, False):
            out.append(path + (os.sep if is_dir else ""))
        return out

    def _complete_buffer(self, text):
        return [b.name for b in self.buffers if b.name.startswith(text)]

    # ── rendering ────────────────────────────────────────────────────────────

    def _scroll(self, buf):
        rows = self.text_rows
        if buf.row < buf.top:
            buf.top = buf.row
        elif buf.row >= buf.top + rows:
            buf.top = buf.row - rows + 1
        dc = len(_display(buf.lines[buf.row][:buf.col]))
        if dc < buf.left or (buf.left > 0 and dc == buf.left) or \
                dc >= buf.left + self.width - 1:
            buf.left = max(0, dc - self.width // 2)
        if dc < self.width - 1:
            buf.left = 0

    def _render_line(self, line, left, sel=None):
        """Render one line; *sel* = (start_col, end_col, past_eol) marks a
        highlighted span in buffer columns."""
        width = self.width
        disp = _display(line)
        seg = disp[left:left + width]
        if left > 0 and seg:
            seg = "$" + seg[1:]
        if len(disp) > left + width:
            seg = seg[:width - 1] + "$"
        if sel is not None:
            sc, ec, past_eol = sel
            a = len(_display(line[:sc])) - left
            z = len(_display(line[:ec])) - left + (1 if past_eol else 0)
            a, z = max(0, a), min(width, z)
            if a < z:
                seg = seg.ljust(z)
                seg = seg[:a] + "\033[7m" + seg[a:z] + "\033[27m" + seg[z:]
        return seg

    def modeline(self):
        buf = self.cur
        flag = "**" if buf.modified else "--"
        idx = self.buffers.index(buf) + 1
        eol = "CRLF" if buf.newline == "\r\n" else "LF"
        enc = {"utf-8-sig": "utf-8-bom"}.get(buf.encoding, buf.encoding)
        return (f" {flag} {buf.name}   L{buf.row + 1} C{buf.col}   "
                f"({idx}/{len(self.buffers)})  {enc} {eol}  "
                f"[{self.keymap.name}]   C-x C-c quit")

    def render(self):
        size = self.size_fn()
        cols = max(10, size.columns)
        rows = max(3, size.lines)
        self.width = cols - 1
        self.text_rows = rows - 2
        buf = self.cur
        self._scroll(buf)
        sel = self.keymap.selection(self)
        out = ["\033[?25l\033[H"]
        for i in range(self.text_rows):
            r = buf.top + i
            if r < len(buf.lines):
                left = buf.left if r == buf.row else 0
                span = None
                if sel is not None:
                    (r1, c1), (r2, c2), linewise = sel
                    if r1 <= r <= r2:
                        line = buf.lines[r]
                        if linewise:
                            span = (0, len(line), True)
                        else:
                            span = (c1 if r == r1 else 0,
                                    c2 if r == r2 else len(line),
                                    r < r2)
                out.append(self._render_line(buf.lines[r], left, span))
            out.append("\033[K\r\n")
        ml = self.modeline()[:self.width].ljust(self.width)
        out.append("\033[7m" + ml + "\033[0m\033[K\r\n")
        if self.minibuffer is not None:
            label, text, pos, extra = self.minibuffer
            line = label + text + extra
            shift = max(0, len(label) + pos - self.width + 1)
            out.append(line[shift:shift + self.width] + "\033[K")
            y, x = rows, len(label) + pos - shift + 1
        else:
            msg = self.message or self.keymap.status(self)
            out.append(msg[:self.width] + "\033[K")
            y = buf.row - buf.top + 1
            x = len(_display(buf.lines[buf.row][:buf.col])) - buf.left + 1
        out.append(f"\033[{y};{x}H{self.keymap.cursor_shape}\033[?25h")
        self.last_frame = "".join(out)
        self._emit(self.last_frame)

    # ── helpers for commands ─────────────────────────────────────────────────

    def _goto(self, pos):
        self.cur.row, self.cur.col = pos

    def _insert(self, text):
        buf = self.cur
        self._goto(buf.insert(buf.row, buf.col, text))

    def _kill(self, text, backward=False):
        self.kill_linewise = False
        if self.last_cmd in _KILL_CMDS:
            self.kill_text = text + self.kill_text if backward \
                else self.kill_text + text
        else:
            self.kill_text = text

    def _region(self):
        buf = self.cur
        if buf.mark is None:
            raise EditorError("The mark is not set now")
        return sorted(((buf.row, buf.col), buf.mark))

    # ── movement ─────────────────────────────────────────────────────────────

    def cmd_forward_char(self, key):
        p = self.cur.next_pos(self.cur.row, self.cur.col)
        if p is None:
            raise EditorError("End of buffer")
        self._goto(p)

    def cmd_backward_char(self, key):
        p = self.cur.prev_pos(self.cur.row, self.cur.col)
        if p is None:
            raise EditorError("Beginning of buffer")
        self._goto(p)

    def _vertical(self, delta):
        buf = self.cur
        if self.last_cmd not in ("next_line", "previous_line") or \
                buf.goal_col is None:
            buf.goal_col = buf.col
        new_row = buf.row + delta
        if new_row < 0:
            buf.row, buf.col = 0, 0
            raise EditorError("Beginning of buffer")
        if new_row >= len(buf.lines):
            buf.row, buf.col = buf.end_pos()
            raise EditorError("End of buffer")
        buf.row = new_row
        buf.col = min(buf.goal_col, len(buf.lines[new_row]))

    def cmd_next_line(self, key):
        self._vertical(1)

    def cmd_previous_line(self, key):
        self._vertical(-1)

    def cmd_beginning_of_line(self, key):
        self.cur.col = 0

    def cmd_end_of_line(self, key):
        self.cur.col = len(self.cur.lines[self.cur.row])

    def cmd_forward_word(self, key):
        self._goto(self.cur.word_forward(self.cur.row, self.cur.col))

    def cmd_backward_word(self, key):
        self._goto(self.cur.word_backward(self.cur.row, self.cur.col))

    def cmd_beginning_of_buffer(self, key):
        self.cur.mark = (self.cur.row, self.cur.col)
        self._goto((0, 0))
        self.message = "Mark set"

    def cmd_end_of_buffer(self, key):
        self.cur.mark = (self.cur.row, self.cur.col)
        self._goto(self.cur.end_pos())
        self.message = "Mark set"

    def cmd_scroll_up(self, key):
        buf = self.cur
        page = max(1, self.text_rows - 2)
        if buf.row >= len(buf.lines) - 1:
            raise EditorError("End of buffer")
        buf.top = min(buf.top + page, max(0, len(buf.lines) - 1))
        buf.row = min(len(buf.lines) - 1, max(buf.row + page, buf.top))

    def cmd_scroll_down(self, key):
        buf = self.cur
        page = max(1, self.text_rows - 2)
        if buf.row == 0:
            raise EditorError("Beginning of buffer")
        buf.top = max(0, buf.top - page)
        buf.row = max(0, buf.row - page)

    def cmd_recenter(self, key):
        buf = self.cur
        buf.top = max(0, buf.row - self.text_rows // 2)

    def cmd_goto_line(self, key):
        text = self.prompt("Goto line: ")
        try:
            n = int(text.strip())
        except ValueError:
            raise EditorError(f"Not a line number: {text}")
        buf = self.cur
        buf.row = max(0, min(n - 1, len(buf.lines) - 1))
        buf.col = 0
        self.cmd_recenter(None)

    # ── editing ──────────────────────────────────────────────────────────────

    def cmd_self_insert(self, key):
        self._insert(key)
        if key.isspace() and self._undo_kind == "self_insert":
            self.cur.break_group()   # emacs: undo typing word by word

    def cmd_newline(self, key):
        buf = self.cur
        indent = ""
        if not self.pasting:
            line = buf.lines[buf.row][:buf.col]
            indent = line[:len(line) - len(line.lstrip(" \t"))]
        self._insert("\n" + indent)

    def cmd_tab(self, key):
        buf = self.cur
        if self.pasting or buf.uses_tabs:
            self._insert("\t")
        else:
            col = len(_display(buf.lines[buf.row][:buf.col]))
            self._insert(" " * (INDENT_WIDTH - col % INDENT_WIDTH))

    def cmd_delete_backward_char(self, key):
        buf = self.cur
        p = buf.prev_pos(buf.row, buf.col)
        if p is None:
            raise EditorError("Beginning of buffer")
        buf.delete(p, (buf.row, buf.col))
        self._goto(p)

    def cmd_delete_char(self, key):
        buf = self.cur
        p = buf.next_pos(buf.row, buf.col)
        if p is None:
            raise EditorError("End of buffer")
        buf.delete((buf.row, buf.col), p)

    def cmd_kill_line(self, key):
        buf = self.cur
        line = buf.lines[buf.row]
        if buf.col < len(line) and line[buf.col:].strip():
            end = (buf.row, len(line))
        elif buf.row < len(buf.lines) - 1:
            # Only whitespace (or nothing) left: kill through the newline.
            end = (buf.row + 1, 0)
        elif buf.col < len(line):
            end = (buf.row, len(line))
        else:
            raise EditorError("End of buffer")
        self._kill(buf.delete((buf.row, buf.col), end))

    def cmd_kill_word(self, key):
        buf = self.cur
        end = buf.word_forward(buf.row, buf.col)
        self._kill(buf.delete((buf.row, buf.col), end))

    def cmd_backward_kill_word(self, key):
        buf = self.cur
        start = buf.word_backward(buf.row, buf.col)
        self._kill(buf.delete(start, (buf.row, buf.col)), backward=True)
        self._goto(start)

    def cmd_yank(self, key):
        if not self.kill_text:
            raise EditorError("Kill ring is empty")
        buf = self.cur
        buf.mark = (buf.row, buf.col)
        self._insert(self.kill_text)

    def cmd_set_mark(self, key):
        self.cur.mark = (self.cur.row, self.cur.col)
        self.message = "Mark set"

    def cmd_kill_region(self, key):
        start, end = self._region()
        self._kill(self.cur.delete(start, end))
        self._goto(start)
        self.cur.mark = None

    def cmd_copy_region(self, key):
        start, end = self._region()
        self.kill_text = self.cur.text_range(start, end)
        self.kill_linewise = False
        self.cur.mark = None
        self.message = "Copied region"

    def cmd_mark_whole_buffer(self, key):
        self.cur.mark = self.cur.end_pos()
        self._goto((0, 0))
        self.message = "Mark set"

    def cmd_keyboard_quit(self, key):
        self.cur.mark = None
        self.message = "Quit"

    def cmd_undo(self, key):
        if not self.cur.undo():
            raise EditorError("No further undo information")
        self.message = "Undo"

    def command_names(self):
        skip = {"self_insert", "execute_extended_command"}
        names = [n[4:] for n in dir(self) if n.startswith("cmd_")]
        return sorted(n.replace("_", "-") for n in names if n not in skip) + \
            ["emacs-mode", "vim-mode"]

    def cmd_execute_extended_command(self, key):
        names = self.command_names()
        text = self.prompt(
            "M-x ", completer=lambda t: [n for n in names if n.startswith(t)]
        ).strip()
        if not text:
            return
        if text in ("vim-mode", "vim"):
            self.set_keymap("vim")
        elif text in ("emacs-mode", "emacs"):
            self.set_keymap("emacs")
        elif text in names:
            self.call(text.replace("-", "_"))
        else:
            raise EditorError(f"[No match] {text}")

    # ── search / replace ─────────────────────────────────────────────────────

    def cmd_isearch_forward(self, key):
        self._isearch(True)

    def cmd_isearch_backward(self, key):
        self._isearch(False)

    def _isearch(self, forward):
        buf = self.cur
        start = (buf.row, buf.col)
        query = ""
        match = None       # (row, col) of the current match start
        failing = False
        try:
            while True:
                label = ("Failing " if failing else "") + \
                    ("I-search: " if forward else "I-search backward: ")
                self.minibuffer = (label, query, len(query), "")
                self.render()
                key = self.read_key()
                if key in (KEY_CTRL_S, KEY_CTRL_R):
                    forward = key == KEY_CTRL_S
                    if not query:
                        query = self.last_search
                        origin = (buf.row, buf.col)
                    elif match is not None:
                        origin = (match[0], match[1] + 1) if forward \
                            else (match[0], match[1] + len(query) - 1)
                    else:
                        origin = (buf.row, buf.col)
                elif key in (KEY_BACKSPACE, KEY_CTRL_H):
                    query = query[:-1]
                    match = None
                    origin = start
                    if not query:
                        self._goto(start)
                        failing = False
                        continue
                elif key == KEY_CTRL_G:
                    self._goto(start)
                    raise EditorError("Quit")
                elif isinstance(key, str) and key.isprintable():
                    query += key
                    if match is not None:
                        origin = match if forward else \
                            (match[0], match[1] + len(query))
                    else:
                        origin = (buf.row, buf.col) if not failing else start
                else:
                    # RET / ESC accept; any other key accepts and runs.
                    if query:
                        self.last_search = query
                    if buf.row != start[0] or buf.col != start[1]:
                        buf.mark = start
                    if key not in (KEY_CR, KEY_LF, KEY_ESC):
                        self.minibuffer = None
                        self.keymap.handle(self, key)
                    return
                if not query:
                    continue
                found = buf.search(query, origin[0], origin[1], forward)
                failing = found is None
                if found is not None:
                    match = found
                    if forward:
                        self._goto((found[0], found[1] + len(query)))
                    else:
                        self._goto(found)
        finally:
            self.minibuffer = None

    def cmd_query_replace(self, key):
        old = self.prompt("Query replace: ", self.last_search)
        if not old:
            raise EditorError("Nothing to replace")
        new = self.prompt(f"Query replace {old} with: ")
        self.last_search = old
        buf = self.cur
        count = 0
        replace_all = False
        pos = (buf.row, buf.col)
        while True:
            found = buf.search(old, pos[0], pos[1], forward=True, wrap=False)
            if found is None:
                break
            end = (found[0], found[1] + len(old))
            self._goto(end)
            if not replace_all:
                answer = self.ask(
                    f"Replace {old} with {new}? (y, n, !, q) ", "yn!q"
                )
                if answer == "q":
                    break
                if answer == "n":
                    pos = end
                    continue
                if answer == "!":
                    replace_all = True
            buf.delete(found, end)
            pos = buf.insert(found[0], found[1], new)
            self._goto(pos)
            count += 1
        self.message = f"Replaced {count} occurrence{'s' if count != 1 else ''}"

    # ── files and buffers ────────────────────────────────────────────────────

    def _save_buffer(self, buf):
        if buf.path is None:
            path = self.prompt("File to save in: ", completer=self._complete_file)
            if not path:
                raise EditorError("No file name")
            buf.path = self.resolve(path)
            buf.name = self._unique_name(os.path.basename(buf.path), buf)
        try:
            buf.save()
        except EncodeError:
            answer = self.ask(
                f"Text cannot be saved as {buf.encoding}; use utf-8? (y or n) ",
                "yn",
            )
            if answer != "y":
                raise EditorError("Not saved")
            buf.save(encoding="utf-8")
        except OSError as e:
            raise EditorError(f"Cannot save {buf.path}: {e.strerror or e}")
        self.message = f"Wrote {buf.path}"

    def cmd_save(self, key):
        if not self.cur.modified and self.cur.path is not None:
            self.message = "(No changes need to be saved)"
            return
        self._save_buffer(self.cur)

    def cmd_write_file(self, key):
        buf = self.cur
        default = ""
        if buf.path:
            rel = os.path.relpath(os.path.dirname(buf.path), self.shell.cwd)
            default = "" if rel == "." else rel + os.sep
        path = self.prompt("Write file: ", default, self._complete_file)
        if not path or path.endswith(("/", os.sep)):
            raise EditorError("No file name")
        buf.path = self.resolve(path)
        buf.name = self._unique_name(os.path.basename(buf.path), buf)
        self._save_buffer(buf)

    def cmd_find_file(self, key):
        default = ""
        if self.cur.path:
            rel = os.path.relpath(os.path.dirname(self.cur.path), self.shell.cwd)
            default = "" if rel == "." else rel + os.sep
        path = self.prompt("Find file: ", default, self._complete_file)
        if not path:
            return
        self.open_file(path)

    def cmd_switch_buffer(self, key):
        other = self.prev if self.prev in self.buffers else None
        if other is None:
            other = next((b for b in self.buffers if b is not self.cur), None)
        label = "Switch to buffer"
        if other is not None:
            label += f" (default {other.name})"
        name = self.prompt(label + ": ", completer=self._complete_buffer)
        if not name:
            if other is None:
                return
            self.select(other)
            return
        for buf in self.buffers:
            if buf.name == name:
                self.select(buf)
                return
        self.new_buffer(name)

    def cmd_kill_buffer(self, key):
        buf = self.cur
        if buf.modified:
            answer = self.ask(
                f"Buffer {buf.name} modified; kill anyway? (y or n) ", "yn"
            )
            if answer != "y":
                return
        self.buffers.remove(buf)
        if not self.buffers:
            self.new_buffer("*scratch*")
        nxt = self.prev if self.prev in self.buffers else self.buffers[-1]
        self.cur = nxt
        self.prev = None

    def cmd_quit(self, key):
        for buf in list(self.buffers):
            if not buf.modified:
                continue
            self.select(buf)
            answer = self.ask(f"Save file {buf.path or buf.name}? (y, n, q) ",
                              "ynq")
            if answer == "q":
                raise EditorError("Quit")
            if answer == "y":
                self._save_buffer(buf)
        self.running = False


# ═════════════════════════════════════════════════════════════════════════════
# Vim key map
# ═════════════════════════════════════════════════════════════════════════════

_SPACE, _WORDCH, _PUNCT = 0, 1, 2


def _cls(ch, big):
    if ch in (" ", "\t", "\n", ""):
        return _SPACE
    if big or _is_word(ch):
        return _WORDCH
    return _PUNCT


def _vim_word_forward(b, r, c, big):
    """'w': start of the next word (an empty line also counts as a word)."""
    cls = _cls(b.char_at(r, c), big)
    if cls != _SPACE:
        while _cls(b.char_at(r, c), big) == cls:
            c += 1
    while True:
        ch = b.char_at(r, c)
        if ch == "\n":
            if r >= len(b.lines) - 1:
                return r, c
            r, c = r + 1, 0
            if b.lines[r] == "":
                return r, c
        elif ch in " \t":
            c += 1
        else:
            return r, c


def _vim_word_end(b, r, c, big):
    """'e': last character of the current/next word."""
    p = b.next_pos(r, c)
    if p is None:
        return r, c
    r, c = p
    while _cls(b.char_at(r, c), big) == _SPACE:
        p = b.next_pos(r, c)
        if p is None:
            return r, c
        r, c = p
    cls = _cls(b.char_at(r, c), big)
    while c + 1 < len(b.lines[r]) and _cls(b.lines[r][c + 1], big) == cls:
        c += 1
    return r, c


def _vim_word_back(b, r, c, big):
    """'b': start of the current/previous word."""
    p = b.prev_pos(r, c)
    if p is None:
        return r, c
    r, c = p
    while _cls(b.char_at(r, c), big) == _SPACE:
        if c == 0 and b.lines[r] == "":
            return r, c
        p = b.prev_pos(r, c)
        if p is None:
            return r, c
        r, c = p
    cls = _cls(b.char_at(r, c), big)
    while c > 0 and _cls(b.lines[r][c - 1], big) == cls:
        c -= 1
    return r, c


def _vim_replacement(repl):
    """Translate a vim :s replacement (& = whole match) to Python syntax."""
    out = []
    i = 0
    while i < len(repl):
        ch = repl[i]
        if ch == "\\" and i + 1 < len(repl):
            nxt = repl[i + 1]
            if nxt == "&":
                out.append("&")
            elif nxt == "n":
                out.append("\\n")
            else:
                out.append(ch + nxt)
            i += 2
            continue
        out.append("\\g<0>" if ch == "&" else ch)
        i += 1
    return "".join(out)


def _split_unescaped(text, delim):
    parts, cur, i = [], [], 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            # \<delim> is a literal delimiter; other escapes stay as they are
            cur.append(delim if text[i + 1] == delim else text[i:i + 2])
            i += 2
            continue
        if text[i] == delim:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(text[i])
        i += 1
    parts.append("".join(cur))
    return parts


class VimKeymap:
    name = "vim"

    _VERTICAL = {"j", "k", KEY_UP, KEY_DOWN, KEY_CTRL_N, KEY_CTRL_P}
    _MOTIONS = {
        "h", "l", "j", "k", "w", "W", "b", "B", "e", "E", "0", "^", "$",
        "G", "n", "N", ";", ",", " ", "+", "-",
        KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_HOME, KEY_END,
        KEY_BACKSPACE, KEY_CTRL_H, KEY_CR, KEY_LF, KEY_CTRL_N, KEY_CTRL_P,
    }
    _OPERATORS = {"d", "c", "y", ">", "<"}

    def __init__(self):
        self.mode = "normal"     # normal | insert | visual | visual_line
        self.vstart = None       # visual anchor
        self.last_visual = None  # (row1, row2) for the '<,'> range
        self.ins_kind = None     # undo-group token of the current insert
        self._serial = 0
        self.goal = None
        self.last_find = None
        self.search_forward = True
        self._paste_insert = False
        self._reset()

    def _reset(self):
        self.count = ""
        self.op = None
        self.op_count = None
        self.prefix = None
        self.prefix_count = None
        self.typed = ""

    # ── interface used by Editor ─────────────────────────────────────────────

    def pending(self):
        return self.typed or None

    def status(self, editor):
        return {
            "insert": "-- INSERT --",
            "visual": "-- VISUAL --",
            "visual_line": "-- VISUAL LINE --",
        }.get(self.mode, "")

    @property
    def cursor_shape(self):
        # bar in insert mode, block otherwise
        return "\033[6 q" if self.mode == "insert" else "\033[2 q"

    def selection(self, editor):
        if self.mode not in ("visual", "visual_line") or self.vstart is None:
            return None
        b = editor.cur
        r = min(self.vstart[0], len(b.lines) - 1)
        anchor = (r, min(self.vstart[1], len(b.lines[r])))
        s, e = sorted((anchor, (b.row, b.col)))
        if self.mode == "visual_line":
            return (s[0], 0), (e[0], len(b.lines[e[0]])), True
        return s, (e[0], min(len(b.lines[e[0]]), e[1] + 1)), False

    def paste_start(self, ed):
        if self.mode == "normal":
            self._paste_insert = True
            self._enter_insert(ed)

    def paste_end(self, ed):
        if self._paste_insert and self.mode == "insert":
            self._paste_insert = False
            self._leave_insert(ed)

    # ── dispatch ─────────────────────────────────────────────────────────────

    def handle(self, ed, key):
        if isinstance(key, tuple):
            # ESC followed quickly by a key arrives as one meta key.
            self.handle(ed, KEY_ESC)
            key = key[1]
        keep_goal = False
        try:
            if self.mode == "insert":
                self._insert_key(ed, key)
            else:
                keep_goal = self._normal_key(ed, key)
        except BaseException:
            self._reset()
            raise
        finally:
            if not keep_goal:
                self.goal = None
            if self.mode != "insert" and ed.cur is not None:
                b = ed.cur
                b.col = min(b.col, max(0, len(b.lines[b.row]) - 1))

    # ── insert mode ──────────────────────────────────────────────────────────

    def _new_insert_kind(self):
        self._serial += 1
        self.ins_kind = ("vim-insert", self._serial)
        return self.ins_kind

    def _enter_insert(self, ed, setup=None):
        """Switch to insert mode; *setup* runs in the same undo step as the
        text typed afterwards (e.g. the newline of 'o')."""
        kind = self._new_insert_kind()
        if setup is not None:
            ed.execute(setup, kind)
        self.mode = "insert"

    def _leave_insert(self, ed):
        b = ed.cur
        line = b.lines[b.row]
        if line and not line.strip() and self.ins_kind is not None:
            # Like vim's autoindent: a line left with only indentation is
            # emptied (as part of the same undo step).
            def strip_indent():
                b.delete((b.row, 0), (b.row, len(line)))
                b.col = 0
            ed.execute(strip_indent, self.ins_kind)
        self.mode = "normal"
        self.ins_kind = None
        b.break_group()
        if b.col > 0:
            b.col -= 1

    _INSERT_EDIT = {
        KEY_CR: "newline", KEY_LF: "newline", KEY_TAB: "tab",
        KEY_BACKSPACE: "delete_backward_char",
        KEY_CTRL_H: "delete_backward_char", KEY_DELETE: "delete_char",
    }
    _INSERT_MOVE = {
        KEY_LEFT: "backward_char", KEY_RIGHT: "forward_char",
        KEY_UP: "previous_line", KEY_DOWN: "next_line",
        KEY_HOME: "beginning_of_line", KEY_END: "end_of_line",
        KEY_PAGEUP: "scroll_down", KEY_PAGEDOWN: "scroll_up",
    }

    def _insert_key(self, ed, key):
        if key in (KEY_ESC, KEY_CTRL_C):
            self._paste_insert = False
            self._leave_insert(ed)
        elif key in self._INSERT_EDIT:
            ed.call(self._INSERT_EDIT[key], key, kind=self.ins_kind)
        elif key in self._INSERT_MOVE:
            ed.call(self._INSERT_MOVE[key], key, kind=None)
        elif key == KEY_CTRL_W:
            def delete_word():
                b = ed.cur
                start = b.word_backward(b.row, b.col)
                b.delete(start, (b.row, b.col))
                b.row, b.col = start
            ed.execute(delete_word, self.ins_kind)
        elif isinstance(key, str) and key.isprintable():
            ed.call("self_insert", key, kind=self.ins_kind)

    # ── normal / visual mode ─────────────────────────────────────────────────

    def _normal_key(self, ed, key):
        """Handle one key; returns True when the goal column must be kept."""
        b = ed.cur
        visual = self.mode in ("visual", "visual_line")
        if self.prefix in ("r", "f", "t", "F", "T"):
            p, count = self.prefix, self.prefix_count
            self.prefix = None
            if not (isinstance(key, str) and key.isprintable()):
                self._reset()
                return False
            if p == "r":
                self._reset()
                ed.execute(lambda: self._replace_char(ed, key, count or 1))
                return False
            self.last_find = (p, key)
            return self._do_motion(ed, ("find", p, key), count)
        if self.prefix == "g":
            count = self.prefix_count
            self.prefix = None
            if key == "g":
                return self._do_motion(ed, "gg", count)
            self._reset()
            raise EditorError(f"g{describe_key(key)} is not supported")
        if self.prefix == "Z":
            self._reset()
            if key == "Z":
                self.ex(ed, "x")
            elif key == "Q":
                self.ex(ed, "q!")
            return False

        if key in (KEY_ESC, KEY_CTRL_C):
            if visual:
                self.mode = "normal"
                self.vstart = None
            self._reset()
            return False
        if isinstance(key, str) and key.isdigit() and (key != "0" or self.count):
            self.count += key
            self.typed += key
            return False
        count = int(self.count) if self.count else None
        self.count = ""

        if key in ("g", "Z", "r", "f", "t", "F", "T"):
            if key in ("Z", "r") and (self.op or visual):
                self._reset()
                return False
            self.prefix = key
            self.prefix_count = count
            self.typed += key
            return False
        if not visual and key in self._OPERATORS:
            if self.op is None:
                self.op = key
                self.op_count = count
                self.typed += key
                return False
            if self.op == key:   # dd, cc, yy, >>, <<
                n = (self.op_count or 1) * (count or 1)
                op = self.op
                self._reset()
                r2 = min(len(b.lines) - 1, b.row + n - 1)
                self._run_op(ed, op, (b.row, 0), (r2, 0), "line")
                return False
        if key in self._MOTIONS:
            return self._do_motion(ed, key, count)
        if self.op:
            self._reset()
            return False
        self.typed = ""
        if visual:
            self._visual_cmd(ed, key, count)
        else:
            self._command(ed, key, count)
        return False

    def _do_motion(self, ed, motion, count):
        op = self.op
        if op and (self.op_count or count):
            count = (self.op_count or 1) * (count or 1)
        self._reset()
        b = ed.cur
        start = (b.row, b.col)
        target, mtype = self._motion(ed, motion, count, op)
        if op:
            self._run_op(ed, op, start, target, mtype)
            return False
        b.row, b.col = target
        return motion in self._VERTICAL or motion in ("$", KEY_END)

    def _motion(self, ed, m, count, op):
        b = ed.cur
        r, c = b.row, b.col
        n = count or 1
        last = len(b.lines) - 1
        line = b.lines[r]
        if isinstance(m, tuple):
            return self._find(b, m[1], m[2], n)
        if m in ("h", KEY_LEFT, KEY_BACKSPACE, KEY_CTRL_H):
            return (r, max(0, c - n)), "excl"
        if m in ("l", KEY_RIGHT, " "):
            limit = len(line) if op else max(0, len(line) - 1)
            return (r, min(limit, c + n)), "excl"
        if m in self._VERTICAL:
            down = m in ("j", KEY_DOWN, KEY_CTRL_N)
            nr = max(0, min(last, r + (n if down else -n)))
            if self.goal is None:
                self.goal = c
            return (nr, min(self.goal, len(b.lines[nr]))), "line"
        if m in ("+", KEY_CR, KEY_LF, "-"):
            nr = max(0, min(last, r + (-n if m == "-" else n)))
            return (nr, _first_nonblank(b.lines[nr])), "line"
        if m in ("0", KEY_HOME):
            return (r, 0), "excl"
        if m == "^":
            return (r, _first_nonblank(line)), "excl"
        if m in ("$", KEY_END):
            nr = min(last, r + n - 1)
            self.goal = 1 << 30
            return (nr, max(0, len(b.lines[nr]) - 1)), \
                ("incl" if b.lines[nr] else "excl")
        if m in ("w", "W"):
            big = m == "W"
            if op == "c" and _cls(b.char_at(r, c), big) != _SPACE:
                # cw changes to the end of the word, like ce
                pos = (r, c)
                cls = _cls(b.char_at(r, c), big)
                col = c
                while col + 1 < len(line) and _cls(line[col + 1], big) == cls:
                    col += 1
                pos = (r, col)
                for _ in range(n - 1):
                    pos = _vim_word_end(b, *pos, big)
                return pos, "incl"
            pos = prev = (r, c)
            for _ in range(n):
                prev = pos
                pos = _vim_word_forward(b, *pos, big)
            if op and pos[0] > prev[0]:
                # the last word moved over ends its line: stop there
                pos = (prev[0], len(b.lines[prev[0]]))
            return pos, "excl"
        if m in ("e", "E"):
            pos = (r, c)
            for _ in range(n):
                pos = _vim_word_end(b, *pos, m == "E")
            return pos, "incl"
        if m in ("b", "B"):
            pos = (r, c)
            for _ in range(n):
                pos = _vim_word_back(b, *pos, m == "B")
            return pos, "excl"
        if m in ("G", "gg"):
            if count:
                nr = min(last, count - 1)
            else:
                nr = last if m == "G" else 0
            return (nr, _first_nonblank(b.lines[nr])), "line"
        if m in ("n", "N"):
            forward = self.search_forward if m == "n" else \
                not self.search_forward
            pos = (r, c)
            for _ in range(n):
                pos = self._search(ed, ed.last_search, forward, pos)
            return pos, "excl"
        if m in (";", ","):
            if self.last_find is None:
                raise EditorError("No previous f/t/F/T")
            p, ch = self.last_find
            if m == ",":
                p = p.swapcase()
            return self._find(b, p, ch, n)
        raise EditorError(f"{describe_key(m)} is not a motion")

    def _find(self, b, p, ch, n):
        r, c = b.row, b.col
        line = b.lines[r]
        idx = c
        for _ in range(n):
            if p in ("f", "t"):
                start = idx + (2 if p == "t" and idx == c and
                               c + 1 < len(line) and line[c + 1] == ch else 1)
                idx = line.find(ch, start)
            else:
                end = idx - (1 if p == "T" and idx == c and
                             c > 0 and line[c - 1] == ch else 0)
                idx = line.rfind(ch, 0, end)
            if idx < 0:
                raise EditorError(f"{ch} not found")
        if p == "f":
            return (r, idx), "incl"
        if p == "t":
            return (r, idx - 1), "incl"
        if p == "F":
            return (r, idx), "excl"
        return (r, idx + 1), "excl"

    def _search(self, ed, query, forward, pos=None):
        if not query:
            raise EditorError("E35: No previous regular expression")
        b = ed.cur
        r, c = pos if pos is not None else (b.row, b.col)
        if forward:
            found = b.search(query, r, c + 1, True)
        else:
            found = b.search(query, r, c + len(query) - 1, False)
        if found is None:
            raise EditorError(f"E486: Pattern not found: {query}")
        if forward and found <= (r, c):
            ed.message = "search hit BOTTOM, continuing at TOP"
        elif not forward and found >= (r, c):
            ed.message = "search hit TOP, continuing at BOTTOM"
        return found

    # ── operators ────────────────────────────────────────────────────────────

    def _set_register(self, ed, text, linewise):
        ed.kill_text = text
        ed.kill_linewise = linewise

    def _run_op(self, ed, op, start, end, mtype):
        kind = self._new_insert_kind() if op == "c" else None
        ed.execute(lambda: self._apply(ed, op, start, end, mtype), kind)
        if op == "c":
            self.mode = "insert"

    def _apply(self, ed, op, start, end, mtype):
        b = ed.cur
        if mtype == "line":
            r1, r2 = sorted((start[0], end[0]))
            text = "\n".join(b.lines[r1:r2 + 1]) + "\n"
            if op == "y":
                self._set_register(ed, text, True)
                if r1 < b.row:
                    b.row = r1
                n = r2 - r1 + 1
                if n > 2:
                    ed.message = f"{n} lines yanked"
            elif op == "d":
                self._set_register(ed, text, True)
                self._delete_lines(b, r1, r2)
                b.row = min(r1, len(b.lines) - 1)
                b.col = _first_nonblank(b.lines[b.row])
            elif op == "c":
                self._set_register(ed, text, True)
                indent = _first_nonblank(b.lines[r1])
                b.delete((r1, indent), (r2, len(b.lines[r2])))
                b.row, b.col = r1, indent
            else:
                self._shift(b, r1, r2, op == ">")
            return
        s, e = sorted((start, end))
        if mtype == "incl":
            e = (e[0], min(len(b.lines[e[0]]), e[1] + 1))
        if op in (">", "<"):
            self._shift(b, s[0], e[0], op == ">")
            return
        text = b.text_range(s, e)
        self._set_register(ed, text, False)
        if op in ("d", "c"):
            b.delete(s, e)
        b.row, b.col = s

    def _delete_lines(self, b, r1, r2):
        last = len(b.lines) - 1
        if r2 < last:
            b.delete((r1, 0), (r2 + 1, 0))
        elif r1 > 0:
            b.delete((r1 - 1, len(b.lines[r1 - 1])), (r2, len(b.lines[r2])))
        else:
            b.delete((0, 0), (r2, len(b.lines[r2])))

    def _shift(self, b, r1, r2, right):
        unit = "\t" if b.uses_tabs else " " * INDENT_WIDTH
        for r in range(r1, r2 + 1):
            line = b.lines[r]
            if right:
                if line:
                    b.insert(r, 0, unit)
            elif line.startswith("\t"):
                b.delete((r, 0), (r, 1))
            else:
                n = len(line) - len(line.lstrip(" "))
                if n:
                    b.delete((r, 0), (r, min(n, INDENT_WIDTH)))
        b.row = r1
        b.col = _first_nonblank(b.lines[r1])

    # ── simple commands ──────────────────────────────────────────────────────

    def _replace_char(self, ed, ch, n):
        b = ed.cur
        r, c = b.row, b.col
        if c + n > len(b.lines[r]):
            return
        b.delete((r, c), (r, c + n))
        b.insert(r, c, ch * n)
        b.col = c + n - 1

    def _delete_chars(self, ed, n, forward):
        b = ed.cur
        r, c = b.row, b.col
        if forward:
            e = min(len(b.lines[r]), c + n)
            if e == c:
                return
            self._set_register(ed, b.delete((r, c), (r, e)), False)
        else:
            s = max(0, c - n)
            if s == c:
                return
            self._set_register(ed, b.delete((r, s), (r, c)), False)
            b.col = s

    def _paste(self, ed, after, n):
        b = ed.cur
        text = ed.kill_text
        if not text:
            raise EditorError("E353: Nothing in register")
        if ed.kill_linewise:
            block = (text if text.endswith("\n") else text + "\n") * n
            if after:
                row = b.row + 1
                if row >= len(b.lines):
                    b.insert(row - 1, len(b.lines[row - 1]), "\n" + block[:-1])
                else:
                    b.insert(row, 0, block)
            else:
                row = b.row
                b.insert(row, 0, block)
            b.row = row
            b.col = _first_nonblank(b.lines[row])
            return
        block = text * n
        col = b.col
        if after and b.lines[b.row]:
            col = min(len(b.lines[b.row]), col + 1)
        end = b.insert(b.row, col, block)
        if "\n" in block:
            b.col = col
        else:
            b.row, b.col = end[0], max(0, end[1] - 1)

    def _join(self, b, r1, count):
        for _ in range(max(1, count - 1)):
            if r1 >= len(b.lines) - 1:
                break
            cur, nxt = b.lines[r1], b.lines[r1 + 1]
            b.delete((r1, len(cur)), (r1 + 1, _first_nonblank(nxt)))
            rest = nxt.lstrip(" \t")
            sep = "" if (not cur or cur.endswith((" ", "\t")) or not rest
                         or rest.startswith(")")) else " "
            b.insert(r1, len(cur), sep)
            b.row, b.col = r1, len(cur)

    def _change_case(self, b, start, end, how):
        text = b.text_range(start, end)
        new = {"toggle": text.swapcase, "lower": text.lower,
               "upper": text.upper}[how]()
        if new != text:
            b.delete(start, end)
            b.insert(start[0], start[1], new)

    def _open_line(self, ed, below):
        b = ed.cur
        line = b.lines[b.row]
        indent = line[:_first_nonblank(line)]
        if below:
            b.row, b.col = b.insert(b.row, len(line), "\n" + indent)
        else:
            b.insert(b.row, 0, indent + "\n")
            b.col = len(indent)

    def _word_under_cursor(self, b):
        line, c = b.lines[b.row], b.col
        while c < len(line) and not _is_word(line[c]):
            c += 1
        if c >= len(line):
            raise EditorError("E348: No string under cursor")
        s = e = c
        while s > 0 and _is_word(line[s - 1]):
            s -= 1
        while e < len(line) and _is_word(line[e]):
            e += 1
        return line[s:e], (b.row, s)

    def _command(self, ed, key, count):
        b = ed.cur
        n = count or 1
        if key == "i":
            self._enter_insert(ed)
        elif key == "a":
            def move():
                if b.lines[b.row]:
                    b.col += 1
            self._enter_insert(ed, move)
        elif key == "I":
            self._enter_insert(
                ed, lambda: setattr(b, "col", _first_nonblank(b.lines[b.row])))
        elif key == "A":
            self._enter_insert(
                ed, lambda: setattr(b, "col", len(b.lines[b.row])))
        elif key in ("o", "O"):
            self._enter_insert(ed, lambda: self._open_line(ed, key == "o"))
        elif key in ("x", KEY_DELETE):
            ed.execute(lambda: self._delete_chars(ed, n, True))
        elif key == "X":
            ed.execute(lambda: self._delete_chars(ed, n, False))
        elif key in ("D", "C"):
            self.op = key.lower()
            self._do_motion(ed, "$", count)
        elif key == "s":
            self.op = "c"
            self._do_motion(ed, "l", count)
        elif key in ("S", "Y"):
            r2 = min(len(b.lines) - 1, b.row + n - 1)
            self._run_op(ed, "c" if key == "S" else "y",
                         (b.row, 0), (r2, 0), "line")
        elif key in ("p", "P"):
            ed.execute(lambda: self._paste(ed, key == "p", n))
        elif key == "J":
            ed.execute(lambda: self._join(b, b.row, max(2, n)))
        elif key == "~":
            def toggle():
                e = min(len(b.lines[b.row]), b.col + n)
                self._change_case(b, (b.row, b.col), (b.row, e), "toggle")
                b.col = e
            ed.execute(toggle)
        elif key == "u":
            for i in range(n):
                if not b.undo():
                    if i == 0:
                        raise EditorError("Already at oldest change")
                    break
        elif key == KEY_CTRL_R:
            for i in range(n):
                if not b.redo():
                    if i == 0:
                        raise EditorError("Already at newest change")
                    break
        elif key in ("v", "V"):
            self.mode = "visual" if key == "v" else "visual_line"
            self.vstart = (b.row, b.col)
        elif key == ":":
            self._ex_prompt(ed)
        elif key in ("/", "?"):
            query = ed.prompt(key) or ed.last_search
            self.search_forward = key == "/"
            ed.last_search = query
            b.row, b.col = self._search(ed, query, self.search_forward)
        elif key in ("*", "#"):
            word, pos = self._word_under_cursor(b)
            ed.last_search = word
            self.search_forward = key == "*"
            b.row, b.col = self._search(ed, word, self.search_forward, pos)
        elif key in (KEY_CTRL_F, KEY_PAGEDOWN):
            ed.call("scroll_up")
        elif key in (KEY_CTRL_B, KEY_PAGEUP):
            ed.call("scroll_down")
        elif key in (KEY_CTRL_D, KEY_CTRL_U):
            half = max(1, ed.text_rows // 2)
            if key == KEY_CTRL_D:
                b.row = min(len(b.lines) - 1, b.row + half)
                b.top = min(max(0, len(b.lines) - 1), b.top + half)
            else:
                b.row = max(0, b.row - half)
                b.top = max(0, b.top - half)
        elif key == KEY_CTRL_G:
            pct = 100 * (b.row + 1) // len(b.lines)
            mod = " [Modified]" if b.modified else ""
            ed.message = f'"{b.name}"{mod} {len(b.lines)} lines --{pct}%--'
        elif key == KEY_CTRL_L:
            pass
        else:
            raise EditorError(f"{describe_key(key)} is not supported in vim mode")

    def _visual_cmd(self, ed, key, count):
        b = ed.cur
        (s, e, linewise) = self.selection(ed)
        if key in ("v", "V"):
            want = "visual" if key == "v" else "visual_line"
            if self.mode == want:
                self.mode, self.vstart = "normal", None
            else:
                self.mode = want
            return
        if key == "o":
            anchor = self.vstart
            self.vstart = (b.row, b.col)
            b.row, b.col = anchor
            return
        if key == ":":
            self.last_visual = (s[0], e[0])
            self.mode, self.vstart = "normal", None
            self._ex_prompt(ed, "'<,'>")
            return
        ops = {"d": "d", "x": "d", KEY_DELETE: "d", "y": "y", "c": "c",
               "s": "c", ">": ">", "<": "<"}
        line_ops = {"D": "d", "X": "d", "Y": "y", "C": "c", "S": "c",
                    "R": "c"}
        self.mode, self.vstart = "normal", None
        if key in ops or key in line_ops:
            op = ops.get(key) or line_ops[key]
            if linewise or key in line_ops or op in (">", "<"):
                self._run_op(ed, op, (s[0], 0), (e[0], 0), "line")
            else:
                self._run_op(ed, op, s, e, "excl")
        elif key in ("~", "u", "U"):
            how = {"~": "toggle", "u": "lower", "U": "upper"}[key]
            if linewise:
                s, e = (s[0], 0), (e[0], len(b.lines[e[0]]))

            def change():
                self._change_case(b, s, e, how)
                b.row, b.col = s
            ed.execute(change)
        elif key == "J":
            ed.execute(lambda: self._join(b, s[0], max(2, e[0] - s[0] + 1)))
        else:
            raise EditorError(f"{describe_key(key)} is not supported in visual mode")

    # ── ex commands ──────────────────────────────────────────────────────────

    def _ex_complete(self, ed, text):
        import re
        m = re.match(r"^(e|edit|w|write|sav|saveas)(!?\s+)(.*)$", text)
        if m:
            return [m.group(1) + m.group(2) + p
                    for p in ed._complete_file(m.group(3))]
        m = re.match(r"^(b|buffer)(\s+)(.*)$", text)
        if m:
            return [m.group(1) + m.group(2) + n
                    for n in ed._complete_buffer(m.group(3))]
        return []

    def _ex_prompt(self, ed, default=""):
        text = ed.prompt(":", default, lambda t: self._ex_complete(ed, t))
        self.ex(ed, text)

    def _parse_range(self, ed, text):
        import re
        b = ed.cur
        last = len(b.lines) - 1
        addr = r"(?:\d+|[.$]|'[<>])"
        m = re.match(rf"^\s*(%|{addr})(?:\s*,\s*({addr}))?", text)
        if not m:
            return None, text.strip()

        def value(a):
            if a == ".":
                return b.row
            if a == "$":
                return last
            if a in ("'<", "'>"):
                if self.last_visual is None:
                    raise EditorError("E20: Mark not set")
                return self.last_visual[0 if a == "'<" else 1]
            return max(0, min(last, int(a) - 1))

        if m.group(1) == "%":
            rng = (0, last)
        else:
            r1 = value(m.group(1))
            r2 = value(m.group(2)) if m.group(2) else r1
            rng = tuple(sorted((r1, r2)))
        return rng, text[m.end():].strip()

    def ex(self, ed, text):
        import re
        b = ed.cur
        rng, rest = self._parse_range(ed, text)
        if not rest:
            if rng is not None:   # :42 goes to line 42
                b.row = rng[1]
                b.col = _first_nonblank(b.lines[b.row])
            return
        # :s/a/b/ — the delimiter directly follows the command name
        sm = re.match(r'^(s|substitute)([^A-Za-z0-9\s\\"|])(.*)$', rest)
        if sm:
            self._substitute(ed, rng or (b.row, b.row), sm.group(2),
                             sm.group(3))
            return
        m = re.match(r"^([A-Za-z]+)(!?)\s*(.*)$", rest)
        if m is None:
            raise EditorError(f"E492: Not an editor command: {rest}")
        name, bang, arg = m.group(1), m.group(2) == "!", m.group(3)

        if name in ("w", "write", "wq", "x", "xit", "exit"):
            if name in ("x", "xit", "exit") and not b.modified and \
                    b.path is not None and not arg:
                pass
            elif arg:
                path = ed.resolve(arg)
                if b.path is None:
                    b.path = path
                    b.name = ed._unique_name(os.path.basename(path), b)
                    ed._save_buffer(b)
                elif os.path.normcase(path) == os.path.normcase(b.path):
                    ed._save_buffer(b)
                else:
                    if os.path.exists(path) and not bang:
                        raise EditorError("E13: File exists (add ! to override)")
                    b.write_copy(path)
                    ed.message = f'"{arg}" written'
            else:
                ed._save_buffer(b)
            if name != "w" and name != "write":
                self._quit(ed, bang)
        elif name == "wa" or name == "wall":
            for buf in ed.buffers:
                if buf.modified:
                    ed._save_buffer(buf)
        elif name in ("q", "quit", "qa", "qall", "quitall"):
            self._quit(ed, bang)
        elif name in ("wqa", "wqall", "xa", "xall"):
            for buf in ed.buffers:
                if buf.modified:
                    ed._save_buffer(buf)
            self._quit(ed, bang)
        elif name in ("e", "edit"):
            if arg:
                ed.open_file(arg)
            elif b.path is None:
                raise EditorError("E32: No file name")
            elif b.modified and not bang:
                raise EditorError(
                    "E37: No write since last change (add ! to override)")
            else:
                self._reload(ed, b)
        elif name in ("bn", "bnext", "bp", "bprevious", "bN", "bNext"):
            idx = ed.buffers.index(b)
            step = 1 if name in ("bn", "bnext") else -1
            ed.select(ed.buffers[(idx + step) % len(ed.buffers)])
        elif name in ("b", "buffer"):
            self._switch_buffer(ed, arg)
        elif name in ("ls", "buffers", "files"):
            ed.message = "  ".join(
                f"{i + 1}{'%' if x is b else ' '}{'+' if x.modified else ''}"
                f" {x.name}" for i, x in enumerate(ed.buffers))
        elif name in ("bd", "bdelete"):
            if b.modified and not bang:
                raise EditorError(
                    "E89: No write since last change (add ! to override)")
            ed.buffers.remove(b)
            if not ed.buffers:
                ed.new_buffer("[No Name]")
            ed.cur = ed.prev if ed.prev in ed.buffers else ed.buffers[-1]
            ed.prev = None
        elif name in ("emacs",):
            ed.set_keymap("emacs")
        elif name in ("noh", "nohlsearch"):
            pass
        elif name in ("h", "help"):
            ed.message = ("i insert, Esc normal, :w save, :q quit, "
                          ":wq save+quit, :q! discard")
        else:
            raise EditorError(f"E492: Not an editor command: {rest}")

    def _quit(self, ed, force):
        if not force:
            for buf in ed.buffers:
                if buf.modified:
                    if buf is ed.cur:
                        raise EditorError(
                            "E37: No write since last change "
                            "(add ! to override)")
                    raise EditorError(
                        f'E162: No write since last change for buffer '
                        f'"{buf.name}"')
        ed.running = False

    def _reload(self, ed, b):
        fresh = Buffer.from_file(b.path, b.name)
        idx = ed.buffers.index(b)
        fresh.row = min(b.row, len(fresh.lines) - 1)
        ed.buffers[idx] = fresh
        if ed.prev is b:
            ed.prev = None
        ed.cur = fresh

    def _switch_buffer(self, ed, arg):
        arg = arg.strip()
        if not arg:
            return
        if arg.isdigit():
            idx = int(arg) - 1
            if not 0 <= idx < len(ed.buffers):
                raise EditorError(f"E86: Buffer {arg} does not exist")
            ed.select(ed.buffers[idx])
            return
        matches = [x for x in ed.buffers if x.name == arg] or \
            [x for x in ed.buffers if arg in x.name]
        if len(matches) != 1:
            raise EditorError(
                f"E93: More than one match for {arg}" if matches
                else f"E94: No matching buffer for {arg}")
        ed.select(matches[0])

    def _substitute(self, ed, rng, delim, body):
        import re
        parts = _split_unescaped(body, delim)
        pattern = parts[0] or re.escape(ed.last_search)
        repl = _vim_replacement(parts[1]) if len(parts) > 1 else ""
        flags = parts[2] if len(parts) > 2 else ""
        try:
            rx = re.compile(pattern, re.IGNORECASE if "i" in flags else 0)
        except re.error as e:
            raise EditorError(f"E486: Bad pattern: {e}")
        b = ed.cur
        total = changed_lines = 0
        last_row = None

        def run():
            nonlocal total, changed_lines, last_row
            for r in range(rng[0], rng[1] + 1):
                line = b.lines[r]
                try:
                    new, k = rx.subn(repl, line, count=0 if "g" in flags else 1)
                except (re.error, IndexError) as e:
                    raise EditorError(f"E486: Bad replacement: {e}")
                if k and new != line:
                    b.delete((r, 0), (r, len(line)))
                    b.insert(r, 0, new)
                if k:
                    total += k
                    changed_lines += 1
                    last_row = r
        ed.execute(run)
        if not total:
            raise EditorError(f"E486: Pattern not found: {parts[0]}")
        b.row = last_row
        b.col = _first_nonblank(b.lines[last_row])
        if total > 1:
            ed.message = (f"{total} substitutions on {changed_lines} "
                          f"line{'s' if changed_lines != 1 else ''}")
