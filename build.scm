;; Builds the native dsh executables with dabscm native's scmc.
;;
;;   scm build.scm [host|windows|linux|linux-arm64|all|deb] [--scmc PATH] [--debug]
;;                 [--no-build]
;;
;; host (default) builds build/dsh(.exe) for this machine; the others
;; cross-compile into dist/<target>/dsh(.exe). scmc is taken from --scmc,
;; else $SCMC, else ../dabscm/scm-native/build/scmc(.exe), else scmc on the
;; PATH (the dabscm-native package).
;;
;; deb builds both Linux executables and packages each as
;; dist/dabshell_<version>_<amd64|arm64>.deb (pure Scheme, see (scm deb));
;; --no-build packages the executables already in dist/. Install with
;; `sudo apt install ./dabshell_<version>_amd64.deb`: dsh goes to /usr/bin
;; and is registered in /etc/shells. The version comes from bin/dsh.scm,
;; the maintainer from git config user.name / user.email.

(import (scheme base)
        (scheme char)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (scm crypto)
        (scm datetime)
        (scm deb)
        (scm fs)
        (scm system))

(define root (directory-name (absolute-path (car (command-line)))))
(define windows-host? (eq? (sys-platform) 'windows))

(define (say . xs) (for-each display xs) (newline))

(define (option name args)
  (let ((m (member name args)))
    (and m (pair? (cdr m)) (cadr m))))

(define (find-scmc args)
  (or (option "--scmc" args)
      (let ((v (get-environment-variable "SCMC"))) (and v (not (string=? v "")) v))
      (let ((p (join-path root "../dabscm/scm-native/build"
                          (if windows-host? "scmc.exe" "scmc"))))
        (and (file-exists? p) (normalized-path p)))
      (which "scmc")
      (error "scmc not found; pass --scmc PATH")))

;; (name triple exe-name output-dir); triple #f for the host
(define targets
  `(("host" #f ,(if windows-host? "dsh.exe" "dsh") "build")
    ("windows" "x86_64-windows" "dsh.exe" "dist/windows-x86_64")
    ("linux" "x86_64-linux-musl" "dsh" "dist/linux-x86_64")
    ("linux-arm64" "aarch64-linux-musl" "dsh" "dist/linux-arm64")))

(define (target-exe target)
  (join-path root (list-ref target 3) (list-ref target 2)))

(define (build scmc target debug?)
  (let* ((dir (join-path root (list-ref target 3)))
         (out (target-exe target))
         (argv (append (list scmc (join-path root "bin/dsh.scm")
                             "-I" (join-path root "src")
                             "-o" out)
                       (if (list-ref target 1) (list "--target" (list-ref target 1)) '())
                       (if debug? '() '("--strip")))))
    (unless (directory-exists? dir) (make-directory dir))
    (say "building " out)
    (let ((rc (run-program argv)))
      (unless (eqv? rc 0)
        (say "build failed for " (car target))
        (exit 1)))))

;; ------------------------------------------------------------------
;; Debian packages

(define (read-bytes path)
  (call-with-port (open-binary-input-file path)
    (lambda (in)
      (let ((out (open-output-bytevector)))
        (let loop ()
          (let ((chunk (read-bytevector 65536 in)))
            (unless (eof-object? chunk)
              (write-bytevector chunk out)
              (loop))))
        (get-output-bytevector out)))))

(define (string-trim s)
  (let loop ((start 0) (end (string-length s)))
    (cond ((and (< start end) (char-whitespace? (string-ref s start))) (loop (+ start 1) end))
          ((and (< start end) (char-whitespace? (string-ref s (- end 1)))) (loop start (- end 1)))
          (else (substring s start end)))))

;; trimmed stdout of a command run in the repository, or #f if it fails
(define (capture . argv)
  (let ((r (guard (e (#t #f)) (run-program/capture argv `((work-dir ,root))))))
    (and (pair? r) (eqv? (car r) 0) (string-trim (cadr r)))))

