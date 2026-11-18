# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run tests
python -m unittest tests/test_dabshell.py

# Run a single test
python -m unittest tests.test_dabshell.TestClassName.test_method_name

# Build package
python -m build

# Install built package
pip install --force-reinstall dist/dabshell-*.whl
```

## Architecture

Almost the entire shell is implemented in a single file: `src/dabshell/__init__.py` (~7,000 lines). The one submodule is `src/dabshell/editor.py`, the full-screen `edit` command (`Buffer` text model, `Editor` session with `cmd_*` commands, `EmacsKeymap`). `CmdEdit` imports it lazily to avoid a circular import. A future vim keymap should map keys onto the same `cmd_*` methods.

**Core classes:**

- **`RawInput`** — Cross-platform raw terminal input. Windows uses `msvcrt`, Linux/macOS uses `termios`/`select`. Parses escape sequences (CSI/SS3) into unified key events.
- **`Stage`** — A single command in a pipeline, holding the command name, arguments, and redirection targets.
- **`Env`** — Lexically-scoped variable/alias environment. Supports parent chaining for nested scopes (e.g., inside `if`/`while`/`def` blocks).
- **`Dabshell`** — Main shell state: history, prompt rendering, command registration, and the top-level `execute()` method. Interactive loop lives here.
- **`Cmd`** — Abstract base for all built-in commands. Each subclass (e.g., `CmdLs`, `CmdGrep`, `CmdCd`) implements `run()`.

**Execution flow:**

```
Dabshell.execute(line)
  → expand variables/quotes
  → split on && (respecting quotes)
  → for each part: parse pipeline (stages separated by |)
  → execute_pipeline(stages)
      → single stage: _run_stage() directly
      → multi-stage: chain via subprocess pipes
  → _run_stage(): resolve command → apply redirections → run
```

Command resolution order: built-ins → aliases → venv/bin → .venv/bin → cwd → PATH.

**Scripting** (`CmdScript`/`CmdSource`): Control flow (`if`, `while`, `for`, `def`) is implemented by reading ahead in the script lines and recursively calling `execute()` within a nested `Env`.

**Expression evaluator**: Token-based recursive descent parser in `_tokenize_expr` / `evaluate_expression`. Operator precedence: `not` > `and` > `or`.

**Prompt** (`Dabshell.prompt()`): Shows venv Python version, project version from `pyproject.toml`, git branch (green=clean/red=dirty via `git status -s -b`), and cwd (truncated from the left).

## Tests

Tests are in `tests/test_dabshell.py` (~465 tests). They mock `RawInput` to avoid terminal interaction, use temporary directories, and capture output via `_CapturingOutput`. Tests are grouped by feature area (quoting, splitting, expressions, control flow, file ops, etc.).
