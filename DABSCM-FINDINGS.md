# dabscm findings from the dabshell port

Bugs and inconsistencies in dabscm found while porting dabshell from Python.
Found on Windows 11 with `scm-java/scm.jar` (JVM) and `scm-native/build/scm.exe`
/ `scmc.exe` (native). Rechecked against dabscm commit 858d1ce (plus the
Windows fix for child output files with `'append` / `'stderr 'stdout`): everything
else reported earlier is fixed or documented there (PATHEXT in `which`,
string escapes, `include`, regex messages, Windows paths, `cd` for child
processes, `glob` case, strict `json-parse`, `exact`, `-0.0`, characters
above #xFFFF, zip entry ports, shortest flonum printing, HTTP timeouts,
`test-assert` errors, sha224/384/512, `real-path`/`file-mode`/in-process
`chmod`, interrupt handlers, `terminal-raw!` keeping output processing,
process I/O options), and dabshell's workarounds for them are removed.
JVM characters stay UTF-16 (`integer->char` above #xFFFF raises), so
dabshell still builds such characters with `utf8->string`.

## Native

1. **Reader errors carry no location natively.** scmc running on the JVM
   now reports `read: unexpected ) (bad.scm 2:11)`, but the native
   `scmc.exe` still prints only `unexpected close parenthesis` for a program
   containing `(display 1))`, and the native `scm.exe` reports
   `tokenizer: invalid string escape: \W` without the `(file line:col)` the
   JVM adds.

## Both

2. **64-bit bitwise arithmetic goes through bignums** and is slow: a
   straightforward SHA-512 in Scheme took 7.7 s/MB native, 15 s/MB on the
   JVM. Less pressing now that (scm crypto) has sha224/sha384/sha512.
   (Not rechecked.)
