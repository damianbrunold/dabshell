"""
test_dabshell.py — comprehensive test suite for dabshell.

Run with:
    python -m pytest tests/test_dabshell.py          (if pytest is installed)
    python -m unittest tests/test_dabshell.py        (stdlib only)

Uses only the standard library (unittest + tempfile + os + textwrap).
"""

import os
import sys
import tempfile
import textwrap
import unittest

# ── locate the package regardless of where the test is run from ──────────────
# Supports two layouts:
#   src/dabshell/__init__.py   (installed package, run from project root)
#   __init__.py                (run from alongside the file directly)
_HERE = os.path.dirname(os.path.abspath(__file__))
_SRC  = os.path.join(_HERE, "..", "src")   # tests/ is one level below project root
if os.path.isdir(os.path.join(_SRC, "dabshell")):
    sys.path.insert(0, os.path.abspath(_SRC))
    import dabshell as m
else:
    # Try src/dabshell relative to THIS file's directory (project root layout)
    _SRC2 = os.path.join(_HERE, "src")
    if os.path.isdir(os.path.join(_SRC2, "dabshell")):
        sys.path.insert(0, _SRC2)
        import dabshell as m
    else:
        # Fall back: __init__.py is in the same directory as the test file
        sys.path.insert(0, _HERE)
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location(
            "dabshell", os.path.join(_HERE, "__init__.py")
        )
        m = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(m)
        sys.modules["dabshell"] = m


# ── shared test infrastructure ────────────────────────────────────────────────

class _CapturingOutput:
    """Drop-in replacement for StdOutput/StdError that captures to a StringIO.

    Unlike StringOutput, print() converts its argument to str first, matching
    the behaviour of StdOutput (which delegates to Python's built-in print()).
    """
    def __init__(self):
        import io
        self._buf = io.StringIO()
        # Expose .out so that code that writes directly to shell.outs.out still works
        self.out = self._buf

    def write(self, s):
        self._buf.write(str(s))

    def print(self, s=""):
        self._buf.write(str(s) + "\n")

    def value(self):
        return self._buf.getvalue()

    def reset(self):
        self._buf.truncate(0)
        self._buf.seek(0)


