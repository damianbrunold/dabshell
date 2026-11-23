(import (scheme base) (scheme process-context) (scm fs) (scm module) (scm test))
(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))
(import (dabshell util) (dabshell core) (dabshell builtins) (dabshell awk) (dabshell testing))
(test-runner-factory scm-test-runner)
(test-begin "awk")

(define-syntax awk-test
  (syntax-rules ()
    ((_ name t body ...) (test-group name (with-shell (lambda (t) body ...))))))

(awk-test "test_default_action_prints_line" t
  (write-file t "d.txt" "alpha\nbeta\n")
  (test-equal "alpha\nbeta" (out t "awk '1' d.txt")))

(awk-test "test_regex_pattern" t
  (write-file t "d.txt" "alpha\nbeta\ngamma\n")
  (test-equal "alpha\nbeta\ngamma" (out t "awk '/a$/' d.txt")))

(awk-test "test_regex_pattern_filter" t
  (write-file t "d.txt" "one\ntwo\nthree\n")
  (test-equal "two\nthree" (out t "awk '/^t/' d.txt")))

(awk-test "test_print_field" t
  (write-file t "d.txt" "a b c\nd e f\n")
  (test-equal "b\ne" (out t "awk '{print $2}' d.txt")))

(awk-test "test_print_multiple_fields" t
  (write-file t "d.txt" "a b c\n")
  (test-equal "a c" (out t "awk '{print $1, $3}' d.txt")))

(awk-test "test_field_separator_F" t
  (write-file t "d.txt" "root:x:0\nuser:x:1000\n")
  (test-equal "root\nuser" (out t "awk -F: '{print $1}' d.txt")))

(awk-test "test_NR_NF" t
  (write-file t "d.txt" "a b\nc d e\n")
  (test-equal "1 2\n2 3" (out t "awk '{print NR, NF}' d.txt")))

(awk-test "test_NF_filter" t
  (write-file t "d.txt" "a\na b\na b c\n")
  (test-equal "a b c" (out t "awk 'NF > 2' d.txt")))

(awk-test "test_sum_column" t
  (write-file t "d.txt" "1\n2\n3\n4\n")
  (test-equal "10" (out t "awk '{sum += $1} END {print sum}' d.txt")))

(awk-test "test_begin_block" t
  (write-file t "d.txt" "x\n")
  (test-equal "hi\nx" (out t "awk 'BEGIN {print \"hi\"} {print}' d.txt")))

(awk-test "test_end_only" t
  (write-file t "d.txt" "a\nb\n")
  (test-equal "2" (out t "awk 'END {print NR}' d.txt")))

(awk-test "test_if_else" t
  (write-file t "d.txt" "1\n2\n3\n4\n")
  (test-equal "odd\neven\nodd\neven"
              (out t "awk '{ if ($1 % 2 == 0) print \"even\"; else print \"odd\" }' d.txt")))

(awk-test "test_next_skips" t
  (write-file t "d.txt" "a\nb\nc\n")
  (test-equal "a\nc" (out t "awk '/b/ {next} {print}' d.txt")))

(awk-test "test_match_operator" t
  (write-file t "d.txt" "foo 1\nbar 2\nfoobar 3\n")
  (test-equal "1\n3" (out t "awk '$1 ~ /foo/ {print $2}' d.txt")))

(awk-test "test_not_match_operator" t
  (write-file t "d.txt" "foo\nbar\n")
  (test-equal "bar" (out t "awk '$1 !~ /foo/' d.txt")))

(awk-test "test_ofs" t
  (write-file t "d.txt" "a b c\n")
  (test-equal "a,b,c" (out t "awk 'BEGIN{OFS=\",\"} {print $1, $2, $3}' d.txt")))

(awk-test "test_concat" t
  (write-file t "d.txt" "x\n")
  (test-equal "hi=x" (out t "awk '{print \"hi=\" $1}' d.txt")))

(awk-test "test_length_function" t
  (write-file t "d.txt" "hello\nworld!\n")
  (test-equal "5\n6" (out t "awk '{print length($1)}' d.txt")))

(awk-test "test_substr" t
  (write-file t "d.txt" "abcdef\n")
  (test-equal "bcd" (out t "awk '{print substr($1, 2, 3)}' d.txt")))

