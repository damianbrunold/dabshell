;; dabshell editor-buffer: the text model of the editor (lines, cursor,
;; mark, undo/redo, search, loading and saving), the Buffer class of
;; editor.py. Positions are pairs (row . col).

(define-library (dabshell editor-buffer)
  (export tab-width indent-width
          editor-error editor-error? editor-error-message encode-error?
          word-char? first-nonblank display-text split-newlines string-find string-rfind
          pos<? pos<=? sort-pos
          make-buffer buffer? buffer-from-file buffer-text buffer-save! buffer-write-copy
          buffer-modified?
          buffer-name buffer-name-set! buffer-path buffer-path-set!
          buffer-row buffer-row-set! buffer-col buffer-col-set! buffer-pos buffer-goto!
          buffer-goal-col buffer-goal-col-set! buffer-mark buffer-mark-set!
          buffer-top buffer-top-set! buffer-left buffer-left-set!
          buffer-encoding buffer-newline buffer-trailing-newline buffer-uses-tabs
          buffer-line buffer-line-count buffer-last-row buffer-lines
          buffer-clamp! buffer-char-at buffer-next-pos buffer-prev-pos buffer-end-pos
          buffer-word-forward buffer-word-backward buffer-text-range
          buffer-insert! buffer-delete!
          buffer-begin-group! buffer-break-group! buffer-undo! buffer-redo!
          buffer-search)
  (import (scheme base)
          (scheme char)
          (scheme time)
          (scm fs)
          (dabshell util))
  (begin

    (define tab-width 8)
    (define indent-width 4)

    ;; ------------------------------------------------------------------
    ;; errors shown in the message line

    (define-record-type editor-error-object
      (make-editor-error message encode?)
      editor-error?
      (message editor-error-message)
      (encode? encode-error?))

    (define (editor-error . parts) (raise (make-editor-error (apply string-append parts) #f)))

    ;; ------------------------------------------------------------------
    ;; text helpers

    (define (word-char? ch)
      (and (char? ch) (or (char-alphabetic? ch) (char-numeric? ch) (char=? ch #\_))))

    ;; index of the first character that is not a space or tab
    (define (first-nonblank line)
      (let ((n (string-length line)))
        (let loop ((i 0))
          (if (and (< i n) (memv (string-ref line i) '(#\space #\tab))) (loop (+ i 1)) i))))

    ;; tabs expanded and control characters shown as "?" (one cell each)
    (define (display-text text)
      (let ((out (open-output-string)))
        (let loop ((i 0) (col 0))
          (when (< i (string-length text))
            (let ((ch (string-ref text i)))
              (cond ((char=? ch #\tab)
                     (let ((n (- tab-width (modulo col tab-width))))
                       (write-string (make-string n #\space) out)
                       (loop (+ i 1) (+ col n))))
                    ((or (< (char->integer ch) #x20) (= (char->integer ch) #x7f))
                     (write-char #\? out)
                     (loop (+ i 1) (if (memv ch '(#\newline #\return)) 0 (+ col 1))))
                    (else (write-char ch out) (loop (+ i 1) (+ col 1)))))))
        (get-output-string out)))

    ;; text.split("\n")
    (define (split-newlines text)
      (let ((n (string-length text)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((>= i n) (reverse (cons (substring text start n) acc)))
                ((char=? (string-ref text i) #\newline)
                 (loop (+ i 1) (+ i 1) (cons (substring text start i) acc)))
                (else (loop (+ i 1) start acc))))))

    (define (match-at? h q i)
      (let ((m (string-length q)))
        (let loop ((k 0))
          (or (= k m)
              (and (char=? (string-ref h (+ i k)) (string-ref q k)) (loop (+ k 1)))))))

    ;; Python's h.find(q, start, end): first index i >= start with q
    ;; inside [start, end), or -1
    (define (string-find h q start . end)
      (let* ((end (if (null? end) (string-length h) (min (car end) (string-length h))))
             (last (- end (string-length q))))
        (let loop ((i (max 0 start)))
          (cond ((> i last) -1)
                ((match-at? h q i) i)
                (else (loop (+ i 1)))))))

    ;; Python's h.rfind(q, start, end)
    (define (string-rfind h q start . end)
      (let* ((end (if (null? end) (string-length h) (min (car end) (string-length h))))
             (start (max 0 start)))
        (let loop ((i (- end (string-length q))))
          (cond ((< i start) -1)
                ((match-at? h q i) i)
                (else (loop (- i 1)))))))

    (define (pos<? a b)
      (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))
    (define (pos<=? a b) (not (pos<? b a)))
    ;; the two positions in order, as (values first second)
    (define (sort-pos a b) (if (pos<? b a) (values b a) (values a b)))

    ;; position just after text inserted at pos
    (define (end-of pos text)
      (let ((parts (split-newlines text)))
        (if (null? (cdr parts))
            (cons (car pos) (+ (cdr pos) (string-length text)))
            (cons (+ (car pos) (length parts) -1) (string-length (car (reverse parts)))))))

    ;; ------------------------------------------------------------------
    ;; buffers

    ;; undo groups; ops are (ins|del (row . col) text), newest first
    (define-record-type undo-group
      (make-undo-group id ops cursor kind)
      undo-group?
      (id group-id)
      (ops group-ops group-ops-set!)
      (cursor group-cursor group-cursor-set!)
      (kind group-kind group-kind-set!))

    (define-record-type buffer
      (%make-buffer name path lines row col goal-col mark top left encoding newline
                    trailing-newline uses-tabs undo-stack redo-stack last-kind next-id saved-id)
      buffer?
      (name buffer-name buffer-name-set!)
      (path buffer-path buffer-path-set!)
      (lines lines-vec lines-vec-set!)
      (row buffer-row buffer-row-set!)
      (col buffer-col buffer-col-set!)
      (goal-col buffer-goal-col buffer-goal-col-set!)
      (mark buffer-mark buffer-mark-set!)
      (top buffer-top buffer-top-set!)
      (left buffer-left buffer-left-set!)
      (encoding buffer-encoding buffer-encoding-set!)
      (newline buffer-newline buffer-newline-set!)
      (trailing-newline buffer-trailing-newline buffer-trailing-newline-set!)
      (uses-tabs buffer-uses-tabs buffer-uses-tabs-set!)
      (undo-stack undo-stack undo-stack-set!)        ; newest first
      (redo-stack redo-stack redo-stack-set!)
      (last-kind last-kind last-kind-set!)
      (next-id next-id next-id-set!)
      (saved-id saved-id saved-id-set!))

    (define (make-buffer name . path)
      (%make-buffer name (if (null? path) #f (car path)) (vector "") 0 0 #f #f 0 0
                    "utf-8" "\n" #t #f '() '() #f 1 #f))

    (define (buffer-line b r) (vector-ref (lines-vec b) r))
    (define (buffer-line-count b) (vector-length (lines-vec b)))
    (define (buffer-last-row b) (- (buffer-line-count b) 1))
    (define (buffer-lines b) (vector->list (lines-vec b)))
    (define (buffer-pos b) (cons (buffer-row b) (buffer-col b)))
    (define (buffer-goto! b pos) (buffer-row-set! b (car pos)) (buffer-col-set! b (cdr pos)))

    ;; replace lines [start, end) with the list new
    (define (splice-lines! b start end new)
      (let ((v (lines-vec b)))
        (lines-vec-set! b (vector-append (vector-copy v 0 start) (list->vector new)
                                         (vector-copy v end (vector-length v))))))

    ;; ------------------------------------------------------------------
    ;; loading / saving

    (define (buffer-from-file path name)
      (let ((buf (make-buffer name path)))
        (cond ((not (path-exists?* path)) buf)
              ((directory? path) (editor-error path " is a directory"))
              (else
               (let ((raw (read-file-bytes path)))
                 (when (binary-bytes? raw) (editor-error path " looks like a binary file"))
                 (let ((enc (detect-file-encoding raw)))
                   (when (eq? enc 'utf-16) (editor-error path ": UTF-16 files are not supported"))
                   (let* ((text (decode-bytes raw))
                          (first-nl (string-index-of text "\n")))
                     (buffer-encoding-set! buf (symbol->string enc))
                     (when (and first-nl (> first-nl 0)
                                (char=? (string-ref text (- first-nl 1)) #\return))
                       (buffer-newline-set! buf "\r\n"))
                     (let* ((text (string-replace* text "\r\n" "\n"))
                            (n (string-length text))
                            (text (if (and (> n 0) (char=? (string-ref text (- n 1)) #\newline))
                                      (substring text 0 (- n 1))
                                      (begin (when (> n 0) (buffer-trailing-newline-set! buf #f))
                                             text))))
                       (lines-vec-set! buf (list->vector (split-newlines text)))
                       (buffer-uses-tabs-set!
                        buf (let loop ((ls (buffer-lines buf)))
                              (and (pair? ls) (or (string-starts? (car ls) "\t") (loop (cdr ls))))))
                       buf))))))))

    (define (buffer-text b)
      (let ((data (string-join* (buffer-lines b) "\n")))
        (if (and (buffer-trailing-newline b)
                 (not (and (= (buffer-line-count b) 1) (string=? (buffer-line b 0) ""))))
            (string-append data "\n")
            data)))

    (define (buffer-save! b . opt)
      (let ((path (or (and (pair? opt) (car opt)) (buffer-path b)))
            (encoding (or (and (pair? opt) (pair? (cdr opt)) (cadr opt)) (buffer-encoding b))))
        (unless path (editor-error "No file name"))
        (write-text b path encoding)
        (buffer-path-set! b path)
        (buffer-encoding-set! b encoding)
        (saved-id-set! b (top-id b))
        (last-kind-set! b #f)))   ; stop merging further typing into this group

    ;; write the text to path without changing the buffer's file
    (define (buffer-write-copy b path) (write-text b path (buffer-encoding b)))

    (define (encode text encoding)
      (cond ((string=? encoding "utf-8") (string->utf8 text))
            ((string=? encoding "utf-8-sig") (bytevector-append (bytevector #xEF #xBB #xBF) (string->utf8 text)))
            (else
             (let ((bv (make-bytevector (string-length text))))
               (let loop ((i 0))
                 (if (= i (string-length text))
                     bv
                     (let ((c (char->integer (string-ref text i))))
                       (when (> c 255)
                         (raise (make-editor-error (string-append "Text cannot be encoded as " encoding) #t)))
                       (bytevector-u8-set! bv i c)
                       (loop (+ i 1)))))))))

    (define tmp-counter 0)

    ;; path with symbolic links of the file itself followed (so that saving
    ;; replaces the link target, not the link)
    (define (resolve-links path)
      (let loop ((path path) (n 0))
        (let ((target (and (< n 40) (guard (e (#t #f)) (and (file-symlink? path) (read-symlink path))))))
          (if target
              (loop (path-normpath (if (path-absolute? target) target (path-join (path-dirname path) target)))
                    (+ n 1))
              path))))

    ;; write atomically: a temporary file in the same directory, then rename
    (define (write-text b path encoding)
      (let* ((path (resolve-links path))
             (data (if (string=? (buffer-newline b) "\n")
                       (buffer-text b)
                       (string-replace* (buffer-text b) "\n" (buffer-newline b))))
             (raw (encode data encoding))
             (dir (let ((d (path-dirname path))) (if (string=? d "") "." d)))
             (tmp (begin (set! tmp-counter (+ tmp-counter 1))
                         (path-join dir (string-append "." (path-basename path) "."
                                                       (number->string (current-jiffy)) "-"
                                                       (number->string tmp-counter) ".tmp")))))
        (guard (e (#t (when (file? tmp) (guard (e2 (#t #f)) (delete-file tmp)))
                      (raise e)))
          (write-file-bytes tmp raw)
          (when (file? path)
            (let ((mode (guard (e (#t #f)) (cdr (assq 'mode (stat path))))))
              (when mode (guard (e (#t #f)) (chmod tmp mode)))))
          (when (eq? (move-file tmp path) #f)
            (error "cannot replace" path)))))

    (define (buffer-modified? b) (not (eqv? (top-id b) (saved-id b))))

    ;; ------------------------------------------------------------------
    ;; positions

    (define (buffer-clamp! b)
      (buffer-row-set! b (max 0 (min (buffer-row b) (buffer-last-row b))))
      (buffer-col-set! b (max 0 (min (buffer-col b) (string-length (buffer-line b (buffer-row b))))))
      (let ((m (buffer-mark b)))
        (when m
          (let ((r (max 0 (min (car m) (buffer-last-row b)))))
            (buffer-mark-set! b (cons r (max 0 (min (cdr m) (string-length (buffer-line b r))))))))))

    ;; the character at (r, c); #\newline past the end of the line
    (define (buffer-char-at b r c)
      (let ((line (buffer-line b r)))
        (if (< c (string-length line)) (string-ref line c) #\newline)))

    (define (buffer-next-pos b r c)
      (cond ((< c (string-length (buffer-line b r))) (cons r (+ c 1)))
            ((< r (buffer-last-row b)) (cons (+ r 1) 0))
            (else #f)))

    (define (buffer-prev-pos b r c)
      (cond ((> c 0) (cons r (- c 1)))
            ((> r 0) (cons (- r 1) (string-length (buffer-line b (- r 1)))))
            (else #f)))

    (define (buffer-end-pos b)
      (cons (buffer-last-row b) (string-length (buffer-line b (buffer-last-row b)))))

    (define (buffer-word-forward b r c)
      (let skip ((r r) (c c))
        (if (not (word-char? (buffer-char-at b r c)))
            (let ((p (buffer-next-pos b r c)))
              (if p (skip (car p) (cdr p)) (cons r c)))
            (let word ((r r) (c c))
              (if (word-char? (buffer-char-at b r c))
                  (let ((p (buffer-next-pos b r c)))
                    (if p (word (car p) (cdr p)) (cons r c)))
                  (cons r c))))))

    (define (buffer-word-backward b r c)
      (let skip ((r r) (c c))
        (let ((p (buffer-prev-pos b r c)))
          (cond ((not p) (cons r c))
                ((not (word-char? (buffer-char-at b (car p) (cdr p)))) (skip (car p) (cdr p)))
                (else
                 (let word ((r r) (c c))
                   (let ((p (buffer-prev-pos b r c)))
                     (if (or (not p) (not (word-char? (buffer-char-at b (car p) (cdr p)))))
                         (cons r c)
                         (word (car p) (cdr p))))))))))

    (define (buffer-text-range b start end)
      (let-values (((s e) (sort-pos start end)))
        (let ((r1 (car s)) (c1 (cdr s)) (r2 (car e)) (c2 (cdr e)))
          (if (= r1 r2)
              (substring (buffer-line b r1) c1 c2)
              (let ((first (buffer-line b r1)) (last (buffer-line b r2)))
                (string-join* (append (list (substring first c1 (string-length first)))
                                      (vector->list (vector-copy (lines-vec b) (+ r1 1) r2))
                                      (list (substring last 0 c2)))
                              "\n"))))))

    ;; ------------------------------------------------------------------
    ;; primitive edits (everything goes through these)

    ;; insert text at (row, col); return the position after it
    (define (buffer-insert! b row col text . opt)
      (let ((record (or (null? opt) (car opt))))
        (if (string=? text "")
            (cons row col)
            (let* ((parts (split-newlines text))
                   (line (buffer-line b row))
                   (before (substring line 0 col))
                   (after (substring line col (string-length line))))
              (let ((end
                     (if (null? (cdr parts))
                         (begin (vector-set! (lines-vec b) row (string-append before text after))
                                (cons row (+ col (string-length text))))
                         (let* ((rev (reverse parts))
                                (middle (reverse (cdr rev)))
                                (new (append (list (string-append before (car middle)))
                                             (cdr middle)
                                             (list (string-append (car rev) after)))))
                           (splice-lines! b row (+ row 1) new)
                           (cons (+ row (length parts) -1) (string-length (car rev)))))))
                (when record (record! b (list 'ins (cons row col) text)))
                end)))))

    ;; delete the text between two positions and return it
    (define (buffer-delete! b start end . opt)
      (let ((record (or (null? opt) (car opt))))
        (let-values (((s e) (sort-pos start end)))
          (let ((text (buffer-text-range b s e)))
            (unless (string=? text "")
              (let ((r1 (car s)) (r2 (car e)) (l2 (buffer-line b (car e))))
                (splice-lines! b r1 (+ r2 1)
                               (list (string-append (substring (buffer-line b r1) 0 (cdr s))
                                                    (substring l2 (cdr e) (string-length l2))))))
              (when record (record! b (list 'del s text))))
            text))))

    ;; ------------------------------------------------------------------
    ;; undo

    ;; Start an undo group for the next command. Commands with the same
    ;; non-#f kind (e.g. consecutive self-inserts) merge into one group.
    (define (buffer-begin-group! b . kind)
      (let* ((kind (if (null? kind) #f (car kind)))
             (stack (undo-stack b))
             (top (and (pair? stack) (car stack))))
        (unless (and kind (equal? kind (last-kind b)) top (pair? (group-ops top)))
          (if (and top (null? (group-ops top)))
              (begin (group-cursor-set! top (buffer-pos b))
                     (group-kind-set! top kind))
              (begin (undo-stack-set! b (cons (make-undo-group (next-id b) '() (buffer-pos b) kind) stack))
                     (next-id-set! b (+ (next-id b) 1))))
          (last-kind-set! b kind))))

    (define (buffer-break-group! b) (last-kind-set! b #f))

    (define (record! b op)
      (when (null? (undo-stack b)) (buffer-begin-group! b))
      (let ((top (car (undo-stack b))))
        (group-ops-set! top (cons op (group-ops top))))
      (redo-stack-set! b '()))

    (define (top-id b)
      (let loop ((s (undo-stack b)))
        (cond ((null? s) #f)
              ((pair? (group-ops (car s))) (group-id (car s)))
              (else (loop (cdr s))))))

    (define (after-undo! b cursor)
      (buffer-goto! b cursor)
      (buffer-mark-set! b #f)
      (last-kind-set! b #f)
      (buffer-clamp! b))

    (define (buffer-undo! b)
      (let drop ()
        (when (and (pair? (undo-stack b)) (null? (group-ops (car (undo-stack b)))))
          (undo-stack-set! b (cdr (undo-stack b)))
          (drop)))
      (if (null? (undo-stack b))
          #f
          (let ((group (car (undo-stack b))))
            (undo-stack-set! b (cdr (undo-stack b)))
            (for-each (lambda (op)
                        (let ((pos (cadr op)) (text (caddr op)))
                          (if (eq? (car op) 'ins)
                              (buffer-delete! b pos (end-of pos text) #f)
                              (buffer-insert! b (car pos) (cdr pos) text #f))))
                      (group-ops group))
            (redo-stack-set! b (cons group (redo-stack b)))
            (after-undo! b (group-cursor group))
            #t)))

    (define (buffer-redo! b)
      (if (null? (redo-stack b))
          #f
          (let* ((group (car (redo-stack b)))
                 (ops (reverse (group-ops group))))
            (redo-stack-set! b (cdr (redo-stack b)))
            (for-each (lambda (op)
                        (let ((pos (cadr op)) (text (caddr op)))
                          (if (eq? (car op) 'ins)
                              (buffer-insert! b (car pos) (cdr pos) text #f)
                              (buffer-delete! b pos (end-of pos text) #f))))
                      ops)
            (undo-stack-set! b (cons group (undo-stack b)))
            (after-undo! b (cadr (car ops)))
            #t)))

    ;; ------------------------------------------------------------------
    ;; search

    ;; Find query; return the (row . col) of the match start or #f. Forward
    ;; finds matches starting at or after (row, col), backward matches that
    ;; end at or before it. Case-insensitive when the query is lowercase.
    (define (buffer-search b query row col . opt)
      (let* ((forward (or (null? opt) (car opt)))
             (wrap (or (null? opt) (null? (cdr opt)) (cadr opt))))
        (if (string=? query "")
            #f
            (let* ((fold (string=? query (string-downcase query)))
                   (q (if fold (string-downcase query) query))
                   (qn (string-length q))
                   (n (buffer-line-count b))
                   (steps (if wrap (+ n 1) (if forward (- n row) (+ row 1)))))
              (define (hay r) (if fold (string-downcase (buffer-line b r)) (buffer-line b r)))
              (let loop ((i 0))
                (if (>= i steps)
                    #f
                    (let* ((r (modulo (if forward (+ row i) (- row i)) n))
                           (h (hay r))
                           (idx (cond ((and forward (= i 0)) (string-find h q col))
                                      (forward (if (= i n)
                                                   (string-find h q 0 (max 0 (+ col qn -1)))
                                                   (string-find h q 0)))
                                      ((= i 0) (string-rfind h q 0 col))
                                      ((= i n) (string-rfind h q (if (> col 0) (+ (- col qn) 1) 0)))
                                      (else (string-rfind h q 0)))))
                      (if (>= idx 0) (cons r idx) (loop (+ i 1))))))))))))