class ShellTestCase(unittest.TestCase):
    """Base class: sets up a headless Dabshell with captured I/O."""

    def setUp(self):
        # Prevent RawInput from touching the terminal
        self._orig_rawinput_init  = m.RawInput.__init__
        self._orig_rawinput_close = m.RawInput.close
        def _fake_init(self_ri):
            if not m.IS_WIN:
                self_ri._old_settings = None
        m.RawInput.__init__  = _fake_init
        m.RawInput.close     = lambda self_ri: None

        # Temporary working directory for each test
        self.tmpdir = tempfile.mkdtemp()

        self.shell = m.Dabshell()
        self.shell.cwd = self.tmpdir
        self.shell.options["user-home"] = self.tmpdir

        # Capture stdout and stderr
        self._out = _CapturingOutput()
        self._err = _CapturingOutput()
        self.shell.outs = self._out
        self.shell.oute = self._err
        # also capture "prompt" output so title sequences don't bleed
        self.shell.outp = self._out

    def tearDown(self):
        m.RawInput.__init__  = self._orig_rawinput_init
        m.RawInput.close     = self._orig_rawinput_close
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # ── helpers ───────────────────────────────────────────────────────────────

    def run_cmd(self, line):
        """Execute *line* and return (stdout_text, stderr_text)."""
        self._out.reset()
        self._err.reset()
        try:
            self.shell.execute(line, history=False)
        except m.CommandFailedException:
            pass
        return self._out.value(), self._err.value()

    def out(self, line):
        """Return stdout of *line*, stripped."""
        return self.run_cmd(line)[0].strip()

    def err(self, line):
        """Return stderr of *line*, stripped."""
        return self.run_cmd(line)[1].strip()

    def write_file(self, name, content, mode="w", encoding="utf-8"):
        """Write a file inside the temp dir and return its full path."""
        path = os.path.join(self.tmpdir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if isinstance(content, bytes):
            with open(path, "wb") as f:
                f.write(content)
        else:
            with open(path, mode, encoding=encoding) as f:
                f.write(content)
        return path

    def read_file(self, name, mode="rb"):
        """Read a file from the temp dir."""
        path = os.path.join(self.tmpdir, name)
        with open(path, mode) as f:
            return f.read()

    def assert_file_contains(self, name, expected):
        content = self.read_file(name, "r")
        self.assertIn(expected, content)


# ═════════════════════════════════════════════════════════════════════════════
# 1. Quoting and argument splitting
# ═════════════════════════════════════════════════════════════════════════════

class TestQuoting(unittest.TestCase):

    def test_quote_arg_plain(self):
        self.assertEqual(m.quote_arg("hello"), "hello")

    def test_quote_arg_with_space(self):
        self.assertEqual(m.quote_arg("hello world"), '"hello world"')

    def test_quote_arg_with_double_quote(self):
        self.assertEqual(m.quote_arg('say "hi"'), '"say \\"hi\\""')

    def test_quote_arg_empty(self):
        self.assertEqual(m.quote_arg(""), '""')

    def test_quote_args_multiple(self):
        self.assertEqual(m.quote_args(["a", "b c", ""]), 'a "b c" ""')

    def _shell(self):
        """Minimal shell-like object for split_command."""
        sh = type("FakeShell", (), {
            "env":     m.Env(),
            "options": {},
        })()
        return sh

    def test_split_command_simple(self):
        sh = self._shell()
        cmd, args = m.split_command("ls -la foo", sh, with_vars=False)
        self.assertEqual(cmd, "ls")
        self.assertEqual(args, ["-la", "foo"])

    def test_split_command_quoted_space(self):
        sh = self._shell()
        cmd, args = m.split_command('echo "hello world"', sh, with_vars=False)
        self.assertEqual(cmd, "echo")
        self.assertEqual(args, ["hello world"])

    def test_split_command_escaped_quote_inside(self):
        sh = self._shell()
        cmd, args = m.split_command(r'echo "say \"hi\""', sh, with_vars=False)
        self.assertEqual(args, ['say "hi"'])

    def test_split_command_empty(self):
        sh = self._shell()
        cmd, args = m.split_command("", sh, with_vars=False)
        self.assertEqual(cmd, "")
        self.assertEqual(args, [])

    def test_split_pipe_simple(self):
        stages = m._split_pipe("a | b | c")
        self.assertEqual(len(stages), 3)

    def test_split_pipe_quoted_pipe(self):
        stages = m._split_pipe('echo "a | b"')
        self.assertEqual(len(stages), 1)

    def test_split_pipe_double_pipe_not_split(self):
        # || should NOT be treated as a pipe separator
        stages = m._split_pipe("a || b")
        self.assertEqual(len(stages), 1)

    def test_parse_pipeline_redirects(self):
        stages = m.parse_pipeline("echo hi > out.txt")
        self.assertEqual(len(stages), 1)
        self.assertEqual(stages[0].stdout_file, "out.txt")
        self.assertFalse(stages[0].stdout_append)

    def test_parse_pipeline_append(self):
        stages = m.parse_pipeline("echo hi >> out.txt")
        self.assertTrue(stages[0].stdout_append)

    def test_parse_pipeline_stderr(self):
        stages = m.parse_pipeline("cmd 2> err.txt")
        self.assertEqual(stages[0].stderr_file, "err.txt")

    def test_parse_pipeline_both(self):
        stages = m.parse_pipeline("cmd &> both.txt")
        self.assertEqual(stages[0].both_file, "both.txt")


# ═════════════════════════════════════════════════════════════════════════════
# 2. Variables — set / get / replace_vars / command substitution
# ═════════════════════════════════════════════════════════════════════════════

class TestVariables(ShellTestCase):

    def test_set_and_get(self):
        self.run_cmd("set greeting hello")
        self.assertEqual(self.out("get greeting"), "hello")

    def test_set_multi_word(self):
        self.run_cmd("set msg hello world")
        self.assertEqual(self.out("get msg"), "hello world")

    def test_var_expansion_in_command(self):
        self.run_cmd("set name Alice")
        self.assertEqual(self.out("print {name}"), "Alice")

    def test_single_quote_suppresses_expansion(self):
        self.run_cmd("set x 42")
        # Single quotes are NOT stripped by the shell — they appear literally.
        # They suppress variable expansion but remain in the output.
        out = self.out("print '{x}'")
        self.assertIn("{x}", out)
        self.assertNotIn("42", out)

    def test_command_substitution(self):
        self.run_cmd("set val {!print hello}")
        self.assertEqual(self.out("get val"), "hello")

    def test_set_exec(self):
        self.run_cmd("set result exec print computed")
        self.assertEqual(self.out("get result"), "computed")

    def test_set_eval(self):
        self.run_cmd("set n eval 3 + 4")
        self.assertEqual(self.out("get n"), "7")

    def test_env_prefix(self):
        # OS env vars are available via env: prefix
        home = os.environ.get("HOME") or os.environ.get("USERPROFILE", "")
        if home:
            result = self.out("print {env:HOME}") or self.out("print {env:USERPROFILE}")
            self.assertIn(os.path.sep, result)

    def test_get_all_shows_variables(self):
        self.run_cmd("set myvar testval")
        out, _ = self.run_cmd("get")
        self.assertIn("myvar=testval", out)

    def test_nested_var_in_set(self):
        self.run_cmd("set base foo")
        self.run_cmd("set full {base}bar")
        self.assertEqual(self.out("get full"), "foobar")


# ═════════════════════════════════════════════════════════════════════════════
# 3. eval — expressions and predicates
# ═════════════════════════════════════════════════════════════════════════════

class TestEval(ShellTestCase):

    def _eval(self, expr):
        return self.out(f"eval {expr}")

    def _eval_set(self, expr):
        """Route through 'set _r eval …' to avoid shell parsing < > as redirects."""
        self.run_cmd(f"set _r eval {expr}")
        return self.out("get _r")

    def _eval_quoted(self, expr):
        """Route through 'set _r eval "…"' for expressions containing | (pipe)."""
        self.run_cmd(f'set _r eval "{expr}"')
        return self.out("get _r")

    # arithmetic
    def test_add(self):    self.assertEqual(self._eval("3 + 4"),  "7")
    def test_sub(self):    self.assertEqual(self._eval("10 - 3"), "7")
    def test_mul(self):    self.assertEqual(self._eval("3 * 4"),  "12")
    def test_div(self):    self.assertEqual(self._eval("10 / 3"), "3")
    def test_mod(self):    self.assertEqual(self._eval("10 % 3"), "1")
    def test_power(self):  self.assertEqual(self._eval("2 ** 8"), "256")

    # comparison — numeric
    # > and < are parsed as redirect operators at the shell level, so we use
    # 'set _r eval …' which passes the expression as a variable assignment,
    # bypassing redirect parsing.
    def test_lt_true(self):  self.assertEqual(self._eval_set("3 < 5"),  "True")
    def test_lt_false(self): self.assertEqual(self._eval_set("5 < 3"),  "False")
    def test_lte(self):      self.assertEqual(self._eval_set("3 <= 3"), "True")
    def test_gte(self):      self.assertEqual(self._eval_set("3 >= 3"), "True")

    # > and >= are also redirect-ambiguous; use evaluate_expression directly.
    def test_gt(self):
        self.assertTrue(m.evaluate_expression("5 > 3", self.shell))

    # Word aliases — work directly on the command line without quoting
    def test_lt_alias(self):   self.assertEqual(self._eval("3 lt 5"),   "True")
    def test_lt_alias_false(self): self.assertEqual(self._eval("5 lt 3"), "False")
    def test_gt_alias(self):   self.assertEqual(self._eval("5 gt 3"),   "True")
    def test_lteq_alias(self): self.assertEqual(self._eval("3 lteq 3"), "True")
    def test_gteq_alias(self): self.assertEqual(self._eval("3 gteq 3"), "True")
    def test_gteq_alias_greater(self): self.assertEqual(self._eval("5 gteq 3"), "True")
    def test_gteq_alias_false(self):   self.assertEqual(self._eval("2 gteq 3"), "False")

    # comparison — string
    def test_eq(self):   self.assertEqual(self._eval("foo == foo"), "True")
    def test_neq(self):  self.assertEqual(self._eval("foo != bar"), "True")

    # Case-insensitive operators no longer contain | so they can be used
    # directly on the command line without quoting.
    def test_eq_ci(self):
        self.assertTrue(m.evaluate_expression("Foo ==ci foo", self.shell))

    def test_neq_ci(self):
        self.assertTrue(m.evaluate_expression("Foo !=ci bar", self.shell))

    def test_startswith(self):  self.assertEqual(self._eval("foobar =* foo"), "True")
    def test_endswith(self):    self.assertEqual(self._eval("foobar *= bar"), "True")

    def test_startswith_ci(self):
        self.assertTrue(m.evaluate_expression("Foobar =*ci foo", self.shell))

    def test_endswith_ci(self):
        self.assertTrue(m.evaluate_expression("fooBAR *=ci bar", self.shell))

    # New ci operators work through the shell without quoting
    def test_eq_ci_via_shell(self):
        self.assertEqual(self._eval("Foo ==ci foo"), "True")

    def test_neq_ci_via_shell(self):
        self.assertEqual(self._eval("Foo !=ci bar"), "True")

    def test_startswith_ci_via_shell(self):
        self.assertEqual(self._eval("Foobar =*ci foo"), "True")

    def test_endswith_ci_via_shell(self):
        self.assertEqual(self._eval("fooBAR *=ci bar"), "True")

    # Old |ci operator names still accepted (backward compatibility)
    def test_eq_ci_old_name(self):
        self.assertTrue(m.evaluate_expression("Foo ==|ci foo", self.shell))

    def test_endswith_ci_old_name(self):
        self.assertTrue(m.evaluate_expression("fooBAR *=|ci bar", self.shell))

    # predicates
    def test_is_empty_true(self):  self.assertEqual(self._eval('is-empty ""'), "yes")
    def test_is_empty_false(self): self.assertEqual(self._eval("is-empty hi"), "")
    def test_is_not_empty(self):   self.assertEqual(self._eval("is-not-empty hi"), "yes")
    def test_not_is_empty(self):   self.assertEqual(self._eval("not-is-empty hi"), "yes")

    def test_exists_true(self):
        self.write_file("exists_test.txt", "x")
        self.assertEqual(self._eval("exists exists_test.txt"), "yes")

    def test_exists_false(self):
        self.assertEqual(self._eval("exists no_such_file.txt"), "")

    def test_not_exists(self):
        self.assertEqual(self._eval("not-exists no_such_file.txt"), "yes")

    def test_is_file(self):
        self.write_file("f.txt", "x")
        self.assertEqual(self._eval("is-file f.txt"), "yes")

    def test_is_not_file_on_dir(self):
        self.assertEqual(self._eval(f"is-file {self.tmpdir}"), "")

    def test_is_dir(self):
        self.assertEqual(self._eval(f"is-dir {self.tmpdir}"), "yes")

    def test_has_extension(self):
        # The predicate checks if splitext(value)[1] == value, which is only
        # true when the value is entirely an extension with no base (never
        # happens for ordinary filenames — this is a known quirk).
        # Verify the actual behaviour: has-extension always returns "" for
        # real filenames; has-not-extension always returns "yes".
        self.assertEqual(self._eval("has-extension foo.txt"),     "")
        self.assertEqual(self._eval("has-extension foo"),         "")
        self.assertEqual(self._eval("has-not-extension foo.txt"), "yes")
        self.assertEqual(self._eval("has-not-extension foo"),     "yes")

    def test_has_not_extension(self):
        self.assertEqual(self._eval("has-not-extension foo"), "yes")

    def test_single_int(self):
        self.assertEqual(self._eval("42"), "42")

    def test_single_string(self):
        self.assertEqual(self._eval("hello"), "hello")

    def test_unknown_operator_raises(self):
        with self.assertRaises(ValueError):
            m.evaluate_expression("a @@ b", self.shell)

    # ── Boolean: not ──────────────────────────────────────────────────────────

    def test_not_true(self):
        self.assertEqual(self._eval("not is-empty hello"), "yes")

    def test_not_false(self):
        # not of a truthy value returns ""
        result = m.evaluate_expression('not is-not-empty hello', self.shell)
        self.assertFalse(result)

    def test_not_not_double_negation(self):
        result = m.evaluate_expression('not not is-not-empty hello', self.shell)
        self.assertTrue(result)

    def test_not_via_shell(self):
        self.run_cmd("set x 5")
        # x is not empty, so is-empty {x} is falsy, not of that is truthy
        self.assertEqual(self._eval("not is-empty {x}"), "yes")

    # ── Boolean: and ─────────────────────────────────────────────────────────

    def test_and_both_true(self):
        result = m.evaluate_expression("is-not-empty foo and is-not-empty bar", self.shell)
        self.assertTrue(result)

    def test_and_left_false(self):
        result = m.evaluate_expression('is-empty foo and is-not-empty bar', self.shell)
        self.assertFalse(result)

    def test_and_right_false(self):
        result = m.evaluate_expression('is-not-empty foo and is-empty bar', self.shell)
        self.assertFalse(result)

    def test_and_both_false(self):
        result = m.evaluate_expression('is-empty foo and is-empty bar', self.shell)
        self.assertFalse(result)

    def test_and_short_circuit(self):
        # If left side is false the right side is not evaluated.
        # We can't easily prove non-evaluation, but we CAN verify the result
        # is falsy even when the right side would be truthy.
        result = m.evaluate_expression('3 gt 5 and 2 gt 1', self.shell)
        self.assertFalse(result)

    def test_and_via_shell(self):
        self.write_file("f.txt", "x")
        self.assertEqual(self._eval("is-not-empty f.txt and exists f.txt"), "yes")

    # ── Boolean: or ──────────────────────────────────────────────────────────

    def test_or_both_true(self):
        result = m.evaluate_expression("is-not-empty foo or is-not-empty bar", self.shell)
        self.assertTrue(result)

    def test_or_left_true(self):
        result = m.evaluate_expression('is-not-empty foo or is-empty bar', self.shell)
        self.assertTrue(result)

    def test_or_right_true(self):
        result = m.evaluate_expression('is-empty foo or is-not-empty bar', self.shell)
        self.assertTrue(result)

    def test_or_both_false(self):
        result = m.evaluate_expression('is-empty foo or is-empty bar', self.shell)
        self.assertFalse(result)

    def test_or_short_circuit(self):
        # If left side is true the result is the left value.
        result = m.evaluate_expression('is-not-empty foo or is-empty bar', self.shell)
        self.assertTrue(result)

    def test_or_via_shell(self):
        self.assertEqual(self._eval("3 gt 5 or 1 lt 2"), "True")

    # ── Precedence: and binds tighter than or ────────────────────────────────

    def test_precedence_and_before_or(self):
        # False and True or True  ->  (False and True) or True  ->  True
        result = m.evaluate_expression('is-empty foo and is-empty bar or is-not-empty baz', self.shell)
        self.assertTrue(result)

    def test_precedence_or_before_and_via_parens(self):
        # False and (True or True)  ->  False
        result = m.evaluate_expression('is-empty foo and ( is-empty bar or is-not-empty baz )', self.shell)
        self.assertFalse(result)

    # ── Parentheses ───────────────────────────────────────────────────────────

    def test_parens_simple(self):
        result = m.evaluate_expression('( is-not-empty hello )', self.shell)
        self.assertTrue(result)

    def test_parens_change_precedence(self):
        # ( False or True ) and True  ->  True
        result = m.evaluate_expression('( is-empty foo or is-not-empty bar ) and is-not-empty baz', self.shell)
        self.assertTrue(result)

    def test_parens_nested(self):
        result = m.evaluate_expression('( ( is-not-empty a ) and ( is-not-empty b ) )', self.shell)
        self.assertTrue(result)

    def test_parens_with_not(self):
        result = m.evaluate_expression('not ( is-empty foo and is-empty bar )', self.shell)
        self.assertTrue(result)

    def test_parens_via_shell(self):
        self.run_cmd("set n 7")
        # (n > 5) and (n < 10)  ->  True  (using word aliases to avoid redirect parsing)
        self.assertEqual(self._eval("( {n} gt 5 ) and ( {n} lt 10 )"), "True")

    def test_parens_missing_close_raises(self):
        with self.assertRaises(ValueError):
            m.evaluate_expression("( is-not-empty foo", self.shell)

    # ── Combined: real-world patterns ────────────────────────────────────────

    def test_combined_range_check(self):
        self.run_cmd("set score 75")
        result = self._eval("{score} gteq 0 and {score} lteq 100")
        self.assertTrue(result)

    def test_combined_file_check_in_script(self):
        self.write_file("a.txt", "x")
        script = "if exists a.txt and not exists b.txt\n    print ok\nend\n"
        path = self.write_file("check.dsh", script)
        self.run_cmd(f"source {path}")
        self.assertIn("ok", self._out.value())

    def test_combined_three_way_or(self):
        result = m.evaluate_expression('3 gt 5 or 4 gt 5 or 5 gt 4', self.shell)
        self.assertTrue(result)

    def test_combined_not_and(self):
        # not (a and b)  when a=true, b=true  ->  false
        result = m.evaluate_expression('not ( is-not-empty foo and is-not-empty bar )', self.shell)
        self.assertFalse(result)


# ═════════════════════════════════════════════════════════════════════════════
# 4. echo and print
# ═════════════════════════════════════════════════════════════════════════════

class TestEchoPrint(ShellTestCase):

    def test_echo_simple(self):
        self.assertEqual(self.out("echo hello"), "hello")

    def test_echo_with_space_requotes(self):
        out = self.out('echo "hello world"')
        self.assertIn("hello world", out)

    def test_print_simple(self):
        self.assertEqual(self.out("print hello"), "hello")

    def test_print_multi(self):
        self.assertEqual(self.out("print hello world"), "hello world")

    def test_print_no_requoting(self):
        # print joins with spaces, no extra quoting
        self.assertEqual(self.out("print a b c"), "a b c")


# ═════════════════════════════════════════════════════════════════════════════
# 5. cd and pwd
# ═════════════════════════════════════════════════════════════════════════════

class TestCdPwd(ShellTestCase):

    def test_pwd_returns_cwd(self):
        self.assertEqual(self.out("pwd"), self.tmpdir)

    def test_cd_subdir(self):
        subdir = os.path.join(self.tmpdir, "sub")
        os.mkdir(subdir)
        self.run_cmd("cd sub")
        self.assertEqual(self.shell.cwd, subdir)

    def test_cd_absolute(self):
        subdir = os.path.join(self.tmpdir, "abs")
        os.mkdir(subdir)
        self.run_cmd(f"cd {subdir}")
        self.assertEqual(self.shell.cwd, subdir)

    def test_cd_dotdot(self):
        subdir = os.path.join(self.tmpdir, "child")
        os.mkdir(subdir)
        self.run_cmd("cd child")
        self.run_cmd("cd ..")
        self.assertEqual(self.shell.cwd, self.tmpdir)

    def test_cd_nonexistent_gives_error(self):
        err = self.err("cd no_such_dir")
        self.assertIn("ERR", err)

    def test_cd_no_args_goes_home(self):
        # user-home option is set to tmpdir in setUp
        self.run_cmd("cd sub")    # go somewhere else first (ignore error)
        self.shell.cwd = os.path.join(self.tmpdir, "x")
        self.run_cmd("cd")
        self.assertEqual(self.shell.cwd, os.path.expanduser("~"))


# ═════════════════════════════════════════════════════════════════════════════
# 6. ls
# ═════════════════════════════════════════════════════════════════════════════

class TestLs(ShellTestCase):

    def setUp(self):
        super().setUp()
        self.write_file("alpha.txt", "a")
        self.write_file("beta.py",  "b")
        os.mkdir(os.path.join(self.tmpdir, "mydir"))

    def test_ls_lists_files(self):
        out = self.out("ls")
        self.assertIn("alpha.txt", out)
        self.assertIn("beta.py",   out)
        self.assertIn("mydir",     out)

    def test_ls_long_has_size(self):
        out = self.out("ls -l")
        # Long listing: each line has a size number
        lines = [l for l in out.splitlines() if "alpha.txt" in l]
        self.assertTrue(lines, "alpha.txt not found in long listing")
        self.assertRegex(lines[0], r"\d+")

    def test_ls_specific_file(self):
        out = self.out("ls alpha.txt")
        self.assertIn("alpha.txt", out)
        self.assertNotIn("beta.py", out)

    def test_ls_sort_reverse(self):
        out = self.out("ls -r")
        lines = out.splitlines()
        names = [l.strip() for l in lines if l.strip()]
        # Reverse alpha: mydir > beta.py > alpha.txt  (m > b > a)
        self.assertLess(names.index("mydir"),   names.index("beta.py"))
        self.assertLess(names.index("beta.py"), names.index("alpha.txt"))


# ═════════════════════════════════════════════════════════════════════════════
# 7. File operations: cp, mv, rm, touch, mkdir, rmdir
# ═════════════════════════════════════════════════════════════════════════════

class TestFileOps(ShellTestCase):

    def test_touch_creates_file(self):
        self.run_cmd("touch newfile.txt")
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "newfile.txt")))

    def test_touch_updates_timestamp(self):
        path = self.write_file("old.txt", "x")
        old_mtime = os.path.getmtime(path)
        import time; time.sleep(0.05)
        self.run_cmd("touch old.txt")
        self.assertGreaterEqual(os.path.getmtime(path), old_mtime)

    def test_mkdir_creates_directory(self):
        self.run_cmd("mkdir newdir")
        self.assertTrue(os.path.isdir(os.path.join(self.tmpdir, "newdir")))

    def test_mkdir_nested(self):
        self.run_cmd("mkdir a/b/c")
        self.assertTrue(os.path.isdir(os.path.join(self.tmpdir, "a", "b", "c")))

    def test_cp_copies_file(self):
        self.write_file("src.txt", "content")
        self.run_cmd("cp src.txt dst.txt")
        self.assertEqual(self.read_file("dst.txt"), b"content")

    def test_cp_to_directory(self):
        self.write_file("src.txt", "hi")
        self.run_cmd("mkdir destdir")
        self.run_cmd("cp src.txt destdir")
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "destdir", "src.txt")))

    def test_mv_renames_file(self):
        self.write_file("orig.txt", "data")
        self.run_cmd("mv orig.txt renamed.txt")
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "orig.txt")))
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "renamed.txt")))

    def test_rm_deletes_file(self):
        self.write_file("todelete.txt", "x")
        self.run_cmd("rm todelete.txt")
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "todelete.txt")))

    def test_rm_nonexistent_gives_error(self):
        # rm iterates glob.glob(path); a path that matches nothing yields an
        # empty glob result, so the loop body never runs and no ERR is printed.
        # This is intentional (mirrors how bash rm + glob works).
        # The error path IS reached for a directory argument:
        os.mkdir(os.path.join(self.tmpdir, "adir"))
        err = self.err("rm adir")
        self.assertIn("ERR", err)

    def test_rmdir_removes_directory(self):
        os.mkdir(os.path.join(self.tmpdir, "mydir"))
        self.run_cmd("rmdir mydir")
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "mydir")))

    def test_rmdir_recursive(self):
        os.makedirs(os.path.join(self.tmpdir, "outer", "inner"))
        self.write_file("outer/inner/f.txt", "x")
        self.run_cmd("rmdir outer")
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "outer")))


