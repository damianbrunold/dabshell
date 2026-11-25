;; dabshell files: commands that list, copy, move, delete, find, hash,
;; open, describe and convert files.

(define-library (dabshell files)
  (export path-relative sha512-hex sha384-hex)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme time)
          (srfi 132)
          (srfi 151)
          (only (srfi 19) make-time time-utc time-utc->date date-zone-offset)
          (scm bytevector)
          (scm crypto)
          (scm fs)
          (scm glob)
          (scm json simple)
          (scm system)
          (scm zip)
          (dabshell util)
          (dabshell core))
  (begin

    (define (out sh . xs) (apply println (shell-outs sh) xs))
    (define (err sh . xs) (apply println (shell-oute sh) xs))

    ;; print an error and fail the command
    (define (fail sh . xs) (apply err sh xs) (command-failed!))

    ;; Python's repr() of a string
    (define (py-repr s)
      (let ((q (if (and (string-contains? s "'") (not (string-contains? s "\""))) #\" #\')))
        (string-append
         (string q)
         (apply string-append
                (map (lambda (c)
                       (cond ((char=? c #\\) "\\\\")
                             ((char=? c q) (string #\\ c))
                             ((char=? c #\newline) "\\n")
                             ((char=? c #\return) "\\r")
                             ((char=? c #\tab) "\\t")
                             (else (string c))))
                     (string->list s)))
         (string q))))

    ;; arguments resolved against the cwd and glob-expanded; an argument
    ;; without matches is kept as is
    (define (expand-args sh args)
      (apply append
             (map (lambda (arg)
                    (let* ((p (shell-path sh arg))
                           (matched (sort-strings (glob p))))
                      (if (null? matched) (list p) matched)))
                  args)))

    (define (symlink? p) (guard (e (#t #f)) (file-symlink? p)))

    ;; size of a file in bytes, 0 if it cannot be read
    (define (safe-size p)
      (guard (e (#t 0))
        (let ((s (stat p))) (if (cdr (assq 'exists s)) (cdr (assq 'size s)) 0))))

    ;; names in a directory, sorted; '() if it cannot be read
    (define (list-dir p)
      (guard (e (#t '())) (sort-strings (map car (directory-entries p)))))

    ;; (name . type) entries of a directory, sorted by name
    (define (dir-entries p)
      (guard (e (#t '()))
        (list-sort (lambda (a b) (string<? (car a) (car b))) (directory-entries p))))

    (define (same-path? a b)
      (if is-win? (string-ci=? (path-normpath a) (path-normpath b))
          (string=? (path-normpath a) (path-normpath b))))

    (define sep (if is-win? "\\" "/"))

    ;; os.path.relpath for normalized absolute paths; #f on another drive
    (define (path-relative path start)
      (let ((pd (path-splitdrive path)) (sd (path-splitdrive start)))
        (and (if is-win? (string-ci=? (car pd) (car sd)) (string=? (car pd) (car sd)))
             (let* ((comps (lambda (p) (filter-empty (string-split-on (string-replace* p "\\" "/") "/"))))
                    (pc (comps (cdr pd)))
                    (sc (comps (cdr sd)))
                    (eq (if is-win? string-ci=? string=?)))
               (let loop ((pc pc) (sc sc))
                 (if (and (pair? pc) (pair? sc) (eq (car pc) (car sc)))
                     (loop (cdr pc) (cdr sc))
                     (let ((parts (append (map (lambda (x) "..") sc) pc)))
                       (if (null? parts) "." (string-join* parts sep)))))))))

    (define (filter-empty lst)
      (cond ((null? lst) '())
            ((string=? (car lst) "") (filter-empty (cdr lst)))
            (else (cons (car lst) (filter-empty (cdr lst))))))

    (define (pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

    ;; "YYYY-MM-DD HH:MM:SS" in local time for seconds since the epoch.
    ;; dabscm's time-utc->date applies the current UTC offset, so times on
    ;; the other side of a DST change are off by the DST difference.
    (define (format-local secs)
      (format-utc (+ secs (date-zone-offset (time-utc->date (make-time time-utc 0 secs))))))

    ;; "YYYY-MM-DD HH:MM:SS" in UTC for seconds since the epoch
    (define (format-utc secs)
      (let* ((days (floor-quotient secs 86400))
             (rem (- secs (* days 86400)))
             ;; civil date from days (H. Hinnant's algorithm)
             (z (+ days 719468))
             (era (floor-quotient z 146097))
             (doe (- z (* era 146097)))
             (yoe (quotient (- doe (quotient doe 1460) (- (quotient doe 36524)) (quotient doe 146096)) 365))
             (doy (- doe (- (+ (* 365 yoe) (quotient yoe 4)) (quotient yoe 100))))
             (mp (quotient (+ (* 5 doy) 2) 153))
             (d (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
             (m (if (< mp 10) (+ mp 3) (- mp 9)))
             (y (+ yoe (* era 400) (if (<= m 2) 1 0))))
        (string-append (number->string y) "-" (pad2 m) "-" (pad2 d) " "
                       (pad2 (quotient rem 3600)) ":" (pad2 (quotient (remainder rem 3600) 60))
                       ":" (pad2 (remainder rem 60)))))

    ;; ------------------------------------------------------------------
    ;; ls

    (define-record-type ls-entry
      (make-ls-entry name path timestamp size)
      ls-entry?
      (name ls-entry-name)
      (path ls-entry-path)
      (timestamp ls-entry-timestamp)
      (size ls-entry-size))

    (define (get-ls-entry path)
      (let ((s (guard (e (#t #f)) (stat path))))
        (if (and s (cdr (assq 'exists s)))
            (make-ls-entry (path-basename path) path
                           (format-local (floor-quotient (cdr (assq 'mtime s)) 1000))
                           (cdr (assq 'size s)))
            (make-ls-entry (path-basename path) path "" 0))))

    (define (ls sh path opts)
      (let* ((entries
              (cond ((directory? path)
                     (map (lambda (name) (get-ls-entry (path-join path name)))
                          (list-dir path)))
                    ((file? path) (list (get-ls-entry path)))
                    (else
                     (if (path-exists?* path)
                         (err sh "ERR: " path " is not a directory")
                         (err sh "ERR: " path " not found"))
                     '())))
             (rev (and (memv #\r opts) #t))
             ;; stable sort, like Python's sort(key=..., reverse=...)
             (by (lambda (key less descending)
                   (list-sort (if descending
                                  (lambda (a b) (less (key b) (key a)))
                                  (lambda (a b) (less (key a) (key b))))
                              entries)))
             ;; newest and largest first unless reversed
             (sorted (cond ((memv #\t opts) (by ls-entry-timestamp string<? (not rev)))
                           ((memv #\S opts) (by ls-entry-size < (not rev)))
                           (else (by ls-entry-name string<? rev))))
             (color (eq? (shell-outs sh) console-out))
             ;; -h: human-readable sizes ("1.50K") in a narrower column
             (size-str (if (memv #\h opts)
                           (lambda (n) (string-pad-left (human-size n) 6))
                           (lambda (n) (string-pad-left (number->string n) 10)))))
        (for-each
         (lambda (e)
           (let ((pname (if (and color (directory? (ls-entry-path e)))
                            (string-append "\x1b;[34m" (ls-entry-name e) "\x1b;[0m")
                            (ls-entry-name e))))
             (if (memv #\l opts)
                 (out sh (size-str (ls-entry-size e)) " "
                      (ls-entry-timestamp e) " " pname)
                 (out sh pname))))
         sorted)))

    (define-command "ls" "[-lhrtS] [<dir>]   : lists the contents of the directory (-l long, -h human-readable sizes)"
      (lambda (sh args)
        (let loop ((as args) (opts '()) (dirs '()))
          (cond ((pair? as)
                 (if (string-starts? (car as) "-")
                     (loop (cdr as) (append opts (cdr (string->list (car as)))) dirs)
                     (loop (cdr as) opts (cons (car as) dirs))))
                ((null? dirs) (ls sh (shell-cwd sh) opts))
                (else (for-each (lambda (p) (ls sh p opts)) (expand-args sh (reverse dirs))))))))

    ;; ------------------------------------------------------------------
    ;; du

    (define (human-size size)
      (let loop ((s (inexact size)) (units '("B" "K" "M" "G" "T" "P")))
        (if (and (>= s 1024) (pair? (cdr units)))
            (loop (/ s 1024) (cdr units))
            (string-append
             (cond ((string=? (car units) "B") (number->string (exact (truncate s))))
                   ((>= s 100) (format-fixed s 0))
                   ((>= s 10) (format-fixed s 1))
                   (else (format-fixed s 2)))
             (car units)))))

    ;; "1K", "2.5M", "100" -> bytes; #f with a message if invalid
    (define (parse-size str)
      (let ((s (string-strip str)))
        (if (string=? s "")
            (values #f "empty size")
            (let* ((suffix (char-upcase (string-ref s (- (string-length s) 1))))
                   (mult (case suffix
                           ((#\B) 1) ((#\K) 1024) ((#\M) (expt 1024 2)) ((#\G) (expt 1024 3))
                           ((#\T) (expt 1024 4)) ((#\P) (expt 1024 5)) (else #f)))
                   (num (if mult (substring s 0 (- (string-length s) 1)) s))
                   (value (string->number (string-strip num)))
                   (size (and value (real? value)
                              (guard (e (#t #f)) (exact (truncate (* value (or mult 1))))))))
              (if size
                  (values size #f)
                  (values #f (string-append "invalid size " (py-repr num))))))))

    ;; walk current below root; returns its total size and appends
    ;; (label . size) entries (post-order) through add!
    (define (du-walk current rel depth max-depth all-files add!)
      (if (or (file? current) (symlink? current))
          (let ((size (safe-size current)))
            (add! rel size)
            size)
          (let loop ((entries (dir-entries current)) (total 0))
            (if (pair? entries)
                (let* ((name (caar entries))
                       (child (path-join current name))
                       (child-rel (if (string=? rel "") name (path-join rel name))))
                  (if (eq? (cdar entries) 'directory)
                      (loop (cdr entries)
                            (+ total (du-walk child child-rel (+ depth 1) max-depth all-files add!)))
                      (let ((size (safe-size child)))
                        (when (and all-files (or (not max-depth) (<= (+ depth 1) max-depth)))
                          (add! child-rel size))
                        (loop (cdr entries) (+ total size)))))
                (begin
                  (when (or (not max-depth) (<= depth max-depth)) (add! rel total))
                  total)))))

    (define-command "du"
      "[-s] [-a] [-b] [-d <n>] [--sort] [--threshold=<size>] [<path>...]   : prints disk usage of files and directories"
      (lambda (sh args)
        (call/cc
         (lambda (return)
           (define (usage . msg) (apply err sh msg) (return #f))
           (let loop ((as args) (summary #f) (all #f) (bytes #f) (depth #f) (sort? #f)
                      (threshold 0) (paths '()) (after #f))
             (if (pair? as)
                 (let ((arg (car as)))
                   (cond
                    ((or after (not (string-starts? arg "-")))
                     (loop (cdr as) summary all bytes depth sort? threshold (cons arg paths) after))
                    ((string=? arg "--") (loop (cdr as) summary all bytes depth sort? threshold paths #t))
                    ((member arg '("-s" "--summary")) (loop (cdr as) #t all bytes depth sort? threshold paths after))
                    ((member arg '("-a" "--all")) (loop (cdr as) summary #t bytes depth sort? threshold paths after))
                    ((member arg '("-b" "--bytes")) (loop (cdr as) summary all #t depth sort? threshold paths after))
                    ((string=? arg "-d")
                     (when (null? (cdr as)) (usage "ERR: du: -d requires an argument"))
                     (let ((n (parse-int (cadr as))))
                       (unless n (usage "ERR: du: invalid depth " (py-repr (cadr as))))
                       (loop (cddr as) summary all bytes n sort? threshold paths after)))
                    ((string-starts? arg "--max-depth=")
                     (let ((n (parse-int (substring arg 12 (string-length arg)))))
                       (unless n (usage "ERR: du: invalid depth in " (py-repr arg)))
                       (loop (cdr as) summary all bytes n sort? threshold paths after)))
                    ((string=? arg "--sort") (loop (cdr as) summary all bytes depth #t threshold paths after))
                    ((string-starts? arg "--threshold=")
                     (let-values (((size msg) (parse-size (substring arg 12 (string-length arg)))))
                       (unless size (usage "ERR: du: " msg))
                       (loop (cdr as) summary all bytes depth sort? size paths after)))
                    (else (usage "ERR: du: unknown option " (py-repr arg)))))
                 (let ((max-depth (if summary 0 depth))
                       (paths (if (null? paths) '(".") (reverse paths))))
                   (for-each
                    (lambda (path)
                      (let ((full (shell-path sh path)))
                        (if (not (path-exists?* full))
                            (err sh "ERR: " path " not found")
                            (let* ((acc '())
                                   (add! (lambda (label size) (set! acc (cons (cons label size) acc)))))
                              (du-walk full "" 0 max-depth all add!)
                              (let ((entries (if sort?
                                                 (list-sort (lambda (a b) (> (cdr a) (cdr b))) (reverse acc))
                                                 (reverse acc))))
                                (for-each
                                 (lambda (e)
                                   (unless (< (cdr e) threshold)
                                     (let ((label (if (string=? (car e) "") path (path-join path (car e)))))
                                       (if bytes
                                           (out sh (string-pad-left (number->string (cdr e)) 12) " " label)
                                           (out sh (string-pad-left (human-size (cdr e)) 7) " " label)))))
                                 entries))))))
                    paths))))))))

    ;; ------------------------------------------------------------------
    ;; cp, mv

    ;; the sources and destination of cp/mv, checked; (values files dest)
    (define (sources-and-dest sh args verb)
      (let* ((rev (reverse args))
             (dest (shell-path sh (car rev)))
             (sources (reverse (cdr rev)))
             (files (expand-args sh sources)))
        ;; several sources (also after glob expansion) need a directory
        (when (and (> (length files) 1) (not (directory? dest)))
          (fail sh "ERR: cannot " verb " multiple files to a file"))
        (values files dest)))

    ;; where source ends up when copied or moved to dest
    (define (target-of source dest)
      (if (directory? dest) (path-join dest (path-basename source)) dest))

    (define-command "cp" "<srcfiles>... <dest> : copies one or multiple files"
      (lambda (sh args)
        (if (< (length args) 2)
            (err sh "ERR: cp requires at least two arguments")
            (let-values (((files dest) (sources-and-dest sh args "copy")))
              (for-each
               (lambda (source)
                 (if (not (file? source))
                     (err sh "ERR: " source " not found")
                     (let ((target (target-of source dest)))
                       (when (same-path? source target)
                         (fail sh "ERR: " source " and " target " are the same file"))
                       (unless (guard (e (#t (fail sh "ERR: " (report-error e))))
                                 (copy-file source target))
                         (fail sh "ERR: cannot copy " source " to " target)))))
               files)))))

    (define-command "mv" "<src>... <dest> : moves one or multiple files or dirs"
      (lambda (sh args)
        (if (< (length args) 2)
            (err sh "ERR: mv requires at least two arguments")
            (let-values (((files dest) (sources-and-dest sh args "move")))
              (for-each
               (lambda (source)
                 (cond
                  ((not (path-exists?* source)) (err sh "ERR: " source " not found"))
                  (else
                   (let ((target (target-of source dest))
                         (dir (directory? source)))
                     ;; a file replaces a file of the same name in the target directory
                     (when (and (not dir) (directory? dest) (file? target))
                       (guard (e (#t (fail sh "ERR: cannot delete " target)))
                         (delete-file target)))
                     (when (and dir (string-starts? (path-normpath target)
                                                    (string-append (path-normpath source) sep)))
                       (fail sh "ERR: cannot move a directory " source " into itself " target))
                     (when (and (directory? dest) (path-exists?* target))
                       (fail sh "ERR: destination path " target " already exists"))
                     (unless (or (string=? (path-normpath source) (path-normpath target))
                                 (guard (e (#t (fail sh "ERR: " (report-error e))))
                                   (if dir (move-directory source target) (move-file source target))))
                       (fail sh "ERR: cannot move " source " to " target))))))
               files)))))

    ;; ------------------------------------------------------------------
    ;; tree

    (define tree-skip '(".git" "venv" ".env" "__pycache__"))

    ;; the files below path (sorted, depth first), skipping tool directories
    (define (tree-walk path visit)
      (for-each
       (lambda (fname)
         (unless (or (member fname tree-skip) (string-ends? fname ".egg-info"))
           (let ((fpath (path-normpath (path-join path fname))))
             (if (directory? fpath) (tree-walk fpath visit) (visit fpath)))))
       (list-dir path)))

    (define (tree-match? fname flt)
      (cond ((string-starts? flt "*") (string-ends? fname (substring flt 1 (string-length flt))))
            ((string-ends? flt "*") (string-starts? fname (substring flt 0 (- (string-length flt) 1))))
            (else (string=? flt fname))))

    (define-command "tree" "<dir> <filter>... : displays file tree"
      (lambda (sh args)
        (let* ((args (if (null? args) '(".") args))
               (first (shell-path sh (car args)))
               ;; without a directory argument all arguments are filters
               (path (if (directory? first) first (shell-cwd sh)))
               (filters (if (directory? first) (cdr args) args)))
          (tree-walk path
                     (lambda (p)
                       (when (or (null? filters)
                                 (let ((fname (path-basename p)))
                                   (let loop ((fs filters))
                                     (and (pair? fs) (or (tree-match? fname (car fs)) (loop (cdr fs)))))))
                         (out sh p)))))))

    ;; ------------------------------------------------------------------
    ;; touch, rm, mkdir, rmdir

    (define (now-millis) (exact (floor (* (current-second) 1000))))

    (define-command "touch" "<filename>... : creates/changes the files"
      (lambda (sh args)
        (for-each
         (lambda (path)
           (cond ((directory? path) (err sh "ERR: " path ": is a directory"))
                 ((path-exists?* path)
                  (unless (set-file-modification-time! path (now-millis))
                    (fail sh "ERR: cannot touch " path)))
                 (else
                  (guard (e (#t (fail sh "ERR: cannot create " path)))
                    (close-port (open-binary-output-file path))))))
         (expand-args sh args))))

    (define-command "rm" "<filename>... : deletes the files"
      (lambda (sh args)
        (for-each
         (lambda (arg)
           ;; only existing files are deleted: a pattern without matches is ignored
           (for-each
            (lambda (path)
              (cond ((directory? path) (err sh "ERR: " path ": is a directory"))
                    ((not (file? path)) (err sh "ERR: " path " not found"))
                    (else
                     (guard (e (#t (fail sh "ERR: cannot delete " path)))
                       (delete-file path)))))
            (sort-strings (glob (shell-path sh arg)))))
         args)))

    (define-command "mkdir" "<dir> : creates the directory"
      (lambda (sh args)
        (for-each
         (lambda (arg)
           (let ((path (shell-path sh arg)))
             (cond ((file? path) (err sh "ERR: " path " already exists"))
                   ((directory? path) #t)
                   (else
                    (guard (e (#t (fail sh "ERR: cannot create " path)))
                      (make-directory path))
                    (unless (directory? path) (fail sh "ERR: cannot create " path))))))
         args)))

    (define-command "rmdir" "<dir> : deletes the directory"
      (lambda (sh args)
        (for-each
         (lambda (path)
           (cond ((file? path) (err sh "ERR: " path " is a file"))
                 ((not (path-exists?* path)) (err sh "ERR: " path " not found"))
                 (else
                  (guard (e (#t (fail sh "ERR: cannot delete " path)))
                    (delete-directory path))
                  (when (path-exists?* path) (fail sh "ERR: cannot delete " path)))))
         (expand-args sh args))))

    ;; ------------------------------------------------------------------
    ;; basename, dirname, get-ext, remove-ext

    (define (path-command name help f)
      (define-command name help
        (lambda (sh args)
          (when (null? args) (fail sh "ERR: " name " requires a path"))
          (out sh (f (car args))))))

    (path-command "basename" "<path> : returns the basename of the path" path-basename)
    (path-command "dirname" "<path> : returns the dirname part of the path" path-dirname)
    (path-command "get-ext" "<filename> : returns the file extension"
                  (lambda (p) (cdr (path-splitext p))))
    (path-command "remove-ext" "<filename> : returns the filename without extension"
                  (lambda (p) (car (path-splitext p))))

    ;; ------------------------------------------------------------------
    ;; find

    ;; visit (path depth dir?) for root and the entries below it, like
    ;; the stack-based walk of the Python version
    (define (find-walk root max-depth visit)
      (let ((root-dir (and (directory? root) (not (symlink? root)))))
        (visit root 0 root-dir)
        (when root-dir
          (let loop ((stack (list (cons root 0))))
            (when (pair? stack)
              (let ((current (caar stack)) (depth (cdar stack)))
                (if (and max-depth (>= depth max-depth))
                    (loop (cdr stack))
                    (let inner ((entries (dir-entries current)) (stack (cdr stack)))
                      (if (null? entries)
                          (loop stack)
                          (let ((child (path-join current (caar entries)))
                                (dir? (eq? (cdar entries) 'directory)))
                            (visit child (+ depth 1) dir?)
                            (inner (cdr entries)
                                   (if dir? (cons (cons child (+ depth 1)) stack) stack))))))))))))

    (define-command "find"
      "[<path>...] [-name <glob>] [-iname <glob>] [-type f|d] [-maxdepth <n>]   : finds files and directories matching the criteria"
      (lambda (sh args)
        (call/cc
         (lambda (return)
           (define (usage . msg) (apply err sh msg) (return #f))
           (define (value as opt)
             (when (null? (cdr as)) (usage "ERR: find: " opt " requires an argument"))
             (cadr as))
           (let loop ((as args) (paths '()) (name #f) (iname #f) (type #f) (max-depth #f))
             (if (pair? as)
                 (let ((arg (car as)))
                   (cond
                    ((string=? arg "-name")
                     (let ((v (value as arg))) (loop (cddr as) paths v iname type max-depth)))
                    ((string=? arg "-iname")
                     (let ((v (value as arg))) (loop (cddr as) paths name v type max-depth)))
                    ((string=? arg "-type")
                     (let ((t (value as arg)))
                       (unless (member t '("f" "d"))
                         (usage "ERR: find: -type must be f or d, got " (py-repr t)))
                       (loop (cddr as) paths name iname t max-depth)))
                    ((string=? arg "-maxdepth")
                     (let ((n (parse-int (value as arg))))
                       (unless n (usage "ERR: find: invalid maxdepth " (py-repr (cadr as))))
                       (loop (cddr as) paths name iname type n)))
                    ((string-starts? arg "-") (usage "ERR: find: unknown option " (py-repr arg)))
                    (else (loop (cdr as) (cons arg paths) name iname type max-depth))))
                 (for-each
                  (lambda (path)
                    (let ((full (shell-path sh path)))
                      (if (not (path-exists?* full))
                          (err sh "ERR: " path " not found")
                          (find-walk
                           full max-depth
                           (lambda (entry depth dir?)
                             (let ((base (path-basename entry)))
                               (when (and (not (and (equal? type "f") dir?))
                                          (not (and (equal? type "d") (not dir?)))
                                          (or (not name) (glob-match? name base))
                                          (or (not iname)
                                              (glob-match? (string-downcase iname) (string-downcase base))))
                                 (let ((rel (path-relative entry (shell-cwd sh))))
                                   ;; relative below the cwd, else absolute
                                   (if (or (not rel) (string=? rel "..")
                                           (string-starts? rel (string-append ".." sep)))
                                       (out sh entry)
                                       (out sh rel))))))))))
                  (if (null? paths) '(".") (reverse paths)))))))))

    ;; ------------------------------------------------------------------
    ;; hash

    (define (sha512-hex bv) (bytevector->hex (sha512-hash bv)))
    (define (sha384-hex bv) (bytevector->hex (sha384-hash bv)))

    (define hash-algorithms
      (list (cons "md5" md5-hash)
            (cons "sha1" sha1-hash)
            (cons "sha256" (lambda (bv) (bytevector->hex (sha256-hash bv))))
            (cons "sha384" sha384-hex)
            (cons "sha512" sha512-hex)))

    (define-command "hash"
      "[-a md5|sha1|sha256|sha384|sha512] [<file>...]   : computes a cryptographic hash of files or stdin"
      (lambda (sh args)
        (call/cc
         (lambda (return)
           (define (usage . msg) (apply err sh msg) (return #f))
           (let loop ((as args) (algo "sha256") (files '()) (after #f))
             (if (pair? as)
                 (let ((arg (car as)))
                   (cond ((or after (not (string-starts? arg "-"))) (loop (cdr as) algo (cons arg files) after))
                         ((string=? arg "--") (loop (cdr as) algo files #t))
                         ((string=? arg "-a")
                          (when (null? (cdr as)) (usage "ERR: hash: -a requires an argument"))
                          (loop (cddr as) (string-downcase (cadr as)) files after))
                         (else (usage "ERR: hash: unknown option " (py-repr arg)))))
                 (let ((h (assoc algo hash-algorithms)))
                   (unless h (usage "ERR: hash: unsupported algorithm " (py-repr algo)))
                   (cond
                    ((pair? files)
                     (for-each
                      (lambda (fn)
                        (let ((path (shell-path sh fn)))
                          (cond ((not (path-exists?* path)) (err sh "ERR: " fn " not found"))
                                ((directory? path) (err sh "ERR: " fn ": is a directory"))
                                (else
                                 (let ((digest (guard (e (#t (err sh "ERR: " fn ": " (report-error e)) #f))
                                                 ((cdr h) (read-file-bytes path)))))
                                   (when digest (out sh digest "  " fn)))))))
                      (reverse files)))
                    ((stdin-string sh)
                     (out sh ((cdr h) (string->utf8 (stdin-string sh)))))))))))))

    ;; ------------------------------------------------------------------
    ;; open

    (define-command "open" "<file_or_url>   : opens a file or URL with the OS default handler"
      (lambda (sh args)
        (if (null? args)
            (err sh "ERR: open: missing argument")
            (let ((target (if (string-contains? (car args) "://") (car args) (shell-path sh (car args)))))
              (if (and (not (string-contains? (car args) "://")) (not (path-exists?* target)))
                  (err sh "ERR: open: " (car args) " not found")
                  (let ((argv (case (sys-platform)
                                ((windows) (list "rundll32" "url.dll,FileProtocolHandler" target))
                                ((macos darwin osx) (list "open" target))
                                (else (list "xdg-open" target)))))
                    (unless (guard (e (#t (err sh "ERR: open: " (report-error e)) #t))
                              (start-program argv))
                      (err sh "ERR: open: cannot start " (car argv)))))))))

    ;; ------------------------------------------------------------------
    ;; file: type detection

    (define file-extensions
      '((".py" . "Python source") (".pyi" . "Python stub")
        (".js" . "JavaScript source") (".mjs" . "JavaScript source") (".cjs" . "JavaScript source")
        (".ts" . "TypeScript source") (".tsx" . "TypeScript source") (".jsx" . "React/JSX source")
        (".java" . "Java source") (".kt" . "Kotlin source") (".kts" . "Kotlin script")
        (".scala" . "Scala source")
        (".c" . "C source") (".h" . "C header") (".cpp" . "C++ source") (".cc" . "C++ source")
        (".cxx" . "C++ source") (".hpp" . "C++ header") (".cs" . "C# source")
        (".go" . "Go source") (".rs" . "Rust source") (".swift" . "Swift source")
        (".rb" . "Ruby source") (".php" . "PHP source") (".lua" . "Lua source")
        (".pl" . "Perl source") (".pm" . "Perl module") (".r" . "R source") (".jl" . "Julia source")
        (".hs" . "Haskell source") (".lhs" . "Haskell literate source")
        (".ml" . "OCaml source") (".mli" . "OCaml interface")
        (".fs" . "F# source") (".fsi" . "F# interface") (".fsx" . "F# script")
        (".clj" . "Clojure source") (".cljs" . "ClojureScript source")
        (".ex" . "Elixir source") (".exs" . "Elixir script")
        (".erl" . "Erlang source") (".hrl" . "Erlang header")
        (".scm" . "Scheme source") (".sld" . "Scheme library definition")
        (".lsp" . "Common Lisp source") (".lisp" . "Common Lisp source")
        (".sh" . "Shell script") (".bash" . "Bash script") (".zsh" . "Zsh script")
        (".fish" . "Fish script") (".bat" . "Windows batch script") (".cmd" . "Windows batch script")
        (".ps1" . "PowerShell script") (".psm1" . "PowerShell module") (".dsh" . "dabshell script")
        (".html" . "HTML document") (".htm" . "HTML document") (".css" . "CSS stylesheet")
        (".scss" . "SCSS stylesheet") (".sass" . "Sass stylesheet") (".less" . "Less stylesheet")
        (".xml" . "XML document") (".xsd" . "XML schema") (".xsl" . "XML stylesheet")
        (".xslt" . "XML stylesheet") (".svg" . "SVG image")
        (".json" . "JSON data") (".jsonl" . "JSON Lines data") (".ndjson" . "JSON Lines data")
        (".yaml" . "YAML data") (".yml" . "YAML data") (".toml" . "TOML config")
        (".ini" . "INI config") (".cfg" . "config file") (".conf" . "config file")
        (".env" . "environment file") (".csv" . "CSV data") (".tsv" . "TSV data")
        (".sql" . "SQL script") (".graphql" . "GraphQL document") (".gql" . "GraphQL document")
        (".proto" . "Protocol Buffers definition")
        (".tf" . "Terraform config") (".tfvars" . "Terraform variables") (".nix" . "Nix expression")
        (".vim" . "Vim script") (".el" . "Emacs Lisp")
        (".md" . "Markdown document") (".markdown" . "Markdown document")
        (".rst" . "reStructuredText document") (".tex" . "LaTeX document")
        (".po" . "Gettext translation") (".pot" . "Gettext template")
        (".diff" . "diff file") (".patch" . "patch file") (".log" . "log file") (".txt" . "plain text")
        (".pem" . "PEM data") (".crt" . "certificate") (".cer" . "certificate") (".key" . "private key")))

    ;; a bytevector from strings (ASCII) and byte values
    (define (bytes . parts)
      (apply bytevector-append
             (map (lambda (p) (if (string? p) (string->utf8 p) (bytevector p))) parts)))

    ;; (offset signature label); label #f is RIFF, resolved by its subtype.
    ;; Checked in order; the first match wins.
    (define file-magic
      (list (list 0 (bytes #x7f "ELF") "ELF executable")
            (list 0 (bytes "MZ") "PE executable (Windows)")
            (list 0 (bytes #xcf #xfa #xed #xfe) "Mach-O 64-bit binary")
            (list 0 (bytes #xce #xfa #xed #xfe) "Mach-O 32-bit binary")
            (list 0 (bytes #xca #xfe #xba #xbe) "Java class file")
            (list 0 (bytes 0 "asm") "WebAssembly binary")
            (list 0 (bytes "%PDF-") "PDF document")
            (list 0 (bytes "PK" 3 4) "ZIP archive")
            (list 0 (bytes #x1f #x8b) "GZIP compressed data")
            (list 0 (bytes "BZh") "BZIP2 compressed data")
            (list 0 (bytes #xfd "7zXZ" 0) "XZ compressed data")
            (list 0 (bytes "7z" #xbc #xaf #x27 #x1c) "7-Zip archive")
            (list 0 (bytes "Rar!" #x1a 7) "RAR archive")
            (list 0 (bytes #x89 "PNG\r\n" #x1a "\n") "PNG image")
            (list 0 (bytes #xff #xd8 #xff) "JPEG image")
            (list 0 (bytes "GIF87a") "GIF image")
            (list 0 (bytes "GIF89a") "GIF image")
            (list 0 (bytes "BM") "BMP image")
            (list 0 (bytes "fLaC") "FLAC audio")
            (list 0 (bytes "OggS") "OGG container")
            (list 0 (bytes "ID3") "MP3 audio")
            (list 0 (bytes #xff #xfb) "MP3 audio")
            (list 0 (bytes #x1a #x45 #xdf #xa3) "Matroska/WebM container")
            (list 0 (bytes "PAR1") "Parquet columnar data")
            (list 0 (bytes "SQLite format 3" 0) "SQLite database")
            (list 0 (bytes #xd0 #xcf #x11 #xe0) "OLE2 compound document (legacy Office)")
            (list 0 (bytes "RIFF") #f)
            (list 257 (bytes "ustar") "TAR archive")
            (list 4 (bytes "ftyp") "MPEG-4 container")
            (list 0 (bytes #xef #xbb #xbf) "UTF-8 BOM text")
            (list 0 (bytes #xff #xfe) "UTF-16 LE text")
            (list 0 (bytes #xfe #xff) "UTF-16 BE text")))

    (define (bytes-at? bv offset sig)
      (let ((n (bytevector-length sig)))
        (and (<= (+ offset n) (bytevector-length bv))
             (let loop ((i 0))
               (or (= i n)
                   (and (= (bytevector-u8-ref bv (+ offset i)) (bytevector-u8-ref sig i))
                        (loop (+ i 1))))))))

    (define (u16be bv i) (+ (* 256 (bytevector-u8-ref bv i)) (bytevector-u8-ref bv (+ i 1))))
    (define (u16le bv i) (+ (bytevector-u8-ref bv i) (* 256 (bytevector-u8-ref bv (+ i 1)))))
    (define (u24le bv i) (+ (u16le bv i) (* 65536 (bytevector-u8-ref bv (+ i 2)))))
    (define (u32be bv i) (+ (* 65536 (u16be bv i)) (u16be bv (+ i 2))))

    (define (dims w h) (string-append ", " (number->string w) "x" (number->string h)))

    ;; the first n bytes of a file
    (define (read-head path n)
      (call-with-port (open-binary-input-file path)
        (lambda (in)
          (let ((b (read-bytevector n in)))
            (if (eof-object? b) (bytevector) b)))))

    (define (png-dims h) (if (>= (bytevector-length h) 24) (dims (u32be h 16) (u32be h 20)) ""))
    (define (gif-dims h) (if (>= (bytevector-length h) 10) (dims (u16le h 6) (u16le h 8)) ""))

    (define (webp-dims h)
      (cond ((< (bytevector-length h) 30) "")
            ((bytes-at? h 12 (bytes "VP8X")) (dims (+ (u24le h 24) 1) (+ (u24le h 27) 1)))
            ((bytes-at? h 12 (bytes "VP8 "))
             (dims (bitwise-and (u16le h 26) #x3fff) (bitwise-and (u16le h 28) #x3fff)))
            (else "")))

    ;; JPEG: scan the segments for a start-of-frame marker
    (define (jpeg-dims path)
      (guard (e (#t ""))
        (let* ((data (read-head path 65536))
               (n (bytevector-length data)))
          (let loop ((i 2))
            (if (or (>= i (- n 8)) (not (= (bytevector-u8-ref data i) #xff)))
                ""
                (let ((marker (bytevector-u8-ref data (+ i 1))))
                  (if (memv marker '(#xc0 #xc1 #xc2 #xc3 #xc5 #xc6 #xc7 #xc9 #xca #xcb #xcd #xce #xcf))
                      (dims (u16be data (+ i 7)) (u16be data (+ i 5)))
                      (loop (+ i 2 (u16be data (+ i 2)))))))))))

    ;; ZIP: Office Open XML documents and Java archives are ZIP files
    (define (probe-zip path)
      (guard (e (#t "ZIP archive"))
        (let* ((z (open-input-zip-file path))
               (names (zip-entry-names z)))
          (close-input-zip z)
          (cond ((member "word/document.xml" names) "Word document (.docx)")
                ((member "xl/workbook.xml" names) "Excel workbook (.xlsx)")
                ((member "ppt/presentation.xml" names) "PowerPoint presentation (.pptx)")
                ((let loop ((ns names))
                   (and (pair? ns) (or (string-starts? (car ns) "META-INF/") (loop (cdr ns)))))
                 "Java archive (JAR)")
                (else "ZIP archive")))))

    (define (check-magic header path)
      (let loop ((ms file-magic))
        (and (pair? ms)
             (let ((offset (car (car ms))) (sig (cadr (car ms))) (label (caddr (car ms))))
               (if (not (bytes-at? header offset sig))
                   (loop (cdr ms))
                   (cond ((not label)
                          (cond ((bytes-at? header 8 (bytes "WAVE")) "WAV audio")
                                ((bytes-at? header 8 (bytes "AVI ")) "AVI video")
                                ((bytes-at? header 8 (bytes "WEBP")) (string-append "WebP image" (webp-dims header)))
                                (else "RIFF container")))
                         ((string=? label "PNG image") (string-append label (png-dims header)))
                         ((string=? label "JPEG image") (string-append label (jpeg-dims path)))
                         ((string=? label "GIF image") (string-append label (gif-dims header)))
                         ((string=? label "ZIP archive") (probe-zip path))
                         (else label)))))))

    (define (non-printable-count bv)
      (let loop ((i 0) (n 0))
        (if (= i (bytevector-length bv))
            n
            (let ((b (bytevector-u8-ref bv i)))
              (loop (+ i 1) (if (or (< b 9) (<= #x0e b #x1f) (= b #x7f)) (+ n 1) n))))))

    ;; UTF-8 validity of a header cut from a longer file: a sequence cut
    ;; at the end does not count as invalid
    (define (header-utf8? header truncated)
      (let ((n (bytevector-length header)))
        (or (utf8-valid? header)
            (and truncated
                 (let loop ((k 1))
                   (and (<= k 3) (< k n)
                        (or (and (>= (bytevector-u8-ref header (- n k)) #xc0)
                                 (utf8-valid? header 0 (- n k)))
                            (loop (+ k 1)))))))))

    ;; "encoding, line endings" of a text header
    (define (text-info header truncated)
      (let* ((n (bytevector-length header))
             (enc (cond ((bytes-at? header 0 (bytes #xef #xbb #xbf)) "UTF-8 (BOM)")
                        ((bytes-at? header 0 (bytes #xff #xfe)) "UTF-16 LE")
                        ((bytes-at? header 0 (bytes #xfe #xff)) "UTF-16 BE")
                        ((header-utf8? header truncated)
                         (if (let loop ((i 0)) (or (= i n) (and (< (bytevector-u8-ref header i) #x80) (loop (+ i 1)))))
                             "ASCII"
                             "UTF-8"))
                        (else "Latin-1"))))
        (let loop ((i 0) (crlf 0) (lf 0) (cr 0))
          (if (< i n)
              (let ((b (bytevector-u8-ref header i))
                    (next (and (< (+ i 1) n) (bytevector-u8-ref header (+ i 1)))))
                (cond ((and (= b 13) (eqv? next 10)) (loop (+ i 2) (+ crlf 1) lf cr))
                      ((= b 13) (loop (+ i 1) crlf lf (+ cr 1)))
                      ((= b 10) (loop (+ i 1) crlf (+ lf 1) cr))
                      (else (loop (+ i 1) crlf lf cr))))
              (let ((types (filter-empty-counts (list (cons "CRLF" crlf) (cons "LF" lf) (cons "CR" cr)))))
                (string-append
                 enc ", "
                 (cond ((null? types) "no line endings")
                       ((null? (cdr types)) (string-append (caar types) " line endings"))
                       (else
                        (string-append
                         "mixed line endings ("
                         (string-join* (map (lambda (t) (string-append (car t) ": " (number->string (cdr t))))
                                            types)
                                       ", ")
                         ")")))))))))

    (define (filter-empty-counts types)
      (cond ((null? types) '())
            ((zero? (cdar types)) (filter-empty-counts (cdr types)))
            (else (cons (car types) (filter-empty-counts (cdr types))))))

    (define shebangs
      '(("python" . "Python script") ("ruby" . "Ruby script") ("perl" . "Perl script")
        ("node" . "Node.js script") ("/bash" . "Bash script") ("/zsh" . "Zsh script")
        ("/fish" . "Fish script") ("/sh" . "Shell script") ("env sh" . "Shell script")
        ("env bash" . "Bash script")))

    ;; a type label from content clues of a text header, or #f
    (define (content-heuristic header)
      (and (<= (non-printable-count header) (/ (max (bytevector-length header) 1) 10))
           (let* ((text (utf8->string header))
                  (lines (splitlines text))
                  (first-line (if (null? lines) "" (car lines)))
                  (first (string-strip first-line))
                  (first-512 (string-downcase (substring text 0 (min 512 (string-length text))))))
             (cond
              ((and (string-starts? first-line "#!")
                    (let ((shebang (string-strip (substring first-line 2 (string-length first-line)))))
                      (let loop ((s shebangs))
                        (cond ((null? s) #f)
                              ((string-contains? shebang (caar s)) (cdar s))
                              (else (loop (cdr s))))))))
              ((string-starts? first "<?php") "PHP script")
              ((or (string-contains? first-512 "<!doctype html") (string-contains? first-512 "<html"))
               "HTML document")
              ((string-starts? first "<?xml") "XML document")
              ((string-starts? (string-downcase first) "-----begin") "PEM data")
              ((and (string-starts? first "---")
                    (string-contains? (substring text 0 (min 256 (string-length text))) ":"))
               "YAML data")
              ((let ((stripped (string-lstrip text)))
                 (and (> (string-length stripped) 0)
                      (memv (string-ref stripped 0) '(#\{ #\[))
                      (guard (e (#t #f)) (json-parse text) #t)))
               "JSON data")
              (else #f)))))

    ;; the description of one file
    (define (describe-file path)
      (cond
       ((not (path-exists?* path)) "ERROR: no such file or directory")
       ((directory? path) "directory")
       ((symlink? path) (string-append "symbolic link to " (or (read-symlink path) "?")))
       (else
        (let ((size (safe-size path)))
          (if (zero? size)
              "empty file"
              (let ((header (guard (e (#t (report-error e))) (read-head path 8192))))
                (if (string? header)
                    (string-append "ERROR: " header)
                    (let* ((truncated (> size (bytevector-length header)))
                           (base (string-downcase (path-basename path)))
                           (ext (assoc (string-downcase (cdr (path-splitext path))) file-extensions)))
                      (cond
                       ((check-magic header path))
                       ((or (string=? base "dockerfile") (string-starts? base "dockerfile.")) "Dockerfile")
                       (ext (string-append (cdr ext) ", " (text-info header truncated)))
                       ((content-heuristic header)
                        => (lambda (label) (string-append label ", " (text-info header truncated))))
                       (else
                        (let ((ratio (/ (non-printable-count header) (bytevector-length header))))
                          (if (> ratio 1/10)
                              (string-append "binary data (" (format-fixed (inexact (* 100 ratio)) 0)
                                             "% non-printable bytes)")
                              (string-append "text, " (text-info header truncated))))))))))))))

    (define-command "file" "<file>...   : detect and describe the type of each file"
      (lambda (sh args)
        (if (null? args)
            (err sh "ERR: file requires at least one argument")
            (for-each (lambda (path) (out sh (path-basename path) ": " (describe-file path)))
                      (collect-files sh args)))))

    ;; ------------------------------------------------------------------
    ;; to-crlf, to-lf, to-utf8, to-utf8-bom, to-latin1

    (define utf8-bom (bytevector #xef #xbb #xbf))

    ;; decode raw bytes: (values text encoding) or (values #f 'utf-16)
    (define (decode-text raw)
      (let ((enc (detect-file-encoding raw)))
        (values (and (not (eq? enc 'utf-16)) (decode-bytes raw)) enc)))

    ;; encode text with an encoding found by detect-file-encoding
    (define (encode-text text enc)
      (case enc
        ((utf-8-sig) (bytevector-append utf8-bom (string->utf8 text)))
        ((utf-8) (string->utf8 text))
        (else (string->latin1 text))))

    (define (normalize-newlines text) (string-replace* (string-replace* text "\r\n" "\n") "\r" "\n"))

    ;; Python's UnicodeEncodeError message for text that is not Latin-1
    (define (latin1-error text)
      (let* ((n (string-length text))
             (bad? (lambda (i) (> (char->integer (string-ref text i)) 255)))
             (start (let loop ((i 0)) (if (bad? i) i (loop (+ i 1)))))
             (end (let loop ((i start)) (if (and (< i n) (bad? i)) (loop (+ i 1)) i))))
        (string-append
         "'latin-1' codec can't encode "
         (if (= end (+ start 1))
             (let* ((code (char->integer (string-ref text start)))
                    (hex (number->string code 16))
                    (width (if (> code #xffff) 8 4)))
               (string-append "character '\\" (if (> code #xffff) "U" "u")
                              (make-string (- width (string-length hex)) #\0) hex
                              "' in position " (number->string start)))
             (string-append "characters in position " (number->string start) "-" (number->string (- end 1))))
         ": ordinal not in range(256)")))

    ;; convert files in place; transform: raw -> (values new-raw skip-reason)
    (define (define-convert name help transform)
      (define-command name help
        (lambda (sh args)
          (if (null? args)
              (err sh "ERR: " name " requires at least one file")
              (for-each
               (lambda (path)
                 (cond
                  ((not (path-exists?* path)) (err sh "ERR: " path " not found"))
                  ((directory? path) (err sh "ERR: " path " is a directory"))
                  (else
                   (let ((raw (guard (e (#t (err sh "ERR: " path ": " (report-error e)) #f))
                                (read-file-bytes path))))
                     (cond
                      ((not raw) #f)
                      ((binary-bytes? raw) (err sh "skipped " path ": binary file"))
                      (else
                       (let-values (((new-raw reason) (transform raw)))
                         (cond (reason (out sh "skipped " path ": " reason))
                               ((equal? new-raw raw) (out sh "unchanged " path))
                               ((guard (e (#t (err sh "ERR: " path ": " (report-error e)) #f))
                                  (write-file-bytes path new-raw)
                                  #t)
                                (out sh "converted " path))))))))))
               (collect-files sh args))))))

    ;; a transform of the decoded text, keeping the file's encoding
    (define (text-transform f)
      (lambda (raw)
        (let-values (((text enc) (decode-text raw)))
          (if text
              (values (encode-text (f text) enc) #f)
              (values raw "UTF-16 not supported")))))

    ;; a transform that re-encodes the decoded text
    (define (encoding-transform encode)
      (lambda (raw)
        (let-values (((text enc) (decode-text raw)))
          (if text (encode raw text) (values raw "UTF-16 not supported")))))

    (define-convert "to-crlf" "<file>...   : convert line endings to CRLF (Windows) in place"
      (text-transform (lambda (text) (string-replace* (normalize-newlines text) "\n" "\r\n"))))

    (define-convert "to-lf" "<file>...   : convert line endings to LF (Unix) in place"
      (text-transform normalize-newlines))

    (define-convert "to-utf8" "<file>...   : convert encoding to UTF-8 (no BOM) in place"
      (encoding-transform (lambda (raw text) (values (string->utf8 text) #f))))

    (define-convert "to-utf8-bom" "<file>...   : convert encoding to UTF-8 with BOM in place"
      (encoding-transform (lambda (raw text) (values (bytevector-append utf8-bom (string->utf8 text)) #f))))

    (define-convert "to-latin1" "<file>...   : convert encoding to Latin-1 (ISO-8859-1) in place"
      (encoding-transform
       (lambda (raw text)
         (if (let loop ((i 0))
               (and (< i (string-length text))
                    (or (> (char->integer (string-ref text i)) 255) (loop (+ i 1)))))
             (values raw (string-append "contains characters not representable in Latin-1: "
                                        (latin1-error text)))
             (values (string->latin1 text) #f)))))))
