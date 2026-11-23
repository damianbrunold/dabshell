# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

dabshell is written in dabscm Scheme (R7RS + dabscm libraries) and compiled
into a native executable with dabscm native's `scmc`. dabscm lives in
`../dabscm` (docs: `../dabscm/documentation/libraries/*.md`). The former
Python implementation is on the `python` branch.

## Commands

`scm` below is the dabscm interpreter: `java -jar ../dabscm/scm-java/scm.jar`.

```bash
# Run all tests on the JVM and compiled natively (build/test_*.exe)
scm run-tests.scm
scm run-tests.scm java            # JVM only, fast
scm run-tests.scm native core     # one test file (tests/test_core.scm), natively

# One test file directly
java -jar ../dabscm/scm-java/scm.jar tests/test_core.scm

# Build the executable (host: build/dsh(.exe); windows|linux|linux-arm64|all: dist/)
scm build.scm
scm build.scm all
scm build.scm deb                 # dist/dabshell_<version>_{amd64,arm64}.deb via (scm deb)

# Run from source
scm bin/dsh.scm
```

Run commands with `</dev/null` and a timeout. When calling `wsl.exe` from
Git Bash, set `MSYS_NO_PATHCONV=1` (otherwise paths and `$?` get mangled).
Linux test binaries can be cross-compiled with
`scmc tests/test_x.scm -I src -I tests -o build/linux/test_x --target x86_64-linux-musl`
and run under WSL.

## Architecture

Library `(dabshell xxx)` is the file `src/dabshell-xxx.sld`; the program is
`bin/dsh.scm`, which imports every command library so their commands get
registered.

- `util` — platform, Python-compatible path functions (`path-join`,
  `path-normpath`, ...; dabshell does not rely on dabscm's path functions),
  string helpers, file decoding (UTF-8 / BOM / Latin-1), binary detection.
- `core` — `env` (lexically scoped variables, aliases and commands share one
  namespace), command records (`define-command` registers a builtin),
  `session` (state shared with nested shells: jobs, history, setscm),
  `shell` (cwd, env, output ports `outs`/`oute`/`outp`, options, piped
  stdin string), parsing (`replace-vars`, `split-command`, `parse-pipeline`,
  `split-command-list`), the expression evaluator, `shell-execute`,
  pipelines, redirects, external programs, background jobs, scripts
  (`execute-lines`: if/for/while/def).
- `builtins` — alias, option(s), run, eval, script, source, cd, pwd, set,
  get, echo, print, history, lhistory, which, title, setscm, reset-term,
  help, time, jobs, wait.
- `files`, `text`, `awk`, `data` (json, fetch, tar, zip), `less`,
  `editor` (+ `editor-buffer`, `editor-core` with the emacs keymap,
  `editor-vim`) — the other commands.
- `keys` — key reader (VT sequences on both platforms) → chars, symbols
  (`'left`, `'ctrl-a`, ...), `(meta . key)`; `with-key-source` for tests.
- `completion`, `interactive` — tab completion, prompt, line editor,
  history file, main loop.

**Execution flow:** `shell-execute` → split on `&&`/`&` → `parse-pipeline`
(stages with redirects and `NAME=value` overlays) → `execute-pipeline`: each
non-last stage's output is captured into a string and fed as stdin to the
next → `dispatch-stage`: alias expansion, then builtin / `.dsh` script /
`.scm` via the scm runner / directory (ls) / external program.

Command resolution: built-ins → aliases → venv/bin → .venv/bin → cwd → PATH
(PATHEXT on Windows).

External programs: inherited console when nothing is piped or redirected
(`run-program`), otherwise `run-program/capture` (output buffered until the
program ends). The shell never changes the process cwd; children get
`work-dir`. Interactive mode switches the terminal to raw mode only while
reading keys (raw mode disables output post-processing, so raw-mode output
uses `\r\n`). On native builds `%shutdown-signal` keeps the shell alive
when Ctrl+C stops a foreground program.

Conventions: Python behaviour was the specification (messages like
`ERR: ...`, `True`/`False` printing of booleans). Failures raise via
`(command-failed!)`; output via `println`/`print-to` on the shell's ports.

`DABSCM-FINDINGS.md` lists dabscm bugs and missing features found during
the port, with repros; dabshell works around them.

## Tests

`tests/test_*.scm` (~1070 checks) use `(scm test)` and `(dabshell testing)`
(`with-shell` gives a headless shell in a temp directory with captured
output; `run-cmd`, `out`, `err`, `write-file`, `read-text`). Every test file
must pass on the JVM and natively (Windows and Linux).