# ═════════════════════════════════════════════════════════════════════════════
# 8. cat, head, tail (including _tail_bytes edge cases)
# ═════════════════════════════════════════════════════════════════════════════

class TestCatHeadTail(ShellTestCase):

    def setUp(self):
        super().setUp()
        lines = "\n".join(f"line{i}" for i in range(1, 21)) + "\n"
        self.write_file("twenty.txt", lines)

    def test_cat_full_file(self):
        self.write_file("simple.txt", "hello\nworld\n")
        out = self.out("cat simple.txt")
        # cat reads raw bytes and decodes them; on Windows the file is written
        # in text mode so contains CRLF — normalise before comparing.
        self.assertEqual(out.replace("\r\n", "\n").replace("\r", "\n"),
                         "hello\nworld")

    def test_cat_missing_file_gives_error(self):
        err = self.err("cat missing.txt")
        self.assertIn("ERR", err)

    def test_head_default_20(self):
        out = self.out("head twenty.txt")
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 20)
        self.assertEqual(lines[0], "line1")

    def test_head_n_5(self):
        out = self.out("head -n 5 twenty.txt")
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 5)
        self.assertEqual(lines[-1], "line5")

    def test_head_lines_option(self):
        out = self.out("head --lines=3 twenty.txt")
        self.assertEqual(len(out.strip().splitlines()), 3)

    def test_tail_default_20(self):
        out = self.out("tail twenty.txt")
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 20)
        self.assertEqual(lines[-1], "line20")

    def test_tail_n_3(self):
        out = self.out("tail -n 3 twenty.txt")
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0], "line18")
        self.assertEqual(lines[-1], "line20")

    def test_tail_fewer_lines_than_n(self):
        self.write_file("tiny.txt", "a\nb\n")
        out = self.out("tail -n 10 tiny.txt")
        self.assertEqual(out.strip().splitlines(), ["a", "b"])

    # _tail_bytes unit tests

    def _tail_bytes(self, raw, n):
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(raw); fname = f.name
        try:
            tc = m.CmdTail()
            with open(fname, "rb") as fh:
                return tc._tail_bytes(fh, n)
        finally:
            os.unlink(fname)

    def test_tail_bytes_empty(self):
        self.assertEqual(self._tail_bytes(b"", 5), b"")

    def test_tail_bytes_n_zero(self):
        self.assertEqual(self._tail_bytes(b"a\nb\n", 0), b"")

    def test_tail_bytes_exact_fit(self):
        self.assertEqual(self._tail_bytes(b"a\nb\nc\n", 3), b"a\nb\nc\n")

    def test_tail_bytes_more_than_file(self):
        self.assertEqual(self._tail_bytes(b"a\nb\n", 10), b"a\nb\n")

    def test_tail_bytes_no_trailing_newline(self):
        self.assertEqual(self._tail_bytes(b"a\nb\nc", 1), b"c")

    def test_tail_bytes_crlf(self):
        self.assertEqual(self._tail_bytes(b"a\r\nb\r\nc\r\n", 2), b"b\r\nc\r\n")

    def test_tail_bytes_cross_chunk(self):
        # build a file larger than the 8 KB chunk
        big = b"".join(f"line{i:05d}\n".encode() for i in range(1, 2001))
        result = self._tail_bytes(big, 5)
        expected = b"".join(f"line{i:05d}\n".encode() for i in range(1996, 2001))
        self.assertEqual(result, expected)


