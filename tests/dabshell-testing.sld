;; Test support: a headless shell in a temporary directory with captured
;; output, like ShellTestCase of the Python test suite.
;;
;;   (with-shell (lambda (t) (test-equal "hello" (out t "echo hello"))))

(define-library (dabshell testing)
  (export with-shell tc-shell tc-dir run-cmd out err out-raw err-raw
          write-file write-bytes read-file read-text file-path make-dirs
          scheme-path)
  (import (scheme base)
          (scheme file)
          (scm fs)
          (dabshell util)
          (dabshell core))
  (begin

    (define-record-type tc
      (make-tc shell dir out err)
      tc?
      (shell tc-shell)
      (dir tc-dir)
      (out tc-out tc-out-set!)
      (err tc-err tc-err-set!))

    (define (with-shell proc)
      (let* ((dir (path-normpath (mktempdir)))
             (sh (make-root-shell))
             (t (make-tc sh dir #f #f)))
        (shell-cwd-set! sh dir)
        (shell-option-set! sh "user-home" dir)
        (let ((o (open-output-string)))
          (shell-outs-set! sh o)
          (shell-outp-set! sh o)
          (shell-oute-set! sh (open-output-string)))
        (dynamic-wind
          (lambda () #f)
          (lambda () (proc t))
          (lambda () (guard (e (#t #f)) (rm dir 'recursive))))))

    ;; execute line; (values stdout stderr)
    (define (run-cmd t line)
      (let ((sh (tc-shell t))
            (o (open-output-string))
            (e (open-output-string)))
        (shell-outs-set! sh o)
        (shell-outp-set! sh o)
        (shell-oute-set! sh e)
        (guard (x ((command-failed? x) #f))
          (shell-execute sh line #f))
        (values (get-output-string o) (get-output-string e))))

    (define (out-raw t line) (let-values (((o e) (run-cmd t line))) o))
    (define (err-raw t line) (let-values (((o e) (run-cmd t line))) e))
    (define (out t line) (string-strip (out-raw t line)))
    (define (err t line) (string-strip (err-raw t line)))

    (define (file-path t name) (path-join (tc-dir t) name))

    (define (make-dirs path)
      (unless (directory? path)
        (make-dirs (path-dirname path))
        (make-directory path)))

    ;; write a text file (UTF-8, as given) and return its path
    (define (write-file t name content)
      (let ((path (file-path t name)))
        (make-dirs (path-dirname path))
        (if (bytevector? content)
            (write-file-bytes path content)
            (write-file-bytes path (string->utf8 content)))
        path))

    (define (write-bytes t name bv) (write-file t name bv))

    (define (read-file t name) (read-file-bytes (file-path t name)))
    (define (read-text t name) (utf8->string (read-file t name)))

    ;; a path written the way the host writes paths ("a/b" -> "a\\b" on Windows)
    (define (scheme-path p) (if is-win? (string-replace* p "/" "\\") p))))
