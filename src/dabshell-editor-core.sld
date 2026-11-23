;; dabshell editor-core: the editor session (buffers, kill ring, prompts,
;; rendering), its editing commands (the cmd_* methods of editor.py) and
;; the emacs key map. Key maps are records of procedures; the vim key map
;; registers itself from (dabshell editor-vim).
;;
;; Keys are those of (dabshell keys): characters, symbols such as 'left or
;; 'ctrl-a, and (meta . key).

(define-library (dabshell editor-core)
  (export make-editor editor? editor-shell editor-out editor-buffers editor-cur editor-cur-set!
          editor-prev editor-prev-set! editor-message editor-message-set! editor-running?
          editor-running-set! editor-keymap editor-text-rows editor-last-frame
          editor-kill-text editor-kill-text-set! editor-kill-linewise editor-kill-linewise-set!
          editor-last-search editor-last-search-set! editor-buffers-set!
          editor-set-keymap! editor-select! editor-open-file! editor-new-buffer! editor-resolve
          editor-unique-name editor-run! editor-render! editor-dispatch! editor-call! editor-execute!
          editor-prompt editor-ask editor-save-buffer! editor-complete-file editor-complete-buffer
          make-keymap keymap? keymap-name keymap-handle keymap-pending keymap-status
          keymap-selection keymap-cursor-shape keymap-paste-start keymap-paste-end
          register-keymap! describe-key printable-key? path-normcase)
  (import (scheme base)
          (scheme char)
          (only (srfi 1) filter)
          (srfi 69)
          (srfi 132)
          (scm fs)
          (dabshell util)
          (dabshell core)
          (dabshell keys)
          (dabshell completion)
          (dabshell editor-buffer))
  (begin

    ;; ------------------------------------------------------------------
    ;; key maps

    ;; handle: (ed key); pending: () -> string or #f; status: (ed) ->
    ;; string; selection: (ed) -> #f or (start end linewise?);
    ;; cursor-shape: () -> escape sequence; paste-start/-end: (ed) or #f
    (define-record-type keymap
      (make-keymap name handle pending status selection cursor-shape paste-start paste-end)
      keymap?
      (name keymap-name)
      (handle keymap-handle)
      (pending keymap-pending)
      (status keymap-status)
      (selection keymap-selection)
      (cursor-shape keymap-cursor-shape)
      (paste-start keymap-paste-start)
      (paste-end keymap-paste-end))

    (define keymap-makers '())
    (define (register-keymap! name make)
      (set! keymap-makers (cons (cons name make) keymap-makers)))

    (define key-names
      '((left . "<left>") (right . "<right>") (up . "<up>") (down . "<down>")
        (home . "<home>") (end . "<end>") (page-up . "<prior>") (page-down . "<next>")
        (backspace . "DEL") (delete . "<delete>") (tab . "TAB") (cr . "RET") (lf . "C-j")
        (esc . "ESC") (ctrl-space . "C-SPC") (ctrl-underscore . "C-_")
        (ctrl-left . "C-<left>") (ctrl-right . "C-<right>")
        (ctrl-up . "C-<up>") (ctrl-down . "C-<down>")))

    ;; a key in emacs notation: "C-x", "M-f", "RET", "SPC"
    (define (describe-key key)
      (cond ((pair? key) (string-append "M-" (describe-key (cdr key))))
            ((assq key key-names) => cdr)
            ((and (symbol? key) (string-starts? (symbol->string key) "ctrl-"))
             (let ((s (symbol->string key))) (string-append "C-" (substring s 5 (string-length s)))))
            ((symbol? key) (symbol->string key))
            ((eqv? key #\space) "SPC")
            ((char? key) (string key))
            ((string? key) key)
            (else "?")))

    ;; Python's str.isprintable() for a key
    (define (printable-key? key)
      (and (char? key)
           (let ((c (char->integer key)))
             (and (>= c #x20) (not (= c #x7f)) (not (<= #x80 c #xa0)) (not (= c #xad))))))

    ;; ------------------------------------------------------------------
    ;; the editor

    (define-record-type editor
      (%make-editor shell out size-fn buffers cur prev kill-text kill-linewise last-search
                    last-cmd this-cmd message minibuffer running pasting keymap undo-kind
                    text-rows width last-frame)
      editor?
      (shell editor-shell)
      (out editor-out)
      (size-fn editor-size-fn)
      (buffers editor-buffers editor-buffers-set!)
      (cur editor-cur editor-cur-set!)
      (prev editor-prev editor-prev-set!)
      (kill-text editor-kill-text editor-kill-text-set!)
      (kill-linewise editor-kill-linewise editor-kill-linewise-set!)   ; vim: whole lines
      (last-search editor-last-search editor-last-search-set!)
      (last-cmd editor-last-cmd editor-last-cmd-set!)
      (this-cmd editor-this-cmd editor-this-cmd-set!)
      (message editor-message editor-message-set!)
      (minibuffer editor-minibuffer editor-minibuffer-set!)   ; #f or (label text pos extra)
      (running editor-running? editor-running-set!)
      (pasting editor-pasting? editor-pasting-set!)
      (keymap editor-keymap editor-keymap-set!)
      (undo-kind editor-undo-kind editor-undo-kind-set!)
      (text-rows editor-text-rows editor-text-rows-set!)
      (width editor-width editor-width-set!)
      (last-frame editor-last-frame editor-last-frame-set!))

    (define (terminal-size*) (cons (terminal-columns) (terminal-rows)))

    ;; (make-editor shell out [size-fn [keymap-name]]); size-fn returns
    ;; (columns . rows)
    (define (make-editor shell out . opt)
      (let ((ed (%make-editor shell out (if (pair? opt) (car opt) terminal-size*)
                              '() #f #f "" #f "" #f #f "" #f #f #f #f #f 20 79 "")))
        (editor-set-keymap! ed (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) "emacs") #t)
        ed))

    (define (editor-set-keymap! ed name . quiet)
      (let ((make (assoc name keymap-makers)))
        (unless make (editor-error "Unknown key bindings: " name))
        (editor-keymap-set! ed ((cdr make)))
        (unless (and (pair? quiet) (car quiet))
          (editor-message-set! ed (string-append "Switched to " name " key bindings")))))

    ;; ------------------------------------------------------------------
    ;; buffers

    (define (path-normcase p) (if is-win? (string-downcase (string-replace* p "/" "\\")) p))

    (define (editor-resolve ed path)
      (let ((path (path-expanduser path)))
        (path-normpath (if (path-absolute? path) path (path-join (shell-cwd (editor-shell ed)) path)))))

    (define (editor-unique-name ed base . exclude)
      (let ((names (map buffer-name (filter (lambda (b) (not (and (pair? exclude) (eq? b (car exclude)))))
                                            (editor-buffers ed)))))
        (let loop ((name base) (n 2))
          (if (member name names)
              (loop (string-append base "<" (number->string n) ">") (+ n 1))
              name))))

    (define (add-buffer! ed buf)
      (editor-buffers-set! ed (append (editor-buffers ed) (list buf)))
      (editor-select! ed buf)
      buf)

    (define (editor-select! ed buf)
      (unless (eq? buf (editor-cur ed))
        (editor-prev-set! ed (editor-cur ed))
        (editor-cur-set! ed buf)))

    (define (editor-open-file! ed path)
      (let* ((full (editor-resolve ed path))
             (existing (let loop ((bs (editor-buffers ed)))
                         (cond ((null? bs) #f)
                               ((and (buffer-path (car bs))
                                     (string=? (path-normcase (buffer-path (car bs))) (path-normcase full)))
                                (car bs))
                               (else (loop (cdr bs)))))))
        (if existing
            (begin (editor-select! ed existing) existing)
            (let ((buf (buffer-from-file full (editor-unique-name ed (path-basename full)))))
              (unless (path-exists?* full) (editor-message-set! ed "(New file)"))
              (add-buffer! ed buf)))))

    (define (editor-new-buffer! ed name)
      (add-buffer! ed (make-buffer (editor-unique-name ed name))))

    ;; ------------------------------------------------------------------
    ;; main loop

    (define (emit ed s)
      (write-string s (editor-out ed))
      (flush-output-port (editor-out ed)))

    (define (editor-run! ed)
      (when (null? (editor-buffers ed)) (editor-new-buffer! ed "*scratch*"))
      (parameterize ((editor-keys #t))
        (emit ed (string-append "\x1b;[?1049h" (if is-win? "" "\x1b;[?2004h")))
        (editor-running-set! ed #t)
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let loop ()
              (when (editor-running? ed)
                (editor-render! ed)
                (editor-dispatch! ed (editor-read-key ed))
                (loop))))
          (lambda ()
            (emit ed (string-append (if is-win? "" "\x1b;[?2004l")
                                    "\x1b;[0m\x1b;[0 q\x1b;[?25h\x1b;[?1049l"))))))

    ;; the next key; bracketed paste markers are consumed here
    (define (editor-read-key ed)
      (let ((key (read-key)))
        (cond ((not key) (editor-read-key ed))
              ((eqv? key #\x0) 'ctrl-space)
              ((eqv? key #\x1f) 'ctrl-underscore)
              ((memq key '(paste-start paste-end))
               (let ((start? (eq? key 'paste-start)))
                 (editor-pasting-set! ed start?)
                 (let ((hook ((if start? keymap-paste-start keymap-paste-end) (editor-keymap ed))))
                   (when (and hook (not (editor-minibuffer ed))) (hook ed))))
               (editor-read-key ed))
              (else key))))

    ;; errors the editor reports instead of passing on (Python's Exception)
    (define (reportable? e) (or (error-object? e) (file-error? e) (read-error? e) (string? e)))

    (define (editor-dispatch! ed key)
      (editor-message-set! ed "")
      (guard (e ((editor-error? e)
                 (editor-minibuffer-set! ed #f)
                 (editor-message-set! ed (editor-error-message e)))
                ((reportable? e)                   ; never take the shell down
                 (editor-minibuffer-set! ed #f)
                 (editor-message-set! ed (string-append "Error: " (report-error e)))))
        ((keymap-handle (editor-keymap ed)) ed key))
      (let ((pending ((keymap-pending (editor-keymap ed)))))
        (when pending (editor-message-set! ed pending))))

    ;; commands: name -> (lambda (ed key) ...)
    (define commands (make-hash-table equal?))
    (define (defcmd name proc) (hash-table-set! commands name proc))

    ;; commands that merge into the previous undo group when repeated
    (define mergeable '("self_insert" "delete_backward_char" "delete_char"))
    ;; commands whose kills append to the previous kill
    (define kill-cmds '("kill_line" "kill_word" "backward_kill_word" "kill_region"))

    (define auto (list 'auto))

    ;; run the command name as one undoable step; (editor-call! ed name [key [kind]])
    (define (editor-call! ed name . opt)
      (let* ((key (if (pair? opt) (car opt) #f))
             (kind (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) auto))
             (kind (if (eq? kind auto) (and (member name mergeable) name) kind))
             (proc (hash-table-ref/default commands name #f)))
        (unless proc (error "no such command" name))
        (editor-execute! ed (lambda () (proc ed key)) kind name)))

    ;; Run thunk as a command. Commands with the same non-#f kind in a row
    ;; share one undo group.
    (define (editor-execute! ed thunk . opt)
      (let ((kind (if (pair? opt) (car opt) #f))
            (name (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) #f)))
        (buffer-begin-group! (editor-cur ed) kind)
        (editor-undo-kind-set! ed kind)
        (editor-this-cmd-set! ed name)
        (dynamic-wind
          (lambda () #f)
          thunk
          (lambda ()
            (editor-last-cmd-set! ed (editor-this-cmd ed))
            (when (editor-cur ed) (buffer-clamp! (editor-cur ed)))))))

    ;; ------------------------------------------------------------------
    ;; prompts

    (define (with-minibuffer ed thunk)
      (dynamic-wind (lambda () #f) thunk (lambda () (editor-minibuffer-set! ed #f))))

    (define (common-string-prefix strs)
      (let loop ((p (car strs)) (rest (cdr strs)))
        (if (null? rest)
            p
            (let* ((s (car rest))
                   (n (let count ((i 0))
                        (if (and (< i (string-length p)) (< i (string-length s))
                                 (char=? (string-ref p i) (string-ref s i)))
                            (count (+ i 1))
                            i))))
              (loop (substring p 0 n) (cdr rest))))))

    (define (completion-label m)
      (let ((b (path-basename (string-rstrip m "/\\"))))
        (if (string=? b "") m b)))

    ;; read a line in the minibuffer; C-g raises Quit
    (define (editor-prompt ed label . opt)
      (let ((default (if (pair? opt) (car opt) ""))
            (completer (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) #f)))
        (with-minibuffer ed
          (lambda ()
            (let loop ((text default) (pos (string-length default)) (extra ""))
              (editor-minibuffer-set! ed (list label text pos extra))
              (editor-render! ed)
              (let ((key (editor-read-key ed))
                    (n (string-length text)))
                (define (cut a b) (substring text a b))
                (cond ((memv key '(cr lf)) text)
                      ((memv key '(ctrl-g esc)) (editor-error "Quit"))
                      ((memv key '(backspace ctrl-h))
                       (if (> pos 0)
                           (loop (string-append (cut 0 (- pos 1)) (cut pos n)) (- pos 1) "")
                           (loop text pos "")))
                      ((memv key '(delete ctrl-d))
                       (loop (if (< pos n) (string-append (cut 0 pos) (cut (+ pos 1) n)) text) pos ""))
                      ((memv key '(left ctrl-b)) (loop text (max 0 (- pos 1)) ""))
                      ((memv key '(right ctrl-f)) (loop text (min n (+ pos 1)) ""))
                      ((memv key '(home ctrl-a)) (loop text 0 ""))
                      ((memv key '(end ctrl-e)) (loop text n ""))
                      ((eq? key 'ctrl-k) (loop (cut 0 pos) pos ""))
                      ((and (eq? key 'tab) completer)
                       (let ((matches (completer text)))
                         (if (null? matches)
                             (loop text pos "  [No match]")
                             (let* ((common (common-string-prefix matches))
                                    (text2 (if (> (string-length common) n) common text))
                                    (pos2 (if (> (string-length common) n) (string-length common) pos)))
                               (loop text2 pos2
                                     (if (pair? (cdr matches))
                                         (string-append "  {" (string-join* (map completion-label (take-up-to matches 20))
                                                                            " | ")
                                                        "}")
                                         ""))))))
                      ((printable-key? key)
                       (loop (string-append (cut 0 pos) (string key) (cut pos n)) (+ pos 1) ""))
                      (else (loop text pos "")))))))))

    ;; ask for a single key out of the string choices; C-g raises Quit
    (define (editor-ask ed question choices)
      (with-minibuffer ed
        (lambda ()
          (let loop ()
            (editor-minibuffer-set! ed (list question "" 0 ""))
            (editor-render! ed)
            (let ((key (editor-read-key ed)))
              (cond ((memv key '(ctrl-g esc)) (editor-error "Quit"))
                    ((and (char? key) (string-index-of choices (string (char-downcase key))))
                     (char-downcase key))
                    (else (loop))))))))

    ;; file names completing text, directories with a trailing separator
    (define (editor-complete-file ed text)
      (let* ((cwd (shell-cwd (editor-shell ed)))
             (split (split-path-word text is-win? (car (path-splitdrive cwd)))))
        (if (not split)
            '()
            (let* ((dir-part (car split))
                   (base (if is-win? (string-downcase (cdr split)) (cdr split)))
                   (dir (if (string=? dir-part "") cwd (path-join cwd dir-part)))
                   (names (sort-strings (guard (e (#t '())) (map car (directory-entries dir))))))
              (let loop ((ns names) (acc '()))
                (if (null? ns)
                    (reverse acc)
                    (let ((fname (car ns)))
                      (loop (cdr ns)
                            (if (string-starts? (if is-win? (string-downcase fname) fname) base)
                                (cons (string-append dir-part fname
                                                     (if (directory? (path-join dir fname)) (if is-win? "\\" "/") ""))
                                      acc)
                                acc)))))))))

    (define (editor-complete-buffer ed text)
      (filter (lambda (n) (string-starts? n text)) (map buffer-name (editor-buffers ed))))

    ;; ------------------------------------------------------------------
    ;; rendering

    (define (scroll! ed buf)
      (let ((rows (editor-text-rows ed))
            (width (editor-width ed)))
        (cond ((< (buffer-row buf) (buffer-top buf)) (buffer-top-set! buf (buffer-row buf)))
              ((>= (buffer-row buf) (+ (buffer-top buf) rows))
               (buffer-top-set! buf (+ (- (buffer-row buf) rows) 1))))
        (let ((dc (string-length (display-text (substring (buffer-line buf (buffer-row buf)) 0 (buffer-col buf)))))
              (left (buffer-left buf)))
          (when (or (< dc left) (and (> left 0) (= dc left)) (>= dc (+ left width -1)))
            (buffer-left-set! buf (max 0 (- dc (quotient width 2)))))
          (when (< dc (- width 1)) (buffer-left-set! buf 0)))))

    (define (slice s a b)
      (let ((n (string-length s)))
        (substring s (min (max a 0) n) (min (max b 0) n))))

    ;; one line of text; sel = (start-col end-col past-eol?) is highlighted
    (define (render-line ed line left sel)
      (let* ((width (editor-width ed))
             (disp (display-text line))
             (seg (slice disp left (+ left width)))
             (seg (if (and (> left 0) (> (string-length seg) 0))
                      (string-append "$" (slice seg 1 (string-length seg)))
                      seg))
             (seg (if (> (string-length disp) (+ left width))
                      (string-append (slice seg 0 (- width 1)) "$")
                      seg)))
        (if (not sel)
            seg
            (let* ((a (- (string-length (display-text (substring line 0 (car sel)))) left))
                   (z (+ (- (string-length (display-text (substring line 0 (cadr sel)))) left)
                         (if (caddr sel) 1 0)))
                   (a (max 0 a))
                   (z (min width z)))
              (if (< a z)
                  (let ((seg (string-pad-right seg z)))
                    (string-append (slice seg 0 a) "\x1b;[7m" (slice seg a z) "\x1b;[27m"
                                   (slice seg z (string-length seg))))
                  seg)))))

    (define (list-index-eq x lst)
      (let loop ((l lst) (i 0)) (cond ((null? l) #f) ((eq? (car l) x) i) (else (loop (cdr l) (+ i 1))))))

    (define (modeline ed)
      (let* ((buf (editor-cur ed))
             (enc (if (string=? (buffer-encoding buf) "utf-8-sig") "utf-8-bom" (buffer-encoding buf))))
        (string-append " " (if (buffer-modified? buf) "**" "--") " " (buffer-name buf)
                       "   L" (number->string (+ (buffer-row buf) 1)) " C" (number->string (buffer-col buf))
                       "   (" (number->string (+ (list-index-eq buf (editor-buffers ed)) 1))
                       "/" (number->string (length (editor-buffers ed))) ")  "
                       enc " " (if (string=? (buffer-newline buf) "\r\n") "CRLF" "LF")
                       "  [" (keymap-name (editor-keymap ed)) "]   C-x C-c quit")))

    (define (editor-render! ed)
      (let* ((size ((editor-size-fn ed)))
             (cols (max 10 (car size)))
             (rows (max 3 (cdr size)))
             (buf (editor-cur ed))
             (km (editor-keymap ed))
             (out (open-output-string)))
        (editor-width-set! ed (- cols 1))
        (editor-text-rows-set! ed (- rows 2))
        (scroll! ed buf)
        (let ((sel ((keymap-selection km) ed))
              (width (editor-width ed)))
          (write-string "\x1b;[?25l\x1b;[H" out)
          (do ((i 0 (+ i 1))) ((= i (editor-text-rows ed)))
            (let ((r (+ (buffer-top buf) i)))
              (when (< r (buffer-line-count buf))
                (let* ((line (buffer-line buf r))
                       (left (if (= r (buffer-row buf)) (buffer-left buf) 0))
                       (span (and sel
                                  (let ((r1 (car (car sel))) (c1 (cdr (car sel)))
                                        (r2 (car (cadr sel))) (c2 (cdr (cadr sel))))
                                    (and (<= r1 r r2)
                                         (if (caddr sel)
                                             (list 0 (string-length line) #t)
                                             (list (if (= r r1) c1 0)
                                                   (if (= r r2) c2 (string-length line))
                                                   (< r r2))))))))
                  (write-string (render-line ed line left span) out)))
              (write-string "\x1b;[K\r\n" out)))
          (let ((ml (string-pad-right (slice (modeline ed) 0 width) width)))
            (write-string (string-append "\x1b;[7m" ml "\x1b;[0m\x1b;[K\r\n") out))
          (let-values
              (((y x)
                (let ((mb (editor-minibuffer ed)))
                  (if mb
                      (let* ((label (car mb)) (pos (caddr mb))
                             (line (string-append label (cadr mb) (cadddr mb)))
                             (shift (max 0 (+ (string-length label) pos (- width) 1))))
                        (write-string (string-append (slice line shift (+ shift width)) "\x1b;[K") out)
                        (values rows (+ (- (+ (string-length label) pos) shift) 1)))
                      (let ((msg (if (string=? (editor-message ed) "") ((keymap-status km) ed) (editor-message ed))))
                        (write-string (string-append (slice msg 0 width) "\x1b;[K") out)
                        (values (+ (- (buffer-row buf) (buffer-top buf)) 1)
                                (+ (- (string-length (display-text (substring (buffer-line buf (buffer-row buf))
                                                                              0 (buffer-col buf))))
                                      (buffer-left buf))
                                   1)))))))
            (write-string (string-append "\x1b;[" (number->string y) ";" (number->string x) "H"
                                         ((keymap-cursor-shape km)) "\x1b;[?25h")
                          out)))
        (editor-last-frame-set! ed (get-output-string out))
        (emit ed (editor-last-frame ed))))

    ;; ------------------------------------------------------------------
    ;; helpers for commands

    (define (cur ed) (editor-cur ed))
    (define (goto! ed pos) (buffer-goto! (cur ed) pos))
    (define (insert-text! ed text)
      (let ((b (cur ed))) (goto! ed (buffer-insert! b (buffer-row b) (buffer-col b) text))))

    (define (kill! ed text . backward)
      (editor-kill-linewise-set! ed #f)
      (editor-kill-text-set!
       ed (if (member (editor-last-cmd ed) kill-cmds)
              (if (and (pair? backward) (car backward))
                  (string-append text (editor-kill-text ed))
                  (string-append (editor-kill-text ed) text))
              text)))

    ;; (values start end) of the region
    (define (region ed)
      (let ((b (cur ed)))
        (unless (buffer-mark b) (editor-error "The mark is not set now"))
        (sort-pos (buffer-pos b) (buffer-mark b))))

    (define (line-of b) (buffer-line b (buffer-row b)))

    ;; ------------------------------------------------------------------
    ;; movement

    (defcmd "forward_char"
      (lambda (ed key)
        (let ((p (buffer-next-pos (cur ed) (buffer-row (cur ed)) (buffer-col (cur ed)))))
          (unless p (editor-error "End of buffer"))
          (goto! ed p))))

    (defcmd "backward_char"
      (lambda (ed key)
        (let ((p (buffer-prev-pos (cur ed) (buffer-row (cur ed)) (buffer-col (cur ed)))))
          (unless p (editor-error "Beginning of buffer"))
          (goto! ed p))))

    (define (vertical! ed delta)
      (let ((b (cur ed)))
        (when (or (not (member (editor-last-cmd ed) '("next_line" "previous_line")))
                  (not (buffer-goal-col b)))
          (buffer-goal-col-set! b (buffer-col b)))
        (let ((new-row (+ (buffer-row b) delta)))
          (cond ((< new-row 0)
                 (buffer-goto! b (cons 0 0))
                 (editor-error "Beginning of buffer"))
                ((>= new-row (buffer-line-count b))
                 (buffer-goto! b (buffer-end-pos b))
                 (editor-error "End of buffer"))
                (else
                 (buffer-row-set! b new-row)
                 (buffer-col-set! b (min (buffer-goal-col b) (string-length (buffer-line b new-row)))))))))

    (defcmd "next_line" (lambda (ed key) (vertical! ed 1)))
    (defcmd "previous_line" (lambda (ed key) (vertical! ed -1)))
    (defcmd "beginning_of_line" (lambda (ed key) (buffer-col-set! (cur ed) 0)))
    (defcmd "end_of_line" (lambda (ed key) (buffer-col-set! (cur ed) (string-length (line-of (cur ed))))))
    (defcmd "forward_word"
      (lambda (ed key) (goto! ed (buffer-word-forward (cur ed) (buffer-row (cur ed)) (buffer-col (cur ed))))))
    (defcmd "backward_word"
      (lambda (ed key) (goto! ed (buffer-word-backward (cur ed) (buffer-row (cur ed)) (buffer-col (cur ed))))))

    (defcmd "beginning_of_buffer"
      (lambda (ed key)
        (buffer-mark-set! (cur ed) (buffer-pos (cur ed)))
        (goto! ed (cons 0 0))
        (editor-message-set! ed "Mark set")))

    (defcmd "end_of_buffer"
      (lambda (ed key)
        (buffer-mark-set! (cur ed) (buffer-pos (cur ed)))
        (goto! ed (buffer-end-pos (cur ed)))
        (editor-message-set! ed "Mark set")))

    (defcmd "scroll_up"
      (lambda (ed key)
        (let ((b (cur ed)) (page (max 1 (- (editor-text-rows ed) 2))))
          (when (>= (buffer-row b) (buffer-last-row b)) (editor-error "End of buffer"))
          (buffer-top-set! b (min (+ (buffer-top b) page) (max 0 (buffer-last-row b))))
          (buffer-row-set! b (min (buffer-last-row b) (max (+ (buffer-row b) page) (buffer-top b)))))))

    (defcmd "scroll_down"
      (lambda (ed key)
        (let ((b (cur ed)) (page (max 1 (- (editor-text-rows ed) 2))))
          (when (= (buffer-row b) 0) (editor-error "Beginning of buffer"))
          (buffer-top-set! b (max 0 (- (buffer-top b) page)))
          (buffer-row-set! b (max 0 (- (buffer-row b) page))))))

    (define (recenter! ed)
      (let ((b (cur ed)))
        (buffer-top-set! b (max 0 (- (buffer-row b) (quotient (editor-text-rows ed) 2))))))

    (defcmd "recenter" (lambda (ed key) (recenter! ed)))

    (defcmd "goto_line"
      (lambda (ed key)
        (let* ((text (editor-prompt ed "Goto line: "))
               (n (parse-int (string-strip text)))
               (b (cur ed)))
          (unless n (editor-error "Not a line number: " text))
          (buffer-row-set! b (max 0 (min (- n 1) (buffer-last-row b))))
          (buffer-col-set! b 0)
          (recenter! ed))))

    ;; ------------------------------------------------------------------
    ;; editing

    (defcmd "self_insert"
      (lambda (ed key)
        (insert-text! ed (string key))
        (when (and (char-whitespace? key) (equal? (editor-undo-kind ed) "self_insert"))
          (buffer-break-group! (cur ed)))))   ; emacs: undo typing word by word

    (defcmd "newline"
      (lambda (ed key)
        (let* ((b (cur ed))
               (line (substring (line-of b) 0 (buffer-col b)))
               (indent (if (editor-pasting? ed) "" (substring line 0 (first-nonblank line)))))
          (insert-text! ed (string-append "\n" indent)))))

    (defcmd "tab"
      (lambda (ed key)
        (let ((b (cur ed)))
          (if (or (editor-pasting? ed) (buffer-uses-tabs b))
              (insert-text! ed "\t")
              (let ((col (string-length (display-text (substring (line-of b) 0 (buffer-col b))))))
                (insert-text! ed (make-string (- indent-width (modulo col indent-width)) #\space)))))))

    (defcmd "delete_backward_char"
      (lambda (ed key)
        (let* ((b (cur ed)) (p (buffer-prev-pos b (buffer-row b) (buffer-col b))))
          (unless p (editor-error "Beginning of buffer"))
          (buffer-delete! b p (buffer-pos b))
          (goto! ed p))))

    (defcmd "delete_char"
      (lambda (ed key)
        (let* ((b (cur ed)) (p (buffer-next-pos b (buffer-row b) (buffer-col b))))
          (unless p (editor-error "End of buffer"))
          (buffer-delete! b (buffer-pos b) p))))

    (defcmd "kill_line"
      (lambda (ed key)
        (let* ((b (cur ed)) (line (line-of b)) (row (buffer-row b)) (col (buffer-col b))
               (n (string-length line))
               (end (cond ((and (< col n) (not (string=? (string-strip (substring line col n)) "")))
                           (cons row n))
                          ;; only whitespace (or nothing) left: kill through the newline
                          ((< row (buffer-last-row b)) (cons (+ row 1) 0))
                          ((< col n) (cons row n))
                          (else (editor-error "End of buffer")))))
          (kill! ed (buffer-delete! b (buffer-pos b) end)))))

    (defcmd "kill_word"
      (lambda (ed key)
        (let* ((b (cur ed)) (end (buffer-word-forward b (buffer-row b) (buffer-col b))))
          (kill! ed (buffer-delete! b (buffer-pos b) end)))))

    (defcmd "backward_kill_word"
      (lambda (ed key)
        (let* ((b (cur ed)) (start (buffer-word-backward b (buffer-row b) (buffer-col b))))
          (kill! ed (buffer-delete! b start (buffer-pos b)) #t)
          (goto! ed start))))

    (defcmd "yank"
      (lambda (ed key)
        (when (string=? (editor-kill-text ed) "") (editor-error "Kill ring is empty"))
        (buffer-mark-set! (cur ed) (buffer-pos (cur ed)))
        (insert-text! ed (editor-kill-text ed))))

    (defcmd "set_mark"
      (lambda (ed key)
        (buffer-mark-set! (cur ed) (buffer-pos (cur ed)))
        (editor-message-set! ed "Mark set")))

    (defcmd "kill_region"
      (lambda (ed key)
        (let-values (((start end) (region ed)))
          (kill! ed (buffer-delete! (cur ed) start end))
          (goto! ed start)
          (buffer-mark-set! (cur ed) #f))))

    (defcmd "copy_region"
      (lambda (ed key)
        (let-values (((start end) (region ed)))
          (editor-kill-text-set! ed (buffer-text-range (cur ed) start end))
          (editor-kill-linewise-set! ed #f)
          (buffer-mark-set! (cur ed) #f)
          (editor-message-set! ed "Copied region"))))

    (defcmd "mark_whole_buffer"
      (lambda (ed key)
        (buffer-mark-set! (cur ed) (buffer-end-pos (cur ed)))
        (goto! ed (cons 0 0))
        (editor-message-set! ed "Mark set")))

    (defcmd "keyboard_quit"
      (lambda (ed key)
        (buffer-mark-set! (cur ed) #f)
        (editor-message-set! ed "Quit")))

    (defcmd "undo"
      (lambda (ed key)
        (unless (buffer-undo! (cur ed)) (editor-error "No further undo information"))
        (editor-message-set! ed "Undo")))

    (define (command-names)
      (append (list-sort string<?
                         (map (lambda (n) (string-replace* n "_" "-"))
                              (filter (lambda (n) (not (member n '("self_insert" "execute_extended_command"))))
                                      (hash-table-keys commands))))
              '("emacs-mode" "vim-mode")))

    (defcmd "execute_extended_command"
      (lambda (ed key)
        (let* ((names (command-names))
               (text (string-strip
                      (editor-prompt ed "M-x " ""
                                     (lambda (t) (filter (lambda (n) (string-starts? n t)) names))))))
          (cond ((string=? text "") #f)
                ((member text '("vim-mode" "vim")) (editor-set-keymap! ed "vim"))
                ((member text '("emacs-mode" "emacs")) (editor-set-keymap! ed "emacs"))
                ((member text names) (editor-call! ed (string-replace* text "-" "_")))
                (else (editor-error "[No match] " text))))))

    ;; ------------------------------------------------------------------
    ;; search / replace

    (defcmd "isearch_forward" (lambda (ed key) (isearch ed #t)))
    (defcmd "isearch_backward" (lambda (ed key) (isearch ed #f)))

    (define (isearch ed forward)
      (let* ((b (cur ed))
             (start (buffer-pos b))
             (query "") (match #f) (failing #f) (origin #f))
        (with-minibuffer ed
          (lambda ()
            (let loop ()
              (editor-minibuffer-set! ed (list (string-append (if failing "Failing " "")
                                                              (if forward "I-search: " "I-search backward: "))
                                               query (string-length query) ""))
              (editor-render! ed)
              (let ((key (editor-read-key ed)) (qn (string-length query)))
                (define (search!)
                  (when (> (string-length query) 0)
                    (let ((found (buffer-search b query (car origin) (cdr origin) forward)))
                      (set! failing (not found))
                      (when found
                        (set! match found)
                        (goto! ed (if forward
                                      (cons (car found) (+ (cdr found) (string-length query)))
                                      found)))))
                  (loop))
                (cond ((memq key '(ctrl-s ctrl-r))
                       (set! forward (eq? key 'ctrl-s))
                       (cond ((= qn 0)
                              (set! query (editor-last-search ed))
                              (set! origin (buffer-pos b)))
                             (match
                              (set! origin (if forward
                                               (cons (car match) (+ (cdr match) 1))
                                               (cons (car match) (+ (cdr match) qn -1)))))
                             (else (set! origin (buffer-pos b))))
                       (search!))
                      ((memq key '(backspace ctrl-h))
                       (set! query (if (> qn 0) (substring query 0 (- qn 1)) query))
                       (set! match #f)
                       (set! origin start)
                       (if (string=? query "")
                           (begin (goto! ed start) (set! failing #f) (loop))
                           (search!)))
                      ((eq? key 'ctrl-g)
                       (goto! ed start)
                       (editor-error "Quit"))
                      ((printable-key? key)
                       (set! query (string-append query (string key)))
                       (set! origin (cond (match (if forward match (cons (car match) (+ (cdr match) (string-length query)))))
                                          (failing start)
                                          (else (buffer-pos b))))
                       (search!))
                      (else
                       ;; RET / ESC accept; any other key accepts and runs
                       (unless (string=? query "") (editor-last-search-set! ed query))
                       (unless (equal? (buffer-pos b) start) (buffer-mark-set! b start))
                       (unless (memq key '(cr lf esc))
                         (editor-minibuffer-set! ed #f)
                         ((keymap-handle (editor-keymap ed)) ed key))))))))))

    (defcmd "query_replace"
      (lambda (ed key)
        (let* ((old (editor-prompt ed "Query replace: " (editor-last-search ed))))
          (when (string=? old "") (editor-error "Nothing to replace"))
          (let ((new (editor-prompt ed (string-append "Query replace " old " with: ")))
                (b (cur ed)))
            (editor-last-search-set! ed old)
            (let loop ((pos (buffer-pos b)) (count 0) (all #f))
              (let ((found (buffer-search b old (car pos) (cdr pos) #t #f)))
                (define (done count)
                  (editor-message-set! ed (string-append "Replaced " (number->string count) " occurrence"
                                                         (if (= count 1) "" "s"))))
                (if (not found)
                    (done count)
                    (let ((end (cons (car found) (+ (cdr found) (string-length old)))))
                      (goto! ed end)
                      (let ((answer (if all #\y (editor-ask ed (string-append "Replace " old " with " new
                                                                              "? (y, n, !, q) ")
                                                            "yn!q"))))
                        (case answer
                          ((#\q) (done count))
                          ((#\n) (loop end count all))
                          (else
                           (buffer-delete! b found end)
                           (let ((p (buffer-insert! b (car found) (cdr found) new)))
                             (goto! ed p)
                             (loop p (+ count 1) (or all (eqv? answer #\!)))))))))))))))

    ;; ------------------------------------------------------------------
    ;; files and buffers

    (define (editor-save-buffer! ed buf)
      (unless (buffer-path buf)
        (let ((path (editor-prompt ed "File to save in: " "" (lambda (t) (editor-complete-file ed t)))))
          (when (string=? path "") (editor-error "No file name"))
          (buffer-path-set! buf (editor-resolve ed path))
          (buffer-name-set! buf (editor-unique-name ed (path-basename (buffer-path buf)) buf))))
      (guard (e ((and (editor-error? e) (encode-error? e))
                 (unless (eqv? (editor-ask ed (string-append "Text cannot be saved as " (buffer-encoding buf)
                                                             "; use utf-8? (y or n) ")
                                           "yn")
                               #\y)
                   (editor-error "Not saved"))
                 (buffer-save! buf #f "utf-8"))
                ((or (file-error? e) (error-object? e))
                 (editor-error "Cannot save " (buffer-path buf) ": " (report-error e))))
        (buffer-save! buf))
      (editor-message-set! ed (string-append "Wrote " (buffer-path buf))))

    (defcmd "save"
      (lambda (ed key)
        (if (and (not (buffer-modified? (cur ed))) (buffer-path (cur ed)))
            (editor-message-set! ed "(No changes need to be saved)")
            (editor-save-buffer! ed (cur ed)))))

    ;; os.path.relpath(dir, start) for absolute normalized paths (dir itself
    ;; when on another drive)
    (define (relpath dir start)
      (define (comps p)
        (filter (lambda (s) (not (string=? s "")))
                (string-split-on (string-replace* (cdr (path-splitdrive p)) "\\" "/") "/")))
      (define (same? a b) (if is-win? (string-ci=? a b) (string=? a b)))
      (if (not (same? (car (path-splitdrive dir)) (car (path-splitdrive start))))
          dir
          (let loop ((a (comps dir)) (b (comps start)))
            (if (and (pair? a) (pair? b) (same? (car a) (car b)))
                (loop (cdr a) (cdr b))
                (let ((parts (append (map (lambda (x) "..") b) a)))
                  (if (null? parts) "." (string-join* parts (if is-win? "\\" "/"))))))))

    ;; the directory of the current file relative to the shell, as a default
    (define (default-dir ed)
      (let ((path (buffer-path (cur ed))))
        (if (not path)
            ""
            (let ((rel (relpath (path-dirname path) (shell-cwd (editor-shell ed)))))
              (if (string=? rel ".") "" (string-append rel (if is-win? "\\" "/")))))))

    (defcmd "write_file"
      (lambda (ed key)
        (let* ((b (cur ed))
               (path (editor-prompt ed "Write file: " (default-dir ed) (lambda (t) (editor-complete-file ed t)))))
          (when (or (string=? path "") (string-ends? path "/") (and is-win? (string-ends? path "\\")))
            (editor-error "No file name"))
          (buffer-path-set! b (editor-resolve ed path))
          (buffer-name-set! b (editor-unique-name ed (path-basename (buffer-path b)) b))
          (editor-save-buffer! ed b))))

    (defcmd "find_file"
      (lambda (ed key)
        (let ((path (editor-prompt ed "Find file: " (default-dir ed) (lambda (t) (editor-complete-file ed t)))))
          (unless (string=? path "") (editor-open-file! ed path)))))

    (defcmd "switch_buffer"
      (lambda (ed key)
        (let* ((other (or (and (memq (editor-prev ed) (editor-buffers ed)) (editor-prev ed))
                          (let loop ((bs (editor-buffers ed)))
                            (cond ((null? bs) #f)
                                  ((eq? (car bs) (cur ed)) (loop (cdr bs)))
                                  (else (car bs))))))
               (label (string-append "Switch to buffer"
                                     (if other (string-append " (default " (buffer-name other) ")") "")
                                     ": "))
               (name (editor-prompt ed label "" (lambda (t) (editor-complete-buffer ed t)))))
          (if (string=? name "")
              (when other (editor-select! ed other))
              (let loop ((bs (editor-buffers ed)))
                (cond ((null? bs) (editor-new-buffer! ed name))
                      ((string=? (buffer-name (car bs)) name) (editor-select! ed (car bs)))
                      (else (loop (cdr bs)))))))))

    (defcmd "kill_buffer"
      (lambda (ed key)
        (let ((b (cur ed)))
          (when (or (not (buffer-modified? b))
                    (eqv? (editor-ask ed (string-append "Buffer " (buffer-name b) " modified; kill anyway? (y or n) ")
                                      "yn")
                          #\y))
            (editor-buffers-set! ed (filter (lambda (x) (not (eq? x b))) (editor-buffers ed)))
            (when (null? (editor-buffers ed)) (editor-new-buffer! ed "*scratch*"))
            (editor-cur-set! ed (if (memq (editor-prev ed) (editor-buffers ed))
                                    (editor-prev ed)
                                    (car (reverse (editor-buffers ed)))))
            (editor-prev-set! ed #f)))))

    (defcmd "quit"
      (lambda (ed key)
        (for-each (lambda (b)
                    (when (buffer-modified? b)
                      (editor-select! ed b)
                      (let ((answer (editor-ask ed (string-append "Save file " (or (buffer-path b) (buffer-name b))
                                                                  "? (y, n, q) ")
                                                "ynq")))
                        (when (eqv? answer #\q) (editor-error "Quit"))
                        (when (eqv? answer #\y) (editor-save-buffer! ed b)))))
                  (editor-buffers ed))
        (editor-running-set! ed #f)))

    ;; ------------------------------------------------------------------
    ;; the emacs key map

    (define emacs-global
      '((ctrl-f . "forward_char") (right . "forward_char")
        (ctrl-b . "backward_char") (left . "backward_char")
        (ctrl-n . "next_line") (down . "next_line")
        (ctrl-p . "previous_line") (up . "previous_line")
        (ctrl-a . "beginning_of_line") (home . "beginning_of_line")
        (ctrl-e . "end_of_line") (end . "end_of_line")
        (ctrl-right . "forward_word") (ctrl-left . "backward_word")
        (ctrl-v . "scroll_up") (page-down . "scroll_up")
        (page-up . "scroll_down")
        (ctrl-l . "recenter")
        (cr . "newline") (lf . "newline")
        (tab . "tab")
        (backspace . "delete_backward_char") (ctrl-h . "delete_backward_char")
        (ctrl-d . "delete_char") (delete . "delete_char")
        (ctrl-k . "kill_line")
        (ctrl-y . "yank")
        (ctrl-space . "set_mark")
        (ctrl-w . "kill_region")
        (ctrl-g . "keyboard_quit")
        (ctrl-underscore . "undo")
        (ctrl-s . "isearch_forward")
        (ctrl-r . "isearch_backward")))

    (define emacs-ctrl-x
      '((ctrl-s . "save") (ctrl-w . "write_file") (ctrl-f . "find_file") (ctrl-c . "quit")
        (ctrl-g . "keyboard_quit") (#\b . "switch_buffer") (#\k . "kill_buffer") (#\u . "undo")
        (#\h . "mark_whole_buffer") (#\space . "set_mark")))

    (define emacs-meta
      '((#\f . "forward_word") (#\b . "backward_word") (#\d . "kill_word")
        (backspace . "backward_kill_word") (#\v . "scroll_down")
        (#\< . "beginning_of_buffer") (#\> . "end_of_buffer") (#\w . "copy_region")
        (#\% . "query_replace") (#\x . "execute_extended_command")))

    (define emacs-meta-g
      '((#\g . "goto_line") ((meta . #\g) . "goto_line")))

    (define (lookup key table) (let ((p (assoc key table))) (and p (cdr p))))

    (define (make-emacs-keymap)
      (let ((prefix #f))   ; #f | c-x | m | m-g
        (define (handle ed key)
          (let ((p prefix))
            (set! prefix #f)
            (cond ((and (not p) (eq? key 'esc)) (set! prefix 'm))
                  ((and (not p) (not (pair? key)) (eq? key 'ctrl-x)) (set! prefix 'c-x))
                  ((and (or (eq? p 'm) (and (not p) (pair? key)))
                        (eqv? (if (pair? key) (cdr key) key) #\g))
                   (set! prefix 'm-g))
                  (else
                   (let-values
                       (((name seq)
                         (cond ((not p)
                                (if (pair? key)
                                    (values (lookup (cdr key) emacs-meta) (string-append "M-" (describe-key (cdr key))))
                                    (values (or (lookup key emacs-global) (and (printable-key? key) "self_insert"))
                                            (describe-key key))))
                               ((eq? p 'c-x)
                                (values (lookup key emacs-ctrl-x) (string-append "C-x " (describe-key key))))
                               ((eq? p 'm)
                                (let ((k (if (pair? key) (cdr key) key)))
                                  (values (lookup k emacs-meta) (string-append "M-" (describe-key k)))))
                               (else
                                (values (lookup key emacs-meta-g) (string-append "M-g " (describe-key key)))))))
                     (if name
                         (editor-call! ed name (if (and (pair? key) (not (eq? p 'm-g))) (cdr key) key))
                         (editor-message-set! ed (string-append seq " is undefined"))))))))
        (make-keymap "emacs" handle
                     (lambda () (case prefix ((c-x) "C-x-") ((m) "ESC-") ((m-g) "M-g-") (else #f)))
                     (lambda (ed) "")
                     (lambda (ed) #f)
                     (lambda () "\x1b;[0 q")
                     #f #f)))

    (register-keymap! "emacs" make-emacs-keymap)))