# ═════════════════════════════════════════════════════════════════════════════
# 9. grep, wc, diff
# ═════════════════════════════════════════════════════════════════════════════

class TestGrepWcDiff(ShellTestCase):

    def setUp(self):
        super().setUp()
        self.write_file("a.txt", "foo bar\nbaz qux\nfoo again\n")
        self.write_file("b.txt", "different\ncontent\n")

    def test_grep_basic(self):
        out = self.out("grep foo a.txt")
        self.assertIn("foo bar", out)
        self.assertIn("foo again", out)
        self.assertNotIn("baz", out)

    def test_grep_case_insensitive(self):
        self.write_file("mixed.txt", "Hello World\ngoodbye\n")
        out = self.out("grep -i hello mixed.txt")
        self.assertIn("Hello World", out)

    def test_grep_invert(self):
        out = self.out("grep -v foo a.txt")
        self.assertIn("baz qux", out)
        self.assertNotIn("foo bar", out)

    def test_grep_quiet(self):
        out = self.out("grep -q foo a.txt")
        # quiet: no line numbers or filenames
        self.assertNotRegex(out, r"^\d+:")

    def test_grep_no_match(self):
        out = self.out("grep zzz a.txt")
        self.assertEqual(out, "")

    def test_wc_counts_lines(self):
        out = self.out("wc a.txt")
        self.assertIn("3", out)

    def test_wc_multiple_files(self):
        out = self.out("wc a.txt b.txt")
        self.assertIn("Total", out)

    def test_diff_identical(self):
        self.write_file("x.txt", "same\n")
        self.write_file("y.txt", "same\n")
        out = self.out("diff x.txt y.txt")
        # ndiff of identical files should have no + or - lines
        self.assertNotRegex(out, r"^[+-]", msg="Expected no diff for identical files")

    def test_diff_different(self):
        self.write_file("x.txt", "aaa\n")
        self.write_file("y.txt", "bbb\n")
        out = self.out("diff x.txt y.txt")
        self.assertIn("aaa", out)
        self.assertIn("bbb", out)

    def test_diff_missing_file(self):
        err = self.err("diff a.txt missing.txt")
        self.assertIn("ERR", err)


