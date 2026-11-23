;; dsh - the dabshell program.
;;
;;   dsh                       interactive shell
;;   dsh script.dsh [arg...]   run a script and exit (exit code 1 on failure)
;;   dsh -c "command line"     run one command line and exit
;;   dsh --version
;;
;; Run from source: scm bin/dsh.scm ...; compile: see build.scm.

(import (scheme base)
        (scheme process-context)
        (scm fs)
        (scm module))

(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (join-path root "src") (module-search-path)))

(import (scm terminal)
        (dabshell util)
        (dabshell core)
        (dabshell builtins)
        (dabshell files)
        (dabshell text)
        (dabshell awk)
        (dabshell data)
        (dabshell less)
        (dabshell editor)
        (dabshell interactive))

(define version "0.1.0")

;; run thunk; the exit code: 1 when a command failed or raised an error
(define (exit-code-of thunk sh)
  (guard (e ((command-failed? e) 1)
            (#t (println (shell-oute sh) (report-error e)) 1))
    (thunk)
    0))

(define (main args)
  (cond
   ((null? args)
    (install-interrupt-handler!)
    (let* ((interactive? (terminal?))
           (sh (start-shell interactive?)))
      (if interactive?
          (run-interactive sh)
          (run-lines sh (current-input-port))))
    0)
   ((member (car args) '("--version" "-V"))
    (println console-out "dabshell " version)
    0)
   ((string=? (car args) "-c")
    (let ((sh (start-shell #f)))
      (shell-cwd-set! sh (path-normpath (current-directory)))
      (exit-code-of (lambda ()
                      (for-each (lambda (line) (shell-execute sh line #f)) (cdr args)))
                    sh)))
   (else
    ;; the directory dsh was started in, not one a cd in ~/.dabshell chose
    (let* ((cwd (path-normpath (current-directory)))
           (script (path-canon (car args) cwd))
           (sh (start-shell #f)))
      (shell-cwd-set! sh cwd)
      ;; the script command gives #f when an error stopped the script
      (let ((stopped #f))
        (let ((rc (exit-code-of
                   (lambda ()
                     (set! stopped (not ((cmd-run (env-get (shell-env sh) "script"))
                                         sh (cons script (cdr args))))))
                   sh)))
          (if stopped 1 rc)))))))

(exit (main (cdr (command-line))))
