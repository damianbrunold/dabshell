# dabshell

A lightweight, cross-platform interactive shell written in pure Python. dabshell runs on both Windows and Linux/macOS, requires Python 3.11 or later, and has no third-party dependencies. It is designed to be simple, portable, and scriptable, with a syntax that is intentionally less complex than bash.

---

## Installation

dabshell is installed from source by cloning the repository, building a wheel, and installing it locally.

### Prerequisites

- Python 3.11 or higher
- `pip` and `build` available in your Python environment

### Steps

**1. Clone the repository**

```bash
git clone https://github.com/damianbrunold/dabshell
cd dabshell
```

**2. Build the wheel**

```bash
pip install build       # if not already installed
python -m build
```

This produces a `.whl` file in the `dist/` directory (e.g. `dist/dabshell-0.0.4-py3-none-any.whl`).

**3. Install the wheel**

```bash
pip install dist/dabshell-0.0.4-py3-none-any.whl
```

Replace 0.0.4 with the current version number.

Once installed, the `dsh` command will be available in your PATH.

Of course, it generally is better to create a local virtual environment and install into this and not in the global one.

### Upgrading

When a new version is available, repeat the build and install steps. To replace the previously installed version, pass the `--force-reinstall` flag:

```bash
pip install --force-reinstall dist/dabshell-0.0.4-py3-none-any.whl
```

### Uninstalling

```bash
pip uninstall dabshell
```

---

### Startup configuration

On startup, dabshell reads `~/.dabshell` if it exists and executes it as a script. Use this file to define aliases, set variables, configure options, and so on.

---

## The prompt

The prompt is drawn on a single line and shows, left to right:

- The active Python version if a `venv/` or `.venv/` virtual environment is found in the current directory or any parent (`py=3.12.1`)
- The project version if a `pyproject.toml` is found in the current directory (`pr=1.4.0`)
- The current git branch, coloured green when clean and red when there are uncommitted changes (`main` or `main*`)
- The current working directory, truncated from the left if it would exceed the terminal width

---

## Line editing

dabshell provides full in-line editing. The following keys are available at the prompt:

| Key | Action |
|-----|--------|
| `Left` / `Right` | Move cursor one character |
| `Ctrl+Left` / `Ctrl+Right` | Move cursor one word |
| `Home` / `End` | Move to start / end of line |
| `Backspace` | Delete character to the left |
| `Delete` | Delete character under cursor |
| `Ctrl+W` | Delete word to the left |
| `Up` / `Down` | Walk backwards / forwards through command history |
| `Esc` | Clear the current line |
| `Tab` | Complete the current word (file, directory, or command name). Press twice to list all candidates. |
| `Ctrl+C` | Clear the current line; exit the shell if the line is already empty |
| `Ctrl+R` | Enter reverse history search (see below) |
| `Enter` | Execute the current line |

---

## History

dabshell maintains two history stores:

**Global history** (`history`) contains every command entered across all sessions, loaded from `~/.dabshell-history` at startup. Use `Up`/`Down` to navigate it at the prompt, or recall a specific entry by number with `!N`.

**Local history** (`lhistory`) is the subset of global history that was entered from the current working directory.

The history file uses a tab-separated format (`path\tcommand`) and is automatically compacted when it exceeds 1000 entries.

### Recalling by number

```
!42
```

Typing `!N` and pressing Enter loads history entry number 42 into the line buffer for editing or execution, without executing it immediately.

### Reverse history search

Press `Ctrl+R` to enter reverse-i-search mode. The prompt changes to:

