;; Runs all tests/test_*.scm on the JVM and/or compiled natively.
;;
;;   scm run-tests.scm [java|native|all] [name ...]
;;
;; java runs the tests with SCM_JAVA (default ../dabscm/scm-java/scm.jar);
;; native compiles each test file with scmc (SCMC, default
;; ../dabscm/scm-native/build/scmc(.exe), else scmc on the PATH) into build/
;; and runs it. Names select test files (test_core, core or test_core.scm).
;; The exit code is 1 when a test file failed.

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (srfi 132)
        (scm fs)
        (scm system))

(define root (directory-name (absolute-path (car (command-line)))))
(define windows? (eq? (sys-platform) 'windows))

(define (say . xs) (for-each display xs) (newline))

(define (env name default)
  (let ((v (get-environment-variable name)))
    (if (and v (not (string=? v ""))) v default)))

(define (starts? s p) (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))
(define (ends? s p) (and (>= (string-length s) (string-length p))
                         (string=? (substring s (- (string-length s) (string-length p))) p)))
(define (strip-scm s) (if (ends? s ".scm") (substring s 0 (- (string-length s) 4)) s))

(define (java-command)
  (list "java" "-jar" (env "SCM_JAVA" (join-path root "../dabscm/scm-java/scm.jar"))))

(define (scmc-command)
  (or (let ((v (env "SCMC" #f))) v)
      (let ((p (join-path root (if windows? "../dabscm/scm-native/build/scmc.exe"
                                   "../dabscm/scm-native/build/scmc"))))
        (and (file-exists? p) p))
      (which "scmc")
      (error "scmc not found; set SCMC")))

(define (test-files names)
  (let ((all (list-sort string<?
                        (filter-list (lambda (f) (and (starts? f "test_") (ends? f ".scm")))
                                     (directory-files (join-path root "tests"))))))
    (if (null? names)
        all
        (filter-list (lambda (f)
                       (let ((base (strip-scm f)))
                         (or (member base names) (member (substring base 5 (string-length base)) names)
                             (member f names))))
                     all))))

(define (filter-list pred lst)
  (cond ((null? lst) '()) ((pred (car lst)) (cons (car lst) (filter-list pred (cdr lst))))
        (else (filter-list pred (cdr lst)))))

(define failures '())

(define (run! label argv)
  (say "== " label)
  (let ((rc (run-program argv `((work-dir ,root)))))
    (unless (eqv? rc 0)
      (set! failures (cons label failures)))))

(define (run-java file)
  (run! (string-append "java " file) (append (java-command) (list (join-path root "tests" file)))))

(define (run-native file)
  (let* ((exe (join-path root "build" (string-append (strip-scm file) (if windows? ".exe" ""))))
         (rc (run-program (list (scmc-command) (join-path root "tests" file)
                                "-I" (join-path root "src") "-I" (join-path root "tests")
                                "-o" exe))))
    (if (eqv? rc 0)
        (run! (string-append "native " file) (list exe))
        (begin (say "== native " file ": compilation failed")
               (set! failures (cons (string-append "native " file " (compile)") failures))))))

(define (main args)
  (let* ((mode (if (and (pair? args) (member (car args) '("java" "native" "all"))) (car args) "all"))
         (names (if (and (pair? args) (member (car args) '("java" "native" "all"))) (cdr args) args))
         (files (test-files names)))
    (unless (directory-exists? (join-path root "build")) (make-directory (join-path root "build")))
    (when (member mode '("java" "all")) (for-each run-java files))
    (when (member mode '("native" "all")) (for-each run-native files))
    (if (null? failures)
        (begin (say "all test files passed") 0)
        (begin (say "FAILED: ") (for-each (lambda (f) (say "  " f)) (reverse failures)) 1))))

(exit (main (cdr (command-line))))
