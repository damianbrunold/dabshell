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
    KEY_CTRL_S, KEY_CTRL_SPACE, KEY_CTRL_UNDERSCORE, KEY_CTRL_V, KEY_CTRL_W,
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
        self.path = path
        self.encoding = encoding
        self.saved_id = self._top_id()
        self.last_kind = None   # stop merging further typing into this group

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
                r, c = pos
                lines = text.split("\n")
                if len(lines) == 1:
                    end = (r, c + len(text))
                else:
                    end = (r + len(lines) - 1, len(lines[-1]))
                self.delete(pos, end, record=False)
            else:
                self.insert(pos[0], pos[1], text, record=False)
        self.row, self.col = group["cursor"]
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
    }
    META_G = {
        "g": "goto_line",
        ("meta", "g"): "goto_line",
    }

    def __init__(self):
        self.prefix = None   # None | "C-x" | "M" | "M-g"

    def pending(self):
        return {"C-x": "C-x-", "M": "ESC-", "M-g": "M-g-"}.get(self.prefix)

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

class Editor:
    def __init__(self, shell, inp, out, size_fn=None):
        self.shell = shell
        self.inp = inp
        self.out = out
        self.size_fn = size_fn or shutil.get_terminal_size
        self.buffers = []
        self.cur = None
        self.prev = None
        self.kill_text = ""
        self.last_search = ""
        self.last_cmd = None
        self.this_cmd = None
        self.message = ""
        self.minibuffer = None    # (label, text, cursor, extra) while prompting
        self.running = False
        self.pasting = False
        self.keymap = EmacsKeymap()
        self.text_rows = 20
        self.width = 79
        self.last_frame = ""

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
                       "\033[0m\033[?25h\033[?1049l")
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
                continue
            if key == KEY_PASTE_END:
                self.pasting = False
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

    def call(self, name, key=None):
        buf = self.cur
        buf.begin_group(name if name in _MERGEABLE else None)
        self.this_cmd = name
        try:
            getattr(self, "cmd_" + name)(key)
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

    def _render_line(self, line, left):
        width = self.width
        disp = _display(line)
        seg = disp[left:left + width]
        if left > 0 and seg:
            seg = "$" + seg[1:]
        if len(disp) > left + width:
            seg = seg[:width - 1] + "$"
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
        out = ["\033[?25l\033[H"]
        for i in range(self.text_rows):
            r = buf.top + i
            if r < len(buf.lines):
                left = buf.left if r == buf.row else 0
                out.append(self._render_line(buf.lines[r], left))
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
            out.append(self.message[:self.width] + "\033[K")
            y = buf.row - buf.top + 1
            x = len(_display(buf.lines[buf.row][:buf.col])) - buf.left + 1
        out.append(f"\033[{y};{x}H\033[?25h")
        self.last_frame = "".join(out)
        self._emit(self.last_frame)

    # ── helpers for commands ─────────────────────────────────────────────────

    def _goto(self, pos):
        self.cur.row, self.cur.col = pos

    def _insert(self, text):
        buf = self.cur
        self._goto(buf.insert(buf.row, buf.col, text))

    def _kill(self, text, backward=False):
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
        if key.isspace():
            self.cur.break_group()

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
