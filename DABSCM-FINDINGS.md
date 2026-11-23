# dabscm findings from the dabshell port

Bugs and inconsistencies in dabscm found while porting dabshell from Python.
dabshell works around them; they are collected here to be fixed in dabscm.
Found on Windows 11 with `scm-java/scm.jar` (JVM) and `scm-native/build/scm.exe`
/ `scmc.exe` (native) as of dabscm commit 3b325cb.

## Native

1. **`which` ignores PATHEXT on Windows** (native only).
   `(which "git")` and `(which "cmd")` give `#f`; `(which "git.exe")` works.
   `(which "notepad")` gives `C:\Program Files\Git\usr\bin\notepad` (an
   extension-less MSYS file) instead of `C:\WINDOWS\system32\notepad.EXE`.
   The JVM tries the PATHEXT extensions in order and gives the `.EXE`.

2. **Invalid string escapes are accepted by the native reader.**
   `(string-length "C:\W")` is 3 natively; the JVM tokenizer rejects it with
   `invalid string escape: \W`. Same for `(write (string->list "a\Db"))`.

2b. **`include` is not implemented natively** ("primitive not implemented
   in dabscm native: include"). On the JVM, `(include "x.scm")` resolves
   against the process cwd instead of the including file's directory
   (R7RS leaves it open, but the file's directory is what users expect).

2c. **`regex-search` error messages differ.** Pattern `"("`: JVM
   "regex-search: invalid pattern: Unclosed group", native "regular
   expression not supported (only the subset common to java.util.regex and
   .NET)" — the native message hides the real syntax error.

3. **`absolute-path` keeps `/` from a relative path on Windows.**
   `(absolute-path "foo/../bar")` → native `C:\...\dabshell\foo/../bar`,
   JVM `C:\...\dabshell\foo\..\bar`.

## JVM

4. **`normalized-path` of a rooted path without drive on Windows.**
   `(normalized-path "/a/b/../c")` → JVM `..\..\..\..\a\c` (relative to the
   cwd!), native `\a\c`.

5. **`cd` (`set-current-directory!`) is not seen by child processes on the
   JVM**, although its doc says child-process invocations behave as if cwd
   were the new path: after `(cd "C:\\Users")`,
   `(run-program/capture '("cmd" "/c" "cd"))` prints the old directory on the
   JVM; natively it prints `C:\Users`.

## Both

6. **`join-path` with an absolute second part concatenates.**
   `(join-path "C:\\a" "D:\\x")` → `C:\a\D:\x` (Python's os.path.join gives
   `D:\x`). Maybe intended; worth documenting either way.

10. **`(scm test)` on the JVM hides errors inside `test-assert`**: an
   error raised by the tested expression is reported as `expected: #f
   actual: #f` with no message. Repro:
   `(test-assert (later 1)) (define (later x) #t)` inside a test-begin.

11. **`glob` is case-sensitive on Windows.** With files `a.txt` and
   `B.TXT` in `d`, `(glob "d\*.txt")` returns only `a.txt` (Windows
   file names and Python's glob there are case-insensitive).

12. **`json-parse` / `json-read` accept trailing garbage.**
   `(json-parse "{\"a\": 1} x")` gives `(("a" . 1))`; a strict parser
   (Python's json) raises. `json-read` consumes the whole port, so a caller
   cannot check what is left.

13. **`directory-files` leaves out directories**, while its doc says "file
   names" (ambiguous); `directory-entries` gives both. Worth a doc note.

14. **scmc syntax errors have no location.** A program containing
   `(display 1))` fails with just "unexpected close parenthesis".

15. **64-bit bitwise arithmetic goes through bignums** and is slow: a
   straightforward SHA-512 in Scheme took 7.7 s/MB native, 15 s/MB on the
   JVM. (scm crypto) has md5, sha1 and sha256 only; sha224/sha384/sha512
   (and ideally sha3/blake2) would let dabshell's `hash` drop its own slow
   SHA-384/512 (0.7 s/MB native after splitting into 32-bit halves).

16. **No in-process `chmod` and no `realpath`.** `(scm fs) chmod` runs
   the external `chmod` program; symlinks have to be resolved by hand with
   `file-symlink?` / `read-symlink`.

17. **`(exact 0.1)` returns `1/10`** on JVM and native. R7RS `exact` of a
   flonum must give the exactly equal rational
   (`3602879701896397/36028797018963968`); `rationalize` is the way to get
   the simplest one. (The native commit log calls the current behaviour
   "as the JVM", so both need the fix.)

18. **Native `(- 0.0)` returns `0.0`**; the JVM gives `-0.0`.

19. **JVM characters above #xFFFF:** `(integer->char #x1F600)` gives
   `#ö00` (truncated) and `(string-length "600;")` is 2. Known
   from the README's UTF-16 note, but the silent truncation in
   `integer->char` is a bug (it should raise or produce the code point).

20. **`(scm zip)` entry ports lose data:** what is written to a
   `zip-add-binary-entry` port is lost unless the port is flushed before
   the next entry / closing the archive, and `close-port` on the entry port
   stops all later entries from being written.

21. **`utf8->string` on invalid bytes:** JVM gives `?`, native U+FFFD (as
   documented).

22. **JVM `(number->string 5e-324)`** gives `"4.9e-324"`, not the shortest
   round-tripping form (native: `"5.0e-324"`).

23. **`(scm json simple)` `json-parse`** also accepts leading zeros (`01`)
   and raw control characters in strings, and rejects `NaN` (see 12).

24. **`http-get-bytevector` with a flonum timeout** fails with "wrong
   argument type"; **`http-not-found`** takes no arguments, which the docs
   do not make clear.

25. **(scm archive) bzip2/xz/tar natively on Windows** cannot find their
   tools, as a consequence of 1 (`which` without PATHEXT).

## Missing features (worked around in dabshell)

7. **No public way to survive Ctrl+C while a child runs.** A shell must
   not die when the user stops a foreground program with Ctrl+C (the
   console sends the interrupt to both). dabshell calls the internal
   `((%primitive "%shutdown-signal"))` under `cond-expand dabscm-native`,
   which installs a recording handler. A public, documented API on all
   three implementations (e.g. `(interrupt-handler! 'ignore|'default|proc)`
   or `(with-interrupts-ignored thunk)`) would be better; on the JVM the
   shell currently dies with Ctrl+C during a child program.

8. **`terminal-raw!` always disables output post-processing** (OPOST), so
   `\n` does not return the carriage. The Python shell kept OPOST on and
   stayed raw for the whole session; dabshell now switches to raw only
   while the line editor reads keys. An option to keep OPOST would allow
   the simpler model.

9. **Process I/O wiring.** `run-program` inherits the console but takes no
   `'stdin` string; `run-program/capture` takes `'stdin` but buffers all
   output until the program ends; `start-program` can only send stdout and
   stderr *together* to a `'log-file` (no append, no separate stderr, no
   new process group/session). So `cmd > file` and `echo x | cmd` (with
   output to the terminal) buffer the whole output instead of streaming
   it, and `cmd 2> err.txt &` cannot be expressed. Options such as
   `'stdout <path>`, `'stderr <path>`, `'append #t`, `'stdin <string|path>`
   on `run-program` and `start-program`, and `'new-group #t` for
   `start-program` would cover what a shell needs.
