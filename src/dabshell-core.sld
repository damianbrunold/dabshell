;; dabshell core: environments, commands, parsing, expressions, execution of
;; command lines, pipelines, redirects, external programs, jobs and scripts.

(define-library (dabshell core)
  (export
   ;; environments
   make-env env? env-parent env-get env-set! env-remove! env-update! env-names env-has-local?
   ;; commands
   make-cmd cmd? cmd-name cmd-help cmd-run cmd-kind cmd-value
   define-command register-command! registered-commands builtin-cmd?
   alias-cmd? make-alias-cmd
   ;; failures
   command-failed! command-failed? report-error
   ;; values
   value->string value-truthy?
   ;; output
   println print-to console-out console-err
   ;; sessions and shells
   make-session session? session-jobs session-scm-override session-scm-override-set!
   session-history session-history-set! session-local-history session-history-file
   session-history-file-set! session-history-index session-history-index-set!
   session-history-current session-history-current-set! session-prompt-dirty?
   session-prompt-dirty-set! session-title session-title-set!
   make-root-shell make-child-shell shell?
   shell-cwd shell-cwd-set! shell-env shell-env-set! shell-outs shell-outs-set!
   shell-oute shell-oute-set! shell-outp shell-outp-set! shell-options shell-options-set!
   shell-session shell-stdin shell-stdin-set!
   shell-option shell-option-set! shell-option-on? shell-path shell-home
   stdin-string stdin-lines
   ;; terminal hooks (set by the interactive front end)
   cooked-wrapper set-terminal-title!
   ;; parsing
   replace-vars split-command quote-arg quote-args shell-exec
   tokenize-unquoted split-pipe split-command-list parse-pipeline parse-redirects
   stage? stage-raw stage-stdout-file stage-stdout-append stage-stderr-file
   stage-stderr-append stage-both-file stage-both-append stage-env-overlay
   ;; expressions
   tokenize-expr evaluate-expression
   ;; execution
   shell-execute execute-pipeline run-external find-executable find-executable-in
   find-in-path find-partial-executables resolve-scm-runner add-history!
   os-environment child-env
   ;; jobs
   job? job-id job-command job-handle job-status jobs-list jobs-get jobs-reap! jobs-remove!
   report-finished-jobs
   ;; scripts
   execute-lines read-script-lines collect-files)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme write)
          (scheme process-context)
          (scheme time)
          (only (srfi 1) filter last-pair)
          (srfi 69)
          (srfi 132)
          (only (scm io) call-with-output-string)
          (scm fs)
          (scm glob)
          (scm system)
          (dabshell util))
  (begin

    ;; ------------------------------------------------------------------
    ;; environments: lexically scoped variables, aliases and commands

    (define-record-type env
      (%make-env parent table)
      env?
      (parent env-parent)
      (table env-table))

    (define (make-env . parent)
      (%make-env (if (null? parent) #f (car parent)) (make-hash-table equal?)))

    (define (env-has-local? e name) (hash-table-exists? (env-table e) name))

    (define (env-get e name . default)
      (let ((d (if (null? default) #f (car default))))
        (let loop ((e e))
          (cond ((not e) d)
                ((hash-table-exists? (env-table e) name) (hash-table-ref (env-table e) name))
                (else (loop (env-parent e)))))))

    (define (env-set! e name value) (hash-table-set! (env-table e) name value))

    (define (env-remove! e name)
      (let loop ((e e))
        (cond ((not e) #f)
              ((hash-table-exists? (env-table e) name) (hash-table-delete! (env-table e) name))
              (else (loop (env-parent e))))))

    ;; update the variable in the scope that defines it, else set it locally
    (define (env-update! e name value)
      (let loop ((s e))
        (cond ((not s) (env-set! e name value))
              ((hash-table-exists? (env-table s) name) (env-set! s name value))
              (else (loop (env-parent s))))))

    (define (env-names e)
      (let ((seen (make-hash-table equal?)))
        (let loop ((e e))
          (when e
            (for-each (lambda (k) (hash-table-set! seen k #t)) (hash-table-keys (env-table e)))
            (loop (env-parent e))))
        (sort-strings (hash-table-keys seen))))

    ;; ------------------------------------------------------------------
    ;; commands: builtins, aliases and procedures live in the environment

    (define-record-type cmd
      (make-cmd name help run kind value)
      cmd?
      (name cmd-name)
      (help cmd-help)        ; string
      (run cmd-run)          ; (lambda (shell args) ...)
      (kind cmd-kind)        ; builtin, alias or procedure
      (value cmd-value))     ; the alias text

    (define (builtin-cmd? x) (and (cmd? x) (not (eq? (cmd-kind x) 'alias))))
    (define (alias-cmd? x) (and (cmd? x) (eq? (cmd-kind x) 'alias)))
    (define (make-alias-cmd name value) (make-cmd name "" #f 'alias value))

    (define registered '())
    (define (registered-commands) (reverse registered))
    (define (register-command! c) (set! registered (cons c registered)) c)

    ;; (define-command "name" "help" (lambda (shell args) ...))
    (define (define-command name help run)
      (register-command! (make-cmd name help run 'builtin #f)))

    ;; ------------------------------------------------------------------
    ;; failures

    (define-record-type command-failure
      (make-command-failure)
      command-failed?)

    ;; a command failed; its message has already been printed
    (define (command-failed!) (raise (make-command-failure)))

    ;; the text of an error, as Python's str(e)
    (define (report-error e)
      (cond ((error-object? e)
             (let ((irritants (error-object-irritants e)))
               (if (null? irritants)
                   (error-object-message e)
                   (string-append (error-object-message e) " "
                                  (string-join* (map (lambda (x) (if (string? x) x (value->string x)))
                                                     irritants)
                                                " ")))))
            ((string? e) e)
            (else (call-with-output-string (lambda (p) (display e p))))))

    ;; ------------------------------------------------------------------
    ;; values: variables hold strings, integers or booleans (Python's
    ;; str() is how they print)

    (define (value->string v)
      (cond ((string? v) v)
            ((eq? v #t) "True")
            ((eq? v #f) "False")
            ((number? v) (number->string v))
            ((cmd? v) (cmd-name v))
            ((null? v) "None")
            (else (call-with-output-string (lambda (p) (display v p))))))

    (define (value-truthy? v)
      (cond ((string? v) (not (string=? v "")))
            ((number? v) (not (zero? v)))
            (else (and v #t))))

    ;; ------------------------------------------------------------------
    ;; output: shells write to ports

    (define console-out (current-output-port))
    (define console-err (current-error-port))

    (define (print-to port . xs)
      (for-each (lambda (x) (write-string (value->string x) port)) xs)
      (flush-output-port port))

    (define (println port . xs)
      (for-each (lambda (x) (write-string (value->string x) port)) xs)
      (newline port)
      (flush-output-port port))

    ;; ------------------------------------------------------------------
    ;; sessions: state shared by a shell and the shells nested in it

    (define-record-type session
      (%make-session jobs scm-override history local-history history-file
                     history-index history-current prompt-dirty title)
      session?
      (jobs session-jobs session-jobs-set!)
      (scm-override session-scm-override session-scm-override-set!)
      (history session-history session-history-set!)          ; vector-like list, oldest first
      (local-history session-local-history)                    ; hash: dir -> list of (idx . cmd), newest first
      (history-file session-history-file session-history-file-set!)
      (history-index session-history-index session-history-index-set!)
      (history-current session-history-current session-history-current-set!)
      (prompt-dirty session-prompt-dirty? session-prompt-dirty-set!)
      (title session-title session-title-set!))

    (define (make-session)
      (%make-session '() #f '() (make-hash-table equal?) #f -1 "" #t "dabshell"))

    (define-record-type shell
      (%make-shell cwd env outp outs oute options session stdin)
      shell?
      (cwd shell-cwd shell-cwd-set!)
      (env shell-env shell-env-set!)
      (outp shell-outp shell-outp-set!)
      (outs shell-outs shell-outs-set!)
      (oute shell-oute shell-oute-set!)
      (options shell-options shell-options-set!)   ; alist, insertion order
      (session shell-session)
      (stdin shell-stdin shell-stdin-set!))        ; string fed to a builtin, or #f

    ;; the environment variables of this process as an alist
    (define (os-environment)
      (map (lambda (p) (cons (car p) (cdr p))) (env-list)))

    (define (make-root-shell)
      (let* ((env (make-env))
             (sh (%make-shell (path-normpath (current-directory)) env
                              console-out console-out console-err
                              (list (cons "echo" "off") (cons "stop-on-error" "on"))
                              (make-session) #f)))
        (for-each (lambda (p) (env-set! env (string-append "env:" (car p)) (cdr p)))
                  (os-environment))
        (for-each (lambda (c) (env-set! env (cmd-name c) c)) (registered-commands))
        sh))

    (define (make-child-shell parent . env)
      (%make-shell (shell-cwd parent)
                   (if (null? env) (make-env (shell-env parent)) (car env))
                   (shell-outp parent) (shell-outs parent) (shell-oute parent)
                   (list-copy (shell-options parent))
                   (shell-session parent)
                   #f))

    (define (shell-option sh name . default)
      (let ((p (assoc name (shell-options sh))))
        (if p (cdr p) (if (null? default) #f (car default)))))

    (define (shell-option-set! sh name value)
      (let ((p (assoc name (shell-options sh))))
        (if p
            (set-cdr! p value)
            (shell-options-set! sh (append (shell-options sh) (list (cons name value)))))))

    (define (shell-option-on? sh name)
      (and (member (shell-option sh name) '("on" "yes" "y" "1" "true")) #t))

    ;; an argument path resolved against the shell's directory
    (define (shell-path sh p) (path-canon p (shell-cwd sh)))

    (define (shell-home sh) (or (shell-option sh "user-home") (home-directory)))

    ;; the piped input of a builtin as a string, or #f
    (define (stdin-string sh) (shell-stdin sh))

    ;; the piped input as lines with their line ends, or #f
    (define (stdin-lines sh)
      (and (shell-stdin sh) (splitlines-keepends (shell-stdin sh))))

    ;; (cooked-wrapper) runs a thunk with the terminal in its normal mode;
    ;; the interactive front end replaces it
    (define cooked-wrapper (make-parameter (lambda (thunk) (thunk))))

    (define (set-terminal-title! sh title)
      (let ((p (shell-outp sh)))
        (write-string (string-append "\x1b;]0;" title "\x7;") p)
        (flush-output-port p)))

    ;; ------------------------------------------------------------------
    ;; parsing

    ;; run a command line in a nested shell and return its output
    (define (shell-exec s sh)
      (let ((child (make-child-shell sh))
            (out (open-output-string)))
        (shell-outs-set! child out)
        (guard (e ((command-failed? e) #f))
          (shell-execute child s #f))
        (string-strip (get-output-string out))))

    ;; expand {name} and {!command}; nothing inside single quotes
    (define (replace-vars s sh)
      (let ((env (shell-env sh))
            (out (open-output-string))
            (var (open-output-string)))
        (let loop ((cs (string->list s)) (in-squote #f) (in-var #f) (level 0))
          (if (null? cs)
              (get-output-string out)
              (let ((ch (car cs)))
                (cond ((and (char=? ch #\{) (not in-squote))
                       (if (= level 0)
                           (loop (cdr cs) in-squote #t 1)
                           (begin (write-char ch var) (loop (cdr cs) in-squote in-var (+ level 1)))))
                      ((and in-var (not (char=? ch #\})))
                       (write-char ch var)
                       (loop (cdr cs) in-squote in-var level))
                      ((and in-var (char=? ch #\}))
                       (if (= level 1)
                           (let ((name (get-output-string var)))
                             (set! var (open-output-string))
                             (write-string
                              (if (string-starts? name "!")
                                  (shell-exec (substring name 1 (string-length name)) sh)
                                  (let ((v (env-get env name 'none)))
                                    (if (eq? v 'none)
                                        (string-append "{" name "}")
                                        (value->string v))))
                              out)
                             (loop (cdr cs) in-squote #f 0))
                           (begin (write-char ch var) (loop (cdr cs) in-squote in-var (- level 1)))))
                      ((char=? ch #\')
                       (write-char ch out)
                       (loop (cdr cs) (not in-squote) in-var level))
                      (else (write-char ch out) (loop (cdr cs) in-squote in-var level))))))))

    ;; split a command line into the command and its arguments
    ;; (values cmd args); cmd is "" for an empty line
    (define (split-command line sh . opt)
      (let* ((with-vars (or (null? opt) (car opt)))
             (line (if with-vars (replace-vars line sh) line))
             (n (string-length line)))
        (let loop ((i 0) (cur '()) (have #f) (dq #f) (sq #f) (parts '()))
          (define (cur-str) (list->string (reverse cur)))
          (if (>= i n)
              (let ((parts (reverse (if have (cons (cur-str) parts) parts))))
                (if (null? parts) (values "" '()) (values (car parts) (cdr parts))))
              (let ((ch (string-ref line i))
                    (next (and (< (+ i 1) n) (string-ref line (+ i 1)))))
                (cond ((and (char=? ch #\") (not sq) (not dq)) (loop (+ i 1) cur #t #t sq parts))
                      ((and (char=? ch #\\) dq next (memv next '(#\" #\\)))
                       (loop (+ i 2) (cons next cur) have dq sq parts))
                      ((and (char=? ch #\") dq) (loop (+ i 1) cur have #f sq parts))
                      ((and (char=? ch #\') (not dq) (not sq)) (loop (+ i 1) cur #t dq #t parts))
                      ((and (char=? ch #\') sq) (loop (+ i 1) cur have dq #f parts))
                      ((and (char=? ch #\~) (not dq) (not sq))
                       (loop (+ i 1) (append (reverse (string->list (shell-home sh))) cur) #t dq sq parts))
                      ((and (char=? ch #\space) (not dq) (not sq))
                       (if have
                           (loop (+ i 1) '() #f dq sq (cons (cur-str) parts))
                           (loop (+ i 1) cur have dq sq parts)))
                      (else (loop (+ i 1) (cons ch cur) #t dq sq parts))))))))

    (define (quote-arg arg)
      (cond ((string=? arg "") "''")
            ((or (string-contains? arg " ") (string-contains? arg "\"") (string-contains? arg "'"))
             (if (not (string-contains? arg "'"))
                 (string-append "'" arg "'")
                 (string-append "\""
                                (string-replace* (string-replace* arg "\\" "\\\\") "\"" "\\\"")
                                "\"")))
            (else arg)))

    (define (quote-args args) (string-join* (map quote-arg args) " "))

    ;; tokens of a stage: list of (text quoted? squoted?)
    (define (tokenize-unquoted s)
      (let ((n (string-length s)))
        (let loop ((i 0) (cur '()) (q #f) (sqd #f) (inq #f) (insq #f) (toks '()))
          (define (flush) (cons (list (list->string (reverse cur)) q sqd) toks))
          (if (>= i n)
              (reverse (if (or (pair? cur) q) (flush) toks))
              (let ((ch (string-ref s i)))
                (cond ((and (char=? ch #\") (not inq) (not insq)) (loop (+ i 1) cur #t sqd #t insq toks))
                      ((and (char=? ch #\") inq) (loop (+ i 1) cur q sqd #f insq toks))
                      ((and (char=? ch #\\) inq (< (+ i 1) n) (memv (string-ref s (+ i 1)) '(#\" #\\)))
                       (loop (+ i 2) (cons (string-ref s (+ i 1)) cur) q sqd inq insq toks))
                      ((and (char=? ch #\') (not inq) (not insq)) (loop (+ i 1) cur #t #t inq #t toks))
                      ((and (char=? ch #\') insq) (loop (+ i 1) cur q sqd inq #f toks))
                      ((and (char=? ch #\space) (not inq) (not insq))
                       (if (or (pair? cur) q)
                           (loop (+ i 1) '() #f #f inq insq (flush))
                           (loop (+ i 1) cur q sqd inq insq toks)))
                      (else (loop (+ i 1) (cons ch cur) q sqd inq insq toks))))))))

    ;; split on unquoted | that is not part of ||
    (define (split-pipe s)
      (let ((n (string-length s)))
        (let loop ((i 0) (cur '()) (inq #f) (insq #f) (stages '()))
          (define (cur-str) (list->string (reverse cur)))
          (if (>= i n)
              (reverse (cons (cur-str) stages))
              (let ((ch (string-ref s i)))
                (cond ((and (char=? ch #\") (not inq) (not insq)) (loop (+ i 1) (cons ch cur) #t insq stages))
                      ((and (char=? ch #\") inq) (loop (+ i 1) (cons ch cur) #f insq stages))
                      ((and (char=? ch #\') (not inq) (not insq)) (loop (+ i 1) (cons ch cur) inq #t stages))
                      ((and (char=? ch #\') insq) (loop (+ i 1) (cons ch cur) inq #f stages))
                      ((and (char=? ch #\|) (not inq) (not insq))
                       (if (and (< (+ i 1) n) (char=? (string-ref s (+ i 1)) #\|))
                           (loop (+ i 2) (cons #\| (cons #\| cur)) inq insq stages)
                           (loop (+ i 1) '() inq insq (cons (cur-str) stages))))
                      (else (loop (+ i 1) (cons ch cur) inq insq stages))))))))

    (define-record-type stage
      (make-stage raw stdout-file stdout-append stderr-file stderr-append
                  both-file both-append env-overlay)
      stage?
      (raw stage-raw stage-raw-set!)
      (stdout-file stage-stdout-file stage-stdout-file-set!)
      (stdout-append stage-stdout-append stage-stdout-append-set!)
      (stderr-file stage-stderr-file stage-stderr-file-set!)
      (stderr-append stage-stderr-append stage-stderr-append-set!)
      (both-file stage-both-file stage-both-file-set!)
      (both-append stage-both-append stage-both-append-set!)
      (env-overlay stage-env-overlay stage-env-overlay-set!))  ; alist or #f

    (define (assignment-token tok)
      ;; NAME=value with NAME = [A-Za-z_][A-Za-z0-9_]*  -> (name . value) or #f
      (let ((i (string-index-of tok "=")))
        (and i (> i 0)
             (let ((name (substring tok 0 i)))
               (and (let ((c (string-ref name 0))) (or (char-alphabetic? c) (char=? c #\_)))
                    (let loop ((cs (string->list name)))
                      (or (null? cs)
                          (and (let ((c (car cs)))
                                 (and (char<? c #\x80)
                                      (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_))))
                               (loop (cdr cs)))))
                    (cons name (substring tok (+ i 1) (string-length tok))))))))

    ;; strip redirects and leading NAME=value assignments from a stage
    (define (parse-redirects raw)
      (let* ((st (make-stage (string-strip raw) #f #f #f #f #f #f #f))
             (toks (list->vector (tokenize-unquoted raw)))
             (n (vector-length toks)))
        (define (tok i) (car (vector-ref toks i)))
        (define (quoted? i) (cadr (vector-ref toks i)))
        (define (squoted? i) (caddr (vector-ref toks i)))
        (let* ((start (let loop ((i 0))
                        (if (and (< i n) (not (quoted? i)) (assignment-token (tok i)))
                            (let ((a (assignment-token (tok i))))
                              (stage-env-overlay-set! st (append (or (stage-env-overlay st) '()) (list a)))
                              (loop (+ i 1)))
                            i))))
          (let loop ((i start) (kept '()))
            (cond ((>= i n)
                   (stage-raw-set! st (string-join* (reverse kept) " "))
                   st)
                  ((quoted? i)
                   (loop (+ i 1)
                         (cons (if (and (squoted? i) (not (string-contains? (tok i) "'")))
                                   (string-append "'" (tok i) "'")
                                   (quote-arg (tok i)))
                               kept)))
                  ((and (member (tok i) '("&>>" "&>" "2>>" "2>" ">>" ">")) (< (+ i 1) n))
                   (let ((op (tok i)) (file (tok (+ i 1))))
                     (cond ((string=? op "&>>") (stage-both-file-set! st file) (stage-both-append-set! st #t))
                           ((string=? op "&>") (stage-both-file-set! st file) (stage-both-append-set! st #f))
                           ((string=? op "2>>") (stage-stderr-file-set! st file) (stage-stderr-append-set! st #t))
                           ((string=? op "2>") (stage-stderr-file-set! st file) (stage-stderr-append-set! st #f))
                           ((string=? op ">>") (stage-stdout-file-set! st file) (stage-stdout-append-set! st #t))
                           (else (stage-stdout-file-set! st file) (stage-stdout-append-set! st #f)))
                     (loop (+ i 2) kept)))
                  (else
                   (loop (+ i 1) (cons (if (string-contains? (tok i) " ") (quote-arg (tok i)) (tok i))
                                       kept))))))))

    ;; split a line on unquoted && and & into a list of (segment . background?)
    (define (split-command-list line)
      (let ((n (string-length line)))
        (let loop ((i 0) (cur '()) (inq #f) (insq #f) (parts '()))
          (define (flush bg)
            (let ((seg (string-strip (list->string (reverse cur)))))
              (if (string=? seg "") parts (cons (cons seg bg) parts))))
          (if (>= i n)
              (reverse (flush #f))
              (let ((ch (string-ref line i)))
                (cond ((and (char=? ch #\\) inq (< (+ i 1) n) (memv (string-ref line (+ i 1)) '(#\" #\\)))
                       (loop (+ i 2) (cons (string-ref line (+ i 1)) (cons ch cur)) inq insq parts))
                      ((and (char=? ch #\") (not insq)) (loop (+ i 1) (cons ch cur) (not inq) insq parts))
                      ((and (char=? ch #\') (not inq)) (loop (+ i 1) (cons ch cur) inq (not insq) parts))
                      ((and (char=? ch #\&) (not inq) (not insq))
                       (let ((prev (and (> i 0) (string-ref line (- i 1))))
                             (next (and (< (+ i 1) n) (string-ref line (+ i 1)))))
                         (cond ((eqv? next #\&) (loop (+ i 2) '() inq insq (flush #f)))
                               ((and (not (eqv? next #\>)) (not (eqv? prev #\>)))
                                (loop (+ i 1) '() inq insq (flush #t)))
                               (else (loop (+ i 1) (cons ch cur) inq insq parts)))))
                      (else (loop (+ i 1) (cons ch cur) inq insq parts))))))))

    (define (parse-pipeline segment) (map parse-redirects (split-pipe segment)))

    ;; ------------------------------------------------------------------
    ;; expressions

    (define (tokenize-expr s)
      (let ((n (string-length s)))
        (let loop ((i 0) (cur '()) (q #f) (inq #f) (insq #f) (toks '()))
          (define (flush) (if (or (pair? cur) q) (cons (list->string (reverse cur)) toks) toks))
          (if (>= i n)
              (reverse (flush))
              (let ((ch (string-ref s i)))
                (cond (insq (if (char=? ch #\')
                                (loop (+ i 1) cur q inq #f toks)
                                (loop (+ i 1) (cons ch cur) q inq insq toks)))
                      (inq (cond ((and (char=? ch #\\) (< (+ i 1) n) (memv (string-ref s (+ i 1)) '(#\" #\\)))
                                  (loop (+ i 2) (cons (string-ref s (+ i 1)) cur) q inq insq toks))
                                 ((char=? ch #\") (loop (+ i 1) cur q #f insq toks))
                                 (else (loop (+ i 1) (cons ch cur) q inq insq toks))))
                      ((char=? ch #\") (loop (+ i 1) cur #t #t insq toks))
                      ((char=? ch #\') (loop (+ i 1) cur #t inq #t toks))
                      ((memv ch '(#\( #\))) (loop (+ i 1) '() #f inq insq (cons (string ch) (flush))))
                      ((char=? ch #\space) (loop (+ i 1) '() #f inq insq (flush)))
                      (else (loop (+ i 1) (cons ch cur) q inq insq toks))))))))

    ;; Python's int(): an error for non-integers
    (define (to-int s)
      (cond ((number? s) s)
            ((boolean? s) (if s 1 0))
            ((parse-int s) => (lambda (v) v))
            (else (error (string-append "invalid literal for int() with base 10: '" s "'")))))

    (define (str v) (value->string v))
    (define (yes b) (if b "yes" ""))

    (define (eval-primary toks pos sh)
      (define n (vector-length toks))
      (define (keyword? t) (member t '("and" "or" "not")))
      (when (>= pos n) (error "unexpected end of expression"))
      (if (string=? (vector-ref toks pos) "(")
          (let-values (((v p) (eval-or toks (+ pos 1) sh)))
            (when (or (>= p n) (not (string=? (vector-ref toks p) ")")))
              (error "missing closing ')'"))
            (values v (+ p 1)))
          (let loop ((p pos) (coll '()))
            (if (and (< p n) (not (keyword? (vector-ref toks p)))
                     (not (member (vector-ref toks p) '("(" ")"))))
                (loop (+ p 1) (cons (vector-ref toks p) coll))
                (let ((coll (reverse coll)))
                  (when (null? coll)
                    (error (string-append "unexpected token '" (vector-ref toks p) "' in expression")))
                  (values (eval-collected coll sh) p))))))

    (define (eval-collected coll sh)
      (define (abs-path v) (shell-path sh v))
      (case (length coll)
        ((3)
         (let ((lhs (car coll)) (op (cadr coll)) (rhs (caddr coll)))
           (define (lower s) (string-downcase s))
           (define (both-ends? a b) (or (string-ends? a b) (string-ends? b a)))
           (define (both-starts? a b) (or (string-starts? a b) (string-starts? b a)))
           (cond ((member op '("<" "lt")) (< (to-int lhs) (to-int rhs)))
                 ((member op '("<=" "lteq")) (<= (to-int lhs) (to-int rhs)))
                 ((member op '(">" "gt")) (> (to-int lhs) (to-int rhs)))
                 ((member op '(">=" "gteq")) (>= (to-int lhs) (to-int rhs)))
                 ((string=? op "+") (+ (to-int lhs) (to-int rhs)))
                 ((string=? op "-") (- (to-int lhs) (to-int rhs)))
                 ((string=? op "*") (* (to-int lhs) (to-int rhs)))
                 ((string=? op "/")
                  (let ((d (to-int rhs)))
                    (when (zero? d) (error "integer division or modulo by zero"))
                    (floor-quotient (to-int lhs) d)))
                 ((string=? op "%")
                  (let ((d (to-int rhs)))
                    (when (zero? d) (error "integer modulo by zero"))
                    (floor-remainder (to-int lhs) d)))
                 ((string=? op "**")
                  (let ((e (to-int rhs)))
                    (if (< e 0) (inexact (expt (to-int lhs) e)) (expt (to-int lhs) e))))
                 ((string=? op "==") (string=? lhs rhs))
                 ((string=? op "!=") (not (string=? lhs rhs)))
                 ((member op '("==ci" "==|ci")) (string=? (lower lhs) (lower rhs)))
                 ((member op '("!=ci" "!=|ci")) (not (string=? (lower lhs) (lower rhs))))
                 ((string=? op "*=") (both-ends? lhs rhs))
                 ((string=? op "=*") (both-starts? lhs rhs))
                 ((member op '("*=ci" "*=|ci")) (both-ends? (lower lhs) (lower rhs)))
                 ((member op '("=*ci" "=*|ci")) (both-starts? (lower lhs) (lower rhs)))
                 (else (error (string-append "unknown operator '" op "'"))))))
        ((2)
         (let ((pred (car coll)) (value (cadr coll)))
           (cond ((string=? pred "exists") (yes (path-exists?* (abs-path value))))
                 ((member pred '("not-exists" "exists-not")) (yes (not (path-exists?* (abs-path value)))))
                 ((string=? pred "is-file") (yes (file? (abs-path value))))
                 ((member pred '("not-is-file" "is-not-file")) (yes (not (file? (abs-path value)))))
                 ((string=? pred "is-dir") (yes (directory? (abs-path value))))
                 ((member pred '("not-is-dir" "is-not-dir")) (yes (not (directory? (abs-path value)))))
                 ;; has-extension <path>: whether the path has an extension
                 ((string=? pred "has-extension")
                  (yes (not (string=? (cdr (path-splitext value)) ""))))
                 ((member pred '("not-has-extension" "has-not-extension"))
                  (yes (string=? (cdr (path-splitext value)) "")))
                 ((string=? pred "is-empty") (yes (string=? value "")))
                 ((member pred '("not-is-empty" "is-not-empty")) (yes (not (string=? value ""))))
                 (else (error (string-append "unknown predicate '" pred "'"))))))
        ((1) (let ((v (parse-int (car coll)))) (or v (car coll))))
        (else
         (error (string-append "unexpected token '" (list-ref coll 3) "' after expression")))))

    (define (eval-not toks pos sh)
      (if (and (< pos (vector-length toks)) (string=? (vector-ref toks pos) "not"))
          (let-values (((v p) (eval-not toks (+ pos 1) sh)))
            (values (if (value-truthy? v) "" "yes") p))
          (eval-primary toks pos sh)))

    (define (eval-and toks pos sh)
      (let-values (((left p) (eval-not toks pos sh)))
        (let loop ((left left) (p p))
          (if (and (< p (vector-length toks)) (string=? (vector-ref toks p) "and"))
              (let-values (((right p2) (eval-not toks (+ p 1) sh)))
                (loop (if (value-truthy? left) right "") p2))
              (values left p)))))

    (define (eval-or toks pos sh)
      (let-values (((left p) (eval-and toks pos sh)))
        (let loop ((left left) (p p))
          (if (and (< p (vector-length toks)) (string=? (vector-ref toks p) "or"))
              (let-values (((right p2) (eval-and toks (+ p 1) sh)))
                (loop (if (value-truthy? left) left right) p2))
              (values left p)))))

    ;; evaluate an expression: a string, an integer or a boolean
    (define (evaluate-expression expr sh)
      (let ((toks (list->vector (tokenize-expr (replace-vars expr sh)))))
        (if (= (vector-length toks) 0)
            ""
            (let-values (((v p) (eval-or toks 0 sh)))
              (unless (= p (vector-length toks))
                (error (string-append "unexpected token '" (vector-ref toks p) "' after expression")))
              v))))

    ;; ------------------------------------------------------------------
    ;; finding executables

    ;; on Windows also the PATHEXT extensions (.bat, .cmd, ...)
    (define (exts-for-dir)
      (if is-win?
          (append '("" ".exe" ".dsh" ".scm")
                  (filter (lambda (e) (not (member e '(".exe" ".dsh" ".scm")))) (pathext)))
          '("" ".dsh" ".scm")))

    ;; the file for executable in dir (trying .exe, .dsh, .scm), or #f
    (define (find-executable-in dir executable)
      (let loop ((exts (exts-for-dir)))
        (cond ((null? exts) #f)
              ((file? (path-join dir (string-append executable (car exts))))
               (path-join dir (string-append executable (car exts))))
              (else (loop (cdr exts))))))

    (define (pathext)
      (let ((v (get-environment-variable "PATHEXT")))
        (map string-downcase
             (filter (lambda (s) (not (string=? s "")))
                     (string-split-on (or v ".COM;.EXE;.BAT;.CMD") ";")))))

    (define (path-dirs)
      (let ((p (get-environment-variable "PATH")))
        (if p
            (filter (lambda (s) (not (string=? s "")))
                    (string-split-on p (if is-win? ";" ":")))
            '())))

    ;; shutil.which: the PATH search (with PATHEXT on Windows)
    (define (find-in-path name)
      (define (candidates)
        (if is-win?
            (let ((exts (pathext)))
              (if (member (string-downcase (cdr (path-splitext name))) exts)
                  (list name)
                  (map (lambda (e) (string-append name e)) exts)))
            (list name)))
      (define (try dir)
        (let loop ((cs (candidates)))
          (cond ((null? cs) #f)
                ((file? (path-join dir (car cs))) (path-join dir (car cs)))
                (else (loop (cdr cs))))))
      (if (or (string-contains? name "/") (and is-win? (string-contains? name "\\")))
          (try "")
          (let loop ((dirs (path-dirs)))
            (cond ((null? dirs) #f)
                  ((try (car dirs)) => (lambda (r) r))
                  (else (loop (cdr dirs)))))))

    (define scripts-folder (if is-win? "Scripts" "bin"))

    ;; venv/bin, .venv/bin, the directory, then PATH
    (define (find-executable cwd executable)
      (or (find-executable-in (path-join cwd "venv" scripts-folder) executable)
          (find-executable-in (path-join cwd ".venv" scripts-folder) executable)
          (find-executable-in cwd executable)
          (find-in-path executable)))

    (define (executable-name? path fname)
      (or (string-ends? fname ".exe") (string-ends? fname ".dsh") (string-ends? fname ".scm")
          is-win?
          (let ((s (guard (e (#t #f)) (stat path))))
            (let ((mode (and s (assq 'mode s))))
              (or (not mode) (not (cdr mode))
                  (not (zero? (bitwise-and* (cdr mode) #o111))))))))

    (define (bitwise-and* a b)
      ;; small non-negative integers only
      (let loop ((a a) (b b) (bit 1) (acc 0))
        (if (or (zero? a) (zero? b))
            acc
            (loop (quotient a 2) (quotient b 2) (* bit 2)
                  (if (and (odd? a) (odd? b)) (+ acc bit) acc)))))

    (define (collect-partial dir word)
      (if (not (directory? dir))
          '()
          (let loop ((es (guard (e (#t '())) (directory-entries dir))) (acc '()))
            (if (null? es)
                (reverse acc)
                (let* ((fname (caar es)) (full (path-join dir fname)))
                  (if (and (string-starts? fname word) (eq? (cdar es) 'file)
                           (executable-name? full fname))
                      (loop (cdr es)
                            (cons (if (or (string-ends? fname ".exe") (string-ends? fname ".dsh")
                                          (string-ends? fname ".scm"))
                                      (substring fname 0 (- (string-length fname) 4))
                                      fname)
                                  acc))
                      (loop (cdr es) acc)))))))

    (define (find-partial-executables cwd word)
      (let* ((r (collect-partial (path-join cwd "venv" scripts-folder) word))
             (r (if (null? r) (collect-partial (path-join cwd ".venv" scripts-folder) word) r))
             (r (if (null? r) (apply append (map (lambda (d) (collect-partial d word)) (path-dirs))) r)))
        (sort-strings r)))

    ;; ------------------------------------------------------------------
    ;; history

    (define (add-history! sh line)
      (let* ((ses (shell-session sh))
             (hist (session-history ses)))
        (when (or (null? hist) (not (string=? (car (last-pair hist)) line)))
          (let ((idx (length hist))
                (cwd (shell-cwd sh)))
            (session-history-set! ses (append hist (list line)))
            (hash-table-set! (session-local-history ses) cwd
                             (append (hash-table-ref/default (session-local-history ses) cwd '())
                                     (list (cons idx line))))
            (let ((file (session-history-file ses)))
              (when file
                (guard (e (#t #f))
                  (let ((p (open-output-file file 'append)))
                    (write-string cwd p) (newline p)
                    (write-string (string-replace* line "\n" " ") p) (newline p)
                    (close-port p)))))))
        (session-history-index-set! ses -1)
        (session-history-current-set! ses "")))

    ;; ------------------------------------------------------------------
    ;; execution

    ;; execute a command line; #f when the shell should exit
    (define (shell-execute sh line . opt)
      (let ((history (or (null? opt) (car opt)))
            (line (string-strip line)))
        (if (string=? line "")
            #t
            (let-values (((cmd0 args0) (split-command line sh #f)))
              (when (and history (not (member cmd0 '("history" "lhistory"))))
                (add-history! sh line))
              (when (shell-option-on? sh "echo")
                (let-values (((cmd args) (split-command line sh)))
                  (println (shell-outs sh) ":: " cmd " " (quote-args args))))
              (session-prompt-dirty-set! (shell-session sh) #t)
              (let loop ((segs (split-command-list line)))
                (cond ((null? segs) #t)
                      ((string=? (string-strip (caar segs)) "exit") #f)
                      (else
                       (let ((stages (parse-pipeline (caar segs))))
                         (guard (e ((and (command-failed? e) (not (shell-option-on? sh "stop-on-error")))
                                    #f))
                           (if (cdar segs)
                               (run-background sh stages (string-strip (caar segs)))
                               (execute-pipeline sh stages history))))
                       (loop (cdr segs)))))))))

    ;; stages connected by pipes: each stage's output becomes the next one's input
    (define (execute-pipeline sh stages . opt)
      (let ((history (or (null? opt) (car opt))))
        (if (null? (cdr stages))
            (run-stage sh (car stages) #f history #f)
            (let loop ((stages stages) (stdin #f))
              (if (null? (cdr stages))
                  (run-stage sh (car stages) stdin history #f)
                  (let ((captured (open-output-string))
                        (saved (shell-outs sh)))
                    (dynamic-wind
                      (lambda () (shell-outs-set! sh captured))
                      (lambda ()
                        (guard (e ((command-failed? e) #f))
                          (run-stage sh (car stages) stdin history #t)))
                      (lambda () (shell-outs-set! sh saved)))
                    (loop (cdr stages) (get-output-string captured))))))))

    (define (open-redirect sh file append)
      (let ((path (shell-path sh file)))
        (guard (e (#t (println (shell-oute sh) "ERR: cannot open " path) (command-failed!)))
          (if append (open-output-file path 'append) (open-output-file path)))))

    ;; (values outs oute ports-to-close) for the redirects of a stage
    (define (resolve-stage-outputs sh st)
      (cond ((stage-both-file st)
             (let ((p (open-redirect sh (stage-both-file st) (stage-both-append st))))
               (values p p (list p))))
            (else
             (let* ((o (and (stage-stdout-file st)
                            (open-redirect sh (stage-stdout-file st) (stage-stdout-append st))))
                    (e (and (stage-stderr-file st)
                            (open-redirect sh (stage-stderr-file st) (stage-stderr-append st)))))
               (values (or o (shell-outs sh)) (or e (shell-oute sh)) (filter (lambda (x) x) (list o e)))))))

    (define (with-stage-outputs sh st thunk)
      (let-values (((outs oute to-close) (resolve-stage-outputs sh st)))
        (let ((saved-outs (shell-outs sh)) (saved-oute (shell-oute sh)))
          (dynamic-wind
            (lambda () (shell-outs-set! sh outs) (shell-oute-set! sh oute))
            thunk
            (lambda ()
              (shell-outs-set! sh saved-outs)
              (shell-oute-set! sh saved-oute)
              (for-each close-port to-close))))))

    (define (run-stage sh st stdin history ignore-stop-on-error)
      (with-stage-outputs sh st
        (lambda ()
          (guard (e ((and (command-failed? e)
                          (or ignore-stop-on-error (not (shell-option-on? sh "stop-on-error"))))
                     #f))
            (dispatch-stage sh st stdin history #f)))))

    (define (run-background sh stages command)
      (unless (null? (cdr stages))
        (println (shell-oute sh) "ERR: pipelines cannot be run in the background")
        (command-failed!))
      ;; a job writes to the redirect file itself (stdout and stderr together)
      (let* ((st (car stages))
             (file (or (stage-both-file st) (stage-stdout-file st))))
        (dispatch-stage sh st #f #f (cons command (and file (shell-path sh file))))))

    ;; the runner of .scm scripts: (values cmd args)
    (define (resolve-scm-runner sh)
      (let ((override (session-scm-override (shell-session sh)))
            (entry (env-get (shell-env sh) "scm")))
        (cond (override (split-command override sh))
              ((alias-cmd? entry) (split-command (cmd-value entry) sh))
              (else (values "scm" '())))))

    (define (call-builtin sh c args stdin)
      (let ((saved (shell-stdin sh)))
        (dynamic-wind
          (lambda () (shell-stdin-set! sh stdin))
          (lambda () ((cmd-run c) sh args))
          (lambda () (shell-stdin-set! sh saved)))))

    (define (dispatch-stage sh st stdin history background)
      (unless (string=? (stage-raw st) "")
        (let-values (((cmd args) (split-command (stage-raw st) sh)))
          (unless (string=? cmd "")
            (let*-values (((entry) (env-get (shell-env sh) cmd))
                          ((cmd args entry)
                           (if (alias-cmd? entry)
                               (let-values (((c a) (split-command
                                                    (string-append (cmd-value entry) " " (quote-args args))
                                                    sh)))
                                 (values c a (env-get (shell-env sh) c)))
                               (values cmd args entry))))
              (define (dir-arg?) (and (null? args) (directory? (shell-path sh cmd))))
              (when (and background
                         (or (builtin-cmd? entry) (string=? cmd "exit") (string-ends? cmd ".dsh")
                             (dir-arg?)))
                (println (shell-oute sh) "ERR: " cmd
                         " is not an external command and cannot be run in the background")
                (command-failed!))
              (cond ((builtin-cmd? entry) (call-builtin sh entry args stdin))
                    ((string=? cmd "exit") #f)
                    ((string-ends? cmd ".dsh")
                     (call-builtin sh (env-get (shell-env sh) "script") (cons cmd args) stdin))
                    ((string-ends? cmd ".scm")
                     (let-values (((scm-cmd scm-args) (resolve-scm-runner sh)))
                       (run-external sh scm-cmd (append scm-args (list (shell-path sh cmd)) args) stdin
                                     history (stage-env-overlay st) #t background)))
                    ((dir-arg?)
                     (let ((ls (env-get (shell-env sh) "ls")))
                       (if (builtin-cmd? ls)
                           (call-builtin sh ls (list cmd) stdin)
                           (run-external sh "ls" (list cmd) stdin history (stage-env-overlay st) #f #f))))
                    (else
                     (run-external sh cmd args stdin history (stage-env-overlay st) #f background))))))))

    ;; the child environment: the shell's env: variables (as (name value)
    ;; lists), replaced or extended by the overlay
    (define (child-env sh overlay)
      (let ((e (shell-env sh))
            (overlay (or overlay '())))
        (append
         (filter (lambda (x) x)
                 (map (lambda (name)
                        (and (string-starts? name "env:")
                             (let ((v (env-get e name))
                                   (n (substring name 4 (string-length name))))
                               (and v (not (assoc n overlay))
                                    (list n (value->string v))))))
                      (env-names e)))
         (map (lambda (p) (list (car p) (cdr p))) overlay))))

    (define (console-port? p) (or (eq? p console-out) (eq? p console-err)))

    (define (run-external sh cmd args stdin history . opt)
      (let ((overlay (if (pair? opt) (car opt) #f))
            (scm-runner (and (pair? opt) (pair? (cdr opt)) (cadr opt)))
            (background (and (pair? opt) (pair? (cdr opt)) (pair? (cddr opt)) (caddr opt))))
        (let* ((found (find-executable (shell-cwd sh) cmd))
               (executable (and found (shell-path sh found))))
          (unless executable
            (println (shell-oute sh) "ERR: " cmd " not found")
            (command-failed!))
          (cond
           ((string-ends? executable ".dsh")
            (when background
              (println (shell-oute sh) "ERR: script " executable " cannot be run in the background")
              (command-failed!))
            (call-builtin sh (env-get (shell-env sh) "script") (cons executable args) stdin))
           ((string-ends? executable ".scm")
            (when scm-runner
              (println (shell-oute sh) "ERR: scm runner " executable " is itself a .scm script")
              (command-failed!))
            (let-values (((scm-cmd scm-args) (resolve-scm-runner sh)))
              (run-external sh scm-cmd (append scm-args (list executable) args) stdin history
                            overlay #t background)))
           (background (start-job sh executable args overlay (car background) (cdr background)))
           (else
            (let* ((argv (cons executable args))
                   (opts `((work-dir ,(shell-cwd sh)) (env ,(child-env sh overlay))))
                   (direct (and (not stdin) (console-port? (shell-outs sh))
                                (console-port? (shell-oute sh))))
                   (rc
                    ((cooked-wrapper)
                     (lambda ()
                       (if direct
                           (run-program argv opts)
                           (let ((r (run-program/capture
                                     argv (if stdin (cons (list 'stdin stdin) opts) opts))))
                             (and r
                                  (begin
                                    (print-to (shell-outs sh) (cadr r))
                                    (print-to (shell-oute sh) (caddr r))
                                    (car r)))))))))
              (unless rc
                (println (shell-oute sh) "ERR: cannot run " executable)
                (command-failed!))
              (unless (eqv? rc 0) (command-failed!))
              (when history (set-terminal-title! sh (session-title (shell-session sh))))))))))

    ;; ------------------------------------------------------------------
    ;; background jobs

    (define-record-type job
      (make-job id handle command)
      job?
      (id job-id)
      (handle job-handle)
      (command job-command))

    (define (job-status j)
      (let ((h (job-handle j)))
        (if (process-alive? h)
            "Running"
            (let ((rc (process-wait h)))
              (if (eqv? rc 0) "Done" (string-append "Exit " (number->string rc)))))))

    (define (jobs-list sh) (session-jobs (shell-session sh)))

    (define (jobs-add! sh handle command)
      (let* ((ses (shell-session sh))
             (id (+ 1 (fold-left max 0 (map job-id (session-jobs ses)))))
             (j (make-job id handle command)))
        (session-jobs-set! ses (append (session-jobs ses) (list j)))
        j))

    (define (fold-left f init lst)
      (if (null? lst) init (fold-left f (f init (car lst)) (cdr lst))))

    ;; a job by %n, n or pid, or #f
    (define (jobs-get sh spec)
      (let ((jobs (jobs-list sh)))
        (if (string-starts? spec "%")
            (let ((id (parse-int (substring spec 1 (string-length spec)))))
              (and id (find-first (lambda (j) (= (job-id j) id)) jobs)))
            (let ((num (parse-int spec)))
              (and num (find-first (lambda (j) (or (= (job-id j) num)
                                                   (= (process-pid (job-handle j)) num)))
                                   jobs))))))

    (define (find-first pred lst)
      (cond ((null? lst) #f) ((pred (car lst)) (car lst)) (else (find-first pred (cdr lst)))))

    (define (jobs-remove! sh j)
      (let ((ses (shell-session sh)))
        (session-jobs-set! ses (filter (lambda (x) (not (eq? x j))) (session-jobs ses)))))

    ;; remove and return the finished jobs
    (define (jobs-reap! sh)
      (let ((done (filter (lambda (j) (not (process-alive? (job-handle j)))) (jobs-list sh))))
        (for-each (lambda (j) (jobs-remove! sh j)) done)
        done))

    (define (report-finished-jobs sh)
      (for-each (lambda (j)
                  (println (shell-oute sh) "[" (job-id j) "] " (string-pad-right (job-status j) 8)
                           " " (job-command j)))
                (jobs-reap! sh)))

    (define (start-job sh executable args overlay command log-file)
      (let* ((opts `((work-dir ,(shell-cwd sh)) (env ,(child-env sh overlay))
                     ,@(if log-file `((log-file ,log-file)) '())))
             (handle (start-program (cons executable args) opts)))
        (unless handle
          (println (shell-oute sh) "ERR: cannot start " executable)
          (command-failed!))
        (let ((j (jobs-add! sh handle command)))
          (println (shell-oute sh) "[" (job-id j) "] " (process-pid handle)))))

    ;; ------------------------------------------------------------------
    ;; scripts

    (define (read-script-lines file)
      (splitlines (decode-bytes (read-file-bytes file))))

    (define (block-start? line)
      (or (string-starts? line "if ") (string-starts? line "for ")
          (string-starts? line "while ") (string-starts? line "def ")))

    ;; the next statement: (values kind lines next-index) or (values #f #f #f)
    (define (get-statement lines idx)
      (if (>= idx (vector-length lines))
          (values #f #f #f)
          (let ((line (vector-ref lines idx)))
            (if (block-start? line)
                (let ((kind (cond ((string-starts? line "if ") 'if)
                                  ((string-starts? line "for ") 'for)
                                  ((string-starts? line "while ") 'while)
                                  (else 'def))))
                  (let loop ((i (+ idx 1)) (depth 0) (acc (list line)))
                    (if (>= i (vector-length lines))
                        (values kind (reverse acc) (+ i 1))
                        (let ((l (vector-ref lines i)))
                          (cond ((block-start? l) (loop (+ i 1) (+ depth 1) (cons l acc)))
                                ((string=? l "end")
                                 (if (= depth 0)
                                     (values kind (reverse acc) (+ i 1))
                                     (loop (+ i 1) (- depth 1) (cons l acc))))
                                (else (loop (+ i 1) depth (cons l acc))))))))
                (values 'single (list line) (+ idx 1))))))

    (define (glob-sorted pattern) (sort-strings (glob pattern)))

    ;; execute script lines in a shell; #f when a failure stopped them
    (define (execute-lines sh lines)
      (let ((lines (list->vector
                    (filter (lambda (l) (and (not (string=? l "")) (not (string-starts? l "#"))))
                            (map string-strip lines)))))
        (let loop ((idx 0))
          (let-values (((kind stmt next) (get-statement lines idx)))
            (if (not kind)
                #t
                (let ((continue?
                       (case kind
                         ((single)
                          (guard (e ((command-failed? e) (not (shell-option-on? sh "stop-on-error"))))
                            (shell-execute sh (car stmt) #f)
                            #t))
                         ((if)
                          (let ((cond-expr (string-strip (substring (car stmt) 3 (string-length (car stmt))))))
                            (if (value-truthy? (evaluate-expression cond-expr sh))
                                (execute-lines sh (cdr stmt))
                                #t)))
                         ((for)
                          (let* ((parts (filter (lambda (p) (not (string=? p "")))
                                                (string-split-on (car stmt) " ")))
                                 (name (cadr parts))
                                 (elements
                                  (apply append
                                         (map (lambda (el)
                                                (if (or (string-contains? el "*") (string-contains? el "?"))
                                                    (glob-sorted (if (path-absolute? el) el (path-join (shell-cwd sh) el)))
                                                    (list el)))
                                              (if (> (length parts) 3) (cdddr parts) '())))))
                            (let floop ((els elements))
                              (cond ((null? els) #t)
                                    (else (env-set! (shell-env sh) name (car els))
                                          (if (execute-lines sh (cdr stmt)) (floop (cdr els)) #t))))))
                         ((while)
                          (let ((c (substring (car stmt) 6 (string-length (car stmt)))))
                            (let wloop ()
                              (if (and (value-truthy? (evaluate-expression c sh))
                                       (execute-lines sh (cdr stmt)))
                                  (wloop)
                                  #t))))
                         ((def)
                          (let* ((params (filter (lambda (p) (not (string=? p "")))
                                                 (map string-strip
                                                      (string-split-on (substring (car stmt) 4 (string-length (car stmt))) " "))))
                                 (name (car params)))
                            (env-set! (shell-env sh) name
                                      (make-procedure-cmd name (cdr params) (cdr stmt) (shell-env sh)))
                            #t)))))
                  (if continue? (loop next) #f)))))))

    (define (make-procedure-cmd name params body lexenv)
      (make-cmd name
                (string-append (string-join* params " ") "   : custom procedure")
                (lambda (sh args)
                  (let ((env (make-env lexenv)))
                    (let loop ((ps params) (as args))
                      (unless (null? ps)
                        (env-set! env (car ps) (if (null? as) "" (car as)))
                        (loop (cdr ps) (if (null? as) '() (cdr as)))))
                    (execute-lines (make-child-shell sh env) body)))
                'procedure #f))

    ;; expand arguments with glob patterns into absolute paths
    (define (collect-files sh args)
      (apply append
             (map (lambda (arg)
                    (let* ((p (if (path-absolute? arg) arg (path-join (shell-cwd sh) arg)))
                           (matched (glob-sorted p)))
                      (if (null? matched) (list p) matched)))
                  args)))))