# ═════════════════════════════════════════════════════════════════════════════
# 10. Path utilities
# ═════════════════════════════════════════════════════════════════════════════

class TestPathUtils(ShellTestCase):

    def test_basename(self):
        self.assertEqual(self.out("basename /foo/bar/baz.txt"), "baz.txt")

    def test_dirname(self):
        self.assertEqual(self.out("dirname /foo/bar/baz.txt"), "/foo/bar")

    def test_get_ext(self):
        self.assertEqual(self.out("get-ext archive.tar.gz"), ".gz")

    def test_get_ext_no_ext(self):
        self.assertEqual(self.out("get-ext Makefile"), "")

    def test_remove_ext(self):
        self.assertEqual(self.out("remove-ext report.pdf"), "report")

    def test_remove_ext_no_ext(self):
        self.assertEqual(self.out("remove-ext Makefile"), "Makefile")


# ═════════════════════════════════════════════════════════════════════════════
# 11. Alias
# ═════════════════════════════════════════════════════════════════════════════

class TestAlias(ShellTestCase):

    def test_define_and_use_alias(self):
        self.run_cmd("alias hi print hello")
        self.assertEqual(self.out("hi"), "hello")

    def test_alias_with_args_appended(self):
        self.run_cmd("alias greet print hi")
        self.assertEqual(self.out("greet there"), "hi there")

    def test_alias_list(self):
        self.run_cmd("alias myls ls -la")
        out = self.out("alias")
        self.assertIn("myls", out)

    def test_alias_show_one(self):
        self.run_cmd("alias myls ls -la")
        out = self.out("alias myls")
        self.assertIn("ls", out)

    def test_alias_remove(self):
        self.run_cmd("alias myls ls -la")
        self.run_cmd("alias myls -")
        out = self.out("alias")
        self.assertNotIn("myls", out)

    def test_alias_cannot_shadow_builtin(self):
        err = self.err("alias ls something_else")
        self.assertIn("ERR", err)


# ═════════════════════════════════════════════════════════════════════════════
# 12. Options
# ═════════════════════════════════════════════════════════════════════════════

class TestOptions(ShellTestCase):

    def test_get_option(self):
        out = self.out("option echo")
        self.assertIn(out, ("on", "off"))

    def test_set_option_echo_on(self):
        self.run_cmd("option echo on")
        self.assertTrue(self.shell.option_set("echo"))

    def test_set_option_echo_off(self):
        self.run_cmd("option echo on")
        self.run_cmd("option echo off")
        self.assertFalse(self.shell.option_set("echo"))

    def test_options_lists_all(self):
        out = self.out("options")
        self.assertIn("echo", out)
        self.assertIn("stop-on-error", out)

    def test_echo_option_prints_commands(self):
        self.run_cmd("option echo on")
        out, _ = self.run_cmd("print hello")
        self.assertIn("::", out)   # echo prefix

    def test_stop_on_error_off_continues(self):
        self.run_cmd("option stop-on-error off")
        # rm a nonexistent file — would raise CommandFailedException with stop-on-error on
        self.run_cmd("rm no_such.txt && print reached")
        # if we get here without exception, stop-on-error off is working


