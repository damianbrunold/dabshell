;; Builds the native dsh executables with dabscm native's scmc.
;;
;;   scm build.scm [host|windows|linux|linux-arm64|all] [--scmc PATH] [--debug]
;;
;; host (default) builds build/dsh(.exe) for this machine; the others
;; cross-compile into dist/<target>/dsh(.exe). scmc is taken from --scmc,
;; else $SCMC, else ../dabscm/scm-native/build/scmc(.exe), else scmc on the
;; PATH (the dabscm-native package).

(import (scheme base)
        (scheme process-context)
        (scheme write)
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

(define (build scmc target debug?)
  (let* ((dir (join-path root (list-ref target 3)))
         (out (join-path dir (list-ref target 2)))
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

(define (main args)
  (let* ((scmc (find-scmc args))
         (which-target (if (and (pair? args) (not (string-starts-with? (car args) "--")))
                           (car args)
                           "host"))
         (debug? (member "--debug" args))
         (selected (if (string=? which-target "all")
                       (cdr targets)
                       (let ((t (assoc which-target targets)))
                         (unless t (say "unknown target " which-target) (exit 2))
                         (list t)))))
    (unless (directory-exists? (join-path root "dist")) (make-directory (join-path root "dist")))
    (for-each (lambda (t) (build scmc t debug?)) selected)
    0))

(define (string-starts-with? s p)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(exit (main (cdr (command-line))))
