;; dabshell keys: reading keys from the terminal, as RawInput.getch of the
;; Python version. Keys are
;;   - a character for a printable key,
;;   - a symbol: left right up down home end page-up page-down backspace
;;     delete lf cr tab esc ctrl-left ctrl-right ctrl-up ctrl-down
;;     ctrl-a ... ctrl-z, and with editor keys on also ctrl-space
;;     ctrl-underscore paste-start paste-end,
;;   - (meta . key) for Alt+key when editor keys are on,
;;   - #f for an unknown key (to be ignored).
;; The terminal sends VT sequences on Linux and on Windows (VT input mode),
;; so one parser serves both. A key source can be replaced (tests feed keys
;; with with-key-source).

(define-library (dabshell keys)
  (export read-key editor-keys with-key-source key-source
          terminal-raw-on! terminal-raw-off! with-raw-terminal raw-terminal?
          terminal-columns terminal-rows)
  (import (scheme base)
          (scm terminal)
          (dabshell util))
  (begin

    ;; Alt keys, Ctrl+Space, Ctrl+_ and bracketed paste (the editor's keys)
    (define editor-keys (make-parameter #f))

    ;; a thunk returning the next key, or #f to read the terminal
    (define key-source (make-parameter #f))

    (define (with-key-source thunk proc)
      (parameterize ((key-source thunk)) (proc)))

    (define raw-on #f)
    (define (raw-terminal?) raw-on)
    (define (terminal-raw-on!)
      (unless raw-on
        (guard (e (#t #f)) (terminal-raw! #t))
        (set! raw-on #t)))
    (define (terminal-raw-off!)
      (when raw-on
        (guard (e (#t #f)) (terminal-raw! #f))
        (set! raw-on #f)))

    (define (with-raw-terminal thunk)
      (let ((was raw-on))
        (dynamic-wind
          terminal-raw-on!
          thunk
          (lambda () (unless was (terminal-raw-off!))))))

    (define (terminal-columns)
      (let ((s (guard (e (#t #f)) (terminal-size))))
        (if s (car s) 80)))

    (define (terminal-rows)
      (let ((s (guard (e (#t #f)) (terminal-size))))
        (if s (cdr s) 24)))

    (define (byte)
      (let ((b (terminal-read-byte)))
        (if (eof-object? b) 4 b)))   ; end of input reads as Ctrl+D

    ;; a further byte within 50 ms
    (define (byte-follows?)
      (guard (e (#t #f)) (terminal-byte-ready? 50)))

    (define ctrl-keys
      (vector 'ctrl-a 'ctrl-b 'ctrl-c 'ctrl-d 'ctrl-e 'ctrl-f 'ctrl-g 'ctrl-h 'ctrl-i
              'ctrl-j 'ctrl-k 'ctrl-l 'ctrl-m 'ctrl-n 'ctrl-o 'ctrl-p 'ctrl-q 'ctrl-r
              'ctrl-s 'ctrl-t 'ctrl-u 'ctrl-v 'ctrl-w 'ctrl-x 'ctrl-y 'ctrl-z))

    (define (read-key)
      (if (key-source)
          ((key-source))
          (read-terminal-key)))

    (define (read-terminal-key)
      (let ((n (byte)))
        (cond ((= n #x1b) (read-escape))
              ((= n #x7f) 'backspace)          ; 0x08 is Ctrl+H (Ctrl+Backspace)
              ((= n #x09) 'tab)
              ((= n #x0a) 'lf)
              ((= n #x0d) 'cr)
              ((<= 1 n 26) (vector-ref ctrl-keys (- n 1)))
              ((and (= n 0) (editor-keys)) 'ctrl-space)
              ((and (= n #x1f) (editor-keys)) 'ctrl-underscore)
              ((< n #x80) (integer->char n))
              (else (read-utf8 n)))))

    (define (read-utf8 n)
      (let* ((count (cond ((< n #xE0) 1) ((< n #xF0) 2) (else 3)))
             (bv (make-bytevector (+ count 1) n)))
        (let loop ((i 1))
          (when (<= i count)
            (bytevector-u8-set! bv i (byte))
            (loop (+ i 1))))
        (let ((s (utf8->string bv)))
          (if (= (string-length s) 1) (string-ref s 0) #\xFFFD))))

    (define (read-escape)
      (if (not (byte-follows?))
          'esc
          (let ((n (byte)))
            (cond ((= n #x1b) 'esc)
                  ((= n #x4f)                                ; SS3: ESC O X
                   (case (byte)
                     ((#x41) 'up) ((#x42) 'down) ((#x43) 'right) ((#x44) 'left)
                     ((#x46) 'end) ((#x48) 'home)
                     (else 'esc)))
                  ((= n #x5b) (read-csi))
                  ((and (editor-keys) (= n #x7f)) (cons 'meta 'backspace))
                  ((and (editor-keys) (<= #x20 n #x7e)) (cons 'meta (integer->char n)))
                  (else 'esc)))))

    ;; ESC [ params final
    (define (read-csi)
      (let loop ((params '()))
        (let ((b (byte)))
          (if (or (<= #x30 b #x3f) (= b #x3b))
              (loop (cons b params))
              (csi-key (list->string (map integer->char (reverse params))) b)))))

    (define (csi-key params final)
      (define (arrow f)
        (case f ((#x41) 'up) ((#x42) 'down) ((#x43) 'right) ((#x44) 'left)
          ((#x46) 'end) ((#x48) 'home) (else #f)))
      (cond ((string=? params "")
             (or (arrow final) 'esc))
            ((= final #x7e)                                  ; ESC [ N ~
             (cond ((member params '("1" "7")) 'home)
                   ((member params '("4" "8")) 'end)
                   ((string=? params "3") 'delete)
                   ((string=? params "5") 'page-up)
                   ((string=? params "6") 'page-down)
                   ((string=? params "200") (if (editor-keys) 'paste-start 'esc))
                   ((string=? params "201") (if (editor-keys) 'paste-end 'esc))
                   (else 'esc)))
            ((string=? params "1;5")                         ; Ctrl+arrow
             (case final
               ((#x41) 'ctrl-up) ((#x42) 'ctrl-down) ((#x43) 'ctrl-right) ((#x44) 'ctrl-left)
               (else 'esc)))
            (else 'esc)))))