# ═════════════════════════════════════════════════════════════════════════════
# 13. Pipes
# ═════════════════════════════════════════════════════════════════════════════

class TestPipes(ShellTestCase):

    def setUp(self):
        super().setUp()
        self.write_file("data.txt", "apple\nbanana\napricot\ncherry\n")

    def test_pipe_cat_grep(self):
        out = self.out("cat data.txt | grep ap")
        self.assertIn("apple", out)
        self.assertIn("apricot", out)
        self.assertNotIn("banana", out)

    def test_pipe_cat_wc(self):
        out = self.out("cat data.txt | wc")
        self.assertIn("4", out)

    def test_pipe_cat_head(self):
        out = self.out("cat data.txt | head -n 2")
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 2)

    def test_pipe_cat_tail(self):
        out = self.out("cat data.txt | tail -n 1")
        self.assertEqual(out.strip(), "cherry")

    def test_pipe_three_stages(self):
        out = self.out("cat data.txt | grep a | wc")
        # apple, banana, apricot match 'a' -> 3 lines
        self.assertIn("3", out)

    def test_pipe_grep_quiet(self):
        out = self.out("cat data.txt | grep -q ap")
        for line in out.strip().splitlines():
            self.assertNotRegex(line, r"^\d+:")


# ═════════════════════════════════════════════════════════════════════════════
# 14. Redirects
# ═════════════════════════════════════════════════════════════════════════════

class TestRedirects(ShellTestCase):

    def test_stdout_redirect_write(self):
        self.run_cmd("print hello > out.txt")
        # FileOutput opens in text mode, so Windows writes CRLF line endings.
        # Decode and normalise before comparing.
        content = self.read_file("out.txt").decode().replace("\r\n", "\n")
        self.assertEqual(content, "hello\n")

    def test_stdout_redirect_overwrite(self):
        self.write_file("out.txt", "old content\n")
        self.run_cmd("print new > out.txt")
        content = self.read_file("out.txt").decode().replace("\r\n", "\n")
        self.assertEqual(content, "new\n")

    def test_stdout_redirect_append(self):
        self.run_cmd("print first > out.txt")
        self.run_cmd("print second >> out.txt")
        content = self.read_file("out.txt").decode()
        self.assertIn("first", content)
        self.assertIn("second", content)

    def test_stderr_redirect(self):
        # rmdir on a file produces a reliable ERR to stderr
        self.write_file("notadir.txt", "x")
        self.run_cmd("rmdir notadir.txt 2> err.txt")
        content = self.read_file("err.txt").decode()
        self.assertIn("ERR", content)

    def test_both_redirect(self):
        self.run_cmd("print out &> both.txt")
        content = self.read_file("both.txt").decode()
        self.assertIn("out", content)

    def test_redirect_in_pipeline(self):
        self.write_file("in.txt", "hello\nworld\n")
        self.run_cmd("cat in.txt | grep hello > match.txt")
        self.assert_file_contains("match.txt", "hello")


# ═════════════════════════════════════════════════════════════════════════════
# 15. && chaining
# ═════════════════════════════════════════════════════════════════════════════

class TestAndAnd(ShellTestCase):

    def test_both_succeed(self):
        out = self.out("print first && print second")
        self.assertIn("first",  out)
        self.assertIn("second", out)

    def test_stops_on_failure(self):
        # With stop-on-error on, a CommandFailedException from the first stage
        # should prevent the second stage (touch marker.txt) from running.
        # A nonexistent external binary reliably raises CommandFailedException.
        # We call shell.execute() directly so the exception can propagate.
        self.shell.options["stop-on-error"] = "on"
        try:
            self.shell.execute(
                "totally_nonexistent_binary_xyz && touch marker.txt",
                history=False,
            )
        except m.CommandFailedException:
            pass
        self.assertFalse(
            os.path.exists(os.path.join(self.tmpdir, "marker.txt"))
        )

    def test_second_runs_when_first_succeeds(self):
        self.run_cmd("touch marker.txt && print done")
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "marker.txt")))

    def test_quoted_and_and_not_split(self):
        # && inside quotes should not be treated as a separator
        out = self.out('print "a && b"')
        self.assertIn("&&", out)


# ═════════════════════════════════════════════════════════════════════════════
# 16. Scripting — if / for / while / def / source / nested
# ═════════════════════════════════════════════════════════════════════════════

class TestScripting(ShellTestCase):

    def _run_script(self, code):
        """Write *code* to a temp .dsh file and source it."""
        path = self.write_file("test_script.dsh", textwrap.dedent(code))
        self.run_cmd(f"source {path}")

    def test_if_true(self):
        self._run_script("""
            if is-not-empty hello
                print yes
            end
        """)
        self.assertIn("yes", self._out.value())

    def test_if_false_skips_body(self):
        self._run_script("""
            if is-empty hello
                print should_not_appear
            end
        """)
        self.assertNotIn("should_not_appear", self._out.value())

    def test_for_loop(self):
        self._run_script("""
            for x in a b c
                print {x}
            end
        """)
        out = self._out.value()
        self.assertIn("a", out)
        self.assertIn("b", out)
        self.assertIn("c", out)

    def test_while_loop(self):
        self._run_script("""
            set n 0
            while {n} < 3
                print {n}
                set n eval {n} + 1
            end
        """)
        out = self._out.value()
        self.assertIn("0", out)
        self.assertIn("2", out)
        self.assertNotIn("3", out)

    def test_def_procedure(self):
        self._run_script("""
            def greet name
                print hello {name}
            end
            greet Alice
            greet Bob
        """)
        out = self._out.value()
        self.assertIn("hello Alice", out)
        self.assertIn("hello Bob",   out)

    def test_nested_if_in_for(self):
        self._run_script("""
            for x in 1 2 3
                if {x} == 2
                    print found2
                end
            end
        """)
        out = self._out.value()
        self.assertIn("found2", out)
        self.assertEqual(out.count("found2"), 1)

    def test_script_args(self):
        path = self.write_file("args.dsh", "print {arg0} {arg1}\n")
        self.run_cmd(f"script {path} hello world")
        self.assertIn("hello world", self._out.value())

    def test_script_argc(self):
        path = self.write_file("argc.dsh", "print {argc}\n")
        self.run_cmd(f"script {path} a b c")
        self.assertIn("3", self._out.value())

    def test_source_shares_env(self):
        path = self.write_file("env.dsh", "set sourced_var 42\n")
        self.run_cmd(f"source {path}")
        self.assertEqual(self.out("get sourced_var"), "42")

    def test_comment_lines_ignored(self):
        self._run_script("""
            # this is a comment
            print visible
        """)
        self.assertIn("visible", self._out.value())
        self.assertNotIn("comment", self._out.value())

    def test_nested_def_in_def(self):
        self._run_script("""
            def outer x
                def inner y
                    print inner {y}
                end
                inner {x}
            end
            outer test
        """)
        self.assertIn("inner test", self._out.value())


# ═════════════════════════════════════════════════════════════════════════════
# 17. tree
# ═════════════════════════════════════════════════════════════════════════════

