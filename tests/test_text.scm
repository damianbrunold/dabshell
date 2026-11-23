;; Tests of the text commands: cat, diff, wc, tail, head, lines, grep,
;; sort, uniq, cut, tee, watch, xargs, date (port of TestSortUniqCutTee,
;; TestCatHeadTail, TestGrepWcDiff, TestDate, TestXargs and the text
;; command tests of TestGlob of tests/test_dabshell.py).

(import (scheme base) (scheme char) (scheme file) (scheme process-context)
        (scm fs) (scm module) (scm string) (scm test) (srfi 19))
(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))
(import (dabshell util) (dabshell core) (dabshell builtins) (dabshell keys)
        (dabshell text) (dabshell testing))

(define (contains? s sub) (string-contains? s sub))
(define (matches? s re) (and (regex-search s re) #t))
(define (lines-of s) (splitlines s))
(define (count-of s sub) (string-count-of s sub))

;; with-shell with the files of a test class's setUp
(define (with-files files proc)
  (with-shell (lambda (t)
                (for-each (lambda (f) (write-file t (car f) (cdr f))) files)
                (proc t))))

;; the result of tail-bytes for the bytes written to a temporary file
(define (tail-of bv n)
  (with-shell (lambda (t) (tail-bytes (write-bytes t "tail.bin" bv) n))))

(define (str->bv s) (string->utf8 s))

;; a thunk returning the given keys one after another (then Ctrl+C)
(define (keys . ks)
  (lambda () (if (null? ks) 'ctrl-c (let ((k (car ks))) (set! ks (cdr ks)) k))))

(define (iota* from to) (if (>= from to) '() (cons from (iota* (+ from 1) to))))
(define (string-pad-left* s n) (if (< (string-length s) n) (string-pad-left* (string-append "0" s) n) s))

(define twenty
  (string-append (apply string-append (map (lambda (i) (string-append "line" (number->string i) "\n"))
                                           (iota* 1 21)))))

(test-runner-factory scm-test-runner)
(test-begin "text")

;; ---------------------------------------------------------------------
(test-group "TestSortUniqCutTee"
  (test-group "test_sort_basic"
    (with-shell (lambda (t)
      (write-file t "a.txt" "banana\napple\ncherry\n")
      (test-equal '("apple" "banana" "cherry") (lines-of (out t "sort a.txt"))))))
  (test-group "test_sort_reverse"
    (with-shell (lambda (t)
      (write-file t "a.txt" "banana\napple\ncherry\n")
      (test-equal '("cherry" "banana" "apple") (lines-of (out t "sort -r a.txt"))))))
  (test-group "test_sort_numeric"
    (with-shell (lambda (t)
      (write-file t "n.txt" "10\n2\n1\n20\n")
      (test-equal '("1" "2" "10" "20") (lines-of (out t "sort -n n.txt"))))))
  (test-group "test_sort_unique"
    (with-shell (lambda (t)
      (write-file t "a.txt" "b\na\nb\nc\na\n")
      (test-equal '("a" "b" "c") (lines-of (out t "sort -u a.txt"))))))
  (test-group "test_sort_key"
    (with-shell (lambda (t)
      (write-file t "a.txt" "z 1\ny 2\nx 3\n")
      (test-equal '("z 1" "y 2" "x 3") (lines-of (out t "sort -k 2 a.txt"))))))
  (test-group "test_sort_pipe"
    (with-shell (lambda (t)
      (write-file t "a.txt" "c\na\nb\n")
      (test-equal '("a" "b" "c") (lines-of (out t "cat a.txt | sort"))))))
  (test-group "test_sort_numeric_non_numbers_last"
    (with-shell (lambda (t)
      (write-file t "n.txt" "x\n10\n2.5\n-1\n")
      (test-equal '("-1" "2.5" "10" "x") (lines-of (out t "sort -n n.txt")))
      (test-equal '("x" "10" "2.5" "-1") (lines-of (out t "sort -n -r n.txt"))))))
  (test-group "test_sort_errors"
    (with-shell (lambda (t)
      (test-assert (contains? (err t "sort -k") "requires an argument"))
      (test-assert (contains? (err t "sort -k x") "invalid field 'x'"))
      (test-assert (contains? (err t "sort -x") "unknown option '-x'"))
      (test-assert (contains? (err t "sort missing.txt") "not found")))))

  (test-group "test_uniq_basic"
    (with-shell (lambda (t)
      (write-file t "u.txt" "a\na\nb\nb\nb\nc\n")
      (test-equal '("a" "b" "c") (lines-of (out t "uniq u.txt"))))))
  (test-group "test_uniq_count"
    (with-shell (lambda (t)
      (write-file t "u.txt" "a\na\nb\nb\nb\nc\n")
      (test-equal '(("2" "a") ("3" "b") ("1" "c"))
                  (map string-split-ws (lines-of (out t "uniq -c u.txt"))))
      (test-equal "      2 a" (car (lines-of (out-raw t "uniq -c u.txt")))))))
  (test-group "test_uniq_only_dups"
    (with-shell (lambda (t)
      (write-file t "u.txt" "a\na\nb\nc\nc\n")
      (test-equal '("a" "c") (lines-of (out t "uniq -d u.txt"))))))
  (test-group "test_uniq_only_unique"
    (with-shell (lambda (t)
      (write-file t "u.txt" "a\na\nb\nc\nc\n")
      (test-equal '("b") (lines-of (out t "uniq -u u.txt"))))))
  (test-group "test_uniq_ignore_case"
    (with-shell (lambda (t)
      (write-file t "u.txt" "a\nA\nb\n")
      (test-equal '("a" "b") (lines-of (out t "uniq -i u.txt"))))))
  (test-group "test_uniq_pipe"
    (with-shell (lambda (t)
      (write-file t "u.txt" "a\na\nb\nb\nc\n")
      (test-equal '("a" "b" "c") (lines-of (out t "cat u.txt | uniq"))))))

  (test-group "test_cut_fields_default_tab"
    (with-shell (lambda (t)
      (write-file t "t.txt" "a\tb\tc\nd\te\tf\n")
      (test-equal '("b" "e") (lines-of (out t "cut -f 2 t.txt"))))))
  (test-group "test_cut_fields_custom_delim"
    (with-shell (lambda (t)
      (write-file t "c.txt" "a,b,c\nd,e,f\n")
      (test-equal '("a,c" "d,f") (lines-of (out t "cut -d , -f 1,3 c.txt"))))))
  (test-group "test_cut_fields_range"
    (with-shell (lambda (t)
      (write-file t "c.txt" "a,b,c,d,e\n")
      (test-equal '("b,c,d") (lines-of (out t "cut -d , -f 2-4 c.txt"))))))
  (test-group "test_cut_fields_open_range"
    (with-shell (lambda (t)
      (write-file t "c.txt" "a,b,c,d,e\n")
      (test-equal '("c,d,e") (lines-of (out t "cut -d , -f 3- c.txt"))))))
  (test-group "test_cut_chars"
    (with-shell (lambda (t)
      (write-file t "c.txt" "abcdef\nghijkl\n")
      (test-equal '("bcd" "hij") (lines-of (out t "cut -c 2-4 c.txt"))))))
  (test-group "test_cut_requires_one_of_f_c"
    (with-shell (lambda (t)
      (test-assert (contains? (err t "cut a.txt") "ERR")))))
  (test-group "test_cut_invalid_ranges"
    (with-shell (lambda (t)
      (write-file t "c.txt" "abc\n")
      (test-equal "ERR: cut: invalid range '3-1'" (err t "cut -c 3-1 c.txt"))
      (test-equal "ERR: cut: invalid literal for int() with base 10: 'x'" (err t "cut -c x c.txt"))
      (test-equal "ERR: cut: empty separator" (err t "cut -d '' -f 1 c.txt")))))

  (test-group "test_tee_writes_file_and_stdout"
    (with-shell (lambda (t)
      (write-file t "in.txt" "hello\nworld\n")
      (test-equal '("hello" "world") (lines-of (out t "cat in.txt | tee out.txt")))
      (test-equal "hello\nworld\n" (read-text t "out.txt")))))
  (test-group "test_tee_multiple_files"
    (with-shell (lambda (t)
      (write-file t "in.txt" "data\n")
      (out t "cat in.txt | tee a.txt b.txt")
      (test-equal "data\n" (read-text t "a.txt"))
      (test-equal "data\n" (read-text t "b.txt")))))
  (test-group "test_tee_append"
    (with-shell (lambda (t)
      (write-file t "out.txt" "first\n")
      (write-file t "in.txt" "second\n")
      (out t "cat in.txt | tee -a out.txt")
      (test-equal "first\nsecond\n" (read-text t "out.txt"))))))

;; ---------------------------------------------------------------------
(test-group "TestCatHeadTail"
  (define (with-twenty proc) (with-files (list (cons "twenty.txt" twenty)) proc))
  (test-group "test_cat_full_file"
    (with-twenty (lambda (t)
      (write-file t "simple.txt" "hello\nworld\n")
      (test-equal "hello\nworld" (out t "cat simple.txt")))))
  (test-group "test_cat_missing_file_gives_error"
    (with-twenty (lambda (t)
      (test-assert (contains? (err t "cat missing.txt") "ERR")))))
  (test-group "test_cat_directory_gives_error"
    (with-twenty (lambda (t)
      (make-dirs (file-path t "sub"))
      (test-assert (contains? (err t "cat sub") "is a directory")))))
  (test-group "test_cat_latin1_fallback"
    (with-twenty (lambda (t)
      (write-bytes t "l1.txt" (bytevector 104 233 10))
      (test-equal "h\xE9;" (out t "cat l1.txt")))))
  (test-group "test_cat_keeps_crlf"
    (with-twenty (lambda (t)
      (write-file t "crlf.txt" "a\r\nb\r\n")
      (test-equal "a\r\nb\r\n" (out-raw t "cat crlf.txt")))))
  (test-group "test_head_default_20"
    (with-twenty (lambda (t)
      (let ((lines (lines-of (out t "head twenty.txt"))))
        (test-equal 20 (length lines))
        (test-equal "line1" (car lines))))))
  (test-group "test_head_n_5"
    (with-twenty (lambda (t)
      (let ((lines (lines-of (out t "head -n 5 twenty.txt"))))
        (test-equal 5 (length lines))
        (test-equal "line5" (list-ref lines 4))))))
  (test-group "test_head_lines_option"
    (with-twenty (lambda (t)
      (test-equal 3 (length (lines-of (out t "head --lines=3 twenty.txt")))))))
  (test-group "test_head_pipe"
    (with-twenty (lambda (t)
      (test-equal '("line1" "line2") (lines-of (out t "cat twenty.txt | head -n 2"))))))
  (test-group "test_head_invalid_count"
    (with-twenty (lambda (t)
      (test-equal "ERR: invalid literal for int() with base 10: 'x'" (err t "head -n x twenty.txt"))
      (test-equal "ERR: head: -n requires an argument" (err t "head twenty.txt -n")))))
  (test-group "test_tail_default_20"
    (with-twenty (lambda (t)
      (let ((lines (lines-of (out t "tail twenty.txt"))))
        (test-equal 20 (length lines))
        (test-equal "line20" (list-ref lines 19))))))
  (test-group "test_tail_n_3"
    (with-twenty (lambda (t)
      (let ((lines (lines-of (out t "tail -n 3 twenty.txt"))))
        (test-equal 3 (length lines))
        (test-equal "line18" (car lines))
        (test-equal "line20" (list-ref lines 2))))))
  (test-group "test_tail_fewer_lines_than_n"
    (with-twenty (lambda (t)
      (write-file t "tiny.txt" "a\nb\n")
      (test-equal '("a" "b") (lines-of (out t "tail -n 10 tiny.txt"))))))
  (test-group "test_tail_pipe"
    (with-twenty (lambda (t)
      (test-equal '("line19" "line20") (lines-of (out t "cat twenty.txt | tail -n 2")))
      ;; Python printed everything for -n 0 (lines[-0:])
      (test-equal "" (out t "cat twenty.txt | tail -n 0")))))
  (test-group "test_tail_follow"
    (with-twenty (lambda (t)
      (let ((path (file-path t "twenty.txt")))
        ;; the first key poll appends a line, the second one quits
        (with-key-source
         (let ((n 0))
           (lambda ()
             (set! n (+ n 1))
             (cond ((= n 1)
                    (let ((p (open-output-file path 'append))) (write-string "line21\n" p) (close-port p))
                    #f)
                   (else #\q))))
         (lambda ()
           (test-equal '("line19" "line20" "line21") (lines-of (out t "tail -n 2 -f twenty.txt")))))))))

  ;; _tail_bytes unit tests
  (test-group "test_tail_bytes_empty"
    (test-equal (bytevector) (tail-of (bytevector) 5)))
  (test-group "test_tail_bytes_n_zero"
    (test-equal (bytevector) (tail-of (str->bv "a\nb\n") 0)))
  (test-group "test_tail_bytes_exact_fit"
    (test-equal (str->bv "a\nb\nc\n") (tail-of (str->bv "a\nb\nc\n") 3)))
  (test-group "test_tail_bytes_more_than_file"
    (test-equal (str->bv "a\nb\n") (tail-of (str->bv "a\nb\n") 10)))
  (test-group "test_tail_bytes_no_trailing_newline"
    (test-equal (str->bv "c") (tail-of (str->bv "a\nb\nc") 1)))
  (test-group "test_tail_bytes_crlf"
    (test-equal (str->bv "b\r\nc\r\n") (tail-of (str->bv "a\r\nb\r\nc\r\n") 2)))
  (test-group "test_tail_bytes_cross_chunk"
    (let ((lines (lambda (from to)
                   (apply string-append
                          (map (lambda (i) (string-append "line" (string-pad-left* (number->string i) 5) "\n"))
                               (iota* from to))))))
      (test-equal (str->bv (lines 1996 2001)) (tail-of (str->bv (lines 1 2001)) 5))))

  ;; lines
  (test-group "test_lines_single"
    (with-twenty (lambda (t) (test-equal '("line3") (lines-of (out t "lines 3 twenty.txt"))))))
  (test-group "test_lines_range"
    (with-twenty (lambda (t)
      (test-equal '("line5" "line6" "line7" "line8") (lines-of (out t "lines 5:8 twenty.txt"))))))
  (test-group "test_lines_open_start"
    (with-twenty (lambda (t)
      (test-equal '("line1" "line2" "line3") (lines-of (out t "lines :3 twenty.txt"))))))
  (test-group "test_lines_open_end"
    (with-twenty (lambda (t)
      (test-equal '("line18" "line19" "line20") (lines-of (out t "lines 18: twenty.txt"))))))
  (test-group "test_lines_negative_tail"
    (with-twenty (lambda (t)
      (test-equal '("line18" "line19" "line20") (lines-of (out t "lines -3: twenty.txt"))))))
  (test-group "test_lines_negative_single"
    (with-twenty (lambda (t) (test-equal '("line20") (lines-of (out t "lines -1 twenty.txt"))))))
  (test-group "test_lines_out_of_range_clamped"
    (with-twenty (lambda (t)
      (test-equal '("line18" "line19" "line20") (lines-of (out t "lines 18:50 twenty.txt"))))))
  (test-group "test_lines_empty_range"
    (with-twenty (lambda (t) (test-equal "" (out t "lines 50:60 twenty.txt")))))
  (test-group "test_lines_zero_rejected"
    (with-twenty (lambda (t)
      (test-assert (contains? (err t "lines 0 twenty.txt") "ERR"))
      (test-equal "ERR: lines: line numbers are 1-based: '0'" (err t "lines 0 twenty.txt"))
      (test-equal "ERR: lines: invalid range component 'x'" (err t "lines x:3 twenty.txt")))))
  (test-group "test_lines_via_pipe"
    (with-twenty (lambda (t)
      (test-equal '("line2" "line3" "line4") (lines-of (out t "cat twenty.txt | lines 2:4"))))))
  (test-group "test_lines_negative_via_pipe"
    (with-twenty (lambda (t)
      (test-equal '("line19" "line20") (lines-of (out t "cat twenty.txt | lines -2:")))))))

;; ---------------------------------------------------------------------
(test-group "TestGrepWcDiff"
  (define (with-ab proc)
    (with-files (list (cons "a.txt" "foo bar\nbaz qux\nfoo again\n") (cons "b.txt" "different\ncontent\n"))
                proc))
  (test-group "test_grep_basic"
    (with-ab (lambda (t)
      (let ((o (out t "grep foo a.txt")))
        (test-assert (contains? o "foo bar"))
        (test-assert (contains? o "foo again"))
        (test-assert (not (contains? o "baz")))
        (test-equal "1: foo bar\n3: foo again" o)))))
  (test-group "test_grep_case_insensitive"
    (with-ab (lambda (t)
      (write-file t "mixed.txt" "Hello World\ngoodbye\n")
      (test-assert (contains? (out t "grep -i hello mixed.txt") "Hello World")))))
  (test-group "test_grep_case_insensitive_keeps_escapes"
    ;; Python lowercased the whole pattern, so \D became \d
    (with-ab (lambda (t)
      (write-file t "d.txt" "123\nABC\n")
      (test-equal "2: ABC" (out t "grep -i \"^\\D+$\" d.txt")))))
  (test-group "test_grep_invert"
    (with-ab (lambda (t)
      (let ((o (out t "grep -v foo a.txt")))
        (test-assert (contains? o "baz qux"))
        (test-assert (not (contains? o "foo bar")))))))
  (test-group "test_grep_quiet"
    (with-ab (lambda (t)
      (let ((o (out t "grep -q foo a.txt")))
        (test-assert (not (matches? o "^\\d+:")))
        (test-equal "foo bar\nfoo again" o)))))
  (test-group "test_grep_no_match"
    (with-ab (lambda (t) (test-equal "" (out t "grep zzz a.txt")))))
  (test-group "test_grep_after_context"
    (with-ab (lambda (t)
      (write-file t "c.txt" "alpha\nbeta\nMATCH\ngamma\ndelta\nepsilon\n")
      (let ((o (out t "grep -A 2 MATCH c.txt")))
        (test-assert (contains? o "3: MATCH"))
        (test-assert (contains? o "4- gamma"))
        (test-assert (contains? o "5- delta"))
        (test-assert (not (contains? o "epsilon")))
        (test-assert (not (contains? o "beta")))))))
  (test-group "test_grep_before_context"
    (with-ab (lambda (t)
      (write-file t "c.txt" "alpha\nbeta\nMATCH\ngamma\n")
      (let ((o (out t "grep -B 2 MATCH c.txt")))
        (test-assert (contains? o "1- alpha"))
        (test-assert (contains? o "2- beta"))
        (test-assert (contains? o "3: MATCH"))
        (test-assert (not (contains? o "gamma")))))))
  (test-group "test_grep_around_context"
    (with-ab (lambda (t)
      (write-file t "c.txt" "a\nb\nMATCH\nc\nd\n")
      (let ((o (out t "grep -C 1 MATCH c.txt")))
        (test-assert (contains? o "2- b"))
        (test-assert (contains? o "3: MATCH"))
        (test-assert (contains? o "4- c"))
        (test-assert (not (contains? o "1- a")))
        (test-assert (not (contains? o "5- d")))))))
  (test-group "test_grep_context_separator_between_groups"
    (with-ab (lambda (t)
      (write-file t "c.txt" "MATCH1\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nMATCH2\n")
      (test-equal "1: MATCH1\n2- x\n--\n12: MATCH2" (out t "grep -A 1 MATCH c.txt")))))
  (test-group "test_grep_context_merges_overlapping"
    (with-ab (lambda (t)
      (write-file t "c.txt" "MATCH1\nx\ny\nMATCH2\n")
      (let ((o (out t "grep -C 2 MATCH c.txt")))
        (test-assert (not (contains? o "--")))
        (test-equal 1 (count-of o "2- x"))))))
  (test-group "test_grep_context_via_pipe"
    (with-ab (lambda (t)
      (write-file t "data.txt" "alpha\nbeta\nMATCH\ngamma\n")
      (let ((o (out t "cat data.txt | grep -B 1 -A 1 MATCH")))
        (test-assert (contains? o "2- beta"))
        (test-assert (contains? o "3: MATCH"))
        (test-assert (contains? o "4- gamma"))))))
  (test-group "test_grep_multiple_files_labels"
    (with-ab (lambda (t)
      (make-dirs (file-path t ".git"))
      (write-file t ".git/x.txt" "foo\n")
      (test-equal "a.txt 1: foo bar\na.txt 3: foo again" (out t "grep foo")))))
  (test-group "test_grep_option_errors"
    ;; Python wrote these to shell.errs, which does not exist
    (with-ab (lambda (t)
      (test-equal "ERR: grep: missing pattern" (err t "grep"))
      (test-equal "ERR: grep: option -A requires an argument" (err t "grep x -A"))
      (test-equal "ERR: grep: invalid value for -A: y" (err t "grep x -A y"))
      (test-equal "ERR: grep: -B requires a non-negative integer" (err t "grep x -B -1"))
      (test-assert (string-starts? (err t "grep \"(\" a.txt") "ERR: grep: ")))))
  (test-group "test_wc_counts_lines"
    (with-ab (lambda (t)
      (test-assert (contains? (out t "wc a.txt") "3"))
      (test-equal "a.txt 3" (out t "wc a.txt")))))
  (test-group "test_wc_multiple_files"
    (with-ab (lambda (t) (test-assert (contains? (out t "wc a.txt b.txt") "Total")))))
  (test-group "test_wc_pipe"
    (with-ab (lambda (t) (test-equal "(stdin) 3" (out t "cat a.txt | wc")))))
  (test-group "test_diff_identical"
    (with-ab (lambda (t)
      (write-file t "x.txt" "same\n")
      (write-file t "y.txt" "same\n")
      (let ((o (out t "diff x.txt y.txt")))
        (test-assert (not (matches? o "^[+-]")))
        (test-equal "same" o)))))
  (test-group "test_diff_different"
    (with-ab (lambda (t)
      (write-file t "x.txt" "aaa\n")
      (write-file t "y.txt" "bbb\n")
      (let ((o (out t "diff x.txt y.txt")))
        (test-assert (contains? o "aaa"))
        (test-assert (contains? o "bbb"))
        (test-equal "- aaa\n+ bbb" o)))))
  (test-group "test_diff_missing_file"
    (with-ab (lambda (t)
      (test-assert (contains? (err t "diff a.txt missing.txt") "ERR"))
      (test-equal "ERR: diff requires two files" (err t "diff a.txt")))))
  (test-group "test_diff_ndiff_format"
    ;; expected outputs from Python's difflib.ndiff
    (test-equal '("- one\n" "?  ^\n" "+ ore\n" "?  ^\n" "- two\n" "- three\n" "?  -\n" "+ tree\n" "+ emu\n")
                (ndiff '("one\n" "two\n" "three\n") '("ore\n" "tree\n" "emu\n")))
    (test-equal '("- abcDefghiJkl\n" "?    ^  ^  ^\n" "+ abcdefGhijkl\n" "?    ^  ^  ^\n")
                (ndiff '("abcDefghiJkl\n") '("abcdefGhijkl\n")))
    (test-equal '("  a\n" "- \tprivate Thread x;\n" "+ \tprivate volatile Thread x;\n" "? \t        +++++++++\n" "  b\n")
                (ndiff '("a\n" "\tprivate Thread x;\n" "b\n") '("a\n" "\tprivate volatile Thread x;\n" "b\n")))
    (test-equal '("+ new\n" "  a\n" "- b\n" "+ c\n")
                (ndiff '("a\n" "b\n") '("new\n" "a\n" "c\n")))))

;; ---------------------------------------------------------------------
(test-group "TestDate"
  (define (today-plus days)
    (let ((d (current-date)))
      (date->string (time-utc->date (add-duration (date->time-utc d) (make-time time-duration 0 (* days 86400)))
                                    (date-zone-offset d))
                    "~Y-~m-~d")))
  (test-group "test_date_default_format"
    (with-shell (lambda (t) (test-assert (matches? (out t "date") "^\\d{4}-\\d{2}-\\d{2}$")))))
  (test-group "test_date_with_time"
    (with-shell (lambda (t)
      (test-assert (matches? (out t "date --with-time") "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}$")))))
  (test-group "test_date_terse"
    (with-shell (lambda (t)
      (test-assert (matches? (out t "date --terse") "^\\d{8}$"))
      (test-assert (matches? (out t "date --terse --with-time") "^\\d{8}-\\d{6}$")))))
  (test-group "test_date_offset"
    (with-shell (lambda (t)
      (test-equal (today-plus 0) (out t "date"))
      (test-equal (today-plus 1) (out t "date 1"))
      (test-equal (today-plus -1) (out t "date -1"))
      (test-equal (today-plus 400) (out t "date 400")))))
  (test-group "test_date_custom_format"
    (with-shell (lambda (t)
      (test-equal (number->string (date-year (current-date))) (out t "date --format \"%Y\""))
      (test-equal "%Q 100%" (out t "date --fmt \"%Q 100%%\"")))))
  (test-group "test_strftime"
    (test-equal "Mon Monday Nov November 23 2026 26 327 1 1 47 47"
                (strftime "%a %A %b %B %d %Y %y %j %w %u %U %W" 2026 11 23 22 5 9 0))
    (test-equal "10:05:09 PM 000042 Mon Nov 23 22:05:09 2026 11/23/26"
                (strftime "%I:%M:%S %p %f %c %x" 2026 11 23 22 5 9 42))
    (test-equal "2024-02-29 060 Thu" (strftime "%F %j %a" 2024 2 29 0 0 0 0))))

;; ---------------------------------------------------------------------
(test-group "TestXargs"
  (test-group "test_basic_xargs"
    (with-shell (lambda (t)
      (write-file t "data.txt" "a\nb\nc\n")
      (test-equal "a b c" (out t "cat data.txt | xargs echo")))))
  (test-group "test_xargs_default_echo"
    (with-shell (lambda (t)
      (write-file t "data.txt" "hello world\n")
      (test-equal "hello world" (out t "cat data.txt | xargs")))))
  (test-group "test_xargs_n_flag"
    (with-shell (lambda (t)
      (write-file t "data.txt" "a\nb\nc\nd\n")
      (test-equal "a b\nc d" (out t "cat data.txt | xargs -n 2 echo")))))
  (test-group "test_xargs_n_uneven"
    (with-shell (lambda (t)
      (write-file t "data.txt" "a\nb\nc\n")
      (test-equal "a b\nc" (out t "cat data.txt | xargs -n 2 echo")))))
  (test-group "test_xargs_I_flag"
    (with-shell (lambda (t)
      (write-file t "data.txt" "hello\nworld\n")
      (test-equal "item: hello\nitem: world" (out t "cat data.txt | xargs -I {} print \"item: {}\"")))))
  (test-group "test_xargs_d_flag"
    (with-shell (lambda (t)
      (write-file t "data.txt" "a,b,c")
      (test-equal "a b c" (out t "cat data.txt | xargs -d , echo")))))
  (test-group "test_xargs_empty_input"
    (with-shell (lambda (t)
      (write-file t "data.txt" "")
      (test-equal "" (out t "cat data.txt | xargs echo")))))
  (test-group "test_xargs_no_stdin"
    (with-shell (lambda (t) (test-equal "" (out t "xargs echo")))))
  (test-group "test_xargs_extra_args"
    (with-shell (lambda (t)
      (write-file t "data.txt" "world\n")
      (test-equal "hello world" (out t "cat data.txt | xargs echo hello")))))
  (test-group "test_xargs_invalid_n"
    (with-shell (lambda (t)
      (write-file t "data.txt" "a\n")
      (test-equal "ERR: xargs: invalid number 'x'" (err t "cat data.txt | xargs -n x echo"))
      (test-equal "ERR: xargs: -n must be at least 1" (err t "cat data.txt | xargs -n 0 echo"))))))

;; ---------------------------------------------------------------------
(test-group "TestWatch"
  (test-group "test_watch_runs_until_ctrl_c"
    (with-shell (lambda (t)
      (with-key-source (keys #\x 'ctrl-c)
        (lambda ()
          (let ((o (out-raw t "watch -n 0.5 echo hi")))
            (test-equal 2 (count-of o "Every 0.5s: echo hi"))
            (test-equal 2 (count-of o "\nhi\n"))))))))
  (test-group "test_watch_errors"
    (with-shell (lambda (t)
      (test-equal "ERR: watch requires a command to execute" (err t "watch"))
      (test-equal "ERR: -n requires a numeric value" (err t "watch -n x echo"))))))

;; ---------------------------------------------------------------------
(test-group "TestGlob"
  (define (with-abc proc)
    (with-files (list (cons "alpha.txt" "aaa\n") (cons "beta.txt" "bbb\n") (cons "gamma.txt" "ccc\n")) proc))
  ;; the process directory is never the shell's directory here, as after
  ;; _change_process_cwd of the Python tests
  (test-group "test_cat_glob_uses_shell_cwd"
    (with-abc (lambda (t)
      (let ((o (out t "cat *.txt")))
        (test-assert (contains? o "aaa"))
        (test-assert (contains? o "bbb"))
        (test-assert (contains? o "ccc"))))))
  (test-group "test_cat_glob_sorted"
    (with-abc (lambda (t) (test-equal "aaa\nbbb\nccc" (out t "cat *.txt")))))
  (test-group "test_wc_glob_uses_shell_cwd"
    (with-abc (lambda (t)
      (let ((o (out t "wc *.txt")))
        (test-assert (contains? o "alpha.txt"))
        (test-assert (contains? o "Total"))))))
  (test-group "test_grep_glob_uses_shell_cwd"
    (with-abc (lambda (t)
      (let ((o (out t "grep aaa *.txt")))
        (test-assert (contains? o "aaa"))
        (test-assert (not (contains? o "bbb")))))))
  (test-group "test_no_match_produces_error"
    (with-abc (lambda (t) (test-assert (contains? (err t "cat *.xyz") "ERR"))))))

(test-end "text")
(exit (if (zero? (last-run-failed-tests)) 0 1))
