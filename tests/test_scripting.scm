;; Tests of scripts (if/for/while/def, script, source, for-loop globs) and
;; background jobs (port of TestScripting, the for-loop part of TestGlob
;; and TestBackground of tests/test_dabshell.py).

(import (scheme base) (scheme char) (scheme process-context) (scheme time)
        (scm fs) (scm module) (scm string) (scm system) (scm test))
(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))
(import (dabshell util) (dabshell core) (dabshell builtins) (dabshell testing))

(define (contains? s sub) (string-contains? s sub))
(define (count-of s sub) (string-count-of s sub))
(define python (or (find-in-path "python") (find-in-path "python3")))
(define (failed? thunk) (guard (e ((command-failed? e) #t)) (thunk) #f))

;; write code to a script and source it; the output
(define (run-script t code)
  (let ((path (write-file t "test_script.dsh" code)))
    (out-raw t (string-append "source " path))))

;; output lines ending in .txt
(define (txt-lines s)
  (filter* (lambda (l) (string-ends? l ".txt")) (map string-strip (splitlines s))))

(define (filter* pred lst)
  (cond ((null? lst) '()) ((pred (car lst)) (cons (car lst) (filter* pred (cdr lst))))
        (else (filter* pred (cdr lst)))))

(define (every-abs? lst) (or (null? lst) (and (path-absolute? (car lst)) (every-abs? (cdr lst)))))

(test-runner-factory scm-test-runner)
(test-begin "scripting")

(test-group "scripting"
  (with-shell (lambda (t)
    (test-assert (contains? (run-script t "if is-not-empty hello\n    print yes\nend\n") "yes"))
    (test-assert (not (contains? (run-script t "if is-empty hello\n    print should_not_appear\nend\n")
                                 "should_not_appear")))
    (test-equal "a\nb\nc\n" (run-script t "for x in a b c\n    print {x}\nend\n"))
    (test-equal "0\n1\n2\n"
                (run-script t "set n 0\nwhile {n} < 3\n    print {n}\n    set n eval {n} + 1\nend\n"))
    (test-equal "hello Alice\nhello Bob\n"
                (run-script t "def greet name\n    print hello {name}\nend\ngreet Alice\ngreet Bob\n"))
    (let ((o (run-script t "for x in 1 2 3\n    if {x} == 2\n        print found2\n    end\nend\n")))
      (test-equal 1 (count-of o "found2")))
    (let ((o (run-script t "    # this is a comment\n    print visible\n")))
      (test-equal "visible\n" o))
    (test-equal "inner test\n"
                (run-script t (string-append "def outer x\n    def inner y\n        print inner {y}\n"
                                             "    end\n    inner {x}\nend\nouter test\n")))))
  (with-shell (lambda (t)
    (let ((path (write-file t "args.dsh" "print {arg0} {arg1}\n")))
      (test-equal "hello world" (out t (string-append "script " path " hello world"))))
    (let ((path (write-file t "argc.dsh" "print {argc}\n")))
      (test-equal "3" (out t (string-append "script " path " a b c"))))
    ;; script runs in a nested scope, source in the shell's
    (let ((path (write-file t "env.dsh" "set sourced_var 42\n")))
      (run-cmd t (string-append "script " path))
      (test-equal "" (out t "get sourced_var"))
      (run-cmd t (string-append "source " path))
      (test-equal "42" (out t "get sourced_var")))
    ;; Python crashed with IndexError / FileNotFoundError
    (test-equal "ERR: source requires a script file" (err t "source"))
    (test-equal "ERR: script requires a script file" (err t "script"))
    (test-equal (string-append "ERR: script " (file-path t "nonexist.dsh") " not found")
                (err t "script nonexist.dsh"))
    (test-equal (string-append "ERR: script " (file-path t "nonexist.dsh") " not found")
                (err t "nonexist.dsh"))))
  (with-shell (lambda (t)
    ;; intentional difference: the help of a procedure works
    (run-script t "def greet name\n    print hello {name}\nend\n")
    (test-equal "greet name   : custom procedure" (out t "help greet")))))

(test-group "for-glob"
  (with-shell (lambda (t)
    (write-file t "alpha.txt" "aaa\n")
    (write-file t "beta.txt" "bbb\n")
    (write-file t "gamma.txt" "ccc\n")
    (let ((lines (txt-lines (run-script t "for f in *.txt\n    print {f}\nend\n"))))
      ;; absolute paths in the shell's directory, sorted
      (test-equal (map (lambda (n) (file-path t n)) '("alpha.txt" "beta.txt" "gamma.txt")) lines)
      (test-assert (every-abs? lines)))
    (test-assert (not (contains? (run-script t "for f in *.xyz\n    print found\nend\n") "found"))))))

;; a shell whose background jobs are killed afterwards
(define (with-job-shell proc)
  (with-shell (lambda (t)
    (dynamic-wind
      (lambda () #f)
      (lambda () (proc t))
      (lambda ()
        (for-each (lambda (j) (process-kill (job-handle j)) (process-wait (job-handle j)))
                  (jobs-list (tc-shell t))))))))

(define (py code) (string-append (quote-arg python) " -c \"" code "\""))

(test-group "background"
  (test-equal '(("a b" . #f)) (split-command-list "a b"))
  (test-equal '(("emacs x.txt" . #t)) (split-command-list "emacs x.txt &"))
  (test-equal '(("emacs x.txt" . #t)) (split-command-list "emacs x.txt&"))
  (test-equal '(("a" . #t) ("b" . #f) ("c" . #t)) (split-command-list "a & b && c &"))
  (test-equal '(("print \"a & b\"" . #f)) (split-command-list "print \"a & b\""))
  (test-equal '(("cmd &> out.txt" . #f)) (split-command-list "cmd &> out.txt"))
  (test-equal '(("cmd &>> out.txt" . #t)) (split-command-list "cmd &>> out.txt &"))
  (with-job-shell (lambda (t)
    (test-assert (contains? (err t "print hi &") "cannot be run in the background"))
    (test-equal '() (jobs-list (tc-shell t)))))
  (when python
    (with-job-shell (lambda (t)
      (let ((start (current-jiffy)))
        (let-values (((o e) (run-cmd t (string-append (py "import time; time.sleep(5)") " &"))))
          (test-assert (< (/ (- (current-jiffy) start) (jiffies-per-second)) 3))
          (test-assert (and (regex-search e "^\\[1\\] \\d+") #t))
          (test-equal 1 (length (jobs-list (tc-shell t))))))
      (let ((o (out t "jobs")))
        (test-assert (contains? o "[1]"))
        (test-assert (contains? o "Running")))))
    (with-job-shell (lambda (t)
      (run-cmd t (string-append (py "print(42)") " > bg.txt &"))
      (run-cmd t "wait")
      (test-equal "42" (string-strip (read-text t "bg.txt")))
      (test-equal '() (jobs-list (tc-shell t)))))
    (with-job-shell (lambda (t)
      (test-assert (contains? (out t (string-append (py "pass") " & print after")) "after"))))
    (with-job-shell (lambda (t)
      (define sh (tc-shell t))
      (run-cmd t (string-append (py "pass") " &"))
      (process-wait (job-handle (car (jobs-list sh))))
      (let ((e (open-output-string)))
        (shell-oute-set! sh e)
        (report-finished-jobs sh)
        (test-assert (contains? (get-output-string e) "[1] Done")))
      (test-equal '() (jobs-list sh))))
    (with-job-shell (lambda (t)
      (define sh (tc-shell t))
      (run-cmd t (string-append (py "import sys; sys.exit(3)") " &"))
      (shell-option-set! sh "stop-on-error" "on")
      (test-assert (failed? (lambda () (shell-execute sh "wait %1" #f))))))
    (with-job-shell (lambda (t)
      (test-assert (contains? (err t (string-append (py "pass") " | sort &"))
                              "pipelines cannot be run in the background"))))))

(test-end "scripting")
(exit (if (zero? (last-run-failed-tests)) 0 1))