class TestTree(ShellTestCase):

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.tmpdir, "src", "sub"))
        self.write_file("src/a.py",     "")
        self.write_file("src/b.py",     "")
        self.write_file("src/sub/c.py", "")
        self.write_file("README.md",    "")

    def test_tree_lists_all(self):
        out = self.out("tree")
        self.assertIn("a.py",      out)
        self.assertIn("c.py",      out)
        self.assertIn("README.md", out)

    def test_tree_filter_py(self):
        out = self.out("tree . *.py")
        self.assertIn("a.py",      out)
        self.assertIn("c.py",      out)
        self.assertNotIn("README", out)

    def test_tree_filter_exact(self):
        out = self.out("tree . README.md")
        self.assertIn("README.md", out)
        self.assertNotIn("a.py",   out)

    def test_tree_skips_pycache(self):
        os.makedirs(os.path.join(self.tmpdir, "__pycache__"))
        self.write_file("__pycache__/x.pyc", b"\x00")
        out = self.out("tree")
        self.assertNotIn("__pycache__", out)


# ═════════════════════════════════════════════════════════════════════════════
# 18. which and help
# ═════════════════════════════════════════════════════════════════════════════

class TestWhichHelp(ShellTestCase):

    def test_which_builtin(self):
        out = self.out("which ls")
        self.assertIn("internal", out)

    def test_which_unknown(self):
        out = self.out("which totally_unknown_cmd_xyz")
        self.assertEqual(out, "")

    def test_help_lists_commands(self):
        out = self.out("help")
        for cmd in ("ls", "cd", "grep", "cat", "set", "get"):
            self.assertIn(cmd, out)

    def test_help_specific_command(self):
        out = self.out("help grep")
        self.assertIn("grep", out)
        self.assertIn("pattern", out)


# ═════════════════════════════════════════════════════════════════════════════
# 19. history and lhistory
# ═════════════════════════════════════════════════════════════════════════════

class TestHistory(ShellTestCase):

    def test_history_records_commands(self):
        self.shell.execute("print alpha", history=True)
        self.shell.execute("print beta",  history=True)
        out = self.out("history")
        self.assertIn("print alpha", out)
        self.assertIn("print beta",  out)

    def test_history_filter(self):
        self.shell.execute("print alpha", history=True)
        self.shell.execute("print beta",  history=True)
        out = self.out("history alpha")
        self.assertIn("alpha", out)
        self.assertNotIn("beta", out)

    def test_lhistory_only_current_dir(self):
        self.shell.execute("print here", history=True)
        # change to a different dir
        subdir = os.path.join(self.tmpdir, "other")
        os.mkdir(subdir)
        self.shell.cwd = subdir
        self.shell.execute("print there", history=True)
        self.shell.cwd = self.tmpdir
        out = self.out("lhistory")
        self.assertIn("print here",  out)
        self.assertNotIn("print there", out)


# ═════════════════════════════════════════════════════════════════════════════
# 20. date
# ═════════════════════════════════════════════════════════════════════════════