```
(reverse-i-search)`': 
```

As you type, the most recent local history entry containing your query is shown. The matching portion is highlighted in bold and underlined.

| Key in search mode | Action |
|--------------------|--------|
| Any character | Append to search query, update match |
| `Backspace` | Shorten query, restart search from newest |
| `Ctrl+R` or `Up` | Cycle to the next older match |
| `Down` | Cycle to the next newer match |
| `Enter` | Accept: load the matched command into the line buffer (does not execute) |
| `Esc` / `Ctrl+C` | Cancel: restore the line that was active before search |
| Any other key | Accept current match, exit search, process the key normally |

---

## Variables

Variables are set with `set` and read back with `get` or with `{varname}` expansion.

```
set greeting hello
print {greeting}         # prints: hello
```

Variable expansion happens before a command is parsed, so variables can appear anywhere in a command line.

### Command substitution

Use `{!command}` to substitute the output of a command inline:

```
set files {!ls}
print {files}
```

### Single-quote suppression

Wrapping text in single quotes suppresses variable expansion:

```
print '{greeting}'       # prints: {greeting}  (literal, not expanded)
```

### Setting a variable from a command's output

```
set result exec ls *.py
```

### Setting a variable from an expression

```
set n eval {n} + 1
```

---

## Pipes and redirections

### Pipes

Commands can be chained with `|`. The standard output of each command is fed as input to the next:

```
cat access.log | grep ERROR | wc
ls -la | grep ".py"
cat file.txt | head -n 5
```

The internal commands `cat`, `grep`, `head`, `tail`, and `wc` all accept piped input when no file arguments are given.

### Output redirection

| Syntax | Effect |
|--------|--------|
| `cmd > file` | Write stdout to file (overwrite) |
| `cmd >> file` | Append stdout to file |
| `cmd 2> file` | Write stderr to file |
| `cmd 2>> file` | Append stderr to file |
| `cmd &> file` | Write stdout and stderr to file (overwrite) |
| `cmd &>> file` | Append stdout and stderr to file |

Examples:

```
ls -la > listing.txt
make &> build.log
grep TODO *.py 2> /dev/null
```

Redirections and pipes can be combined. The redirect applies to the stage it is attached to:

```
find . -name "*.log" 2> /dev/null | grep error > errors.txt
```

---

## Chaining commands

Use `&&` to run the next command only if the previous one succeeded:

```
mkdir dist && cp build/* dist && echo done
```

`&&` is quote-aware and will not split on `&&` inside a quoted string.

---

## Quoting

- **Double quotes** preserve spaces and prevent word splitting: `echo "hello world"`
- Inside double quotes, `\"` produces a literal `"` and `\\` produces a literal `\`
- **Single quotes** additionally suppress variable expansion: `echo '{not expanded}'`
- `~` is expanded to the home directory outside of quotes

---

## Glob expansion

Many built-in commands accept glob patterns (`*`, `?`) in file arguments. Patterns are always resolved against the **current working directory** of the shell (not the process working directory). When a pattern matches multiple files the results are always in **alphabetical order**. If a pattern matches nothing the literal string is passed through unchanged, allowing the command's usual missing-file error to fire.

Commands that support glob expansion: `ls`, `cat`, `head`, `tail`, `wc`, `diff`, `grep`, `cp`, `mv`, `rm`, `rmdir`, `touch`, `file`, `to-lf`, `to-crlf`, `to-utf8`, `to-utf8-bom`, `to-latin1`.

---

## Built-in commands

### Navigation

#### `cd [<dir>]`
Change the current directory. With no argument, changes to the home directory (`~`).
```
cd /tmp
cd projects/myapp
cd          # go to home directory
cd ..
```

#### `pwd`
Print the current working directory.
```
pwd
```

#### `ls [<options>] [<path>...]`
List directory contents. Glob patterns are accepted.

Options: `-l` (long format with size and timestamp), `-t` (sort by modification time, newest first), `-S` (sort by size, largest first), `-r` (reverse sort order).

Directories are shown in blue when output is going to the terminal.

```
ls
ls -la
ls -lt *.py
ls /tmp
```

### File viewing

#### `cat [<file>...]`
Print the contents of one or more files. Handles UTF-8 and Latin-1 encoding automatically. Accepts piped input when called with no arguments.
```
cat README.md
cat *.log
ls | cat
```

#### `head [-n <N>] [--lines=<N>] [<file>...]`
Print the first N lines of each file (default 20). Accepts piped input.
```
head -n 5 log.txt
cat access.log | head -n 100
```

#### `tail [-n <N>] [--lines=<N>] [-f] [<file>...]`
Print the last N lines of each file (default 20). With `-f` / `--follow`, keep reading as the file grows. Accepts piped input.
```
tail -n 20 app.log
tail -f /var/log/syslog
cat data.csv | tail -n 10
```

#### `wc [<file>...]`
Count lines in files. Prints a total when more than one file is counted. Accepts piped input. Skips directories silently.
```
wc *.py
cat README.md | wc
```

#### `diff <file1> <file2>`
Show a unified diff between two text files using Python's `difflib`.
```
diff old.py new.py
```

#### `grep <pattern> [-i] [-v] [-q] [<location>...]`
Search for a regular expression pattern in files. When no location is given and there is piped input, searches that instead. When no location is given and there is no piped input, searches the current directory recursively.

Options: `-i` (case-insensitive), `-v` (invert match, show non-matching lines), `-q` (quiet: print only the matched line without filename or line number).

The following directories are always skipped during recursive search: `venv`, `.venv`, `.env`, `__pycache__`, `.git`.

```
grep TODO *.py
grep -i error logs/
cat build.log | grep -i warning
grep "def " src/ -i
```

### File management

#### `cp <source>... <dest>`
Copy one or more files to a destination file or directory. Glob patterns are accepted in source paths.
```
cp README.md README.md.bak
cp *.py backup/
```

#### `mv <source>... <dest>`
Move one or more files or directories to a destination. Glob patterns are accepted.
```
mv old_name.py new_name.py
mv *.log archive/
```

#### `rm <file>...`
Delete files. Glob patterns are accepted. Prints an error for directories (use `rmdir` instead).
```
rm *.pyc
rm build/output.o
```

#### `mkdir <dir>...`
Create directories, including any missing parent directories.
```
mkdir src/utils
mkdir -p a/b/c     # (parent creation is always on)
```

#### `rmdir <dir>...`
Delete directories and their contents recursively. Glob patterns are accepted.
```
rmdir build/
rmdir __pycache__ .mypy_cache
```

#### `touch <file>...`
Update the modification timestamp of existing files, or create new empty files if they do not exist. Glob patterns are accepted for existing files.
```
touch marker.txt
touch *.py        # update timestamps of all .py files
```

#### `tree [<dir>] [<filter>...]`
Display a recursive file tree. Skips `venv`, `.venv`, `.env`, `__pycache__`, `.git`, and `*.egg-info` directories automatically.

Optional filter arguments match filenames: `*.py` matches by suffix, `Makefile` matches exactly, `test*` matches by prefix.

```
tree
tree src/
tree . *.py *.md
```

### Path utilities

#### `basename <path>`
Return the filename component of a path.
```
basename /home/user/file.txt    # → file.txt
```

#### `dirname <path>`
Return the directory component of a path.
```
dirname /home/user/file.txt     # → /home/user
```

#### `get-ext <filename>`
Return the file extension including the leading dot.
```
get-ext archive.tar.gz          # → .gz
```

#### `remove-ext <filename>`
Return the filename without its extension.
```
remove-ext report.pdf           # → report
```

### Output

#### `echo <value>...`
Print arguments, re-quoting any that contain spaces.
```
echo hello world
echo "path is" {cwd}
```

#### `print <value>...`
Print arguments joined by spaces, without re-quoting.
```
print hello world
print {greeting}, user!
```

### Variables

#### `set <name> <value>...`
Set a variable.
```
set greeting hello
set path /usr/local/bin
set n eval {n} + 1          # set from expression result
set files exec ls *.py      # set from command output
```

#### `get [<name>]`
Print the value of a variable. With no argument, prints all variables.
```
get greeting
get
```

#### `eval <expression>`
Evaluate an expression and print the result. See the [Expressions](#expressions) section for the full operator list.
```
eval 3 + 4
eval {x} > 10
eval exists myfile.txt
```

### Aliases

#### `alias [<name> [<value>... | -]]`
Define, show, or remove a command alias. With no arguments, lists all aliases. With only a name, shows that alias. With a name and `-`, removes the alias. Aliases cannot shadow built-in commands.

```
alias ll ls -la
alias gs git status
alias                       # list all
alias ll                    # show one
alias ll -                  # remove
```

Once defined, an alias is expanded before the command is executed:

```
ll /tmp                     # expands to: ls -la /tmp
```

### History

#### `history [<filter>]`
Show the global command history with index numbers. If a filter is given, shows only entries containing that string.
```
history
history git
```

#### `lhistory [<filter>]`
Show the history for the current working directory only.
```
lhistory
lhistory pytest
```

### Scripts

#### `script <file> [<arg>...]`
Execute a `.dsh` script file. Arguments are available as `{arg0}`, `{arg1}`, …, `{argc}` (number of arguments), and `{args}` (all arguments as a quoted string).

```
script deploy.dsh production
script build.dsh {arg0}
```

`.dsh` files can also be run directly by name:

```
deploy.dsh production
```

#### `source <file>`
Execute a script in the current shell environment (variables and aliases defined in the script remain active afterwards).
```
source ~/.dabshell
source project_env.dsh
```

### Introspection

#### `which <name>...`
Show where a command is found. Prints `internal command` for built-ins, and the full path for executables.
```
which python
which ls grep
```

#### `help [<command>]`
List all available commands, or show the help text for a specific command.
```
help
help grep
help set
```

### Shell options

#### `option <name> [<value>]`
Get or set a shell option. Without a value, prints the current setting.

| Option | Default | Description |
|--------|---------|-------------|
| `echo` | `off` | When `on`, print each command before executing it |
| `stop-on-error` | `on` | When `on`, stop script execution if a command fails |

```
option echo on
option stop-on-error off
option echo               # print current value
```

#### `options`
List all currently active options and their values.
```
options
```

### Other

#### `date [<offset>] [--terse] [--with-time] [--format <fmt>]`
Print the current date. `offset` is a number of days to add or subtract. `--with-time` includes hours, minutes, and seconds. `--terse` removes separators. `--format` accepts a `strftime` format string.
```
date
date -1                     # yesterday
date 7                      # one week from today
date --with-time
date --terse --with-time    # e.g. 20240315-143022
date --format "%B %d, %Y"  # e.g. March 15, 2024
```

#### `title <text>`
Set the terminal window title. Uses the standard OSC escape sequence, which works on Linux/macOS terminals and on Windows 10+ consoles. On very old Windows versions, falls back to the `title` system command.
```
title My Project
```

#### `reset-term`
Reset the terminal state. Useful if the terminal display becomes corrupted.

### File conversion

These commands convert text files in place. Each file is read, transformed, and written back only if the content actually changed. Binary files are detected automatically and skipped. Glob patterns are accepted.

Each command prints one of the following per file:
- `converted <path>` — file was changed
- `unchanged <path>` — file was already in the target format
- `skipped <path>: <reason>` — file was not modified (binary, UTF-16, or unencodable characters)
- `ERR: …` — file could not be read or written

#### `to-lf <file>...`
Convert all line endings to LF (`\n`, Unix style). CRLF and bare CR are both normalised. The file encoding is preserved, including any UTF-8 BOM.
```
to-lf notes.txt
to-lf *.py
```

#### `to-crlf <file>...`
Convert all line endings to CRLF (`\r\n`, Windows style). Mixed or bare-LF line endings are both normalised. The file encoding is preserved, including any UTF-8 BOM.
```
to-crlf report.txt
to-crlf *.csv
```

#### `to-utf8 <file>...`
Re-encode the file as UTF-8 without BOM. Latin-1 and UTF-8-BOM files are converted; plain UTF-8 files are left unchanged. Line endings are preserved.
```
to-utf8 legacy.txt
to-utf8 *.html
```

#### `to-utf8-bom <file>...`
Re-encode the file as UTF-8 with a BOM prefix (`\xef\xbb\xbf`). Useful for tools (such as Excel) that require a BOM to recognise UTF-8. Line endings are preserved.
```
to-utf8-bom data.csv
```

#### `to-latin1 <file>...`
Re-encode the file as Latin-1 (ISO 8859-1). If the file contains characters that cannot be represented in Latin-1 (e.g. CJK characters, emoji), the file is skipped and a message is printed. Line endings are preserved.
```
to-latin1 old-system-export.txt
```

#### `watch [-n <seconds>] <cmd> [<arg>...]`
Run a command repeatedly, clearing the screen and redisplaying its output each time. Output is capped to one screen so the display never scrolls. Press `Ctrl+C` to stop.

On Windows, ANSI virtual-terminal processing is enabled automatically at startup so the screen clears the same way as on Linux/macOS. On very old Windows versions where VT mode is unavailable, `cls` is used as a fallback.

| Option | Default | Description |
|--------|---------|-------------|
| `-n <seconds>` | `10` | Interval between runs (decimals accepted) |

A header line shows the interval and the command being watched. The output area uses all remaining terminal rows, truncating both line width and line count to fit.

```
watch ls
watch -n 5 ls -la
watch -n 2 git status
watch -n 30 df -h
```

#### `time <cmd> [<arg>...]`
Execute a command and print the elapsed wall-clock time to stderr when it finishes. The output format mirrors the Linux `time` built-in: seconds only for runs under one minute, or `Xm Y.YYYs` for longer runs. The timed command is not added to history.
```
time python myscript.py
time grep -r TODO .
time make && echo done
```

Example output:
```
real	0.341s
real	2m14.007s
```

#### `run <command> [<arg>...]`
Explicitly run an external command. Normally you do not need this — any unrecognised command name is passed to the OS automatically. `run` is useful when you need to be explicit or when the command name clashes with something in the environment.
```
run python script.py
```

#### `file <file>...`
Detect and describe the type of each file. Uses magic byte signatures for binary formats and content/extension heuristics for text formats. For text files, reports the character encoding and line endings. PNG, JPEG, GIF, BMP, WebP, and TIFF images include pixel dimensions. Glob patterns are accepted.

```
file README.md
file *
file ~/downloads/*
```

Example output:
```
README.md:        Markdown document, UTF-8, LF line endings
main.py:          Python source, ASCII, LF line endings
config.yaml:      YAML data, UTF-8, LF line endings
archive.tar.gz:   GZIP compressed data
photo.jpg:        JPEG image, 1920x1080
thumbnail.png:    PNG image, 64x64
logo.gif:         GIF image, 320x240
report.docx:      Word document (.docx)
data.xlsx:        Excel workbook (.xlsx)
app.exe:          PE executable (Windows)
libfoo.so:        ELF executable
notes_win.txt:    plain text, ASCII, CRLF line endings
mixed.log:        log file, UTF-8, mixed line endings (CRLF: 3, LF: 142)
dump.bin:         binary data (78% non-printable bytes)
```

**Supported types by detection method:**

*Magic bytes (binary formats):*
ELF executable, PE executable (Windows), Mach-O binary (macOS), Java class file, WebAssembly, PDF, ZIP, GZIP, BZIP2, XZ, 7-Zip, RAR, TAR (ustar), MPEG-4 container, PNG, JPEG, GIF, BMP, WebP, FLAC, OGG, MP3, Matroska/WebM, WAV, AVI, Parquet, SQLite, OLE2/legacy Office, compiled Python (.pyc). ZIP archives are probed internally to distinguish Word (.docx), Excel (.xlsx), PowerPoint (.pptx), and JAR files from plain ZIPs.

*By file extension (text formats):*

| Category | Extensions |
|---|---|
| Python | `.py` `.pyi` |
| JavaScript/TypeScript | `.js` `.mjs` `.cjs` `.ts` `.tsx` `.jsx` |
| JVM | `.java` `.kt` `.kts` `.scala` |
| C/C++ | `.c` `.h` `.cpp` `.cc` `.cxx` `.hpp` |
| Systems | `.cs` `.go` `.rs` `.swift` |
| Dynamic/scripting | `.rb` `.php` `.lua` `.pl` `.pm` `.r` `.R` `.jl` |
| Functional | `.hs` `.lhs` `.ml` `.mli` `.fs` `.fsi` `.fsx` `.clj` `.cljs` `.ex` `.exs` `.erl` `.hrl` |
| Lisp family | `.scm` `.sld` (Scheme), `.lsp` `.lisp` (Common Lisp) |
| Shell | `.sh` `.bash` `.zsh` `.fish` `.bat` `.cmd` `.ps1` `.psm1` `.dsh` |
| Web/markup | `.html` `.htm` `.css` `.scss` `.sass` `.less` `.xml` `.xsd` `.xsl` `.svg` |
| Data | `.json` `.jsonl` `.ndjson` `.yaml` `.yml` `.toml` `.ini` `.cfg` `.conf` `.env` `.csv` `.tsv` `.sql` `.graphql` `.gql` `.proto` |
| Infrastructure | `.tf` `.tfvars` `.nix` `.vim` `.el` `Dockerfile` |
| Docs | `.md` `.markdown` `.rst` `.tex` `.po` `.pot` |
| Misc text | `.diff` `.patch` `.log` `.txt` |
| Certificates | `.pem` `.crt` `.cer` `.key` |

*By content heuristics (no extension or unknown extension):*
Python, Shell, Bash, Zsh, Fish, Ruby, Perl, Node.js (shebang detection), PHP (`<?php`), HTML (`<!DOCTYPE html>`), XML (`<?xml`), YAML (leading `---`), JSON (structural parse), PEM data (`-----BEGIN`).

**Encoding detection:** BOM markers are checked first (UTF-8 BOM, UTF-16 LE/BE). Otherwise the file is tested against UTF-8; content that decodes cleanly and contains only ASCII codepoints is reported as `ASCII`, valid multibyte UTF-8 as `UTF-8`, and anything that fails UTF-8 decoding as `Latin-1`.

**Line ending detection:** Counts CRLF, bare LF, and bare CR sequences independently. Reports a single type when only one is present, or `mixed line endings (CRLF: N, LF: M)` when more than one type appears.

---

## Scripting

Scripts are plain text files with one statement per line. Lines starting with `#` are comments and blank lines are ignored.

### Running a script

```
script myscript.dsh arg1 arg2
```

Or if the file ends in `.dsh`, directly:

```
myscript.dsh arg1 arg2
```

### Script arguments

Inside a script, the following variables are set automatically:

| Variable | Value |
|----------|-------|
| `{arg0}` | First argument |
| `{arg1}` | Second argument |
| `{argN}` | Nth argument |
| `{argc}` | Number of arguments |
| `{args}` | All arguments as a single quoted string |

### Control flow

All blocks are closed with `end`.

#### `if <expression>`

```
if exists output.txt
    cat output.txt
end
```

#### `for <var> in <values...>`

Values can be literals or glob patterns. When a value contains `*` or `?`, it is expanded against the current working directory and the results are sorted alphabetically. The loop variable receives the full absolute path for each match. If a glob pattern matches nothing, the loop body is simply skipped for that pattern.

```
for f in *.py
    print {f}
end

for env in production staging
    script deploy.dsh {env}
end
```

#### `while <expression>`

```
set n 0
while {n} < 10
    print {n}
    set n eval {n} + 1
end
```

#### `def <name> [<param>...]`

Defines a reusable procedure. Parameters become local variables inside the body.

```
def greet name
    print Hello, {name}!
end

greet Alice
greet Bob
```

Procedures defined in a script can call each other. They share the lexical environment where they were defined.

### Example script

```
# build.dsh — build and optionally deploy
set target {arg0}
if is-empty {target}
    set target dev
end

print Building for {target}...
python -m build

if {target} == production
    print Deploying to production
    script deploy.dsh
end

print Done.
```

---

## Expressions

The `eval` command and `if`/`while` conditions all use the same expression evaluator.

### Arithmetic operators (integer only)

| Operator | Meaning |
|----------|---------|
| `+` | Add |
| `-` | Subtract |
| `*` | Multiply |
| `/` | Integer divide |
| `%` | Modulo |
| `**` | Power |

```
eval 10 + 3        # 13
eval 10 / 3        # 3
eval 2 ** 8        # 256
```

### Comparison operators

| Operator | Meaning |
|----------|---------|
| `==` | Equal (string) |
| `!=` | Not equal (string) |
| `==ci` | Equal, case-insensitive |
| `!=ci` | Not equal, case-insensitive |
| `<` | Less than (integer) |
| `<=` | Less than or equal (integer) |
| `>` | Greater than (integer) |
| `>=` | Greater than or equal (integer) |
| `lt` | Less than (integer) — unambiguous alias for `<` |
| `lteq` | Less than or equal (integer) — unambiguous alias for `<=` |
| `gt` | Greater than (integer) — unambiguous alias for `>` |
| `gteq` | Greater than or equal (integer) — unambiguous alias for `>=` |
| `=*` | Starts with (either side) |
| `*=` | Ends with (either side) |
| `=*ci` | Starts with, case-insensitive |
| `*=ci` | Ends with, case-insensitive |

The symbolic operators `<`, `>`, `<=`, `>=` are interpreted by the shell as redirect operators when used in a command line. Use the word aliases (`lt`, `gt`, `lteq`, `gteq`) to avoid quoting or redirection ambiguity in scripts. The symbolic forms still work when properly quoted: `eval "5 > 3"`.

```
eval {name} == Alice
eval {ext} *=ci .PY
eval {count} gteq 10
eval {n} lt 100
```

### Predicates (two-part expressions)

| Predicate | True when |
|-----------|-----------|
| `exists <path>` | Path exists |
| `not-exists <path>` | Path does not exist |
| `is-file <path>` | Path is a regular file |
| `is-not-file <path>` | Path is not a regular file |
| `is-dir <path>` | Path is a directory |
| `is-not-dir <path>` | Path is not a directory |
| `has-extension <path>` | Path has the given extension |
| `has-not-extension <path>` | Path does not have the given extension |
| `is-empty <value>` | Value is an empty string |
| `is-not-empty <value>` | Value is not empty |

```
if is-file output.json
    cat output.json
end

if not-exists dist/
    mkdir dist
end

if is-not-empty {arg0}
    set target {arg0}
end
```

### Boolean operators and parentheses

Expressions can be combined using `and`, `or`, and `not`. Parentheses control grouping. These work in `eval`, `if`, `while`, and `set … eval`.

| Operator | Meaning |
|----------|---------|
| `not <expr>` | True if `<expr>` is falsy, false otherwise |
| `<expr> and <expr>` | True if both sides are truthy (short-circuits) |
| `<expr> or <expr>` | True if either side is truthy (short-circuits) |
| `( <expr> )` | Group sub-expressions to control precedence |

Precedence (highest to lowest): `not` > `and` > `or`. Use parentheses to override.

```
if is-file config.json and is-not-empty {target}
    print building {target}
end

if {score} gteq 0 and {score} lteq 100
    print valid score
end

if not exists output/ or not is-file output/result.txt
    print output missing
end

if ( {mode} == fast or {mode} == turbo ) and is-not-empty {input}
    print running in {mode} mode
end

set ok eval is-file src.txt and not is-file dst.txt
```

---

## Configuration file

On startup, dabshell executes `~/.dabshell` as a script using `source`. This is the right place for aliases, variable defaults, and option settings:

```
# ~/.dabshell

option echo off
option stop-on-error on

alias ll ls -la
alias gs git status
alias gp git pull
alias ..  cd ..
alias ... cd ../..

set EDITOR vim
```

---

## Environment variables

OS environment variables are available with the `env:` prefix:

```
print {env:HOME}
print {env:PATH}
set here {env:PWD}
```

---

## Virtual environment detection

dabshell searches the current directory and each parent directory for a `venv/` or `.venv/` folder. When found, it runs `python --version` inside that venv and shows the result in the prompt (`py=3.12.1`). The venv does **not** need to be activated — dabshell detects and uses it automatically for executable lookup too: binaries in `venv/bin` (or `venv/Scripts` on Windows) are found before anything on `PATH`.

---

## Executable lookup order

When you type a command, dabshell searches in this order:

1. Internal built-in commands
2. Aliases
3. `venv/bin/` or `venv/Scripts/` in the current directory
4. `.venv/bin/` or `.venv/Scripts/` in the current directory
5. The current directory itself
6. The system `PATH`

`.dsh` scripts are found in all of the above locations and run automatically.