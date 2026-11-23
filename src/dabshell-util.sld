;; dabshell util: platform, Python-compatible path functions, string helpers,
;; text file helpers. Everything here is independent of the shell state.

(define-library (dabshell util)
  (export is-win? home-directory
          ;; paths (semantics of Python's os.path on the host platform)
          path-sep-char? path-absolute? path-join path-join* path-normpath
          path-split path-dirname path-basename path-splitext path-splitdrive
          path-canon path-expanduser path-ismount
          file? directory? path-exists?*
          ;; strings
          string-starts? string-ends? string-index-of string-contains?
          string-lower string-upper string-strip string-lstrip string-rstrip
          string-split-ws string-split-on string-join* string-replace*
          string-repeat string-pad-right string-pad-left splitlines
          splitlines-keepends string-count-of
          ;; numbers
          parse-int format-fixed
          ;; text files
          read-file-bytes write-file-bytes bytes->string-utf8
          detect-file-encoding binary-bytes? decode-bytes
          ;; misc
          list-index-of take-up-to sort-strings)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme process-context)
          (scheme inexact)
          (srfi 132)
          (scm bytevector)
          (scm fs)
          (scm system))
  (begin

    (define is-win? (eq? (sys-platform) 'windows))

    (define (home-directory)
      (or (and is-win? (get-environment-variable "USERPROFILE"))
          (get-environment-variable "HOME")
          (special-folder-user-home)))

    ;; ------------------------------------------------------------------
    ;; strings

    (define (string-starts? s prefix)
      (let ((n (string-length prefix)))
        (and (<= n (string-length s)) (string=? (substring s 0 n) prefix))))

    (define (string-ends? s suffix)
      (let ((n (string-length suffix)) (m (string-length s)))
        (and (<= n m) (string=? (substring s (- m n) m) suffix))))

    ;; index of needle in s at or after start, or #f
    (define (string-index-of s needle . opt)
      (let ((start (if (null? opt) 0 (car opt)))
            (n (string-length needle))
            (m (string-length s)))
        (let loop ((i start))
          (cond ((> (+ i n) m) #f)
                ((string=? (substring s i (+ i n)) needle) i)
                (else (loop (+ i 1)))))))

    (define (string-contains? s needle) (and (string-index-of s needle) #t))

    (define (string-count-of s needle)
      (if (string=? needle "")
          (+ (string-length s) 1)
          (let loop ((i 0) (n 0))
            (let ((j (string-index-of s needle i)))
              (if j (loop (+ j (string-length needle)) (+ n 1)) n)))))

    (define (string-lower s) (string-downcase s))
    (define (string-upper s) (string-upcase s))

    (define (ws? c) (char-whitespace? c))

    (define (string-lstrip s . chars)
      (let ((pred (if (null? chars) ws? (lambda (c) (memv c (string->list (car chars))))))
            (n (string-length s)))
        (let loop ((i 0))
          (if (and (< i n) (pred (string-ref s i))) (loop (+ i 1)) (substring s i n)))))

    (define (string-rstrip s . chars)
      (let ((pred (if (null? chars) ws? (lambda (c) (memv c (string->list (car chars)))))))
        (let loop ((i (string-length s)))
          (if (and (> i 0) (pred (string-ref s (- i 1)))) (loop (- i 1)) (substring s 0 i)))))

    (define (string-strip s . chars)
      (apply string-rstrip (apply string-lstrip s chars) chars))

    ;; Python's str.split() without arguments
    (define (string-split-ws s)
      (let ((n (string-length s)))
        (let loop ((i 0) (acc '()))
          (cond ((>= i n) (reverse acc))
                ((ws? (string-ref s i)) (loop (+ i 1) acc))
                (else
                 (let scan ((j i))
                   (if (and (< j n) (not (ws? (string-ref s j))))
                       (scan (+ j 1))
                       (loop j (cons (substring s i j) acc)))))))))

    ;; Python's str.split(sep [, maxsplit])
    (define (string-split-on s sep . opt)
      (let ((maxsplit (if (null? opt) -1 (car opt)))
            (n (string-length sep)))
        (let loop ((start 0) (acc '()) (count 0))
          (let ((j (and (not (= count maxsplit)) (string-index-of s sep start))))
            (if j
                (loop (+ j n) (cons (substring s start j) acc) (+ count 1))
                (reverse (cons (substring s start (string-length s)) acc)))))))

    (define (string-join* strings sep)
      (if (null? strings)
          ""
          (let loop ((rest (cdr strings)) (acc (list (car strings))))
            (if (null? rest)
                (apply string-append (reverse acc))
                (loop (cdr rest) (cons (car rest) (cons sep acc)))))))

    ;; replace all occurrences of old (non-empty) by new
    (define (string-replace* s old new)
      (let ((n (string-length old)))
        (let loop ((start 0) (acc '()))
          (let ((j (string-index-of s old start)))
            (if j
                (loop (+ j n) (cons new (cons (substring s start j) acc)))
                (apply string-append
                       (reverse (cons (substring s start (string-length s)) acc))))))))

    (define (string-repeat s n)
      (let loop ((i 0) (acc '()))
        (if (>= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

    (define (string-pad-right s n)
      (if (>= (string-length s) n) s (string-append s (make-string (- n (string-length s)) #\space))))

    (define (string-pad-left s n)
      (if (>= (string-length s) n) s (string-append (make-string (- n (string-length s)) #\space) s)))

    ;; Python's str.splitlines(): \n, \r\n and \r end lines; no trailing empty line
    (define (splitlines s) (map car (splitlines* s)))
    (define (splitlines-keepends s) (map (lambda (p) (string-append (car p) (cdr p))) (splitlines* s)))
    (define (splitlines* s)
      (let ((n (string-length s)))
        (let loop ((start 0) (i 0) (acc '()))
          (cond ((>= i n)
                 (reverse (if (< start n) (cons (cons (substring s start n) "") acc) acc)))
                ((char=? (string-ref s i) #\newline)
                 (loop (+ i 1) (+ i 1) (cons (cons (substring s start i) "\n") acc)))
                ((char=? (string-ref s i) #\return)
                 (if (and (< (+ i 1) n) (char=? (string-ref s (+ i 1)) #\newline))
                     (loop (+ i 2) (+ i 2) (cons (cons (substring s start i) "\r\n") acc))
                     (loop (+ i 1) (+ i 1) (cons (cons (substring s start i) "\r") acc))))
                (else (loop start (+ i 1) acc))))))

    ;; Python's int(s): optional sign, digits, surrounding whitespace; #f if invalid
    (define (parse-int s)
      (let* ((t (string-strip s))
             (body (if (and (> (string-length t) 0) (memv (string-ref t 0) '(#\+ #\-)))
                       (substring t 1 (string-length t))
                       t)))
        ;; digits; single underscores are allowed between digits ("1_000")
        (and (> (string-length body) 0)
             (let loop ((cs (string->list body)) (prev-digit #f))
               (cond ((null? cs) prev-digit)
                     ((char<=? #\0 (car cs) #\9) (loop (cdr cs) #t))
                     ((char=? (car cs) #\_) (and prev-digit (loop (cdr cs) #f)))
                     (else #f)))
             (let ((v (string->number (string-replace* body "_" "") 10)))
               (and v (if (char=? (string-ref t 0) #\-) (- v) v))))))

    ;; x formatted with digits decimals, like Python's f"{x:.3f}"
    (define (format-fixed x digits)
      (let* ((scale (expt 10 digits))
             (n (exact (round (* (abs x) scale))))
             (int-part (quotient n scale))
             (frac (remainder n scale))
             (fs (number->string frac)))
        (string-append (if (and (< x 0) (> n 0)) "-" "")
                       (number->string int-part)
                       (if (> digits 0)
                           (string-append "." (make-string (- digits (string-length fs)) #\0) fs)
                           ""))))

    ;; ------------------------------------------------------------------
    ;; paths: the semantics of Python's ntpath (Windows) or posixpath

    (define (path-sep-char? c) (or (char=? c #\/) (and is-win? (char=? c #\\))))
    (define sep (if is-win? "\\" "/"))

    ;; (drive . rest); drive is "C:" or "\\\\server\\share" on Windows
    (define (path-splitdrive p)
      (if (not is-win?)
          (cons "" p)
          (let ((n (string-length p)))
            (cond ((and (>= n 2) (path-sep-char? (string-ref p 0)) (path-sep-char? (string-ref p 1))
                        (not (and (>= n 3) (path-sep-char? (string-ref p 2)))))
                   ;; UNC: \\server\share
                   (let* ((i (let loop ((i 2)) (cond ((>= i n) #f) ((path-sep-char? (string-ref p i)) i) (else (loop (+ i 1))))))
                          (j (and i (let loop ((j (+ i 1))) (cond ((>= j n) n) ((path-sep-char? (string-ref p j)) j) (else (loop (+ j 1))))))))
                     (if (and i (> j (+ i 1)))
                         (cons (substring p 0 j) (substring p j n))
                         (cons "" p))))
                  ((and (>= n 2) (char=? (string-ref p 1) #\:) (char-alphabetic? (string-ref p 0)))
                   (cons (substring p 0 2) (substring p 2 n)))
                  (else (cons "" p))))))

    (define (path-absolute? p)
      (let ((rest (cdr (path-splitdrive p))))
        (and (> (string-length rest) 0) (path-sep-char? (string-ref rest 0)))))

    (define (path-join a . more) (path-join* (cons a more)))

    (define (path-join* parts)
      (let loop ((result (car parts)) (rest (cdr parts)))
        (if (null? rest)
            result
            (let* ((p (car rest))
                   (rd (path-splitdrive result))
                   (pd (path-splitdrive p)))
              (loop
               (cond ((path-absolute? p)
                      (if (and is-win? (string=? (car pd) ""))
                          (string-append (car rd) p)
                          p))
                     ((and is-win? (not (string=? (car pd) ""))
                           (not (string-ci=? (car pd) (car rd))))
                      p)
                     ((string=? result "") p)
                     ((path-sep-char? (string-ref result (- (string-length result) 1)))
                      (string-append result (cdr pd)))
                     ((and is-win? (string=? (cdr rd) "") (not (string=? (car rd) "")))
                      (string-append result (cdr pd)))   ; "C:" + "x" -> "C:x"
                     (else (string-append result sep (cdr pd))))
               (cdr rest))))))

    (define (split-components s)
      (let ((n (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((>= i n) (reverse (cons (substring s start n) acc)))
                ((path-sep-char? (string-ref s i)) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
                (else (loop (+ i 1) start acc))))))

    (define (path-normpath p)
      (if (string=? p "")
          "."
          (let* ((d (path-splitdrive p))
                 (drive (if is-win? (string-replace* (car d) "/" "\\") (car d)))
                 (rest (cdr d))
                 (rooted (and (> (string-length rest) 0) (path-sep-char? (string-ref rest 0))))
                 ;; posix keeps exactly two leading slashes
                 (prefix (cond ((not rooted) "")
                               (is-win? "\\")
                               ((and (>= (string-length rest) 2)
                                     (string=? (substring rest 0 2) "//")
                                     (not (and (>= (string-length rest) 3) (char=? (string-ref rest 2) #\/))))
                                "//")
                               (else "/")))
                 (comps (let loop ((cs (split-components rest)) (acc '()))
                          (cond ((null? cs) (reverse acc))
                                ((or (string=? (car cs) "") (string=? (car cs) ".")) (loop (cdr cs) acc))
                                ((string=? (car cs) "..")
                                 (cond ((and (pair? acc) (not (string=? (car acc) ".."))) (loop (cdr cs) (cdr acc)))
                                       (rooted (loop (cdr cs) acc))
                                       (else (loop (cdr cs) (cons ".." acc)))))
                                (else (loop (cdr cs) (cons (car cs) acc))))))
                 (body (string-join* comps sep)))
            (if (and (string=? drive "") (string=? prefix "") (string=? body ""))
                "."
                (string-append drive prefix body)))))

    ;; (head . tail) like os.path.split
    (define (path-split p)
      (let* ((d (path-splitdrive p))
             (drive (car d))
             (rest (cdr d))
             (i (let loop ((i (string-length rest)))
                  (if (and (> i 0) (not (path-sep-char? (string-ref rest (- i 1))))) (loop (- i 1)) i)))
             (head (substring rest 0 i))
             (tail (substring rest i (string-length rest)))
             (head2 (let ((h (string-rstrip head (if is-win? "/\\" "/"))))
                      (if (string=? h "") head h))))
        (cons (string-append drive head2) tail)))

    (define (path-dirname p) (car (path-split p)))
    (define (path-basename p) (cdr (path-split p)))

    ;; (root . ext) like os.path.splitext
    (define (path-splitext p)
      (let* ((base (path-basename p))
             (dot (let loop ((i (- (string-length base) 1)))
                    (cond ((< i 0) #f)
                          ((char=? (string-ref base i) #\.) i)
                          (else (loop (- i 1))))))
             (leading (let loop ((i 0)) (if (and (< i (string-length base)) (char=? (string-ref base i) #\.)) (loop (+ i 1)) i))))
        ;; split at the last dot when a non-dot character precedes it
        (if (and dot (< leading dot))
            (let ((cut (- (string-length p) (- (string-length base) dot))))
              (cons (substring p 0 cut) (substring p cut (string-length p))))
            (cons p ""))))

    (define (path-expanduser p)
      (cond ((string=? p "~") (home-directory))
            ((and (>= (string-length p) 2) (char=? (string-ref p 0) #\~) (path-sep-char? (string-ref p 1)))
             (string-append (home-directory) (substring p 1 (string-length p))))
            (else p)))

    ;; normalized absolute path relative to cwd
    (define (path-canon p cwd)
      (path-normpath (if (path-absolute? p)
                         (path-join (car (path-splitdrive cwd)) p)
                         (path-join cwd p))))

    (define (path-ismount p)
      (let* ((n (path-normpath p))
             (d (path-splitdrive n)))
        (or (and (path-absolute? n) (= (string-length (cdr d)) 1))
            (and is-win? (string=? (cdr d) "") (not (string=? (car d) ""))))))

    (define (stat-type p)
      (guard (e (#t #f))
        (let ((s (stat p)))
          (and (cdr (assq 'exists s)) (cdr (assq 'type s))))))

    (define (file? p) (eq? (stat-type p) 'file))
    (define (directory? p) (eq? (stat-type p) 'directory))
    (define (path-exists?* p) (and (stat-type p) #t))

    ;; ------------------------------------------------------------------
    ;; files

    (define (read-file-bytes path)
      (call-with-port (open-binary-input-file path)
        (lambda (in)
          (let loop ((chunks '()))
            (let ((b (read-bytevector 65536 in)))
              (if (eof-object? b)
                  (apply bytevector-append (reverse chunks))
                  (loop (cons b chunks))))))))

    (define (write-file-bytes path bv)
      (call-with-port (open-binary-output-file path)
        (lambda (out) (write-bytevector bv out))))

    (define (bytes->string-utf8 bv) (utf8->string bv))

    ;; 'utf-8-sig, 'utf-16, 'utf-8 or 'latin-1 like _detect_file_encoding
    (define (detect-file-encoding raw)
      (let ((n (bytevector-length raw)))
        (cond ((and (>= n 3) (= (bytevector-u8-ref raw 0) #xEF) (= (bytevector-u8-ref raw 1) #xBB)
                    (= (bytevector-u8-ref raw 2) #xBF))
               'utf-8-sig)
              ((and (>= n 2) (or (and (= (bytevector-u8-ref raw 0) #xFF) (= (bytevector-u8-ref raw 1) #xFE))
                                 (and (= (bytevector-u8-ref raw 0) #xFE) (= (bytevector-u8-ref raw 1) #xFF))))
               'utf-16)
              ((utf8-valid? raw) 'utf-8)
              (else 'latin-1))))

    ;; decode bytes with the detected encoding (BOM stripped)
    (define (decode-bytes raw)
      (case (detect-file-encoding raw)
        ((utf-8-sig) (utf8->string raw 3 (bytevector-length raw)))
        ((utf-8) (utf8->string raw))
        (else (latin1->string raw))))

    ;; more than 10% control bytes in the first 8 KB
    (define (binary-bytes? raw)
      (let* ((n (min (bytevector-length raw) 8192)))
        (and (> n 0)
             (let loop ((i 0) (bad 0))
               (if (>= i n)
                   (> (/ bad n) 1/10)
                   (let ((b (bytevector-u8-ref raw i)))
                     (loop (+ i 1)
                           (if (or (< b 9) (<= #x0e b #x1f) (= b #x7f)) (+ bad 1) bad))))))))

    ;; ------------------------------------------------------------------
    ;; lists

    (define (list-index-of pred lst)
      (let loop ((l lst) (i 0))
        (cond ((null? l) #f) ((pred (car l)) i) (else (loop (cdr l) (+ i 1))))))

    (define (take-up-to lst n)
      (let loop ((lst lst) (n n) (acc '()))
        (if (or (null? lst) (<= n 0)) (reverse acc) (loop (cdr lst) (- n 1) (cons (car lst) acc)))))

    ;; Python's sorted() on strings (code point order)
    (define (sort-strings lst) (list-sort string<? lst))))
