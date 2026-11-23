;; dabshell builtins: the commands about the shell itself (variables,
;; aliases, options, scripts, directories, history, jobs).

(define-library (dabshell builtins)
  (export)
  (import (scheme base)
          (scheme char)
          (scheme time)
          (srfi 69)
          (only (srfi 1) filter)
          (scm system)
          (dabshell util)
          (dabshell core))
  (begin

    (define (out sh . xs) (apply println (shell-outs sh) xs))
    (define (err sh . xs) (apply println (shell-oute sh) xs))

    (define-command "alias" "[<name> [<value> | -]]   : set, list or remove alias"
      (lambda (sh args)
        (let ((env (shell-env sh)))
          (if (null? args)
              (for-each (lambda (name)
                          (let ((a (env-get env name)))
                            (when (alias-cmd? a) (out sh (cmd-name a) " = " (cmd-value a)))))
                        (env-names env))
              (let ((name (car args))
                    (value (if (pair? (cdr args)) (quote-args (cdr args)) #f)))
                (cond ((equal? value "-")
                       (when (alias-cmd? (env-get env name)) (env-remove! env name)))
                      ((not value)
                       (let ((a (env-get env name)))
                         (when (alias-cmd? a) (out sh (cmd-name a) " = " (cmd-value a)))))
                      ((builtin-cmd? (env-get env name))
                       (err sh "ERR: " name " is a builtin command and cannot be aliased"))
                      (else (env-set! env name (make-alias-cmd name value)))))))))

    (define-command "options" "<options>   : list currently active options"
      (lambda (sh args)
        (for-each (lambda (p) (out sh (car p) " " (cdr p))) (shell-options sh))))

    (define-command "option" "<option> [<value>]   : gets/sets options"
      (lambda (sh args)
        (if (null? args)
            (begin (err sh "ERR: option requires a name") (command-failed!))
            (let ((option (car args)))
              (if (pair? (cdr args))
                  (let ((value (cadr args)))
                    (shell-option-set! sh option
                                       (if (member option '("echo" "stop-on-error"))
                                           (if (member value '("on" "1" "yes" "y" "true")) "on" "off")
                                           value)))
                  (out sh (shell-option sh option "")))))))

    (define-command "run" "<cmd> [<arg>...]   : runs the external command"
      (lambda (sh args)
        (if (null? args)
            (begin (err sh "ERR: run requires a command") (command-failed!))
            (run-external sh (car args) (cdr args) (stdin-string sh) #t))))

    (define-command "eval"
      "(<arg> <op> <arg> | <predicate> <arg>  | <arg>)   : Evaluates the expression"
      (lambda (sh args)
        (out sh (evaluate-expression (quote-args args) sh))))

    (define (script-file sh args name)
      (when (null? args)
        (err sh "ERR: " name " requires a script file")
        (command-failed!))
      (let ((file (shell-path sh (car args))))
        (unless (file? file)
          (err sh "ERR: script " file " not found")
          (command-failed!))
        file))

    (define-command "script" "<scriptfile> [<arg>...]   : runs a dabshell script"
      (lambda (sh args)
        (let* ((file (script-file sh args "script"))
               (args (cdr args))
               (child (make-child-shell sh))
               (env (shell-env child)))
          (env-set! env "argc" (length args))
          (let loop ((as args) (i 0))
            (unless (null? as)
              (env-set! env (string-append "arg" (number->string i)) (car as))
              (loop (cdr as) (+ i 1))))
          (env-set! env "args" (quote-args args))
          (execute-lines child (read-script-lines file)))))

    (define-command "source" "<scriptfile>   : sources a dabshell script"
      (lambda (sh args)
        (execute-lines sh (read-script-lines (script-file sh args "source")))))

    (define-command "cd" "<dir>   : changes the current directory"
      (lambda (sh args)
        (if (null? args)
            (shell-cwd-set! sh (path-normpath (home-directory)))
            (let ((dir (shell-path sh (car args))))
              (if (directory? dir)
                  (shell-cwd-set! sh dir)
                  (err sh "ERR: cannot cd to " dir))))))

    (define-command "pwd" ": prints the current directory"
      (lambda (sh args) (out sh (shell-cwd sh))))

    (define-command "set" "<name> <value>   : sets a variable"
      (lambda (sh args)
        (if (< (length args) 2)
            (err sh "ERR: set requires a name and a value")
            (env-set! (shell-env sh) (car args)
                      (cond ((string=? (cadr args) "exec") (shell-exec (quote-args (cddr args)) sh))
                            ((string=? (cadr args) "eval") (evaluate-expression (quote-args (cddr args)) sh))
                            (else (string-join* (cdr args) " ")))))))

    (define-command "get" "<name>   : prints the value of a variable"
      (lambda (sh args)
        (let ((env (shell-env sh)))
          (if (null? args)
              (for-each (lambda (name) (out sh name "=" (env-get env name))) (env-names env))
              (let ((v (env-get env (car args) 'none)))
                (out sh (if (eq? v 'none) "" v)))))))

    (define-command "echo" "<value> : echoes the value"
      (lambda (sh args) (out sh (quote-args args))))

    (define-command "print" "<value> : prints the value"
      (lambda (sh args) (out sh (string-join* args " "))))

    (define (print-history sh entries args)
      ;; entries: list of (index . line)
      (let ((query (and (pair? args) (string-downcase (string-join* args " ")))))
        (let loop ((es entries) (last #f))
          (unless (null? es)
            (let ((line (cdar es)))
              (if (and (not (equal? line last))
                       (or (not query) (string-contains? (string-downcase line) query)))
                  (begin (out sh (caar es) " " line) (loop (cdr es) line))
                  (loop (cdr es) last)))))))

    (define-command "history" "[<filter>]   : shows the history of commands, optionally filtered"
      (lambda (sh args)
        (print-history sh
                       (let loop ((h (session-history (shell-session sh))) (i 0))
                         (if (null? h) '() (cons (cons i (car h)) (loop (cdr h) (+ i 1)))))
                       args)))

    (define-command "lhistory"
      "[<filter>]   : shows the history of commands, optionally filtered, only for the current directory"
      (lambda (sh args)
        (print-history sh
                       (hash-table-ref/default (session-local-history (shell-session sh)) (shell-cwd sh) '())
                       args)))

    (define-command "which" "<filename>   : searches filename in the PATH and shows the location"
      (lambda (sh args)
        (for-each (lambda (arg)
                    (when (builtin-cmd? (env-get (shell-env sh) arg))
                      (out sh arg ": internal command"))
                    (let ((location (find-executable (shell-cwd sh) arg)))
                      (when location (out sh (shell-path sh location)))))
                  args)))

    (define-command "title" "<title>   : sets the terminal window title"
      (lambda (sh args)
        (let ((title (string-join* args " ")))
          (session-title-set! (shell-session sh) title)
          (set-terminal-title! sh title))))

    (define-command "setscm"
      "[<runner> [<arg>...] | -]   : show, set or reset the runner for .scm scripts"
      (lambda (sh args)
        (cond ((null? args)
               (let-values (((cmd extra) (resolve-scm-runner sh)))
                 (out sh (quote-args (cons cmd extra)))))
              ((equal? args '("-")) (session-scm-override-set! (shell-session sh) #f))
              (else (session-scm-override-set! (shell-session sh) (quote-args args))))))

    (define-command "reset-term" "Resets the terminal"
      (lambda (sh args)
        ;; leave the alternate screen, show the cursor, reset attributes
        (print-to (shell-outp sh) "\x1b;[?1049l\x1b;[?25h\x1b;[0m")))

    (define-command "help"
      "[<cmd>]   : shows the list of available command and optionally the description of a specific command"
      (lambda (sh args)
        (let ((env (shell-env sh)))
          (if (null? args)
              (out sh (string-join* (filter (lambda (n) (cmd? (env-get env n))) (env-names env)) " "))
              (let ((c (env-get env (car args))))
                (when (cmd? c)
                  (out sh (cmd-name c) " "
                       (if (alias-cmd? c) (string-append "= " (cmd-value c)) (cmd-help c)))))))))

    (define-command "time" "<cmd> [<arg>...]   : execute a command and print its elapsed time"
      (lambda (sh args)
        (if (null? args)
            (err sh "ERR: time requires a command to execute")
            (let ((start (current-jiffy)))
              (guard (e ((command-failed? e) #f))
                (shell-execute sh (quote-args args) #f))
              (let* ((elapsed (/ (- (current-jiffy) start) (jiffies-per-second)))
                     (minutes (exact (floor (/ elapsed 60))))
                     (seconds (- elapsed (* minutes 60))))
                (if (> minutes 0)
                    (err sh "\nreal\t" minutes "m" (format-fixed seconds 3) "s")
                    (err sh "\nreal\t" (format-fixed elapsed 3) "s")))))))

    (define-command "jobs" "   : list commands started in the background with '&'"
      (lambda (sh args)
        (for-each (lambda (j)
                    (out sh "[" (job-id j) "] "
                         (string-pad-right (number->string (process-pid (job-handle j))) 7) " "
                         (string-pad-right (job-status j) 8) " " (job-command j)))
                  (jobs-list sh))
        (jobs-reap! sh)))

    (define-command "wait"
      "[%<n>|<pid>...]   : wait for background jobs to finish (all jobs if none given)"
      (lambda (sh args)
        (let* ((jobs (if (null? args)
                         (jobs-list sh)
                         (map (lambda (spec)
                                (or (jobs-get sh spec)
                                    (begin (err sh "ERR: no such job: " spec) (command-failed!))))
                              args)))
               (rc ((cooked-wrapper)
                    (lambda ()
                      (let loop ((js jobs) (rc 0))
                        (if (null? js)
                            rc
                            (let ((r (process-wait (job-handle (car js)))))
                              (jobs-remove! sh (car js))
                              (loop (cdr js) r))))))))
          (unless (eqv? rc 0) (command-failed!)))))))