(awk-test "test_toupper_tolower" t
  (write-file t "d.txt" "Hello\n")
  (test-equal "HELLO hello" (out t "awk '{print toupper($1), tolower($1)}' d.txt")))

(awk-test "test_pipe_input" t
  (test-equal "bar" (out t "print foo bar | awk '{print $2}'")))

(awk-test "test_printf" t
  (write-file t "d.txt" "3\n")
  (test-equal "00003" (out t "awk '{printf \"%05d\\n\", $1}' d.txt")))

(awk-test "test_comparison_numeric" t
  (write-file t "d.txt" "5\n10\n2\n")
  (test-equal "5\n10" (out t "awk '$1 > 3' d.txt")))

(awk-test "test_string_comparison" t
  (test-equal "yes" (out t "awk 'BEGIN { if (\"apple\" < \"banana\") print \"yes\" }'")))

(awk-test "test_assignment_to_field" t
  (write-file t "d.txt" "a b c\n")
  (test-equal "a X c" (out t "awk '{$2 = \"X\"; print}' d.txt")))

(awk-test "test_division_by_zero" t
  (test-assert (string-contains? (err t "awk 'BEGIN { print 1/0 }'") "division by zero")))

;; tests added in the port

(awk-test "test_number_formatting" t
  ;; Python's str of int/float results and format(v, "g")
  (test-equal "3.5 2 0.333333 3.33333e-21 2" (out t "awk 'BEGIN { x = 4; x /= 2; print 7/2, 4/2, 1/3, 1 / 3e20, x }'"))
  (test-equal "2 1 1.5" (out t "awk 'BEGIN { print -7 % 3, 7 % -3 + 3, 7.5 % 2 * 1 }'")))

(awk-test "test_printf_conversions" t
  (test-equal "[  3.14][3.142e+00][1e+06][ff][0X1F][  ab][a][x  ][+5][%][0o10]"
              (out t "awk 'BEGIN { printf \"[%6.2f][%.3e][%g][%x][%#X][%4s][%c][%-3s][%+d][%%][%#o]\\n\", 3.14159, 3.14159, 1000000, 255, 31, \"ab\", \"abc\", \"x\", 5, 8 }'"))
  (test-equal "2 0.1 0.30000000000000004" (out t "awk 'BEGIN { printf \"%.0f %s %.17g\\n\", 2.5, sprintf(\"%g\", 0.1), 0.1 + 0.2 }'")))

(awk-test "test_string_to_number" t
  (write-file t "d.txt" " 12 x\n1e3 y\n1_0 z\nabc w\n")
  (test-equal "13\n1001\n11\n1" (out t "awk '{ print $1 + 1 }' d.txt")))

(awk-test "test_substr_negative_length" t
  ;; Python sliced from the end for a negative end index
  (test-equal "[][he]" (out t "awk 'BEGIN { print \"[\" substr(\"hello\", 1, -2) \"][\" substr(\"hello\", 0, 3) \"]\" }'")))

(awk-test "test_index_int_sprintf" t
  (test-equal "3 0 -3 x=007" (out t "awk 'BEGIN { print index(\"hello\", \"l\"), index(\"a\", \"\"), int(-3.7), sprintf(\"x=%03d\", 7) }'")))

(awk-test "test_errors" t
  (test-equal "ERR: awk: missing program" (err t "awk"))
  (test-equal "ERR: awk: -F requires an argument" (err t "awk -F"))
  (test-equal "ERR: awk: unterminated string in awk program" (err t "awk 'BEGIN { print \"x }'"))
  (test-equal "ERR: awk: unexpected character '@' in awk program" (err t "awk '@'"))
  (test-equal "ERR: awk: awk: expected ')', got '}'" (err t "awk 'BEGIN { print (1 }'"))
  (test-equal "ERR: awk: unknown function 'foo'" (err t "awk 'BEGIN { foo(1) }'"))
  (test-assert (string-starts? (err t "awk 1 nope.txt") "ERR: "))
  (test-assert (string-ends? (err t "awk 1 nope.txt") "nope.txt not found")))

(awk-test "test_set_field_extends_record" t
  (write-file t "d.txt" "a b\n")
  (test-equal "a b  d 4" (out t "awk '{ $4 = \"d\"; print $0, NF }' d.txt"))
  (test-equal "x y 2" (out t "awk '{ $0 = \"x y\"; print $1, $2, NF }' d.txt")))

(test-end "awk")