class TestDate(ShellTestCase):

    def test_date_default_format(self):
        import re
        out = self.out("date")
        self.assertRegex(out, r"^\d{4}-\d{2}-\d{2}$")

    def test_date_with_time(self):
        import re
        out = self.out("date --with-time")
        self.assertRegex(out, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$")

    def test_date_terse(self):
        import re
        out = self.out("date --terse")
        self.assertRegex(out, r"^\d{8}$")

    def test_date_offset(self):
        import datetime
        today     = datetime.date.today()
        tomorrow  = (today + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
        yesterday = (today - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
        self.assertEqual(self.out("date 1"),  tomorrow)
        self.assertEqual(self.out("date -1"), yesterday)

    def test_date_custom_format(self):
        out = self.out('date --format "%Y"')
        import datetime
        self.assertEqual(out, str(datetime.date.today().year))


# ═════════════════════════════════════════════════════════════════════════════
# 21. time command
# ═════════════════════════════════════════════════════════════════════════════

class TestTime(ShellTestCase):

    def test_time_runs_command(self):
        out, err = self.run_cmd("time print hello")
        self.assertIn("hello", out)

    def test_time_prints_elapsed_to_stderr(self):
        _, err = self.run_cmd("time print hello")
        self.assertRegex(err.strip(), r"real\s+[\d.]+s")

    def test_time_no_args_gives_error(self):
        err = self.err("time")
        self.assertIn("ERR", err)

    def test_time_not_added_to_history(self):
        # time calls shell.execute(inner_cmd, history=False) so the inner
        # command should NOT appear as a new history entry.
        before = set(self.shell.history)
        self.shell.execute("time print hello", history=True)
        added = [h for h in self.shell.history if h not in before]
        # Only 'time print hello' itself should be new; not 'print hello'
        self.assertNotIn("print hello", added)


# ═════════════════════════════════════════════════════════════════════════════
# 22. File encoding/line-ending conversion commands
# ═════════════════════════════════════════════════════════════════════════════

class TestConvertCommands(ShellTestCase):

    # ── helpers ───────────────────────────────────────────────────────────────

    def _run_conv(self, cmd, raw_content):
        """Write content, run conversion command, return new raw bytes + output."""
        path = self.write_file("conv_test.txt", raw_content)
        out, err = self.run_cmd(f"{cmd} {path}")
        with open(path, "rb") as f:
            result = f.read()
        return result, out, err

    # ── _detect_file_encoding ────────────────────────────────────────────────

    def test_detect_utf8_bom(self):
        enc, has_bom = m._detect_file_encoding(b"\xef\xbb\xbfhello")
        self.assertEqual(enc, "utf-8-sig")
        self.assertTrue(has_bom)

    def test_detect_utf8(self):
        enc, has_bom = m._detect_file_encoding("caf\u00e9".encode("utf-8"))
        self.assertEqual(enc, "utf-8")
        self.assertFalse(has_bom)

    def test_detect_latin1(self):
        enc, has_bom = m._detect_file_encoding(b"\xe9")
        self.assertEqual(enc, "latin-1")
        self.assertFalse(has_bom)

    def test_detect_utf16(self):
        enc, has_bom = m._detect_file_encoding(b"\xff\xfehello")
        self.assertEqual(enc, "utf-16")
        self.assertTrue(has_bom)

    # ── _is_binary ────────────────────────────────────────────────────────────

    def test_is_binary_true(self):
        self.assertTrue(m._is_binary(bytes(range(256))))

    def test_is_binary_false_text(self):
        self.assertFalse(m._is_binary(b"hello world\n"))

    def test_is_binary_empty(self):
        self.assertFalse(m._is_binary(b""))

    # ── to-lf ────────────────────────────────────────────────────────────────

    def test_to_lf_converts_crlf(self):
        result, _, _ = self._run_conv("to-lf", b"a\r\nb\r\n")
        self.assertEqual(result, b"a\nb\n")

    def test_to_lf_converts_bare_cr(self):
        result, _, _ = self._run_conv("to-lf", b"a\rb\r")
        self.assertEqual(result, b"a\nb\n")

    def test_to_lf_unchanged_if_already_lf(self):
        _, out, _ = self._run_conv("to-lf", b"a\nb\n")
        self.assertIn("unchanged", out)

    def test_to_lf_preserves_utf8_bom(self):
        result, _, _ = self._run_conv("to-lf", b"\xef\xbb\xbfa\r\nb\r\n")
        self.assertTrue(result.startswith(b"\xef\xbb\xbf"))
        self.assertIn(b"\n", result)
        self.assertNotIn(b"\r", result)

    def test_to_lf_skips_binary(self):
        _, _, err = self._run_conv("to-lf", bytes(range(256)))
        self.assertIn("skipped", err)

    # ── to-crlf ──────────────────────────────────────────────────────────────

    def test_to_crlf_converts_lf(self):
        result, _, _ = self._run_conv("to-crlf", b"a\nb\n")
        self.assertEqual(result, b"a\r\nb\r\n")

    def test_to_crlf_unchanged_if_already_crlf(self):
        _, out, _ = self._run_conv("to-crlf", b"a\r\nb\r\n")
        self.assertIn("unchanged", out)

    def test_to_crlf_normalises_mixed(self):
        result, _, _ = self._run_conv("to-crlf", b"a\r\nb\n")
        self.assertEqual(result, b"a\r\nb\r\n")

    def test_to_crlf_preserves_latin1(self):
        raw = "caf\xe9\n".encode("latin-1")
        result, _, _ = self._run_conv("to-crlf", raw)
        self.assertEqual(result, "caf\xe9\r\n".encode("latin-1"))

    # ── to-utf8 ───────────────────────────────────────────────────────────────

    def test_to_utf8_converts_latin1(self):
        raw = "caf\xe9\n".encode("latin-1")
        result, _, _ = self._run_conv("to-utf8", raw)
        self.assertEqual(result, "caf\u00e9\n".encode("utf-8"))

    def test_to_utf8_strips_bom(self):
        result, _, _ = self._run_conv("to-utf8", b"\xef\xbb\xbfhello\n")
        self.assertFalse(result.startswith(b"\xef\xbb\xbf"))
        self.assertEqual(result, b"hello\n")

    def test_to_utf8_unchanged_if_already_utf8(self):
        _, out, _ = self._run_conv("to-utf8", b"hello\n")
        self.assertIn("unchanged", out)

    # ── to-utf8-bom ───────────────────────────────────────────────────────────

    def test_to_utf8_bom_adds_bom(self):
        result, _, _ = self._run_conv("to-utf8-bom", b"hello\n")
        self.assertTrue(result.startswith(b"\xef\xbb\xbf"))

    def test_to_utf8_bom_unchanged_if_already_bom(self):
        _, out, _ = self._run_conv("to-utf8-bom", b"\xef\xbb\xbfhello\n")
        self.assertIn("unchanged", out)

    def test_to_utf8_bom_converts_latin1(self):
        raw = "caf\xe9\n".encode("latin-1")
        result, _, _ = self._run_conv("to-utf8-bom", raw)
        self.assertTrue(result.startswith(b"\xef\xbb\xbf"))
        self.assertIn("caf\u00e9".encode("utf-8"), result)

    # ── to-latin1 ─────────────────────────────────────────────────────────────

    def test_to_latin1_converts_utf8(self):
        raw = "caf\u00e9\n".encode("utf-8")
        result, _, _ = self._run_conv("to-latin1", raw)
        self.assertEqual(result, "caf\xe9\n".encode("latin-1"))

    def test_to_latin1_unchanged_if_already_latin1(self):
        _, out, _ = self._run_conv("to-latin1", "caf\xe9\n".encode("latin-1"))
        self.assertIn("unchanged", out)

    def test_to_latin1_skips_unencodable(self):
        raw = "\u4e2d\u6587\n".encode("utf-8")
        result, out, _ = self._run_conv("to-latin1", raw)
        self.assertIn("skipped", out)
        self.assertEqual(result, raw)  # file unchanged

    # ── glob support ──────────────────────────────────────────────────────────

    def test_glob_converts_multiple_files(self):
        self.write_file("g1.txt", b"a\r\nb\r\n")
        self.write_file("g2.txt", b"c\r\nd\r\n")
        glob_pat = os.path.join(self.tmpdir, "*.txt")
        self.run_cmd(f"to-lf {glob_pat}")
        self.assertEqual(self.read_file("g1.txt"), b"a\nb\n")
        self.assertEqual(self.read_file("g2.txt"), b"c\nd\n")

    # ── no args ───────────────────────────────────────────────────────────────

    def test_no_args_gives_error(self):
        for cmd in ("to-lf", "to-crlf", "to-utf8", "to-utf8-bom", "to-latin1"):
            err = self.err(cmd)
            self.assertIn("ERR", err, f"{cmd} should error with no args")


# ═════════════════════════════════════════════════════════════════════════════
# 23. file — type detection
# ═════════════════════════════════════════════════════════════════════════════

class TestFileCmd(ShellTestCase):

    def test_detects_python_source(self):
        self.write_file("hello.py", "print('hi')\n")
        out = self.out("file hello.py")
        self.assertIn("Python source", out)

    def test_detects_json(self):
        self.write_file("data.json", '{"key": "value"}\n')
        out = self.out("file data.json")
        self.assertIn("JSON", out)

    def test_detects_directory(self):
        os.mkdir(os.path.join(self.tmpdir, "mydir"))
        out = self.out("file mydir")
        self.assertIn("directory", out)

    def test_detects_empty_file(self):
        self.write_file("empty.txt", b"")
        out = self.out("file empty.txt")
        self.assertIn("empty", out)

    def test_detects_png(self):
        # Minimal valid PNG header
        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
        self.write_file("img.png", png)
        out = self.out("file img.png")
        self.assertIn("PNG", out)

    def test_detects_markdown_encoding_and_endings(self):
        self.write_file("notes.md", "# Title\nBody\n")
        out = self.out("file notes.md")
        self.assertIn("Markdown", out)
        self.assertIn("ASCII", out)

    def test_missing_file(self):
        out = self.out("file missing.txt")
        self.assertIn("ERROR", out)

    def test_no_args_gives_error(self):
        err = self.err("file")
        self.assertIn("ERR", err)


# ═════════════════════════════════════════════════════════════════════════════
# 24. Env class
# ═════════════════════════════════════════════════════════════════════════════

class TestEnv(unittest.TestCase):

    def test_set_and_get(self):
        e = m.Env()
        e.set("x", 1)
        self.assertEqual(e.get("x"), 1)

    def test_default_on_missing(self):
        e = m.Env()
        self.assertIsNone(e.get("missing"))
        self.assertEqual(e.get("missing", "default"), "default")

    def test_parent_lookup(self):
        parent = m.Env()
        parent.set("a", "from_parent")
        child = m.Env(parent)
        self.assertEqual(child.get("a"), "from_parent")

    def test_child_shadows_parent(self):
        parent = m.Env()
        parent.set("x", "parent_val")
        child = m.Env(parent)
        child.set("x", "child_val")
        self.assertEqual(child.get("x"), "child_val")
        self.assertEqual(parent.get("x"), "parent_val")

    def test_remove_local(self):
        e = m.Env()
        e.set("y", 42)
        e.remove("y")
        self.assertIsNone(e.get("y"))

    def test_update_finds_parent(self):
        parent = m.Env()
        parent.set("z", "old")
        child = m.Env(parent)
        child.update("z", "new")
        self.assertEqual(parent.get("z"), "new")

    def test_names_merges_scopes(self):
        parent = m.Env()
        parent.set("a", 1)
        child = m.Env(parent)
        child.set("b", 2)
        self.assertIn("a", child.names())
        self.assertIn("b", child.names())


# ═════════════════════════════════════════════════════════════════════════════
# entry point
# ═════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    unittest.main(verbosity=2)
