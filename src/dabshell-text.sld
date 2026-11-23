;; dabshell text: commands that read and transform text: cat, diff, wc,
;; tail, head, lines, grep, sort, uniq, cut, tee, watch, xargs, date.

(define-library (dabshell text)
  (export tail-bytes ndiff strftime)
  (import (scheme base)
          (scheme char)
          (scheme cxr)
          (scheme file)
          (scheme time)
          (only (srfi 1) append-map)
          (srfi 69)
          (srfi 132)
          (only (srfi 19) current-date date-year date-month date-day date-hour
                date-minute date-second date-nanosecond)
          (only (scm string) regex-search)
          (only (scm bytevector) utf8-valid? latin1->string)
          (scm random access)
          (only (scm fs) directory-entries)
          (only (scm system) sleep)
          (only (scm terminal) terminal-byte-ready?)
          (dabshell util)
          (dabshell core)
          (dabshell keys))
  (begin

    ;; ------------------------------------------------------------------
    ;; helpers

    ;; Python's repr() of a string
    (define (py-repr s)
      (if (and (string-contains? s "'") (not (string-contains? s "\"")))
          (string-append "\"" s "\"")
          (string-append "'" (string-replace* (string-replace* s "\\" "\\\\") "'" "\\'") "'")))

    (define (fail sh . parts)
      (apply println (shell-oute sh) parts)
      (command-failed!))

    ;; Python's int() of an argument; reports the ValueError and fails
    (define (int-arg sh s)
      (or (parse-int s)
          (fail sh "ERR: invalid literal for int() with base 10: " (py-repr s))))

    ;; Python's float(), or #f
    (define (parse-float s)
      (let ((t (string-lower (string-strip s))))
        (cond ((member t '("inf" "+inf" "infinity" "+infinity")) +inf.0)
              ((member t '("-inf" "-infinity")) -inf.0)
              ((and (> (string-length t) 0)
                    (let loop ((cs (string->list t)))
                      (or (null? cs) (and (memv (car cs) (string->list "0123456789+-.e")) (loop (cdr cs))))))
               (let ((n (string->number t)))
                 (and n (real? n) (inexact n))))
              (else #f))))

    ;; the value of option arg at args[i+1], or a failure
    (define (option-value sh cmd args i)
      (if (< (+ i 1) (length args))
          (list-ref args (+ i 1))
          (fail sh "ERR: " cmd ": " (list-ref args i) " requires an argument")))

    ;; file arguments as Python's commands collect them: absolute,
    ;; normalized, glob patterns expanded (sorted), unmatched kept literally
    (define (expand-files sh args)
      (collect-files sh (map (lambda (a) (shell-path sh a)) args)))

    ;; path relative to the shell's directory if it lies inside it
    (define (relative-to-cwd sh path)
      (let* ((cwd (shell-cwd sh)) (n (string-length cwd)) (m (string-length path)))
        (cond ((not (and (string-starts? path cwd) (> m n))) path)
              ((path-sep-char? (string-ref path n)) (substring path (+ n 1) m))
              ((path-sep-char? (string-ref cwd (- n 1))) (substring path n m))
              (else path))))

    ;; the first n elements of a list (all if shorter)
    (define (take* lst n)
      (let loop ((l lst) (n n) (acc '()))
        (if (or (null? l) (<= n 0)) (reverse acc) (loop (cdr l) (- n 1) (cons (car l) acc)))))

    (define (write-out sh s) (print-to (shell-outs sh) s))

    (define (print-lines sh lines)
      (print-to (shell-outs sh) (apply string-append (map (lambda (l) (string-append l "\n")) lines))))

    ;; ------------------------------------------------------------------
    ;; reading files

    ;; a bytevector split after each newline byte
    (define (byte-lines bv)
      (let ((n (bytevector-length bv)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((= i n) (reverse (if (< start n) (cons (bytevector-copy bv start n) acc) acc)))
                ((= (bytevector-u8-ref bv i) 10)
                 (loop (+ i 1) (+ i 1) (cons (bytevector-copy bv start (+ i 1)) acc)))
                (else (loop (+ i 1) start acc))))))

    ;; decode byte lines as UTF-8 until a line is not valid UTF-8, from
    ;; then on as Latin-1 (the decoding of Python's cat, head, diff, ...);
    ;; (values strings still-utf8?)
    (define (decode-lines* blines utf8)
      (let loop ((ls blines) (utf8 utf8) (acc '()))
        (cond ((null? ls) (values (reverse acc) utf8))
              ((and utf8 (utf8-valid? (car ls))) (loop (cdr ls) #t (cons (utf8->string (car ls)) acc)))
              (else (loop (cdr ls) #f (cons (latin1->string (car ls)) acc))))))

    (define (decode-lines blines)
      (let-values (((lines utf8) (decode-lines* blines #t))) lines))

    ;; the lines of a file with their line ends, decoded as Python's cat does
    (define (file-lines path) (decode-lines (byte-lines (read-file-bytes path))))

    ;; the lines of a file without line ends, read as Python's text mode
    ;; (universal newlines, UTF-8); invalid bytes are dropped (ignore) or
    ;; replaced by U+FFFD
    (define (text-file-lines path ignore-errors)
      (let* ((bv (read-file-bytes path))
             (s (utf8->string bv))
             (s (if (and ignore-errors (not (utf8-valid? bv)))
                    (list->string (keep (lambda (c) (not (char=? c #\xFFFD))) (string->list s)))
                    s)))
        (splitlines s)))

    ;; the elements of a list that satisfy keep?
    (define (keep keep? lst)
      (let loop ((l lst) (acc '()))
        (cond ((null? l) (reverse acc)) ((keep? (car l)) (loop (cdr l) (cons (car l) acc))) (else (loop (cdr l) acc)))))

    ;; piped input lines without line ends
    (define (stdin-text-lines sh) (map (lambda (l) (string-rstrip (string-rstrip l "\n") "\r"))
                                       (or (stdin-lines sh) '())))

    ;; the checks of the file commands: #t if path is a readable file;
    ;; else prints the error (directories only if dir-error)
    (define (check-file sh path dir-error)
      (cond ((not (path-exists?* path)) (println (shell-oute sh) "ERR: " path " not found") #f)
            ((directory? path)
             (when dir-error (println (shell-oute sh) "ERR: " path ": is a directory"))
             #f)
            (else #t)))

    ;; ------------------------------------------------------------------
    ;; the terminal: waiting for keys while following output

    (define (now-ms) (quotient (* 1000 (current-jiffy)) (jiffies-per-second)))

    ;; wait up to ms milliseconds for one of the keys in stops; #t if one
    ;; was pressed. With a key source (tests) one key is read without waiting.
    (define (stop-key-within? ms stops)
      (if (key-source)
          (and (member (read-key) stops) #t)
          (let ((deadline (+ (now-ms) ms)))
            (let loop ()
              (let ((left (- deadline (now-ms))))
                (cond ((<= left 0) #f)
                      ((not (guard (e (#t (sleep (/ left 1000)) #f)) (terminal-byte-ready? left))) (loop))
                      ((member (read-key) stops) #t)
                      (else (loop))))))))

    ;; text for the shell's output: in raw mode the console needs "\r\n"
    (define (console-text sh s)
      (if (and (raw-terminal?) (eq? (shell-outs sh) console-out))
          (let loop ((cs (string->list s)) (prev #f) (acc '()))
            (cond ((null? cs) (list->string (reverse acc)))
                  ((and (char=? (car cs) #\newline) (not (eqv? prev #\return)))
                   (loop (cdr cs) (car cs) (cons #\newline (cons #\return acc))))
                  (else (loop (cdr cs) (car cs) (cons (car cs) acc)))))
          s))

    ;; ------------------------------------------------------------------
    ;; cat

    (define-command "cat" "[<file> ...]   : prints the contents of the files"
      (lambda (sh args)
        (if (and (null? args) (stdin-string sh))
            (write-out sh (stdin-string sh))
            (for-each (lambda (path)
                        (when (check-file sh path #t)
                          (write-out sh (apply string-append (file-lines path)))))
                      (expand-files sh args)))))

    ;; ------------------------------------------------------------------
    ;; diff: Python's difflib.ndiff

    ;; the second sequence of a SequenceMatcher with its index: b2j maps
    ;; each element to its increasing positions (without junk and, for
    ;; long sequences, popular elements)
    (define-record-type seq2
      (%make-seq2 b b2j junk fullcount)
      seq2?
      (b seq2-b)
      (b2j seq2-b2j)
      (junk seq2-junk)                         ; hash set of junk elements
      (fullcount seq2-fullcount seq2-fullcount-set!))

    (define (make-seq2 b junk?)
      (let ((b2j (make-hash-table equal?)) (junk (make-hash-table equal?)) (n (vector-length b)))
        (let loop ((i (- n 1)))
          (when (>= i 0)
            (hash-table-update!/default b2j (vector-ref b i) (lambda (l) (cons i l)) '())
            (loop (- i 1))))
        (when junk?
          (for-each (lambda (x) (when (junk? x) (hash-table-set! junk x #t) (hash-table-delete! b2j x)))
                    (hash-table-keys b2j)))
        (when (>= n 200)
          (let ((ntest (+ (quotient n 100) 1)))
            (for-each (lambda (x) (when (> (length (hash-table-ref b2j x)) ntest) (hash-table-delete! b2j x)))
                      (hash-table-keys b2j))))
        (%make-seq2 b b2j junk #f)))

    ;; longest matching block of a[alo:ahi] and b[blo:bhi]: (i j size)
    (define (find-longest-match a s2 alo ahi blo bhi)
      (let ((b (seq2-b s2)) (b2j (seq2-b2j s2)))
        (define (junk? x) (hash-table-exists? (seq2-junk s2) x))
        (define (eq-at? i j) (equal? (vector-ref a i) (vector-ref b j)))
        (let loop ((i alo) (j2len (make-hash-table eqv?)) (bi alo) (bj blo) (bk 0))
          (if (< i ahi)
              (let ((new (make-hash-table eqv?)))
                (let jloop ((js (hash-table-ref/default b2j (vector-ref a i) '())) (bi bi) (bj bj) (bk bk))
                  (cond ((or (null? js) (>= (car js) bhi)) (loop (+ i 1) new bi bj bk))
                        ((< (car js) blo) (jloop (cdr js) bi bj bk))
                        (else
                         (let* ((j (car js)) (k (+ 1 (hash-table-ref/default j2len (- j 1) 0))))
                           (hash-table-set! new j k)
                           (if (> k bk)
                               (jloop (cdr js) (+ (- i k) 1) (+ (- j k) 1) k)
                               (jloop (cdr js) bi bj bk)))))))
              ;; extend the match with equal non-junk, then junk elements
              (let extend ((bi bi) (bj bj) (bk bk) (want-junk #f))
                (cond ((and (> bi alo) (> bj blo) (eq? (junk? (vector-ref b (- bj 1))) want-junk)
                            (eq-at? (- bi 1) (- bj 1)))
                       (extend (- bi 1) (- bj 1) (+ bk 1) want-junk))
                      ((and (< (+ bi bk) ahi) (< (+ bj bk) bhi) (eq? (junk? (vector-ref b (+ bj bk))) want-junk)
                            (eq-at? (+ bi bk) (+ bj bk)))
                       (extend bi bj (+ bk 1) want-junk))
                      ((not want-junk) (extend bi bj bk #t))
                      (else (list bi bj bk))))))))

    (define (block<? x y)
      (or (< (car x) (car y))
          (and (= (car x) (car y))
               (or (< (cadr x) (cadr y)) (and (= (cadr x) (cadr y)) (< (caddr x) (caddr y)))))))

    ;; matching blocks (i j size), adjacent ones joined, ending with (la lb 0)
    (define (matching-blocks a s2)
      (let ((la (vector-length a)) (lb (vector-length (seq2-b s2))))
        (let loop ((queue (list (list 0 la 0 lb))) (blocks '()))
          (if (pair? queue)
              (let* ((q (car queue)) (alo (car q)) (ahi (cadr q)) (blo (caddr q)) (bhi (cadddr q))
                     (m (find-longest-match a s2 alo ahi blo bhi))
                     (i (car m)) (j (cadr m)) (k (caddr m)))
                (if (> k 0)
                    (loop (append (if (and (< (+ i k) ahi) (< (+ j k) bhi)) (list (list (+ i k) ahi (+ j k) bhi)) '())
                                  (if (and (< alo i) (< blo j)) (list (list alo i blo j)) '())
                                  (cdr queue))
                          (cons m blocks))
                    (loop (cdr queue) blocks)))
              (let join ((bs (list-sort block<? blocks)) (i1 0) (j1 0) (k1 0) (acc '()))
                (if (null? bs)
                    (reverse (cons (list la lb 0) (if (> k1 0) (cons (list i1 j1 k1) acc) acc)))
                    (let ((i2 (caar bs)) (j2 (cadar bs)) (k2 (caddar bs)))
                      (if (and (= (+ i1 k1) i2) (= (+ j1 k1) j2))
                          (join (cdr bs) i1 j1 (+ k1 k2) acc)
                          (join (cdr bs) i2 j2 k2 (if (> k1 0) (cons (list i1 j1 k1) acc) acc))))))))))

    ;; opcodes (tag i1 i2 j1 j2) with tags replace, delete, insert, equal
    (define (opcodes blocks)
      (let loop ((bs blocks) (i 0) (j 0) (acc '()))
        (if (null? bs)
            (reverse acc)
            (let* ((ai (caar bs)) (bj (cadar bs)) (size (caddar bs))
                   (tag (cond ((and (< i ai) (< j bj)) 'replace) ((< i ai) 'delete) ((< j bj) 'insert) (else #f)))
                   (acc (if tag (cons (list tag i ai j bj) acc) acc))
                   (acc (if (> size 0) (cons (list 'equal ai (+ ai size) bj (+ bj size)) acc) acc)))
              (loop (cdr bs) (+ ai size) (+ bj size) acc)))))

    (define (calc-ratio matches total) (if (> total 0) (/ (* 2.0 matches) total) 1.0))

    (define (ratio a s2)
      (calc-ratio (apply + (map caddr (matching-blocks a s2))) (+ (vector-length a) (vector-length (seq2-b s2)))))

    (define (quick-ratio a s2)
      (unless (seq2-fullcount s2)
        (let ((h (make-hash-table equal?)))
          (vector-for-each (lambda (x) (hash-table-update!/default h x (lambda (n) (+ n 1)) 0)) (seq2-b s2))
          (seq2-fullcount-set! s2 h)))
      (let ((avail (make-hash-table equal?)) (full (seq2-fullcount s2)))
        (let loop ((i 0) (matches 0))
          (if (< i (vector-length a))
              (let* ((x (vector-ref a i))
                     (numb (if (hash-table-exists? avail x) (hash-table-ref avail x) (hash-table-ref/default full x 0))))
                (hash-table-set! avail x (- numb 1))
                (loop (+ i 1) (if (> numb 0) (+ matches 1) matches)))
              (calc-ratio matches (+ (vector-length a) (vector-length (seq2-b s2))))))))

    (define (real-quick-ratio a s2)
      (let ((la (vector-length a)) (lb (vector-length (seq2-b s2))))
        (calc-ratio (min la lb) (+ la lb))))

    (define (char-junk? c) (or (char=? c #\space) (char=? c #\tab)))

    (define (dump tag x lo hi)
      (let loop ((i (- hi 1)) (acc '()))
        (if (< i lo) acc (loop (- i 1) (cons (string-append tag " " (vector-ref x i)) acc)))))

    (define (plain-replace a alo ahi b blo bhi)
      (if (< (- bhi blo) (- ahi alo))
          (append (dump "+" b blo bhi) (dump "-" a alo ahi))
          (append (dump "-" a alo ahi) (dump "+" b blo bhi))))

    ;; tags with the whitespace of s where the tag is blank, right-stripped
    (define (keep-original-ws s tags)
      (string-rstrip
       (list->string (map (lambda (c t) (if (and (char=? t #\space) (char-whitespace? c)) c t))
                          (string->list s) (string->list tags)))))

    (define (qformat aline bline atags btags)
      (let ((atags (keep-original-ws aline atags)) (btags (keep-original-ws bline btags)))
        (append (list (string-append "- " aline))
                (if (string=? atags "") '() (list (string-append "? " atags "\n")))
                (list (string-append "+ " bline))
                (if (string=? btags "") '() (list (string-append "? " btags "\n"))))))

    ;; Differ._fancy_replace: synch on the most similar pair of lines
    (define (fancy-replace a alo ahi b blo bhi)
      (let loop-j ((j blo) (best 0.74) (bi #f) (bj #f) (eqi #f) (eqj #f))
        (if (< j bhi)
            (let* ((bline (vector-ref b j)) (s2 (make-seq2 (list->vector (string->list bline)) char-junk?)))
              (let loop-i ((i alo) (best best) (bi bi) (bj bj) (eqi eqi) (eqj eqj))
                (if (< i ahi)
                    (let ((aline (vector-ref a i)))
                      (if (string=? aline bline)
                          (if eqi
                              (loop-i (+ i 1) best bi bj eqi eqj)
                              (loop-i (+ i 1) best bi bj i j))
                          (let ((av (list->vector (string->list aline))))
                            (if (and (> (real-quick-ratio av s2) best) (> (quick-ratio av s2) best)
                                     (> (ratio av s2) best))
                                (loop-i (+ i 1) (ratio av s2) i j eqi eqj)
                                (loop-i (+ i 1) best bi bj eqi eqj)))))
                    (loop-j (+ j 1) best bi bj eqi eqj))))
            (cond ((and (< best 0.75) (not eqi)) (plain-replace a alo ahi b blo bhi))
                  (else
                   (let* ((identical (< best 0.75))
                          (bi (if identical eqi bi))
                          (bj (if identical eqj bj))
                          (aline (vector-ref a bi))
                          (bline (vector-ref b bj)))
                     (append
                      (fancy-helper a alo bi b blo bj)
                      (if identical
                          (list (string-append "  " aline))
                          (intraline aline bline))
                      (fancy-helper a (+ bi 1) ahi b (+ bj 1) bhi))))))))

    ;; the "- ? + ?" lines marking the differences within a similar pair
    (define (intraline aline bline)
      (let ((av (list->vector (string->list aline)))
            (s2 (make-seq2 (list->vector (string->list bline)) char-junk?)))
        (let loop ((ops (opcodes (matching-blocks av s2))) (atags '()) (btags '()))
          (if (null? ops)
              (qformat aline bline (apply string-append (reverse atags)) (apply string-append (reverse btags)))
              (let* ((op (car ops)) (la (- (caddr op) (cadr op))) (lb (- (list-ref op 4) (cadddr op))))
                (case (car op)
                  ((replace) (loop (cdr ops) (cons (make-string la #\^) atags) (cons (make-string lb #\^) btags)))
                  ((delete) (loop (cdr ops) (cons (make-string la #\-) atags) btags))
                  ((insert) (loop (cdr ops) atags (cons (make-string lb #\+) btags)))
                  (else (loop (cdr ops) (cons (make-string la #\space) atags)
                              (cons (make-string lb #\space) btags)))))))))

    (define (fancy-helper a alo ahi b blo bhi)
      (cond ((and (< alo ahi) (< blo bhi)) (fancy-replace a alo ahi b blo bhi))
            ((< alo ahi) (dump "-" a alo ahi))
            ((< blo bhi) (dump "+" b blo bhi))
            (else '())))

    ;; difflib.ndiff of two lists of lines (with line ends): the delta lines
    (define (ndiff alines blines)
      (let ((a (list->vector alines)) (b (list->vector blines)))
        (append-map (lambda (op)
                      (let ((alo (cadr op)) (ahi (caddr op)) (blo (cadddr op)) (bhi (list-ref op 4)))
                        (case (car op)
                          ((replace) (fancy-replace a alo ahi b blo bhi))
                          ((delete) (dump "-" a alo ahi))
                          ((insert) (dump "+" b blo bhi))
                          (else (dump " " a alo ahi)))))
                    (opcodes (matching-blocks a (make-seq2 b #f))))))

    (define-command "diff" "<file1> <file2> : shows the differences between the two text files"
      (lambda (sh args)
        (let ((files (expand-files sh args)))
          (cond ((< (length files) 2) (println (shell-oute sh) "ERR: diff requires two files"))
                ((not (path-exists?* (car files))) (println (shell-oute sh) "ERR: " (car files) " not found"))
                ((not (path-exists?* (cadr files))) (println (shell-oute sh) "ERR: " (cadr files) " not found"))
                (else
                 (for-each (lambda (f) (when (directory? f) (fail sh "ERR: " f ": is a directory")))
                           (list (car files) (cadr files)))
                 (println (shell-outs sh)
                          (apply string-append (ndiff (file-lines (car files)) (file-lines (cadr files))))))))))

    ;; ------------------------------------------------------------------
    ;; wc

    (define-command "wc" "<file> ...  : returns the number of lines of the files"
      (lambda (sh args)
        (let ((files (expand-files sh args)))
          (if (and (null? files) (stdin-string sh))
              (println (shell-outs sh) "(stdin) " (length (stdin-lines sh)))
              (let loop ((files files) (total 0) (counted 0))
                (cond ((pair? files)
                       (let ((f (car files)))
                         (if (check-file sh f #f)
                             (let ((count (length (byte-lines (read-file-bytes f)))))
                               (println (shell-outs sh) (relative-to-cwd sh f) " " count)
                               (loop (cdr files) (+ total count) (+ counted 1)))
                             (loop (cdr files) total counted))))
                      ((> counted 1) (println (shell-outs sh) "Total " total))))))))

    ;; ------------------------------------------------------------------
    ;; head, tail

    ;; (values n files) from [-n <lines>] [--lines=<lines>] [--] <file> ...
    (define (parse-count-args sh cmd args)
      (let loop ((as args) (n 20) (files '()) (after #f))
        (cond ((null? as) (values n (reverse files)))
              ((and (not after) (string-starts? (car as) "-"))
               (let ((a (car as)))
                 (cond ((string=? a "--") (loop (cdr as) n files #t))
                       ((string=? a "-n")
                        (when (null? (cdr as)) (fail sh "ERR: " cmd ": -n requires an argument"))
                        (loop (cddr as) (int-arg sh (cadr as)) files after))
                       ((string-starts? a "--lines=")
                        (loop (cdr as) (int-arg sh (substring a 8 (string-length a))) files after))
                       (else (loop (cdr as) n files after)))))
              (else (loop (cdr as) n (cons (car as) files) after)))))

    (define-command "head" "[-n <lines>] [--lines=<lines>] <file> ...  : prints the first lines of each file"
      (lambda (sh args)
        (let-values (((n names) (parse-count-args sh "head" args)))
          (let ((files (expand-files sh names)))
            (if (and (null? files) (stdin-string sh))
                (write-out sh (apply string-append (take* (stdin-lines sh) n)))
                (for-each (lambda (f)
                            (when (check-file sh f #t)
                              (write-out sh (apply string-append
                                                   (decode-lines (take* (byte-lines (read-file-bytes f)) n))))))
                          files))))))

    ;; the raw bytes of the last n lines of the file, read backwards in
    ;; chunks so that only the end of a large file is read
    (define tail-chunk 8192)

    (define (tail-bytes path n)
      (call-with-random-access-file path 'read
        (lambda (f)
          (let ((size (random-access-file-size f)))
            (define (from start) (random-access-file-read f start (- size start)))
            (if (or (= n 0) (= size 0))
                (bytevector)
                (let* ((ends-nl (= 10 (bytevector-u8-ref (random-access-file-read f (- size 1) 1) 0)))
                       (scan-end (if ends-nl (- size 1) size)))
                  (let loop ((pos scan-end) (found 0))
                    (if (<= pos 0)
                        (from 0)
                        (let* ((cs (min tail-chunk pos))
                               (p (- pos cs))
                               (chunk (random-access-file-read f p cs)))
                          (let scan ((i (- cs 1)) (found found))
                            (cond ((< i 0) (loop p found))
                                  ((= (bytevector-u8-ref chunk i) 10)
                                   (if (= (+ found 1) n) (from (+ p i 1)) (scan (- i 1) (+ found 1))))
                                  (else (scan (- i 1) found)))))))))))))

    (define (file-size path) (call-with-random-access-file path 'read random-access-file-size))

    (define (file-bytes-from path start)
      (call-with-random-access-file path 'read
        (lambda (f) (random-access-file-read f start (- (random-access-file-size f) start)))))

    ;; print what is appended to the file until Ctrl+C or q is pressed
    (define (follow sh path utf8)
      (with-raw-terminal
       (lambda ()
         (let loop ((pos (file-size path)) (utf8 utf8))
           (let ((size (file-size path)))
             (cond ((< size pos) (loop 0 utf8))          ; truncated: start over
                   ((> size pos)
                    (let-values (((lines utf8) (decode-lines* (byte-lines (file-bytes-from path pos)) utf8)))
                      (write-out sh (console-text sh (apply string-append lines)))
                      (loop size utf8)))
                   ((not (stop-key-within? 1000 '(ctrl-c ctrl-d #\q))) (loop pos utf8))))))))

    (define-command "tail" "[-n <lines>] [--lines=<lines>] [-f] <file> ...  : prints the last lines of each file"
      (lambda (sh args)
        (let-values (((n names) (parse-count-args sh "tail" args)))
          (let ((files (expand-files sh names))
                (follow? (or (member "-f" args) (member "--follow" args))))
            (if (and (null? files) (stdin-string sh))
                (let ((lines (stdin-lines sh)))
                  (write-out sh (apply string-append
                                       (cond ((= n 0) '())
                                             ((> n 0) (list-tail lines (max 0 (- (length lines) n))))
                                             (else (list-tail lines (min (- n) (length lines))))))))
                (for-each (lambda (f)
                            (when (check-file sh f #f)
                              (let* ((bv (tail-bytes f n)) (utf8 (utf8-valid? bv)))
                                (write-out sh (if utf8 (utf8->string bv) (latin1->string bv)))
                                (when follow? (follow sh f utf8)))))
                          files))))))

    ;; ------------------------------------------------------------------
    ;; lines

    (define (parse-bound s)
      (or (parse-int s) (raise (string-append "invalid range component " (py-repr s)))))

    ;; (start . end), 1-based inclusive; #f for an open bound, negative from the end
    (define (parse-range spec)
      (let* ((parts (if (string-contains? spec ":") (string-split-on spec ":" 1) (list spec spec)))
             (lhs (car parts)) (rhs (cadr parts))
             (start (and (not (string=? lhs "")) (parse-bound lhs)))
             (end (and (not (string=? rhs "")) (parse-bound rhs))))
        (when (or (eqv? start 0) (eqv? end 0))
          (raise (string-append "line numbers are 1-based: " (py-repr spec))))
        (cons start end)))

    ;; the selected lines of a list
    (define (select-range range lines)
      (let* ((total (length lines))
             (fix (lambda (b default) (cond ((not b) default) ((< b 0) (+ total 1 b)) (else b))))
             (lo (max 1 (fix (car range) 1)))
             (hi (min total (fix (cdr range) total))))
        (if (or (> lo hi) (= total 0))
            '()
            (take* (list-tail lines (- lo 1)) (+ (- hi lo) 1)))))

    (define-command "lines"
      (string-append "<range> [<file> ...]   : prints the selected line range. "
                     "Range is 1-based and inclusive: N, N:M, :M, N:, :. "
                     "Negative indices count from the end (e.g. -10: for the last 10 lines).")
      (lambda (sh args)
        (if (null? args)
            (println (shell-oute sh) "ERR: lines: missing range argument")
            (let ((range (guard (e ((string? e) (println (shell-oute sh) "ERR: lines: " e) #f))
                           (parse-range (car args)))))
              (when range
                (let ((files (expand-files sh (cdr args))))
                  (if (and (null? files) (stdin-string sh))
                      (write-out sh (apply string-append (select-range range (stdin-lines sh))))
                      (for-each (lambda (f)
                                  (when (check-file sh f #t)
                                    (write-out sh (apply string-append (select-range range (file-lines f))))))
                                files))))))))

    ;; ------------------------------------------------------------------
    ;; grep

    ;; Python's re syntax in the host's: named groups (?P<name>...)
    (define (host-regex p) (string-replace* p "(?P<" "(?<"))

    ;; the pattern for matching lowercased lines: literal characters
    ;; lowercased, escapes (\D, \S, \W, ...) kept
    (define (lower-pattern p)
      (let loop ((cs (string->list p)) (acc '()))
        (cond ((null? cs) (list->string (reverse acc)))
              ((and (char=? (car cs) #\\) (pair? (cdr cs))) (loop (cddr cs) (cons (cadr cs) (cons #\\ acc))))
              (else (loop (cdr cs) (cons (char-downcase (car cs)) acc))))))

    (define grep-skip '("venv" ".env" "__pycache__" ".git"))

    ;; the files below path (sorted), skipping the usual tool directories
    (define (walk-dir path)
      (cond ((member (path-basename path) grep-skip) '())
            ((directory? path)
             (append-map (lambda (name)
                           (let ((p (path-join path name)))
                             (if (directory? p) (walk-dir p) (list p))))
                         (sort-strings (map car (directory-entries path)))))
            (else (list path))))

    (define (grep-files sh locations)
      (append-map (lambda (loc)
                    (let ((p (shell-path sh loc)))
                      (if (or (string-contains? loc "*") (string-contains? loc "?"))
                          (append-map walk-dir (collect-files sh (list p)))
                          (walk-dir p))))
                  locations))

    ;; print the matching lines (stripped) with numbers and context:
    ;; "N: line" for matches, "N- line" for context, "--" between groups
    (define (grep-lines sh match? lines label quiet before after)
      (define (fmt nr line is-match)
        (let ((line (string-strip line)))
          (cond (quiet line)
                (label (string-append label " " (number->string nr) (if is-match ":" "-") " " line))
                (else (string-append (number->string nr) (if is-match ":" "-") " " line)))))
      (let ((out (shell-outs sh)) (context (or (> before 0) (> after 0))))
        (let loop ((ls lines) (nr 1) (buf '()) (after-left 0) (last 0))
          (when (pair? ls)
            (let* ((line (car ls))
                   ;; the last `before` lines including this one
                   (buf* (if (> before 0)
                             (let ((b (append buf (list (cons nr line)))))
                               (if (> (length b) before) (cdr b) b))
                             '())))
              (cond ((match? line)
                     (when (and context (> last 0) (> (if (pair? buf) (caar buf) nr) (+ last 1)))
                       (println out "--"))
                     (for-each (lambda (b) (when (> (car b) last) (println out (fmt (car b) (cdr b) #f))))
                               buf)
                     (println out (fmt nr line #t))
                     (loop (cdr ls) (+ nr 1) buf* after nr))
                    ((> after-left 0)
                     (println out (fmt nr line #f))
                     (loop (cdr ls) (+ nr 1) buf* (- after-left 1) nr))
                    (else (loop (cdr ls) (+ nr 1) buf* after-left last))))))))

    (define-command "grep"
      "<pattern> [-i] [-v] [-q] [-A <n>] [-B <n>] [-C <n>] [<location>...]   : searches the pattern in the files at location"
      (lambda (sh args)
        (let loop ((as args) (case-sensitive #t) (invert #f) (quiet #f) (before 0) (after 0) (rest '()))
          (cond
           ((pair? as)
            (let ((a (car as)))
              (cond ((string=? a "-q") (loop (cdr as) case-sensitive invert #t before after rest))
                    ((string=? a "-i") (loop (cdr as) #f invert quiet before after rest))
                    ((string=? a "-v") (loop (cdr as) case-sensitive #t quiet before after rest))
                    ((member a '("-A" "-B" "-C"))
                     (when (null? (cdr as)) (fail sh "ERR: grep: option " a " requires an argument"))
                     (let ((n (parse-int (cadr as))))
                       (unless n (fail sh "ERR: grep: invalid value for " a ": " (cadr as)))
                       (when (< n 0) (fail sh "ERR: grep: " a " requires a non-negative integer"))
                       (loop (cddr as) case-sensitive invert quiet
                             (if (string=? a "-A") before n) (if (string=? a "-B") after n) rest)))
                    (else (loop (cdr as) case-sensitive invert quiet before after (cons a rest))))))
           ((null? rest) (fail sh "ERR: grep: missing pattern"))
           (else
            (let* ((rest (reverse rest))
                   (pattern (host-regex (if case-sensitive (car rest) (lower-pattern (car rest)))))
                   (locations (cdr rest)))
              (guard (e ((not (command-failed? e)) (fail sh "ERR: grep: " (report-error e))))
                (regex-search "" pattern))
              (let ((match? (lambda (line)
                              (let ((found (and (regex-search (if case-sensitive line (string-lower line)) pattern) #t)))
                                (not (eq? found invert))))))
                (if (and (null? locations) (stdin-string sh))
                    (grep-lines sh match? (stdin-text-lines sh) #f quiet before after)
                    (let* ((files (grep-files sh (if (null? locations) '(".") locations)))
                           (multi (> (length files) 1)))
                      (for-each (lambda (f)
                                  (when (file? f)
                                    (grep-lines sh match? (text-file-lines f #t)
                                                (and multi (relative-to-cwd sh f)) quiet before after)))
                                files))))))))))

    ;; ------------------------------------------------------------------
    ;; sort, uniq, cut

    ;; the text lines of the files (no glob), or of the piped input
    (define (input-text-lines sh files dir-error)
      (if (pair? files)
          (append-map (lambda (name)
                        (let ((f (shell-path sh name)))
                          (if (check-file sh f dir-error) (text-file-lines f #f) '())))
                      files)
          (stdin-text-lines sh)))

    ;; Python's sort key (rank value): numbers before other values with -n
    (define (sort-key line field numeric)
      (let ((v (if field
                   (let ((parts (string-split-ws line)))
                     (if (<= field (length parts)) (list-ref parts (- field 1)) ""))
                   line)))
        (if numeric
            (let ((x (parse-float v))) (if x (cons 0 x) (cons 1 v)))
            (cons 0 v))))

    (define (key<? x y)
      (cond ((< (car x) (car y)) #t)
            ((> (car x) (car y)) #f)
            ((string? (cdr x)) (string<? (cdr x) (cdr y)))
            (else (< (cdr x) (cdr y)))))

    (define-command "sort" "[-r] [-n] [-u] [-k <field>] [<file>...]   : sorts lines from files or stdin"
      (lambda (sh args)
        (let loop ((as args) (reverse? #f) (numeric #f) (unique #f) (field #f) (files '()) (after #f))
          (if (pair? as)
              (let ((a (car as)))
                (cond ((or after (not (string-starts? a "-")))
                       (loop (cdr as) reverse? numeric unique field (cons a files) after))
                      ((string=? a "--") (loop (cdr as) reverse? numeric unique field files #t))
                      ((string=? a "-r") (loop (cdr as) #t numeric unique field files after))
                      ((string=? a "-n") (loop (cdr as) reverse? #t unique field files after))
                      ((string=? a "-u") (loop (cdr as) reverse? numeric #t field files after))
                      ((string=? a "-k")
                       (when (null? (cdr as)) (fail sh "ERR: sort: -k requires an argument"))
                       (let ((k (parse-int (cadr as))))
                         (unless k (fail sh "ERR: sort: invalid field " (py-repr (cadr as))))
                         (when (< k 1) (fail sh "ERR: sort: field must be >= 1"))
                         (loop (cddr as) reverse? numeric unique k files after)))
                      (else (fail sh "ERR: sort: unknown option " (py-repr a)))))
              (let* ((lines (input-text-lines sh (reverse files) #t))
                     (keyed (map (lambda (l) (cons (sort-key l field numeric) l)) lines))
                     (sorted (list-sort (if reverse?
                                            (lambda (x y) (key<? (car y) (car x)))
                                            (lambda (x y) (key<? (car x) (car y))))
                                        keyed))
                     (result (if unique
                                 (let ((seen (make-hash-table equal?)))
                                   (let dedup ((ks sorted) (acc '()))
                                     (cond ((null? ks) (reverse acc))
                                           ((hash-table-exists? seen (caar ks)) (dedup (cdr ks) acc))
                                           (else (hash-table-set! seen (caar ks) #t)
                                                 (dedup (cdr ks) (cons (car ks) acc))))))
                                 sorted)))
                (print-lines sh (map cdr result)))))))

    (define-command "uniq" "[-c] [-d] [-u] [-i] [<file>]   : collapse adjacent duplicate lines"
      (lambda (sh args)
        (let loop ((as args) (count-mode #f) (only-dups #f) (only-unique #f) (ignore-case #f) (file #f) (after #f))
          (if (pair? as)
              (let ((a (car as)))
                (cond ((or after (not (string-starts? a "-")))
                       (when file (fail sh "ERR: uniq: only one file allowed"))
                       (loop (cdr as) count-mode only-dups only-unique ignore-case a after))
                      ((string=? a "--") (loop (cdr as) count-mode only-dups only-unique ignore-case file #t))
                      ((string=? a "-c") (loop (cdr as) #t only-dups only-unique ignore-case file after))
                      ((string=? a "-d") (loop (cdr as) count-mode #t only-unique ignore-case file after))
                      ((string=? a "-u") (loop (cdr as) count-mode only-dups #t ignore-case file after))
                      ((string=? a "-i") (loop (cdr as) count-mode only-dups only-unique #t file after))
                      (else (fail sh "ERR: uniq: unknown option " (py-repr a)))))
              (let ((lines (cond (file (let ((f (shell-path sh file)))
                                         (if (path-exists?* f)
                                             (text-file-lines f #f)
                                             (fail sh "ERR: " f " not found"))))
                                 (else (stdin-text-lines sh))))
                    (out '()))
                (define (emit line count)
                  (unless (or (and only-dups (< count 2)) (and only-unique (> count 1)))
                    (set! out (cons (if count-mode
                                        (string-append (string-pad-left (number->string count) 7) " " line)
                                        line)
                                    out))))
                (define (key l) (if ignore-case (string-lower l) l))
                (when (pair? lines)
                  (let group ((ls (cdr lines)) (prev (car lines)) (count 1))
                    (cond ((null? ls) (emit prev count))
                          ((string=? (key (car ls)) (key prev)) (group (cdr ls) prev (+ count 1)))
                          (else (emit prev count) (group (cdr ls) (car ls) 1)))))
                (print-lines sh (reverse out)))))))

    ;; "1,3-5,7-" -> ((1 . 1) (3 . 5) (7 . #f)); raises a message string
    (define (parse-ranges spec)
      (define (num s)
        (or (parse-int s) (raise (string-append "invalid literal for int() with base 10: " (py-repr s)))))
      (let ((result
             (append-map
              (lambda (part)
                (let ((part (string-strip part)))
                  (if (string=? part "")
                      '()
                      (let* ((r (if (string-contains? part "-")
                                    (let ((lr (string-split-on part "-" 1)))
                                      (cons (if (string=? (car lr) "") 1 (num (car lr)))
                                            (if (string=? (cadr lr) "") #f (num (cadr lr)))))
                                    (let ((n (num part))) (cons n n)))))
                        (when (or (< (car r) 1) (and (cdr r) (< (cdr r) (car r))))
                          (raise (string-append "invalid range " (py-repr part))))
                        (list r)))))
              (string-split-on spec ","))))
        (when (null? result) (raise "empty range list"))
        result))

    ;; the selected elements of a list, each once, in range order
    (define (select-ranges ranges seq)
      (let* ((v (list->vector seq)) (n (vector-length v)) (taken (make-vector n #f)))
        (append-map (lambda (r)
                      (let ((end (if (cdr r) (min (cdr r) n) n)))
                        (let loop ((i (- (car r) 1)) (acc '()))
                          (cond ((>= i end) (reverse acc))
                                ((vector-ref taken i) (loop (+ i 1) acc))
                                (else (vector-set! taken i #t) (loop (+ i 1) (cons (vector-ref v i) acc)))))))
                    ranges)))

    (define-command "cut" "(-f <list> [-d <delim>] | -c <list>) [<file>...]   : extract fields or characters from each line"
      (lambda (sh args)
        (let loop ((as args) (delim "\t") (fields #f) (chars #f) (files '()) (after #f))
          (if (pair? as)
              (let ((a (car as)))
                (cond ((or after (not (string-starts? a "-")))
                       (loop (cdr as) delim fields chars (cons a files) after))
                      ((string=? a "--") (loop (cdr as) delim fields chars files #t))
                      ((member a '("-d" "-f" "-c"))
                       (when (null? (cdr as)) (fail sh "ERR: cut: " a " requires an argument"))
                       (let ((v (cadr as)))
                         (loop (cddr as) (if (string=? a "-d") v delim) (if (string=? a "-f") v fields)
                               (if (string=? a "-c") v chars) files after)))
                      (else (fail sh "ERR: cut: unknown option " (py-repr a)))))
              (begin
                (when (eq? (not fields) (not chars)) (fail sh "ERR: cut: specify exactly one of -f or -c"))
                (when (and fields (string=? delim "")) (fail sh "ERR: cut: empty separator"))
                (let ((ranges (guard (e ((string? e) (fail sh "ERR: cut: " e)))
                                (parse-ranges (or fields chars)))))
                  (define (process line)
                    (if chars
                        (list->string (select-ranges ranges (string->list line)))
                        (string-join* (select-ranges ranges (string-split-on line delim)) delim)))
                  (print-lines sh (map process
                                       (if (pair? files)
                                           (append-map (lambda (name)
                                                         (let ((f (shell-path sh name)))
                                                           (if (path-exists?* f)
                                                               (text-file-lines f #f)
                                                               (begin (println (shell-oute sh) "ERR: " f " not found")
                                                                      '()))))
                                                       (reverse files))
                                           (stdin-text-lines sh))))))))))

    ;; ------------------------------------------------------------------
    ;; tee

    (define-command "tee" "[-a] <file> ...   : copy stdin to each file and to stdout"
      (lambda (sh args)
        (let ((append? (or (member "-a" args) (member "--append" args)))
              (names (keep (lambda (a) (not (member a '("-a" "--append")))) args))
              (text (stdin-string sh)))
          (when text
            (let ((ports (append-map
                          (lambda (name)
                            (let ((f (shell-path sh name)))
                              (guard (e (#t (println (shell-oute sh) "ERR: tee: " f ": " (report-error e)) '()))
                                (list (if append? (open-output-file f 'append) (open-output-file f))))))
                          names)))
              (write-out sh text)
              (for-each (lambda (p) (write-string text p) (close-port p)) ports))))))

    ;; ------------------------------------------------------------------
    ;; watch

    ;; Python's f"{x:g}" for the interval
    (define (format-g x)
      (if (and (integer? x) (< (abs x) 1e15)) (number->string (exact x)) (number->string x)))

    (define-command "watch" "[-n <seconds>] <cmd> [<arg>...]   : run a command repeatedly, refreshing the screen each time"
      (lambda (sh args)
        (let loop ((as args) (interval 10) (cmd-args '()))
          (cond
           ((and (pair? as) (string=? (car as) "-n") (pair? (cdr as)))
            (let ((x (parse-float (cadr as))))
              (unless x (fail sh "ERR: -n requires a numeric value"))
              (loop (cddr as) x cmd-args)))
           ((pair? as) (loop (cdr as) interval (cons (car as) cmd-args)))
           ((null? cmd-args) (fail sh "ERR: watch requires a command to execute"))
           (else
            (let ((cmd-line (quote-args (reverse cmd-args))))
              (with-raw-terminal
               (lambda ()
                 (let repeat ()
                   (let ((cols (terminal-columns))
                         (rows (terminal-rows))
                         (captured (open-output-string))
                         (saved (shell-outs sh)))
                     (dynamic-wind
                       (lambda () (shell-outs-set! sh captured))
                       (lambda () (guard (e ((command-failed? e) #f)) (shell-execute sh cmd-line #f)))
                       (lambda () (shell-outs-set! sh saved)))
                     (let* ((clip (lambda (s) (if (> (string-length s) cols) (substring s 0 cols) s)))
                            (header (clip (string-append "Every " (format-g interval) "s: " cmd-line)))
                            (lines (map clip (take* (splitlines (get-output-string captured))
                                                         (max 1 (- rows 2))))))
                       (write-out sh (console-text sh (apply string-append "\x1b;[2J\x1b;[H" header "\n" "\n"
                                                             (map (lambda (l) (string-append l "\n")) lines)))))
                     (unless (stop-key-within? (exact (round (* interval 1000))) '(ctrl-c ctrl-d))
                       (repeat))))))))))))

    ;; ------------------------------------------------------------------
    ;; xargs

    (define-command "xargs" "[-n <max>] [-d <delim>] [-I <repl>] <cmd> [<arg>...]   : build and execute commands from stdin"
      (lambda (sh args)
        (when (stdin-string sh)
          (let loop ((as args) (max-args #f) (delim #f) (repl #f))
            (cond
             ((and (pair? as) (pair? (cdr as)) (string=? (car as) "-n"))
              (let ((n (parse-int (cadr as))))
                (unless n (fail sh "ERR: xargs: invalid number '" (cadr as) "'"))
                (when (< n 1) (fail sh "ERR: xargs: -n must be at least 1"))
                (loop (cddr as) n delim repl)))
             ((and (pair? as) (pair? (cdr as)) (string=? (car as) "-d")) (loop (cddr as) max-args (cadr as) repl))
             ((and (pair? as) (pair? (cdr as)) (string=? (car as) "-I")) (loop (cddr as) max-args delim (cadr as)))
             (else
              (let* ((cmd-args (if (null? as) '("echo") as))
                     (input (stdin-string sh))
                     (items (keep (lambda (s) (not (string=? s "")))
                                          (cond ((not delim) (string-split-ws input))
                                                ((string=? delim "") (fail sh "ERR: xargs: empty separator"))
                                                (else (string-split-on input delim)))))
                     (run (lambda (words) (shell-execute sh (quote-args words) #f))))
                (cond ((null? items))
                      (repl (for-each (lambda (item)
                                        (run (map (lambda (a) (if (string=? repl "") a (string-replace* a repl item)))
                                                  cmd-args)))
                                      items))
                      (max-args (let batch ((items items))
                                  (when (pair? items)
                                    (run (append cmd-args (take* items max-args)))
                                    (batch (if (> (length items) max-args) (list-tail items max-args) '())))))
                      (else (run (append cmd-args items)))))))))))

    ;; ------------------------------------------------------------------
    ;; date

    ;; days since 1970-01-01 of a civil date, and back
    (define (days-from-civil y m d)
      (let* ((y (if (<= m 2) (- y 1) y))
             (era (floor-quotient y 400))
             (yoe (- y (* era 400)))
             (doy (+ (quotient (+ (* 153 (modulo (+ m 9) 12)) 2) 5) (- d 1)))
             (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
        (+ (* era 146097) doe -719468)))

    (define (civil-from-days z)
      (let* ((z (+ z 719468))
             (era (floor-quotient z 146097))
             (doe (- z (* era 146097)))
             (yoe (quotient (+ (- doe (quotient doe 1460)) (quotient doe 36524) (- (quotient doe 146096))) 365))
             (doy (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
             (mp (quotient (+ (* 5 doy) 2) 153))
             (d (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
             (m (if (< mp 10) (+ mp 3) (- mp 9)))
             (y (+ yoe (* era 400))))
        (list (if (<= m 2) (+ y 1) y) m d)))

    (define day-names '#("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))
    (define month-names '#("January" "February" "March" "April" "May" "June" "July"
                           "August" "September" "October" "November" "December"))

    (define (pad n width ch)
      (let ((s (number->string n)))
        (if (< (string-length s) width) (string-append (make-string (- width (string-length s)) ch) s) s)))
    (define (abbrev s) (substring s 0 3))

    ;; C's strftime of a local date-time (y m d hh mm ss microseconds);
    ;; the time zone is unknown (empty %z and %Z, as for Python's naive
    ;; datetime); unknown directives are kept
    (define (strftime fmt y m d hh mm ss us)
      (let* ((days (days-from-civil y m d))
             (wday (modulo (+ days 4) 7))                       ; Sunday = 0
             (yday (- days (days-from-civil y 1 1)))            ; 0-based
             (h12 (let ((h (modulo hh 12))) (if (= h 0) 12 h))))
        (define (directive c)
          (case c
            ((#\Y) (number->string y))
            ((#\y) (pad (modulo y 100) 2 #\0))
            ((#\m) (pad m 2 #\0))
            ((#\d) (pad d 2 #\0))
            ((#\e) (pad d 2 #\space))
            ((#\H) (pad hh 2 #\0))
            ((#\I) (pad h12 2 #\0))
            ((#\M) (pad mm 2 #\0))
            ((#\S) (pad ss 2 #\0))
            ((#\f) (pad us 6 #\0))
            ((#\p) (if (< hh 12) "AM" "PM"))
            ((#\A) (vector-ref day-names wday))
            ((#\a) (abbrev (vector-ref day-names wday)))
            ((#\B) (vector-ref month-names (- m 1)))
            ((#\b #\h) (abbrev (vector-ref month-names (- m 1))))
            ((#\j) (pad (+ yday 1) 3 #\0))
            ((#\w) (number->string wday))
            ((#\u) (number->string (if (= wday 0) 7 wday)))
            ((#\U) (pad (quotient (+ yday 7 (- wday)) 7) 2 #\0))
            ((#\W) (pad (quotient (+ yday 7 (- (modulo (+ wday 6) 7))) 7) 2 #\0))
            ((#\z #\Z) "")
            ((#\D #\x) (strftime "%m/%d/%y" y m d hh mm ss us))
            ((#\F) (strftime "%Y-%m-%d" y m d hh mm ss us))
            ((#\T #\X) (strftime "%H:%M:%S" y m d hh mm ss us))
            ((#\R) (strftime "%H:%M" y m d hh mm ss us))
            ((#\c) (strftime "%a %b %e %H:%M:%S %Y" y m d hh mm ss us))
            ((#\n) "\n")
            ((#\t) "\t")
            ((#\%) "%")
            (else (string #\% c))))
        (let loop ((cs (string->list fmt)) (acc '()))
          (cond ((null? cs) (apply string-append (reverse acc)))
                ((and (char=? (car cs) #\%) (pair? (cdr cs))) (loop (cddr cs) (cons (directive (cadr cs)) acc)))
                (else (loop (cdr cs) (cons (string (car cs)) acc)))))))

    (define-command "date" "[<offset>] [--terse] [--with-time] [--format <fmt>]  : shows the current date"
      (lambda (sh args)
        (let* ((fmt (if (member "--with-time" args) "%Y-%m-%dT%H:%M:%S" "%Y-%m-%d"))
               (fmt (if (member "--terse" args)
                        (string-replace* (string-replace* (string-replace* fmt "-" "") ":" "") "T" "-")
                        fmt))
               (fmt (let loop ((as args))
                      (cond ((null? as) fmt)
                            ((member (car as) '("--format" "--fmt")) (if (pair? (cdr as)) (cadr as) fmt))
                            (else (loop (cdr as))))))
               (offset (let loop ((as args))
                         (cond ((null? as) 0)
                               ((member (car as) '("--format" "--fmt")) (loop (if (pair? (cdr as)) (cddr as) '())))
                               ((string-starts? (car as) "--") (loop (cdr as)))
                               (else (int-arg sh (car as))))))
               (now (current-date))
               (ymd (civil-from-days (+ (days-from-civil (date-year now) (date-month now) (date-day now)) offset))))
          (println (shell-outs sh)
                   (strftime fmt (car ymd) (cadr ymd) (caddr ymd) (date-hour now) (date-minute now)
                             (min 59 (date-second now)) (quotient (date-nanosecond now) 1000))))))))
