(import (scheme base) (scheme process-context) (scm fs) (scm module) (scm test))
(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))
(import (dabshell util) (dabshell core) (dabshell keys) (dabshell testing)
        (dabshell editor-buffer) (dabshell editor-core) (dabshell editor-vim) (dabshell editor))

(test-runner-factory scm-test-runner)
(test-begin "editor")

;; ----------------------------------------------------------------------
;; helpers (the _KeyFeeder / _keys / TestEditor helpers of the Python tests)

;; raised when a scripted editor session runs dry (Python's _OutOfKeys); it
;; is no error object, so the editor does not report it but ends
(define-record-type out-of-keys (make-out-of-keys) out-of-keys?)

(define (key-feeder keys)
  (lambda ()
    (if (null? keys)
        (raise (make-out-of-keys))
        (let ((k (car keys))) (set! keys (cdr keys)) k))))

;; strings become single-character keys, lists are spliced, others pass
(define (keys . items)
  (let loop ((items items) (acc '()))
    (cond ((null? items) (reverse acc))
          ((string? (car items)) (loop (cdr items) (append (reverse (string->list (car items))) acc)))
          ((list? (car items)) (loop (cdr items) (append (reverse (apply keys (car items))) acc)))
          (else (loop (cdr items) (cons (car items) acc))))))

(define SAVE '(ctrl-x ctrl-s))
(define QUIT '(ctrl-x ctrl-c))
(define ESC 'esc)
(define (meta k) (cons 'meta k))
(define (ex cmd) (list #\: cmd 'cr))

(define (editor t files . vim)
  (let ((e (make-editor (tc-shell t) (open-output-string) (lambda () (cons 40 10)))))
    (for-each (lambda (f) (editor-open-file! e f)) files)
    (when (pair? (editor-buffers e)) (editor-select! e (car (editor-buffers e))))
    (when (and (pair? vim) (car vim))
      (editor-set-keymap! e "vim" #t)
      (when (null? (editor-buffers e)) (editor-new-buffer! e "[No Name]")))
    e))
(define (vim-editor t files) (editor t files #t))

;; run the editor with keys: 'done when it quit, 'out-of-keys when the keys
;; ran out first
(define (run! e ks)
  (guard (x ((out-of-keys? x) 'out-of-keys))
    (with-key-source (key-feeder ks) (lambda () (editor-run! e)))
    'done))

(define (session t files ks . vim)
  (let ((e (editor t files (and (pair? vim) (car vim)))))
    (test-eq 'done (run! e ks))
    e))

(define (lines e) (buffer-lines (editor-cur e)))
(define (cur-pos e) (buffer-pos (editor-cur e)))
(define (contains? s sub) (string-contains? s sub))

;; edit v.txt containing text with vim keys, then :wq; return the text
(define (vim t text ks)
  (write-file t "v.txt" text)
  (session t '("v.txt") (keys ks ESC (ex "wq")) #t)
  (read-text t "v.txt"))

;; ----------------------------------------------------------------------
;; TestEditor: Buffer model

(test-group "test_insert_delete_multiline"
  (let* ((b (make-buffer "t"))
         (end (buffer-insert! b 0 0 "ab\ncd\nef")))
    (test-equal '("ab" "cd" "ef") (buffer-lines b))
    (test-equal '(2 . 2) end)
    (test-equal "b\ncd\ne" (buffer-delete! b '(0 . 1) '(2 . 1)))
    (test-equal '("af") (buffer-lines b))))

(test-group "test_word_motion"
  (let ((b (make-buffer "t")))
    (buffer-insert! b 0 0 "foo bar_baz\n  qux")
    (test-equal '(0 . 3) (buffer-word-forward b 0 0))
    (test-equal '(0 . 11) (buffer-word-forward b 0 3))
    (test-equal '(1 . 5) (buffer-word-forward b 0 11))
    (test-equal '(1 . 2) (buffer-word-backward b 1 5))
    (test-equal '(0 . 4) (buffer-word-backward b 1 2))))

(test-group "test_undo_restores_text_and_modified"
  (let ((b (make-buffer "t")))
    (test-assert (not (buffer-modified? b)))
    (buffer-begin-group! b)
    (buffer-insert! b 0 0 "hello")
    (test-assert (buffer-modified? b))
    (buffer-begin-group! b)
    (buffer-delete! b '(0 . 0) '(0 . 2))
    (test-equal '("llo") (buffer-lines b))
    (buffer-undo! b)
    (test-equal '("hello") (buffer-lines b))
    (buffer-undo! b)
    (test-equal '("") (buffer-lines b))
    (test-assert (not (buffer-modified? b)))))

(test-group "test_search_wraps_and_folds_case"
  (let ((b (make-buffer "t")))
    (buffer-insert! b 0 0 "Alpha\nbeta\nALPHA")
    (test-equal '(2 . 0) (buffer-search b "alpha" 1 0))
    (test-equal '(0 . 0) (buffer-search b "alpha" 2 1))
    (test-equal #f (buffer-search b "Alpha" 1 0 #t #f))
    (test-equal '(1 . 0) (buffer-search b "beta" 2 5 #f))))

;; fixed: Python's rfind got a negative start when wrapping back to the
;; first row and missed the match
(test-group "search_backward_wraps_to_start_row"
  (let ((b (make-buffer "t")))
    (buffer-insert! b 0 0 "xabc")
    (test-equal '(0 . 1) (buffer-search b "abc" 0 1 #f))))

;; ----------------------------------------------------------------------
;; TestEditor: loading / saving

(test-group "test_save_preserves_crlf"
  (with-shell (lambda (t)
    (write-file t "crlf.txt" (string->utf8 "one\r\ntwo\r\n"))
    (session t '("crlf.txt") (keys "x" SAVE QUIT))
    (test-equal (string->utf8 "xone\r\ntwo\r\n") (read-file t "crlf.txt")))))

(test-group "test_save_preserves_bom_and_missing_newline"
  (with-shell (lambda (t)
    (write-file t "bom.txt" (bytevector #xEF #xBB #xBF 104 105))
    (session t '("bom.txt") (keys 'ctrl-e "!" SAVE QUIT))
    (test-equal (bytevector #xEF #xBB #xBF 104 105 33) (read-file t "bom.txt")))))

(test-group "test_save_preserves_latin1"
  (with-shell (lambda (t)
    (write-file t "l1.txt" (bytevector 99 97 102 #xE9 10))
    (session t '("l1.txt") (keys 'ctrl-e "s" SAVE QUIT))
    (test-equal (bytevector 99 97 102 #xE9 115 10) (read-file t "l1.txt")))))

(test-group "latin1_save_asks_for_utf8"
  (with-shell (lambda (t)
    (write-file t "l1.txt" (bytevector 99 97 102 #xE9 10))
    (session t '("l1.txt") (keys 'ctrl-e (string (integer->char #x20AC)) SAVE "y" QUIT))
    (test-equal "caf\xe9;\x20ac;\n" (read-text t "l1.txt")))))

;; like Python (os.path.realpath), saving through a symbolic link writes the
;; target (only checked where links can be created)
(test-group "save_through_symlink_keeps_link"
  (with-shell (lambda (t)
    (write-file t "target.txt" "a\n")
    (when (guard (e (#t #f)) (make-symlink (file-path t "target.txt") (file-path t "link.txt")) (file-symlink? (file-path t "link.txt")))
      (session t '("link.txt") (keys "x" SAVE QUIT))
      (test-assert (file-symlink? (file-path t "link.txt")))
      (test-equal "xa\n" (read-text t "target.txt"))))))

(test-group "test_new_file_created_on_save"
  (with-shell (lambda (t)
    (session t '("new.txt") (keys "hello" SAVE QUIT))
    (test-equal (string->utf8 "hello\n") (read-file t "new.txt")))))

(test-group "test_binary_refused"
  (with-shell (lambda (t)
    (let ((bv (make-bytevector 256)))
      (do ((i 0 (+ i 1))) ((= i 256)) (bytevector-u8-set! bv i i))
      (write-file t "bin.dat" bv)
      (test-assert (guard (e ((editor-error? e) #t)) (editor t '("bin.dat")) #f))))))

(test-group "test_scratch_save_prompts_for_name"
  (with-shell (lambda (t)
    (session t '() (keys "abc" SAVE "out.txt" 'cr QUIT))
    (test-equal (string->utf8 "abc\n") (read-file t "out.txt")))))

;; ----------------------------------------------------------------------
;; TestEditor: key-driven sessions

(test-group "test_quit_without_saving"
  (with-shell (lambda (t)
    (write-file t "a.txt" "orig\n")
    (let ((e (session t '("a.txt") (keys "zzz" QUIT "n"))))
      (test-assert (not (editor-running? e)))
      (test-equal "orig\n" (read-text t "a.txt"))))))

(test-group "test_quit_cancel_keeps_running"
  (with-shell (lambda (t)
    (write-file t "a.txt" "orig\n")
    (let ((e (editor t '("a.txt"))))
      (test-eq 'out-of-keys (run! e (keys "z" QUIT "q")))
      (test-assert (editor-running? e))))))

(test-group "test_kill_line_appends_and_yank"
  (with-shell (lambda (t)
    (write-file t "k.txt" "one\ntwo\nthree\n")
    (session t '("k.txt") (keys 'ctrl-k 'ctrl-k 'ctrl-k 'ctrl-n 'ctrl-y SAVE QUIT))
    ;; lines are now ("" "three"); the yank lands at the start of "three"
    (test-equal "\none\ntwothree\n" (read-text t "k.txt")))))

(test-group "test_region_kill_and_undo"
  (with-shell (lambda (t)
    (write-file t "r.txt" "hello world\n")
    (let ((e (session t '("r.txt") (keys 'ctrl-space (meta #\f) 'ctrl-w SAVE 'ctrl-underscore QUIT "n"))))
      (test-equal " world\n" (read-text t "r.txt"))
      (test-equal '("hello world") (lines e))))))

(test-group "test_typing_undoes_as_word_groups"
  (with-shell (lambda (t)
    (let ((e (session t '() (keys "foo bar" 'ctrl-underscore QUIT "n"))))
      (test-equal '("foo ") (buffer-lines (car (editor-buffers e))))))))

(test-group "test_esc_prefix_is_meta"
  (with-shell (lambda (t)
    (write-file t "w.txt" "alpha beta\n")
    (let ((e (session t '("w.txt") (keys ESC "f" "X" QUIT "n"))))
      (test-equal "alphaX beta" (car (lines e)))))))

(test-group "test_newline_keeps_indent"
  (with-shell (lambda (t)
    (let ((e (session t '() (keys "    x" 'cr "y" QUIT "n"))))
      (test-equal '("    x" "    y") (lines e))))))

(test-group "test_paste_does_not_indent"
  (with-shell (lambda (t)
    (let ((e (session t '() (keys "    x" 'paste-start 'cr "y" 'paste-end QUIT "n"))))
      (test-equal '("    x" "y") (lines e))))))

(test-group "test_isearch_moves_cursor"
  (with-shell (lambda (t)
    (write-file t "s.txt" "abc\nfoo bar\nfoo baz\n")
    (let ((e (session t '("s.txt") (keys 'ctrl-s "foo" 'ctrl-s 'cr QUIT))))
      (test-equal '(2 . 3) (cur-pos e))))))

(test-group "test_isearch_cancel_restores"
  (with-shell (lambda (t)
    (write-file t "s.txt" "abc\nfoo\n")
    (let ((e (session t '("s.txt") (keys 'ctrl-s "foo" 'ctrl-g QUIT))))
      (test-equal '(0 . 0) (cur-pos e))))))

(test-group "test_query_replace"
  (with-shell (lambda (t)
    (write-file t "q.txt" "a x a x a\n")
    (session t '("q.txt") (keys (meta #\%) "a" 'cr "b" 'cr "y" "n" "y" SAVE QUIT))
    (test-equal "b x a x b\n" (read-text t "q.txt")))))

(test-group "test_query_replace_all"
  (with-shell (lambda (t)
    (write-file t "q.txt" "a a a\n")
    (session t '("q.txt") (keys (meta #\%) "a" 'cr "bb" 'cr "!" SAVE QUIT))
    (test-equal "bb bb bb\n" (read-text t "q.txt")))))

(test-group "test_switch_buffers"
  (with-shell (lambda (t)
    (write-file t "one.txt" "1\n")
    (write-file t "two.txt" "2\n")
    (let ((e (session t '("one.txt" "two.txt") (keys 'ctrl-x "b" 'cr "!" QUIT "y" "y"))))
      (test-equal "two.txt" (buffer-name (editor-cur e)))
      (test-equal "!2\n" (read-text t "two.txt"))
      (test-equal "1\n" (read-text t "one.txt"))))))

(test-group "test_find_file_opens_buffer"
  (with-shell (lambda (t)
    (write-file t "other.txt" "o\n")
    (let ((e (session t '() (keys 'ctrl-x 'ctrl-f "oth" 'tab 'cr QUIT))))
      (test-equal "other.txt" (buffer-name (editor-cur e)))
      (test-equal '("o") (lines e))))))

(test-group "test_goto_line"
  (with-shell (lambda (t)
    (write-file t "g.txt" (let loop ((i 49) (acc "")) (if (< i 0) acc (loop (- i 1) (string-append (number->string i) "\n" acc)))))
    (let ((e (session t '("g.txt") (keys (meta #\g) "g" "30" 'cr QUIT))))
      (test-equal 29 (buffer-row (editor-cur e)))))))

(test-group "test_undefined_key_message"
  (with-shell (lambda (t)
    (let ((e (editor t '())))
      (test-eq 'out-of-keys (run! e (keys 'ctrl-x "z")))
      (test-assert (contains? (editor-message e) "C-x z is undefined"))))))

(test-group "write_file_defaults_to_the_file_directory"
  (with-shell (lambda (t)
    (write-file t "sub/a.txt" "a\n")
    (session t '("sub/a.txt") (keys 'ctrl-x 'ctrl-w "b.txt" 'cr QUIT))
    (test-equal "a\n" (read-text t "sub/b.txt")))))

;; ----------------------------------------------------------------------
;; TestEditor: rendering

(test-group "test_render_modeline_and_long_line"
  (with-shell (lambda (t)
    (write-file t "long.txt" (string-append (make-string 100 #\x) "\nshort\n"))
    (let ((e (editor t '("long.txt"))))
      (editor-render! e)
      (test-assert (contains? (editor-last-frame e) "long.txt"))
      (test-assert (contains? (editor-last-frame e) "L1 C0"))
      (test-assert (contains? (editor-last-frame e) (string-append (make-string 38 #\x) "$")))))))

(test-group "test_render_scrolls_to_cursor"
  (with-shell (lambda (t)
    (write-file t "many.txt" (let loop ((i 99) (acc '()))
                               (if (< i 0)
                                   (string-join* acc "\n")
                                   (loop (- i 1) (cons (string-append "line" (number->string i)) acc)))))
    (let ((e (editor t '("many.txt"))))
      (buffer-row-set! (editor-cur e) 60)
      (editor-render! e)
      (test-assert (contains? (editor-last-frame e) "line60"))
      (test-assert (not (contains? (editor-last-frame e) "line0\x1b;")))))))

;; ----------------------------------------------------------------------
;; TestEditor: the command

(test-group "test_edit_refuses_without_terminal"
  (with-shell (lambda (t)
    (test-assert (contains? (err t "edit foo.txt") "interactive terminal")))))

(test-group "test_edit_command_runs_editor"
  (with-shell (lambda (t)
    (parameterize ((edit-interactive? (lambda (sh) #t)))
      (with-key-source (key-feeder (keys "hi" SAVE QUIT))
        (lambda () (run-cmd t "edit cmd.txt"))))
    (test-equal "hi\n" (read-text t "cmd.txt")))))

(test-group "edit_refuses_pipe"
  (with-shell (lambda (t)
    (test-assert (contains? (err t "echo x | edit") "pipe")))))

;; ----------------------------------------------------------------------
;; TestEditorVim: modes and inserting

(test-group "test_insert_and_save_quit"
  (with-shell (lambda (t)
    (test-equal "hello world\n" (vim t "world\n" (list "i" "hello " ESC))))))

(test-group "test_append_and_open_lines"
  (with-shell (lambda (t)
    (test-equal "aXb\n" (vim t "ab\n" (list "a" "X" ESC)))
    (test-equal "ab!\n" (vim t "ab\n" (list "A" "!" ESC)))
    (test-equal "  ab\n  c\n" (vim t "  ab\n" (list "o" "c" ESC)))
    (test-equal "top\nab\n" (vim t "ab\n" (list "O" "top" ESC))))))

(test-group "test_esc_removes_unused_autoindent"
  (with-shell (lambda (t)
    (test-equal "  a\n\nb\n" (vim t "  a\nb\n" (list "o" ESC)))
    (test-equal "  a\n" (vim t "  a\n" (list "o" ESC "u"))))))

(test-group "test_esc_moves_cursor_left"
  (with-shell (lambda (t)
    (let ((e (session t '() (keys "i" "abc" ESC (ex "q!")) #t)))
      (test-equal 2 (buffer-col (editor-cur e)))))))

(test-group "test_meta_tuple_is_esc_then_key"
  (with-shell (lambda (t)
    ;; Esc followed quickly by a key arrives as (meta . key): the Esc leaves
    ;; insert mode (cursor back on the X) and x deletes it
    (test-equal "ab\n" (vim t "ab\n" (list "i" "X" (meta #\x)))))))

(test-group "test_normal_keys_do_not_insert"
  (with-shell (lambda (t)
    (test-equal "abc\n" (vim t "abc\n" (list "l" "l"))))))

;; TestEditorVim: motions

(test-group "test_word_motions"
  (with-shell (lambda (t)
    (let* ((e (vim-editor t '()))
           (b (editor-cur e)))
      (buffer-insert! b 0 0 "foo.bar baz\n\nqux")
      (test-equal '(0 . 3) (vim-word-forward b 0 0 #f))
      (test-equal '(0 . 8) (vim-word-forward b 0 0 #t))
      (test-equal '(1 . 0) (vim-word-forward b 0 8 #f))
      (test-equal '(0 . 2) (vim-word-end b 0 0 #f))
      (test-equal '(1 . 0) (vim-word-back b 2 0 #f))
      (test-equal '(0 . 4) (vim-word-back b 0 8 #f))))))

(test-group "test_counts_and_line_motions"
  (with-shell (lambda (t)
    (write-file t "g.txt" (let loop ((i 19) (acc "")) (if (< i 0) acc (loop (- i 1) (string-append "  l" (number->string i) "\n" acc)))))
    (test-equal '(4 . 2) (cur-pos (session t '("g.txt") (keys "5" "G" (ex "q")) #t)))
    (test-equal '(3 . 3) (cur-pos (session t '("g.txt") (keys "3" "j" "$" (ex "q")) #t)))
    (test-equal 0 (buffer-row (editor-cur (session t '("g.txt") (keys "G" "g" "g" (ex "q")) #t)))))))

(test-group "test_find_char"
  (with-shell (lambda (t)
    (write-file t "f.txt" "a,b,c,d\n")
    (test-equal 3 (buffer-col (editor-cur (session t '("f.txt") (keys "f" "," ";" (ex "q")) #t)))))))

(test-group "test_ex_goto_line"
  (with-shell (lambda (t)
    (write-file t "g.txt" "xxxxx\nxxxxx\nxxxxx\nxxxxx\nxxxxx\nxxxxx\nxxxxx\nxxxxx\nxxxxx\nxxxxx")
    (test-equal 6 (buffer-row (editor-cur (session t '("g.txt") (keys (ex "7") (ex "q")) #t)))))))

;; TestEditorVim: operators

(test-group "test_dd_and_count"
  (with-shell (lambda (t)
    (test-equal "1\n4\n" (vim t "1\n2\n3\n4\n" (list "j" "2" "d" "d")))
    (test-equal "1\n" (vim t "1\n2\n" (list "G" "d" "d"))))))

(test-group "test_dw_cw_de"
  (with-shell (lambda (t)
    (test-equal "bar baz\n" (vim t "foo bar baz\n" (list "d" "w")))
    (test-equal "X bar\n" (vim t "foo bar\n" (list "c" "w" "X" ESC)))
    (test-equal " bar\n" (vim t "foo bar\n" (list "d" "e")))
    (test-equal "\nz\n" (vim t "foo bar\nz\n" (list "d" "2" "w"))))))

(test-group "test_dw_at_end_of_line_keeps_newline"
  (with-shell (lambda (t)
    (test-equal "\nbar\n" (vim t "foo\nbar\n" (list "d" "w"))))))

(test-group "test_D_C_x_X_r_tilde"
  (with-shell (lambda (t)
    (test-equal "ab\n" (vim t "abcdef\n" (list "l" "l" "D")))
    (test-equal "aZ\n" (vim t "abcdef\n" (list "l" "C" "Z" ESC)))
    (test-equal "def\n" (vim t "abcdef\n" (list "3" "x")))
    (test-equal "abcdf\n" (vim t "abcdef\n" (list "$" "X")))
    (test-equal "zbc\n" (vim t "abc\n" (list "r" "z")))
    (test-equal "ABc\n" (vim t "abc\n" (list "2" "~"))))))

(test-group "test_dj_and_dG_linewise"
  (with-shell (lambda (t)
    (test-equal "3\n" (vim t "1\n2\n3\n" (list "d" "j")))
    (test-equal "1\n" (vim t "1\n2\n3\n" (list "j" "d" "G"))))))

(test-group "test_cc_keeps_indent"
  (with-shell (lambda (t)
    (test-equal "  new\nx\n" (vim t "  old\nx\n" (list "c" "c" "new" ESC))))))

(test-group "test_yank_and_paste"
  (with-shell (lambda (t)
    (test-equal "a\na\nb\n" (vim t "a\nb\n" (list "y" "y" "p")))
    (test-equal "a\nb\nb\n" (vim t "a\nb\n" (list "j" "y" "y" "P")))
    (test-equal "aab\n" (vim t "ab\n" (list "y" "l" "p")))
    (test-equal "bar foo baz\n" (vim t "foo bar baz\n" (list "d" "w" "w" "P")))
    (test-equal "a\na\na\na\n" (vim t "a\n" (list "y" "y" "3" "p"))))))

(test-group "test_paste_line_at_end_of_file"
  (with-shell (lambda (t)
    (test-equal "a\nb\na" (vim t "a\nb" (list "y" "y" "G" "p"))))))

(test-group "test_join_and_shift"
  (with-shell (lambda (t)
    (test-equal "a b\nc\n" (vim t "a\n   b\nc\n" (list "J")))
    (test-equal "a b c\n" (vim t "a\nb\nc\n" (list "3" "J")))
    (test-equal "    a\nb\n" (vim t "a\nb\n" (list ">" ">")))
    (test-equal "a\n" (vim t "    a\n" (list "<" "<")))
    (test-equal "    a\n    b\n" (vim t "a\nb\n" (list ">" "j"))))))

;; TestEditorVim: undo / redo

(test-group "test_insert_session_is_one_undo_step"
  (with-shell (lambda (t)
    (let ((e (session t '() (keys "i" "foo bar" 'cr "baz" ESC "u" (ex "q")) #t)))
      (test-equal '("") (lines e))))))

(test-group "test_undo_redo"
  (with-shell (lambda (t)
    (write-file t "u.txt" "a\nb\nc\n")
    (let ((e (session t '("u.txt") (keys "d" "d" "d" "d" "u" "u" 'ctrl-r (ex "q!")) #t)))
      (test-equal '("b" "c") (lines e))))))

(test-group "test_o_and_typing_undo_together"
  (with-shell (lambda (t)
    (test-equal "a\n" (vim t "a\n" (list "o" "b" ESC "u"))))))

;; TestEditorVim: visual mode

(test-group "test_visual_delete_and_yank"
  (with-shell (lambda (t)
    (test-equal " world\n" (vim t "hello world\n" (list "v" "e" "d")))
    (test-equal "ef\n" (vim t "ab\ncd\nef\n" (list "V" "j" "d")))
    (test-equal "ab\ncd\nab\n" (vim t "ab\ncd\n" (list "V" "y" "j" "p")))
    (test-equal "ABc\n" (vim t "abc\n" (list "v" "l" "U")))
    (test-equal "    a\n    b\n" (vim t "a\nb\n" (list "V" "j" ">"))))))

(test-group "test_visual_change"
  (with-shell (lambda (t)
    (test-equal "X def\n" (vim t "abc def\n" (list "v" "e" "c" "X" ESC))))))

(test-group "test_visual_selection_and_render"
  (with-shell (lambda (t)
    (let* ((e (vim-editor t '()))
           (handle (keymap-handle (editor-keymap e))))
      (buffer-insert! (editor-cur e) 0 0 "abcdef")
      (handle e #\l)
      (handle e #\v)
      (handle e #\l)
      (test-equal '((0 . 1) (0 . 3) #f) ((keymap-selection (editor-keymap e)) e))
      (editor-render! e)
      (test-assert (contains? (editor-last-frame e) "a\x1b;[7mbc\x1b;[27mdef"))
      (test-assert (contains? (editor-last-frame e) "-- VISUAL --"))))))

(test-group "test_visual_range_substitute"
  (with-shell (lambda (t)
    (test-equal "a\nb\nb\n" (vim t "a\na\na\n" (list "j" "V" "j" ":" "s/a/b/" 'cr))))))

;; TestEditorVim: search

(test-group "test_search_and_n"
  (with-shell (lambda (t)
    (write-file t "s.txt" "foo\nbar foo\nfoo\n")
    (test-equal '(2 . 0) (cur-pos (session t '("s.txt") (keys "/" "foo" 'cr "n" (ex "q")) #t)))
    (test-equal '(1 . 4) (cur-pos (session t '("s.txt") (keys "G" "?" "foo" 'cr (ex "q")) #t))))))

(test-group "test_search_not_found"
  (with-shell (lambda (t)
    (write-file t "s.txt" "foo\n")
    (let ((e (vim-editor t '("s.txt"))))
      (test-eq 'out-of-keys (run! e (keys "/" "zzz" 'cr)))
      (test-assert (contains? (editor-message e) "E486"))))))

(test-group "test_star_and_dn"
  (with-shell (lambda (t)
    (test-equal "foo\n" (vim t "x foo y foo\n" (list "l" "l" "*" "d" "0"))))))

;; TestEditorVim: ex commands

(test-group "test_substitute"
  (with-shell (lambda (t)
    (test-equal "b a\na\n" (vim t "a a\na\n" (ex "s/a/b/")))
    (test-equal "b b\nb\n" (vim t "a a\na\n" (ex "%s/a/b/g")))
    (test-equal "foo\n" (vim t "foo\n" (ex "s/o\\+/[&]/")))   ; vim-style \+ is not Python regex
    (test-equal "f[oo]\n" (vim t "foo\n" (ex "s/o+/[&]/")))
    (test-equal "b-a\n" (vim t "a-b\n" (ex "s/(\\w)-(\\w)/\\2-\\1/")))
    (test-equal "x\\y\n" (vim t "x/y\n" (ex "s#/#\\\\#"))))))

(test-group "substitute_flags_and_bad_input"
  (with-shell (lambda (t)
    (test-equal "-a-b--d-\n" (vim t "abxd\n" (ex "s/x*/-/g")))
    (test-equal "XbX\n" (vim t "AbA\n" (ex "s/a/X/gi")))
    (test-equal "a\nb\n" (vim t "a-b\n" (ex "s/-/\\n/")))
    (let ((e (vim-editor t '())))
      (test-eq 'out-of-keys (run! e (keys (ex "s/(/x/"))))
      (test-assert (contains? (editor-message e) "E486: Bad pattern")))
    (let ((e (vim-editor t '())))
      (buffer-insert! (editor-cur e) 0 0 "a")
      (test-eq 'out-of-keys (run! e (keys (ex "s/a/\\q/"))))
      (test-assert (contains? (editor-message e) "E486: Bad replacement"))))))

(test-group "test_q_refuses_with_changes"
  (with-shell (lambda (t)
    (write-file t "a.txt" "a\n")
    (let ((e (vim-editor t '("a.txt"))))
      (test-eq 'out-of-keys (run! e (keys "x" (ex "q"))))
      (test-assert (editor-running? e))
      (test-assert (contains? (editor-message e) "E37"))))))

(test-group "test_q_bang_discards"
  (with-shell (lambda (t)
    (write-file t "a.txt" "a\n")
    (let ((e (session t '("a.txt") (keys "x" (ex "q!")) #t)))
      (test-assert (not (editor-running? e)))
      (test-equal "a\n" (read-text t "a.txt"))))))

(test-group "test_ZZ_saves"
  (with-shell (lambda (t)
    (write-file t "a.txt" "ab\n")
    (session t '("a.txt") (keys "x" "Z" "Z") #t)
    (test-equal "b\n" (read-text t "a.txt")))))

(test-group "test_write_copy_keeps_buffer_file"
  (with-shell (lambda (t)
    (write-file t "a.txt" "ab\n")
    (let ((e (session t '("a.txt") (keys "x" (ex "w b.txt") (ex "q!")) #t)))
      (test-equal "b\n" (read-text t "b.txt"))
      (test-equal "ab\n" (read-text t "a.txt"))
      (test-equal "a.txt" (buffer-name (editor-cur e)))))))

(test-group "test_buffers_and_edit"
  (with-shell (lambda (t)
    (write-file t "one.txt" "1\n")
    (write-file t "two.txt" "22\n")
    (let ((e (session t '("one.txt") (keys (ex "e two.txt") "x" (ex "w") (ex "bp") (ex "q")) #t)))
      (test-equal "one.txt" (buffer-name (editor-cur e)))
      (test-equal "2\n" (read-text t "two.txt")))
    (let ((e (session t '("one.txt" "two.txt") (keys (ex "b 2") (ex "q")) #t)))
      (test-equal "two.txt" (buffer-name (editor-cur e)))))))

(test-group "test_unknown_ex_command"
  (with-shell (lambda (t)
    (let ((e (vim-editor t '())))
      (test-eq 'out-of-keys (run! e (keys (ex "frobnicate"))))
      (test-assert (contains? (editor-message e) "E492"))))))

(test-group "test_switch_keymaps"
  (with-shell (lambda (t)
    (let ((e (vim-editor t '())))
      (test-eq 'out-of-keys (run! e (keys (ex "emacs") "x")))
      (test-equal "emacs" (keymap-name (editor-keymap e)))
      (test-equal '("x") (lines e)))
    (let ((e (editor t '())))
      (test-eq 'out-of-keys (run! e (keys (meta #\x) "vim-mode" 'cr "x")))
      (test-equal "vim" (keymap-name (editor-keymap e)))
      (test-equal '("") (lines e))))))

(test-group "test_paste_in_normal_mode_inserts_text"
  (with-shell (lambda (t)
    (test-equal "dab\n" (vim t "ab\n" (list 'paste-start "dd" 'paste-end "x"))))))

(test-group "test_edit_command_vim_flag_and_option"
  (with-shell (lambda (t)
    (parameterize ((edit-interactive? (lambda (sh) #t)))
      (with-key-source (key-feeder (keys "i" "hi" ESC (ex "wq")))
        (lambda () (run-cmd t "edit --vim a.txt")))
      (test-equal "hi\n" (read-text t "a.txt"))
      (shell-option-set! (tc-shell t) "editor-keys" "vim")
      (with-key-source (key-feeder (keys "x" (ex "wq")))
        (lambda () (run-cmd t "edit a.txt")))
      (test-equal "i\n" (read-text t "a.txt"))
      (shell-option-set! (tc-shell t) "editor-keys" "nano")
      (test-assert (contains? (err t "edit a.txt") "editor-keys"))))))

(test-end "editor")
