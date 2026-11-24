;; dabshell data: json, fetch (HTTP GET), tar and zip.

(define-library (dabshell data)
  (export json-decode json-encode)
  (import (scheme base)
          (scheme char)
          (scheme inexact)
          (srfi 132)
          (scm bytevector)
          (scm fs)
          (scm system)
          (scm compression)
          (scm zip)
          (scm net http client)
          (scm net http response)
          (dabshell util)
          (dabshell core)
          (dabshell awk))
  (begin

    ;; ------------------------------------------------------------------
    ;; common helpers

    (define-record-type data-error
      (make-data-error message)
      data-error?
      (message data-error-message))

    (define (fail . parts) (raise (make-data-error (apply string-append parts))))

    (define (error-text e)
      (if (data-error? e) (data-error-message e) (report-error e)))

    ;; Python's FileNotFoundError text
    (define (not-found-text path)
      (string-append "[Errno 2] No such file or directory: " (py-repr-str path)))

    (define (err sh . parts) (apply println (shell-oute sh) parts))

    ;; ------------------------------------------------------------------
    ;; JSON with the semantics of Python's json module: objects are
    ;; (object (key . value) ...), arrays vectors, null the symbol null

    (define (json-object? v) (and (pair? v) (eq? (car v) 'object)))

    ;; JSONDecodeError text: "msg: line L column C (char P)"
    (define (json-fail text msg pos)
      (let loop ((i 0) (line 1) (last-nl -1))
        (if (< i pos)
            (if (char=? (string-ref text i) #\newline)
                (loop (+ i 1) (+ line 1) i)
                (loop (+ i 1) line last-nl))
            (fail msg ": line " (number->string line) " column "
                  (number->string (- pos last-nl)) " (char " (number->string pos) ")"))))

    ;; a string of one code point (integer->char of dabscm on the JVM
    ;; raises for code points above #xFFFF; utf8->string gives a pair of
    ;; UTF-16 surrogates there)
    (define (codepoint->string cp)
      (if (< cp #x10000)
          (string (integer->char cp))
          (utf8->string (bytevector (+ #xF0 (quotient cp #x40000))
                                    (+ #x80 (remainder (quotient cp #x1000) #x40))
                                    (+ #x80 (remainder (quotient cp #x40) #x40))
                                    (+ #x80 (remainder cp #x40))))))

    (define (json-ws? c) (memv c '(#\space #\tab #\newline #\return)))

    ;; json.loads
    (define (json-decode text)
      (let ((n (string-length text)))
        (define (ch i) (if (< i n) (string-ref text i) #\null))
        (define (skip-ws i) (if (and (< i n) (json-ws? (string-ref text i))) (skip-ws (+ i 1)) i))
        (define (literal? i word) (and (<= (+ i (string-length word)) n)
                                       (string=? (substring text i (+ i (string-length word))) word)))
        (define (digits-end i) (if (and (< i n) (char<=? #\0 (string-ref text i) #\9)) (digits-end (+ i 1)) i))

        ;; the value at i: (values value end)
        (define (scan-value i)
          (let ((c (ch i)))
            (cond ((>= i n) (json-fail text "Expecting value" i))
                  ((char=? c #\") (scan-string (+ i 1)))
                  ((char=? c #\{) (scan-object (+ i 1)))
                  ((char=? c #\[) (scan-array (+ i 1)))
                  ((literal? i "null") (values 'null (+ i 4)))
                  ((literal? i "true") (values #t (+ i 4)))
                  ((literal? i "false") (values #f (+ i 5)))
                  ((literal? i "NaN") (values +nan.0 (+ i 3)))
                  ((literal? i "Infinity") (values +inf.0 (+ i 8)))
                  ((literal? i "-Infinity") (values -inf.0 (+ i 9)))
                  (else (scan-number i)))))

        ;; -?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?
        (define (scan-number i)
          (let* ((j (if (char=? (ch i) #\-) (+ i 1) i))
                 (k (cond ((char=? (ch j) #\0) (+ j 1))
                          ((char<=? #\1 (ch j) #\9) (digits-end j))
                          (else #f))))
            (if (not k)
                (json-fail text "Expecting value" i)
                (let* ((f (and (char=? (ch k) #\.) (char<=? #\0 (ch (+ k 1)) #\9)
                               (digits-end (+ k 1))))
                       (k2 (or f k))
                       (e (and (memv (ch k2) '(#\e #\E))
                               (let ((s (if (memv (ch (+ k2 1)) '(#\+ #\-)) (+ k2 2) (+ k2 1))))
                                 (and (char<=? #\0 (ch s) #\9) (digits-end s)))))
                       (end (or e k2))
                       (s (substring text i end)))
                  (values (if (or f e) (inexact (py-float-parse s)) (string->number s)) end)))))

        (define (hex4 i)
          (let ((s (and (<= (+ i 4) n) (substring text i (+ i 4)))))
            (and s (not (string-index-of (string-downcase s) "x"))
                 (string->number s 16))))

        ;; after the opening quote at i-1
        (define (scan-string i)
          (let ((start (- i 1)) (out (open-output-string)))
            (let loop ((i i))
              (cond
               ((>= i n) (json-fail text "Unterminated string starting at" start))
               ((char=? (ch i) #\") (values (get-output-string out) (+ i 1)))
               ((char<? (ch i) #\space)
                (json-fail text (string-append "Invalid control character " (py-repr-str (string (ch i)))
                                               " at")
                           i))
               ((char=? (ch i) #\\)
                (let ((e (ch (+ i 1))))
                  (cond
                   ((>= (+ i 1) n) (json-fail text "Unterminated string starting at" start))
                   ((char=? e #\u)
                    (let ((u (hex4 (+ i 2))))
                      (unless u (json-fail text "Invalid \\uXXXX escape" (+ i 1)))
                      (let* ((low (and (<= #xD800 u #xDBFF) (char=? (ch (+ i 6)) #\\)
                                       (char=? (ch (+ i 7)) #\u) (hex4 (+ i 8))))
                             (pair (and low (<= #xDC00 low #xDFFF))))
                        (cond (pair
                               (write-string (codepoint->string (+ #x10000 (* (- u #xD800) #x400) (- low #xDC00))) out)
                               (loop (+ i 12)))
                              ((<= #xD800 u #xDFFF) (write-char #\xFFFD out) (loop (+ i 6)))
                              (else (write-char (integer->char u) out) (loop (+ i 6)))))))
                   (else
                    (let ((p (assv e '((#\" . #\") (#\\ . #\\) (#\/ . #\/) (#\b . #\x8)
                                       (#\f . #\xC) (#\n . #\newline) (#\r . #\return) (#\t . #\tab)))))
                      (unless p
                        (json-fail text (string-append "Invalid \\escape: " (py-repr-str (string e)))
                                   (+ i 1)))
                      (write-char (cdr p) out)
                      (loop (+ i 2)))))))
               (else (write-char (ch i) out) (loop (+ i 1)))))))

        ;; after the {
        (define (scan-object i)
          (let ((i (skip-ws i)))
            (cond
             ((char=? (ch i) #\}) (values (list 'object) (+ i 1)))
             ((not (char=? (ch i) #\"))
              (json-fail text "Expecting property name enclosed in double quotes" i))
             (else
              (let loop ((i (+ i 1)) (pairs '()))
                (let*-values (((key i) (scan-string i))
                              ((i) (skip-ws i)))
                  (unless (char=? (ch i) #\:) (json-fail text "Expecting ':' delimiter" i))
                  (let*-values (((value i) (scan-value (skip-ws (+ i 1))))
                                ((pairs) (let ((p (assoc key pairs)))
                                           (if p
                                               (begin (set-cdr! p value) pairs)
                                               (cons (cons key value) pairs))))
                                ((i) (skip-ws i)))
                    (cond
                     ((char=? (ch i) #\}) (values (cons 'object (reverse pairs)) (+ i 1)))
                     ((not (char=? (ch i) #\,)) (json-fail text "Expecting ',' delimiter" i))
                     (else
                      (let ((j (skip-ws (+ i 1))))
                        (cond ((char=? (ch j) #\") (loop (+ j 1) pairs))
                              ((char=? (ch j) #\})
                               (json-fail text "Illegal trailing comma before end of object" i))
                              (else (json-fail text "Expecting property name enclosed in double quotes"
                                               j)))))))))))))

        ;; after the [
        (define (scan-array i)
          (let ((i (skip-ws i)))
            (if (char=? (ch i) #\])
                (values (vector) (+ i 1))
                (let loop ((i i) (items '()))
                  (let*-values (((value i) (scan-value i))
                                ((i) (skip-ws i)))
                    (cond
                     ((char=? (ch i) #\]) (values (list->vector (reverse (cons value items))) (+ i 1)))
                     ((not (char=? (ch i) #\,)) (json-fail text "Expecting ',' delimiter" i))
                     (else
                      (let ((j (skip-ws (+ i 1))))
                        (if (char=? (ch j) #\])
                            (json-fail text "Illegal trailing comma before end of array" i)
                            (loop j (cons value items)))))))))))

        (let-values (((value end) (scan-value (skip-ws 0))))
          (let ((end (skip-ws end)))
            (unless (= end n) (json-fail text "Extra data" end))
            value))))

    (define (json-string s)
      (let ((out (open-output-string)))
        (write-char #\" out)
        (string-for-each
         (lambda (c)
           (case c
             ((#\") (write-string "\\\"" out))
             ((#\\) (write-string "\\\\" out))
             ((#\newline) (write-string "\\n" out))
             ((#\return) (write-string "\\r" out))
             ((#\tab) (write-string "\\t" out))
             ((#\x8) (write-string "\\b" out))
             ((#\xC) (write-string "\\f" out))
             (else
              (if (char<? c #\space)
                  (let ((h (number->string (char->integer c) 16)))
                    (write-string (string-append "\\u" (make-string (- 4 (string-length h)) #\0) h) out))
                  (write-char c out)))))
         s)
        (write-char #\" out)
        (get-output-string out)))

    (define (json-number x)
      (cond ((exact? x) (number->string x))
            ((nan? x) "NaN")
            ((infinite? x) (if (> x 0) "Infinity" "-Infinity"))
            (else (py-float-repr x))))

    ;; json.dumps(value, ensure_ascii=False, indent=indent); indent #f = compact
    (define (json-encode value indent)
      (define (container open close items level render)
        (if (null? items)
            (string-append open close)
            (if indent
                (let ((inner (string-append "\n" (make-string (* (max indent 0) (+ level 1)) #\space))))
                  (string-append open inner
                                 (string-join* (map (lambda (x) (render x (+ level 1))) items)
                                               (string-append "," inner))
                                 "\n" (make-string (* (max indent 0) level) #\space) close))
                (string-append open (string-join* (map (lambda (x) (render x level)) items) ", ")
                               close))))
      (let enc ((v value) (level 0))
        (cond ((string? v) (json-string v))
              ((number? v) (json-number v))
              ((eq? v #t) "true")
              ((eq? v #f) "false")
              ((eq? v 'null) "null")
              ((vector? v) (container "[" "]" (vector->list v) level enc))
              (else (container "{" "}" (cdr v) level
                               (lambda (p level)
                                 (string-append (json-string (car p)) ": " (enc (cdr p) level))))))))

    (define (json-type-name v)
      (cond ((string? v) "str")
            ((exact? v) "int")
            ((number? v) "float")
            ((boolean? v) "bool")
            ((eq? v 'null) "NoneType")
            ((vector? v) "list")
            (else "dict")))

    ;; the value at a dotted path ("users.0.name")
    (define (json-walk data path)
      (let loop ((data data) (parts (string-split-on path ".")))
        (cond
         ((null? parts) data)
         ((string=? (car parts) "") (loop data (cdr parts)))
         ((vector? data)
          (let* ((part (car parts))
                 (i (or (parse-int part)
                        (fail "invalid literal for int() with base 10: " (py-repr-str part))))
                 (n (vector-length data))
                 (k (if (< i 0) (+ i n) i)))
            (if (and (>= k 0) (< k n))
                (loop (vector-ref data k) (cdr parts))
                (fail "list index out of range"))))
         ((json-object? data)
          (let ((p (assoc (car parts) (cdr data))))
            (if p (loop (cdr p) (cdr parts)) (fail (py-repr-str (car parts))))))
         (else
          (fail "cannot descend into " (json-type-name data) " at " (py-repr-str (car parts)))))))

    (define-command "json"
      "[-c] [-p <path>] [-i <indent>] [<file>]   : pretty-prints JSON or extracts a value at <path> (dot/index syntax: 'users.0.name')"
      (lambda (sh args)
        (let parse ((args args) (after #f) (compact #f) (path #f) (indent 2) (file #f))
          (cond
           ((and (pair? args) (not after) (string-starts? (car args) "-"))
            (let ((a (car args)))
              (cond ((string=? a "--") (parse (cdr args) #t compact path indent file))
                    ((string=? a "-c") (parse (cdr args) after #t path indent file))
                    ((string=? a "-p")
                     (if (null? (cdr args))
                         (err sh "ERR: json: -p requires an argument")
                         (parse (cddr args) after compact (cadr args) indent file)))
                    ((string=? a "-i")
                     (cond ((null? (cdr args)) (err sh "ERR: json: -i requires an argument"))
                           ((parse-int (cadr args))
                            => (lambda (i) (parse (cddr args) after compact path i file)))
                           (else (err sh "ERR: json: invalid indent " (py-repr-str (cadr args))))))
                    (else (err sh "ERR: json: unknown option " (py-repr-str a))))))
           ((pair? args)
            (if file
                (err sh "ERR: json: only one file allowed")
                (parse (cdr args) after compact path indent (car args))))
           (else
            (let ((text (cond (file
                               (let ((p (shell-path sh file)))
                                 (if (path-exists?* p)
                                     (utf8->string (read-file-bytes p))
                                     (begin (err sh "ERR: " p " not found") #f))))
                              ((stdin-string sh) => (lambda (s) s))
                              (else (err sh "ERR: json: no input") #f))))
              (when text
                (guard (e ((data-error? e) (err sh "ERR: json: parse error: " (data-error-message e))))
                  (let ((data (json-decode text)))
                    (guard (e ((data-error? e) (err sh "ERR: json: " (data-error-message e))))
                      (let ((data (if path (json-walk data path) data)))
                        (println (shell-outs sh)
                                 (if (and path (string? data))
                                     data
                                     (json-encode data (if compact #f indent)))))))))))))))

    ;; ------------------------------------------------------------------
    ;; fetch

    (define reason-phrases
      '((300 . "Multiple Choices") (304 . "Not Modified") (400 . "Bad Request")
        (401 . "Unauthorized") (403 . "Forbidden") (404 . "Not Found")
        (405 . "Method Not Allowed") (406 . "Not Acceptable") (408 . "Request Timeout")
        (409 . "Conflict") (410 . "Gone") (413 . "Content Too Large")
        (415 . "Unsupported Media Type") (429 . "Too Many Requests")
        (500 . "Internal Server Error") (501 . "Not Implemented") (502 . "Bad Gateway")
        (503 . "Service Unavailable") (504 . "Gateway Timeout")))

    ;; the charset parameter of a Content-Type header, lower case, or #f
    (define (content-charset content-type)
      (and content-type
           (let loop ((params (cdr (string-split-on content-type ";"))))
             (and (pair? params)
                  (let* ((kv (string-split-on (car params) "=" 1)))
                    (if (and (= (length kv) 2)
                             (string=? (string-downcase (string-strip (car kv))) "charset"))
                        (string-downcase (string-strip (string-strip (cadr kv)) "\"'"))
                        (loop (cdr params))))))))

    ;; decode a body like data.decode(charset), falling back to Latin-1
    (define (decode-body bv charset)
      (cond ((member charset '("utf-8" "utf8" "u8"))
             (if (utf8-valid? bv) (utf8->string bv) (latin1->string bv)))
            ((member charset '("latin-1" "latin1" "iso-8859-1" "iso8859-1" "l1" "ascii" "us-ascii"))
             (latin1->string bv))
            (else (fail "unknown encoding: " charset))))

    (define-command "fetch"
      "[-o <file>] [-H <header>]... [--timeout <s>] <url>   : downloads from a URL (HTTP GET); writes to stdout or <file>"
      (lambda (sh args)
        (let parse ((args args) (output #f) (headers '()) (timeout 30.0) (url #f))
          (cond
           ((null? args)
            (if (not url)
                (err sh "ERR: fetch: missing URL")
                (fetch sh url output (reverse headers) timeout)))
           ((member (car args) '("-o" "-H" "--timeout"))
            (let ((a (car args)))
              (if (null? (cdr args))
                  (err sh "ERR: fetch: " a " requires an argument")
                  (let ((v (cadr args)) (rest (cddr args)))
                    (cond ((string=? a "-o") (parse rest v headers timeout url))
                          ((string=? a "-H") (parse rest output (cons v headers) timeout url))
                          ((py-float-parse v) => (lambda (t) (parse rest output headers t url)))
                          (else (err sh "ERR: fetch: invalid timeout " (py-repr-str v))))))))
           ((string-starts? (car args) "-")
            (err sh "ERR: fetch: unknown option " (py-repr-str (car args))))
           (url (err sh "ERR: fetch: only one URL allowed"))
           (else (parse (cdr args) output headers timeout (car args)))))))

    (define (fetch sh url output headers timeout)
      (let ((bad (let loop ((hs headers))
                   (cond ((null? hs) #f)
                         ((string-index-of (car hs) ":") (loop (cdr hs)))
                         (else (car hs))))))
        (if bad
            (err sh "ERR: fetch: invalid header " (py-repr-str bad))
            (guard (e (#t (err sh "ERR: fetch: " (error-text e))))
              (let* ((alist (map (lambda (h)
                                   (let ((kv (string-split-on h ":" 1)))
                                     (cons (string-strip (car kv)) (string-strip (cadr kv)))))
                                 headers))
                     (resp (http-get-bytevector url alist timeout))
                     (status (http-response-status resp)))
                (unless (<= 200 status 299)
                  (fail "HTTP Error " (number->string status) ": "
                        (let ((p (assv status reason-phrases))) (if p (cdr p) ""))))
                (let ((body (http-response-body resp)))
                  (if output
                      (write-file-bytes (shell-path sh output) body)
                      (print-to (shell-outs sh)
                                (decode-body body (or (content-charset
                                                       (http-response-header resp "Content-Type"))
                                                      "utf8"))))))))))

    ;; ------------------------------------------------------------------
    ;; archives: shared argument parsing of tar and zip

    ;; (mode archive chdir members) or #f after printing an error
    (define (parse-archive-args sh name args)
      (let loop ((args args) (mode #f) (archive #f) (chdir #f) (members '()))
        (cond
         ((null? args)
          (if (and mode archive)
              (list mode archive chdir (reverse members))
              (begin (err sh "ERR: " name ": missing mode or archive") #f)))
         ((member (car args) '("-c" "-x" "-t"))
          (if mode
              (begin (err sh "ERR: " name ": specify exactly one of -c/-x/-t") #f)
              (loop (cdr args) (car args) archive chdir members)))
         ((string=? (car args) "-C")
          (if (null? (cdr args))
              (begin (err sh "ERR: " name ": -C requires an argument") #f)
              (loop (cddr args) mode archive (cadr args) members)))
         ((string-starts? (car args) "-")
          (err sh "ERR: " name ": unknown option " (py-repr-str (car args)))
          #f)
         (archive (loop (cdr args) mode archive chdir (cons (car args) members)))
         (else (loop (cdr args) mode (car args) chdir members)))))

    ;; the path of a member argument as Python's os.path.join(cwd, m)
    (define (member-path sh m) (shell-path sh m))

    ;; the absolute destination of an extraction, created
    (define (extraction-dir sh chdir)
      (let ((dest (shell-path sh (or chdir "."))))
        (make-dirs dest)
        dest))

    (define (make-dirs path)
      (unless (directory? path)
        (let ((parent (path-dirname path)))
          (unless (string=? parent path) (make-dirs parent)))
        (make-directory path)))

    ;; refuse names that would land outside dest
    (define (check-inside dest name)
      (let ((target (path-normpath (path-join dest name))))
        (unless (or (string=? target dest)
                    (string-starts? target (string-append dest (if is-win? "\\" "/"))))
          (fail "refusing to extract outside dest: " name))))

    (define (sorted-entries dir)
      (list-sort (lambda (a b) (string<? (car a) (car b))) (directory-entries dir)))

    (define (mtime-seconds path)
      (let ((ms (file-modification-timestamp path)))
        (if (and (integer? ms) (> ms 0)) (quotient ms 1000) 0)))

    ;; ------------------------------------------------------------------
    ;; tar (USTAR with pax headers for long or non-ASCII names, like Python's
    ;; tarfile; gz built in, bz2 and xz through the bzip2/xz programs)

    (define (tar-compression archive)
      (let ((low (string-downcase archive)))
        (cond ((or (string-ends? low ".tar.gz") (string-ends? low ".tgz")) 'gz)
              ((or (string-ends? low ".tar.bz2") (string-ends? low ".tbz2")) 'bz2)
              ((or (string-ends? low ".tar.xz") (string-ends? low ".txz")) 'xz)
              (else #f))))

    (define (require-program name)
      (or (find-in-path name) (fail name ": program not found on PATH")))

    ;; run the program (bzip2 or xz) with flag on bytes written to a temporary
    ;; file in-name; returns the bytes of the file out-name it makes
    (define (with-tool-file bytes in-name out-name program flag)
      (let ((exe (require-program program))
            (dir (mktempdir)))
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let ((in (path-join dir in-name)) (out (path-join dir out-name)))
              (write-file-bytes in bytes)
              (let ((r (run-program/capture (list exe flag "-f" in))))
                (unless (and (pair? r) (eqv? (car r) 0) (file? out))
                  (fail program " failed")))
              (read-file-bytes out)))
          (lambda () (guard (e (#t #f)) (rm dir 'recursive))))))

    (define (tar-compress bytes compression)
      (case compression
        ((gz) (gzip-compress bytes 9))
        ((bz2) (with-tool-file bytes "a.tar" "a.tar.bz2" "bzip2" "-z"))
        ((xz) (with-tool-file bytes "a.tar" "a.tar.xz" "xz" "-z"))
        (else bytes)))

    (define (tar-decompress bytes compression)
      (case compression
        ((bz2) (require-program "bzip2"))
        ((xz) (require-program "xz")))
      (guard (e (#t (fail (case compression
                            ((gz) "not a gzip file")
                            ((bz2) "not a bzip2 file")
                            (else "not an lzma file")))))
        (case compression
          ((gz) (gzip-decompress bytes))
          ((bz2) (with-tool-file bytes "a.tar.bz2" "a.tar" "bzip2" "-d"))
          ((xz) (with-tool-file bytes "a.tar.xz" "a.tar" "xz" "-d"))
          (else bytes))))

    ;; writing

    (define (put-string! bv off s)
      (let ((b (string->utf8 s)))
        (bytevector-copy! bv off b)))

    (define (put-octal! bv off width n)
      (let ((s (number->string n 8)))
        (put-string! bv off (string-append (make-string (max 0 (- width 1 (string-length s))) #\0) s))))

    (define (ascii? s) (let loop ((cs (string->list s)))
                         (or (null? cs) (and (< (char->integer (car cs)) 128) (loop (cdr cs))))))

    (define (utf8-length s) (bytevector-length (string->utf8 s)))

    ;; (prefix . name) fitting the ustar fields, or #f
    (define (ustar-split name)
      (if (<= (utf8-length name) 100)
          (cons "" name)
          (let loop ((i (- (string-length name) 1)))
            (cond ((<= i 0) #f)
                  ((and (char=? (string-ref name i) #\/)
                        (<= (utf8-length (substring name (+ i 1) (string-length name))) 100)
                        (<= (utf8-length (substring name 0 i)) 155)
                        (> (string-length name) (+ i 1)))
                   (cons (substring name 0 i) (substring name (+ i 1) (string-length name))))
                  (else (loop (- i 1)))))))

    (define (tar-header name prefix size mtime mode type linkname)
      (let ((bv (make-bytevector 512 0)))
        (put-string! bv 0 name)
        (put-octal! bv 100 8 mode)
        (put-octal! bv 108 8 0)
        (put-octal! bv 116 8 0)
        (put-octal! bv 124 12 size)
        (put-octal! bv 136 12 mtime)
        (put-string! bv 148 "        ")
        (bytevector-u8-set! bv 156 (char->integer type))
        (put-string! bv 157 linkname)
        (put-string! bv 257 "ustar")
        (put-string! bv 263 "00")
        (put-string! bv 345 prefix)
        (let loop ((i 0) (sum 0))
          (if (< i 512)
              (loop (+ i 1) (+ sum (bytevector-u8-ref bv i)))
              (let ((s (number->string sum 8)))
                (put-string! bv 148 (string-append (make-string (- 6 (string-length s)) #\0) s))
                (bytevector-u8-set! bv 154 0))))
        bv))

    (define (pad-bytes size)
      (make-bytevector (modulo (- 512 (modulo size 512)) 512) 0))

    ;; "len key=value\n" with len counting the whole record
    (define (pax-record key value)
      (let* ((body (string-append " " key "=" value "\n"))
             (n (utf8-length body)))
        (let loop ((len (+ n 1)))
          (let ((total (+ n (string-length (number->string len)))))
            (if (= total len)
                (string-append (number->string len) body)
                (loop total))))))

    ;; the blocks of one member (header, data, padding)
    (define (tar-member-blocks name size mtime mode type linkname data)
      (let* ((split (and (ascii? name) (ascii? linkname) (<= (string-length linkname) 100)
                         (ustar-split name)))
             (pax (if split
                      '()
                      (let ((records (string->utf8
                                      (string-append (pax-record "path" name)
                                                     (if (string=? linkname "") ""
                                                         (pax-record "linkpath" linkname))))))
                        (list (tar-header (string-append "./PaxHeaders/" (path-basename* name)) ""
                                          (bytevector-length records) mtime #o644 #\x "")
                              records
                              (pad-bytes (bytevector-length records))))))
             (short (lambda (s) (let ((b (string->utf8 s)))
                                  (if (> (bytevector-length b) 100)
                                      (utf8->string (bytevector-copy b 0 100)) s)))))
        (append pax
                (list (tar-header (if split (cdr split) (short (path-basename* name)))
                                  (if split (car split) "")
                                  size mtime mode type (if split linkname (short linkname))))
                (if data (list data (pad-bytes size)) '()))))

    (define (path-basename* name)
      (let ((parts (string-split-on (string-rstrip name "/") "/")))
        (car (reverse parts))))

    ;; the member name of an argument, as tarfile.gettarinfo makes it
    (define (tar-arcname arcname)
      (string-lstrip (string-replace* (cdr (path-splitdrive arcname)) (if is-win? "\\" "/") "/") "/"))

    (define (file-mode path dir?)
      (let* ((st (guard (e (#t '())) (stat path)))
             (m (let ((p (assq 'mode st))) (and p (cdr p)))))
        (cond ((string? m) (remainder (string->number m 8) #o10000))
              ((integer? m) (remainder m #o10000))
              (dir? #o777)
              (else #o666))))

    ;; tarfile.add(path, arcname) recursively; a list of blocks
    (define (tar-add path arcname archive-path)
      (cond
       ((string=? (path-normpath path) archive-path) '())
       ((file-symlink? path)
        (tar-member-blocks (tar-arcname arcname) 0 (mtime-seconds path) #o777 #\2
                           (or (read-symlink path) "") #f))
       ((directory? path)
        (let ((name (tar-arcname arcname)))
          (append (tar-member-blocks (if (or (string=? name "") (string-ends? name "/")) name (string-append name "/"))
                                     0 (mtime-seconds path) (file-mode path #t) #\5 "" #f)
                  (apply append
                         (map (lambda (e)
                                (tar-add (path-join path (car e)) (path-join arcname (car e))
                                         archive-path))
                              (sorted-entries path))))))
       ((file? path)
        (let ((data (read-file-bytes path)))
          (tar-member-blocks (tar-arcname arcname) (bytevector-length data) (mtime-seconds path)
                             (file-mode path #f) #\0 "" data)))
       ((path-exists?* path) '())
       (else (fail (not-found-text path)))))

    (define (tar-create sh archive-path compression members)
      (let* ((blocks (apply append
                            (map (lambda (m) (tar-add (member-path sh m) m archive-path)) members)))
             (port (open-output-bytevector)))
        (for-each (lambda (b) (write-bytevector b port)) blocks)
        ;; two zero blocks, then zeros up to a full 10240-byte record
        (let* ((size (+ (bytevector-length (get-output-bytevector port)) 1024))
               (padded (* 10240 (quotient (+ size 10239) 10240))))
          (write-bytevector (make-bytevector (- padded size -1024) 0) port))
        (write-file-bytes archive-path (tar-compress (get-output-bytevector port) compression))))

    ;; reading: a list of members #(name type mode mtime linkname data)

    (define (field-string bv off len)
      (let loop ((i 0))
        (if (or (>= i len) (zero? (bytevector-u8-ref bv (+ off i))))
            (let ((b (bytevector-copy bv off (+ off i))))
              (if (utf8-valid? b) (utf8->string b) (latin1->string b)))
            (loop (+ i 1)))))

    (define (field-number bv off len)
      (if (>= (bytevector-u8-ref bv off) #x80)
          (let loop ((i 1) (v (- (bytevector-u8-ref bv off) #x80)))
            (if (< i len) (loop (+ i 1) (+ (* v 256) (bytevector-u8-ref bv (+ off i)))) v))
          (let ((s (string-strip (field-string bv off len))))
            (if (string=? s "") 0 (or (string->number s 8) (fail "invalid header"))))))

    (define (checksum-ok? bv off)
      (let loop ((i 0) (sum 0) (ssum 0))
        (if (< i 512)
            (let* ((b (if (<= 148 i 155) 32 (bytevector-u8-ref bv (+ off i))))
                   (sb (if (>= b 128) (- b 256) b)))
              (loop (+ i 1) (+ sum b) (+ ssum sb)))
            (let ((stored (field-number bv (+ off 148) 8)))
              (or (= stored sum) (= stored ssum))))))

    (define (zero-block? bv off)
      (let loop ((i 0))
        (or (>= i 512) (and (zero? (bytevector-u8-ref bv (+ off i))) (loop (+ i 1))))))

    ;; pax records as an alist
    (define (parse-pax bytes)
      (let ((text (utf8->string bytes)))
        (let loop ((i 0) (acc '()))
          (let ((sp (string-index-of text " " i)))
            (if (not sp)
                acc
                (let* ((len (string->number (substring text i sp)))
                       (end (and len (min (string-length text) (+ i len))))
                       (rec (and end (substring text (+ sp 1) (- end 1))))
                       (eq (and rec (string-index-of rec "="))))
                  (if (and eq (> len 0))
                      (loop end (cons (cons (substring rec 0 eq)
                                            (substring rec (+ eq 1) (string-length rec)))
                                      acc))
                      acc)))))))

    (define (tar-read bv)
      (let ((n (bytevector-length bv)))
        (cond ((or (= n 0) (and (>= n 512) (zero-block? bv 0))) (fail "empty file"))
              ((< n 512) (fail "truncated header"))
              ((not (checksum-ok? bv 0)) (fail "bad checksum")))
        (let loop ((off 0) (overrides '()) (acc '()))
          (if (or (> (+ off 512) n) (zero-block? bv off) (not (checksum-ok? bv off)))
              (reverse acc)
              (let* ((size0 (field-number bv (+ off 124) 12))
                     (type (integer->char (bytevector-u8-ref bv (+ off 156))))
                     (size (let ((p (assoc "size" overrides)))
                             (if (and p (memv type '(#\0 #\null #\7))) (string->number (cdr p)) size0)))
                     (data-off (+ off 512))
                     (next (+ data-off (* 512 (quotient (+ size 511) 512))))
                     (data (bytevector-copy bv (min n data-off) (min n (+ data-off size)))))
                (case type
                  ((#\x) (loop next (append (parse-pax data) overrides) acc))
                  ((#\g) (loop next overrides acc))
                  ((#\L) (loop next (cons (cons "path" (field-string data 0 size)) overrides) acc))
                  ((#\K) (loop next (cons (cons "linkpath" (field-string data 0 size)) overrides) acc))
                  (else
                   (let* ((prefix (if (string=? (field-string bv (+ off 257) 5) "ustar")
                                      (field-string bv (+ off 345) 155)
                                      ""))
                          (raw-name (field-string bv off 100))
                          (name (cond ((assoc "path" overrides) => cdr)
                                      ((string=? prefix "") raw-name)
                                      (else (string-append prefix "/" raw-name))))
                          (dir? (or (char=? type #\5)
                                    (and (memv type '(#\0 #\null)) (string-ends? name "/"))))
                          (link (cond ((assoc "linkpath" overrides) => cdr)
                                      (else (field-string bv (+ off 157) 100))))
                          (mtime (cond ((assoc "mtime" overrides)
                                        => (lambda (p) (exact (floor (or (py-float-parse (cdr p)) 0)))))
                                       (else (field-number bv (+ off 136) 12)))))
                     (loop next '()
                           (cons (vector (if dir? (string-rstrip name "/") name)
                                         (if dir? #\5 type)
                                         (field-number bv (+ off 100) 8)
                                         mtime link data)
                                 acc))))))))))

    (define (tar-members archive-path compression)
      (unless (file? archive-path) (fail (not-found-text archive-path)))
      (tar-read (tar-decompress (read-file-bytes archive-path) compression)))

    (define (member-name m) (vector-ref m 0))
    (define (member-type m) (vector-ref m 1))

    ;; the extraction path of a member name, as tarfile with filter="data"
    (define (tar-target dest name)
      (path-normpath (path-join dest (string-lstrip name "/"))))

    (define (tar-extract members dest)
      (for-each (lambda (m) (check-inside dest (member-name m))) members)
      (let ((dirs '()))
        (for-each
         (lambda (m)
           (let ((target (tar-target dest (member-name m)))
                 (type (member-type m)))
             (case type
               ((#\5) (make-dirs target) (set! dirs (cons (cons target m) dirs)))
               ((#\1 #\2)
                (let* ((link (vector-ref m 4))
                       (source-name (if (char=? type #\1)
                                        link
                                        (path-join (path-dirname (member-name m)) link)))
                       (source (let find ((ms members))
                                 (cond ((null? ms) #f)
                                       ((string=? (path-normpath (member-name (car ms)))
                                                  (path-normpath source-name))
                                        (car ms))
                                       (else (find (cdr ms)))))))
                  (check-inside dest source-name)
                  (make-dirs (path-dirname target))
                  (unless (and (char=? type #\2) (not (path-exists?* target))
                               (begin (make-symlink link target) (file-symlink? target)))
                    (if (and source (not (memv (member-type source) '(#\1 #\2 #\5))))
                        (write-member-file target source)
                        (fail "unable to resolve link inside archive: " (member-name m))))))
               ((#\3 #\4 #\6) #f)
               (else (make-dirs (path-dirname target)) (write-member-file target m)))))
         members)
        (for-each (lambda (d) (set-mtime (car d) (cdr d))) dirs)))

    (define (write-member-file target m)
      (write-file-bytes target (vector-ref m 5))
      (set-mtime target m)
      (when (and (not is-win?) (not (zero? (bitwise-and* (vector-ref m 2) #o111))))
        (chmod target (number->string (bitwise-and* (vector-ref m 2) #o755) 8))))

    (define (bitwise-and* a b)
      (let loop ((a a) (b b) (bit 1) (acc 0))
        (if (or (zero? a) (zero? b))
            acc
            (loop (quotient a 2) (quotient b 2) (* bit 2)
                  (if (and (odd? a) (odd? b)) (+ acc bit) acc)))))

    (define (set-mtime path m)
      (guard (e (#t #f)) (set-file-modification-time! path (* 1000 (vector-ref m 3)))))

    (define-command "tar"
      "(-c|-x|-t) <archive> [-C <dir>] [<file>...]   : create, extract, or list a tar archive (compression auto-detected by extension)"
      (lambda (sh args)
        (let ((parsed (parse-archive-args sh "tar" args)))
          (when parsed
            (let* ((mode (car parsed))
                   (archive (cadr parsed))
                   (archive-path (shell-path sh archive))
                   (compression (tar-compression archive))
                   (members (cadddr parsed)))
              (if (and (string=? mode "-c") (null? members))
                  (err sh "ERR: tar: -c requires at least one file")
                  (guard (e (#t (err sh "ERR: tar: " (error-text e))))
                    (cond ((string=? mode "-c") (tar-create sh archive-path compression members))
                          ((string=? mode "-t")
                           (for-each (lambda (m) (println (shell-outs sh) (member-name m)))
                                     (tar-members archive-path compression)))
                          (else
                           (let ((dest (extraction-dir sh (caddr parsed))))
                             (tar-extract (tar-members archive-path compression) dest)))))))))))

    ;; ------------------------------------------------------------------
    ;; zip

    ;; the entry name of an argument, as ZipInfo.from_file makes it
    (define (zip-arcname arcname)
      (let* ((p (path-normpath (cdr (path-splitdrive arcname))))
             (p (string-lstrip p (if is-win? "\\/" "/"))))
        (if is-win? (string-replace* p "\\" "/") p)))

    ;; the files below dir (os.walk order) as (path . arcname)
    (define (walk-files dir base)
      (let* ((entries (sorted-entries dir))
             (files (filter-map* (lambda (e)
                                   (and (not (eq? (cdr e) 'directory))
                                        (file? (path-join dir (car e)))
                                        (cons (path-join dir (car e)) (path-join base (car e)))))
                                 entries))
             (dirs (filter-map* (lambda (e)
                                  (and (eq? (cdr e) 'directory) (car e)))
                                entries)))
        (append files
                (apply append (map (lambda (d) (walk-files (path-join dir d) (path-join base d)))
                                   dirs)))))

    ;; os.path.relpath of two normalized absolute paths
    (define (relative-path path start)
      (let* ((sep (if is-win? "\\" "/"))
             (split (lambda (p) (filter-map* (lambda (x) (and (not (string=? x "")) x))
                                             (string-split-on p sep)))))
        (let loop ((a (split path)) (b (split start)))
          (if (and (pair? a) (pair? b) (string=? (string-downcase (car a)) (string-downcase (car b))))
              (loop (cdr a) (cdr b))
              (let ((parts (append (map (lambda (x) "..") b) a)))
                (if (null? parts) "." (string-join* parts sep)))))))

    (define (filter-map* f lst)
      (let loop ((lst lst) (acc '()))
        (if (null? lst)
            (reverse acc)
            (let ((v (f (car lst)))) (loop (cdr lst) (if v (cons v acc) acc))))))

    (define (zip-create sh archive-path members)
      (let ((files (apply append
                          (map (lambda (m)
                                 (let ((p (member-path sh m)))
                                   (cond ((directory? p)
                                          ;; names relative to the parent of the unnormalized
                                          ;; path, like os.path.relpath(full, dirname(m_abs))
                                          (let ((parent (path-normpath
                                                         (path-dirname (path-join (shell-cwd sh) m)))))
                                            (walk-files p (relative-path p parent))))
                                         ((file? p) (list (cons p m)))
                                         (else (fail (not-found-text p))))))
                               members))))
        ;; a name given twice is stored once (Python writes a duplicate entry)
        (call-with-output-zip archive-path
          (lambda (z)
            (let loop ((files files) (seen '()))
              (when (pair? files)
                (let ((name (zip-arcname (cdar files))))
                  (unless (member name seen)
                    (write-bytevector (read-file-bytes (caar files))
                                      (zip-add-binary-entry z name (mtime-seconds (caar files)))))
                  (loop (cdr files) (cons name seen)))))))))

    (define (zip-names archive-path)
      (unless (file? archive-path) (fail (not-found-text archive-path)))
      (guard (e (#t (fail "File is not a zip file")))
        (call-with-input-zip archive-path zip-entry-names)))

    ;; the extraction path of an entry, sanitized like ZipFile._extract_member
    (define (zip-target dest name)
      (let* ((p (cdr (path-splitdrive (if is-win? (string-replace* name "/" "\\") name))))
             (parts (filter-map* (lambda (x) (and (not (member x '("" "." ".."))) x))
                                 (string-split-on p (if is-win? "\\" "/"))))
             (parts (if is-win? (map sanitize-windows-part parts) parts)))
        (path-normpath (path-join* (cons dest parts)))))

    (define (sanitize-windows-part s)
      (string-rstrip (list->string (map (lambda (c) (if (memv c (string->list ":<>|\"?*")) #\_ c))
                                        (string->list s)))
                     ". "))

    (define (zip-extract archive-path dest)
      (let ((names (zip-names archive-path)))
        (for-each (lambda (n) (check-inside dest n)) names)
        (call-with-input-zip archive-path
          (lambda (z)
            (for-each (lambda (n)
                        (let ((target (zip-target dest n)))
                          (if (string-ends? n "/")
                              (make-dirs target)
                              (begin (make-dirs (path-dirname target))
                                     (zip-extract-entry z n target)))))
                      names)))))

    (define-command "zip"
      "(-c|-x|-t) <archive> [-C <dir>] [<file>...]   : create, extract, or list a zip archive"
      (lambda (sh args)
        (let ((parsed (parse-archive-args sh "zip" args)))
          (when parsed
            (let* ((mode (car parsed))
                   (archive-path (shell-path sh (cadr parsed)))
                   (members (cadddr parsed)))
              (if (and (string=? mode "-c") (null? members))
                  (err sh "ERR: zip: -c requires at least one file")
                  (guard (e (#t (err sh "ERR: zip: " (error-text e))))
                    (cond ((string=? mode "-c") (zip-create sh archive-path members))
                          ((string=? mode "-t")
                           (for-each (lambda (n) (println (shell-outs sh) n)) (zip-names archive-path)))
                          (else (zip-extract archive-path (extraction-dir sh (caddr parsed))))))))))))))
