(import (scheme base) (scheme process-context) (scm fs) (scm module) (scm test))
(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))
(import (dabshell util) (dabshell core) (dabshell keys) (dabshell less) (dabshell testing))

(test-runner-factory scm-test-runner)
(test-begin "less")

(define big (apply string-append
                   (let loop ((i 0) (acc '()))
                     (if (= i 200)
                         (reverse acc)
                         (loop (+ i 1) (cons (string-append "line" (number->string i) "\n") acc))))))

;; a key source replaying keys, then q forever
(define (feed keys)
  (lambda ()
    (if (null? keys)
        #\q
        (let ((k (car keys))) (set! keys (cdr keys)) k))))

;; the first line number of the last status line after keys on big.txt
(define (less-status t keys)
  (write-file t "big.txt" big)
  (let* ((o (with-key-source (feed keys) (lambda () (out-raw t "less big.txt"))))
         (i (let loop ((i (- (string-length o) 6)))
              (cond ((< i 0) #f)
                    ((string=? (substring o i (+ i 6)) "lines ") i)
                    (else (loop (- i 1))))))
         (j (let loop ((j (+ i 6))) (if (char=? (string-ref o j) #\-) j (loop (+ j 1))))))
    (substring o (+ i 6) j)))

(test-group "test_less_short_file_prints_directly"
  (with-shell (lambda (t)
    (write-file t "short.txt" "one\ntwo\nthree\n")
    (let ((o (out t "less short.txt")))
      (test-assert (string-contains? o "one"))
      (test-assert (string-contains? o "three"))))))

(test-group "test_less_missing_file"
  (with-shell (lambda (t)
    (test-assert (string-contains? (err t "less nope.txt") "ERR")))))

(test-group "test_less_pager_quits_on_q"
  (with-shell (lambda (t)
    (write-file t "big.txt" big)
    (test-assert (string-contains? (with-key-source (lambda () #\q)
                                     (lambda () (out-raw t "less big.txt")))
                                   "lines 1-")))))

(test-group "test_less_arrow_keys_scroll"
  (with-shell (lambda (t)
    (test-equal "3" (less-status t '(down down)))
    (test-equal "2" (less-status t '(down down up))))))

(test-group "test_less_page_keys_scroll"
  (with-shell (lambda (t)
    (test-assert (> (parse-int (less-status t '(page-down))) 2))
    (test-equal "1" (less-status t '(page-down page-up)))
    (test-equal "1" (less-status t '(end home))))))

(test-group "test_less_enter_scrolls_and_ctrl_c_quits"
  (with-shell (lambda (t)
    (test-equal "2" (less-status t '(cr ctrl-c #\j))))))

(test-group "less_reads_stdin_and_directory_error"
  (with-shell (lambda (t)
    (make-dirs (file-path t "d"))
    (test-assert (string-contains? (err t "less d") "is a directory"))
    (test-equal "a" (out t "echo a | less")))))

(test-end "less")