;; the version string of (define version "x.y.z") in bin/dsh.scm
(define (dsh-version)
  (let ((src (utf8->string (read-bytes (join-path root "bin/dsh.scm"))))
        (key "(define version \""))
    (let loop ((i 0))
      (cond ((> (+ i (string-length key)) (string-length src))
             (error "no (define version ...) in bin/dsh.scm"))
            ((string=? (substring src i (+ i (string-length key))) key)
             (let* ((start (+ i (string-length key)))
                    (end (let find ((j start))
                           (if (char=? (string-ref src j) #\") j (find (+ j 1))))))
               (substring src start end)))
            (else (loop (+ i 1)))))))

(define (maintainer)
  (let ((name (capture "git" "config" "user.name"))
        (mail (capture "git" "config" "user.email")))
    (cond ((and name mail (not (string=? name "")) (not (string=? mail "")))
           (string-append name " <" mail ">"))
          (else (say "git config user.name / user.email are not set") (exit 1)))))

(define postinst
  "#!/bin/sh
set -e
if [ \"$1\" = configure ] && command -v add-shell >/dev/null 2>&1; then
    add-shell /usr/bin/dsh
fi
")

(define postrm
  "#!/bin/sh
set -e
if [ \"$1\" = remove ] || [ \"$1\" = purge ]; then
    if command -v remove-shell >/dev/null 2>&1; then
        remove-shell /usr/bin/dsh
    fi
fi
")

(define (package-deb target arch version maint mtime)
  (let ((exe (target-exe target)))
    (unless (file-exists? exe)
      (say exe " not found (build without --no-build)")
      (exit 1))
    (let* ((doc "usr/share/doc/dabshell/")
           (data (list (list "usr/bin/dsh" #o755 (read-bytes exe))
                       (list (string-append doc "README.md") #o644
                             (read-bytes (join-path root "README.md")))))
           (installed-kib
            (+ (apply + (map (lambda (e) (quotient (+ (bytevector-length (entry-content e)) 1023) 1024))
                             data))
               (- (length (add-parent-dirs data)) (length data))))
           (control
            (string-append "Package: dabshell\n"
                           "Version: " version "\n"
                           "Architecture: " arch "\n"
                           "Maintainer: " maint "\n"
                           "Installed-Size: " (number->string installed-kib) "\n"
                           "Section: shells\n"
                           "Priority: optional\n"
                           "Homepage: https://github.com/damianbrunold/dabshell\n"
                           "Description: lightweight, cross-platform interactive shell\n"
                           " dabshell (dsh) is a simple, scriptable shell with a syntax that is\n"
                           " intentionally less complex than bash. It has built-in file, text,\n"
                           " awk, json, archive and fetch commands, a pager and an editor, and\n"
                           " works the same on Linux and Windows. Statically linked.\n"))
           (md5sums
            (apply string-append
                   (map (lambda (e) (string-append (md5-hash (entry-content e)) "  " (entry-name e) "\n"))
                        data)))
           (control-entries
            (list (list "control" #o644 (string->utf8 control))
                  (list "md5sums" #o644 (string->utf8 md5sums))
                  (list "postinst" #o755 (string->utf8 postinst))
                  (list "postrm" #o755 (string->utf8 postrm))))
           (deb (join-path root "dist" (string-append "dabshell_" version "_" arch ".deb"))))
      (call-with-port (open-binary-output-file deb)
        (lambda (out) (write-bytevector (deb-bytevector control-entries data mtime) out)))
      (say "wrote " deb " (" installed-kib " KiB installed)"))))

(define (make-debs scmc args)
  (let ((linux (list (assoc "linux" targets) "amd64"))
        (arm64 (list (assoc "linux-arm64" targets) "arm64"))
        (version (dsh-version))
        (maint (maintainer))
        ;; the last commit's time, so rebuilding a commit gives the same package
        (mtime (or (let ((t (capture "git" "log" "-1" "--format=%ct"))) (and t (string->number t)))
                   (quotient (timestamp) 1000))))
    (for-each (lambda (t)
                (unless (member "--no-build" args) (build (scmc) (car t) (member "--debug" args)))
                (package-deb (car t) (cadr t) version maint mtime))
              (list linux arm64))))

;; ------------------------------------------------------------------

(define (main args)
  (let* ((which-target (if (and (pair? args) (not (string-starts-with? (car args) "--")))
                           (car args)
                           "host"))
         (debug? (member "--debug" args)))
    (unless (directory-exists? (join-path root "dist")) (make-directory (join-path root "dist")))
    (if (string=? which-target "deb")
        (make-debs (lambda () (find-scmc args)) args)
        (let ((scmc (find-scmc args))
              (selected (if (string=? which-target "all")
                            (cdr targets)
                            (let ((t (assoc which-target targets)))
                              (unless t (say "unknown target " which-target) (exit 2))
                              (list t)))))
          (for-each (lambda (t) (build scmc t debug?)) selected)))
    0))

(define (string-starts-with? s p)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(exit (main (cdr (command-line))))
