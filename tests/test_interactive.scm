;; Tests for the interactive line editor: editing keys, history, reverse
;; search, completion and accepting lines, driven by a key source.
;; Run: scm tests/test_interactive.scm

(import (scheme base)
        (scheme process-context)
        (scm fs)
        (scm module)
        (scm test))

(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))

(import (dabshell util)
        (dabshell core)
        (dabshell builtins)
        (dabshell keys)
        (dabshell interactive)
        (dabshell testing))

(test-runner-factory scm-test-runner)
(test-begin "interactive")

;; feed keys (a string is typed character by character) to a fresh line
;; editor; returns the editor after the keys
(define (type t . keys)
  (let ((ed (make-editor (tc-shell t) "" 0 #f "" -1 #f))
        (ses (shell-session (tc-shell t))))
    (define (key! k)
      (unless (and (ed-search? ed) (search-key ed k))
        (handle-key! ed k)))
    ;; a new prompt starts outside the history, as after executing a line
    (session-history-index-set! ses -1)
    (session-history-current-set! ses "")
    (for-each (lambda (k)
                (if (string? k) (for-each key! (string->list k)) (key! k)))
              keys)
    ed))

(define (line-after t . keys) (ed-line (apply type t keys)))

(test-group "editing"
  (with-shell
   (lambda (t)
     (test-equal "typing" "echo hi" (line-after t "echo hi"))
     (test-equal "backspace" "echo h" (line-after t "echo hi" 'backspace))
     (test-equal "insert in the middle" "echo Xhi" (line-after t "echo hi" 'left 'left "X"))
     (test-equal "home inserts at start" "Xecho" (line-after t "echo" 'home "X"))
     (test-equal "delete at cursor" "cho" (line-after t "echo" 'home 'delete))
     (test-equal "ctrl-w deletes a word" "echo " (line-after t "echo hello" 'ctrl-w))
     (test-equal "ctrl-w at start of word" "hi" (line-after t "echo hi" 'ctrl-left 'ctrl-w))
     (test-equal "esc clears" "" (line-after t "echo hi" 'esc))
     (test-equal "ctrl-k kills to end" "ec" (line-after t "echo" 'left 'left 'ctrl-k))
     (test-equal "ctrl-u kills to start" "ho" (line-after t "echo" 'left 'left 'ctrl-u))
     (test-equal "unknown keys are ignored" "ab" (line-after t "a" 'f5 'page-up "b"))
     (let ((ed (type t "one two three" 'ctrl-left)))
       (test-equal "ctrl-left to word start" 8 (ed-index ed)))
     (let ((ed (type t "one two three" 'home 'ctrl-right)))
       (test-equal "ctrl-right to next word" 4 (ed-index ed))))))

(test-group "accepting lines"
  (with-shell
   (lambda (t)
     (let* ((ed (type t "set greeting hello" 'cr)))
       (test-equal "line is cleared" "" (ed-line ed))
       (test-equal "command ran" "hello" (out t "get greeting"))
       (test-equal "history recorded" '("set greeting hello")
                   (session-history (shell-session (tc-shell t)))))
     (test-equal "ctrl-c on empty line exits" #f
                 (handle-key! (make-editor (tc-shell t) "" 0 #f "" -1 #f) 'ctrl-c))
     (test-equal "exit command exits" #f
                 (handle-key! (make-editor (tc-shell t) "exit" 4 #f "" -1 #f) 'cr)))))

(test-group "history"
  (with-shell
   (lambda (t)
     (type t "set a 1" 'cr "set b 2" 'cr)
     (test-equal "up recalls the last" "set b 2" (line-after t 'up))
     (test-equal "up twice" "set a 1" (line-after t 'up 'up))
     (test-equal "up stops at oldest" "set a 1" (line-after t 'up 'up 'up))
     (test-equal "down returns to the typed line" "draft" (line-after t "draft" 'up 'down))
     (test-equal "!n recalls entry n" "set a 1" (line-after t "!0" 'cr)))))

(test-group "reverse search"
  (with-shell
   (lambda (t)
     (type t "set alpha 1" 'cr "set beta 2" 'cr "set alphabet 3" 'cr)
     (test-equal "finds the newest match" "set alphabet 3" (line-after t 'ctrl-r "alpha" 'cr))
     (test-equal "ctrl-r again finds older" "set alpha 1" (line-after t 'ctrl-r "alpha" 'ctrl-r 'cr))
     (test-equal "esc cancels" "" (line-after t 'ctrl-r "beta" 'esc))
     (test-equal "other key accepts and is handled" "set beta 2X"
                 (line-after t 'ctrl-r "beta" 'end "X")))))

(test-group "completion"
  (with-shell
   (lambda (t)
     (write-file t "readme-file.txt" "x")
     (test-equal "completes a file" "cat readme-file.txt " (line-after t "cat read" 'tab))
     (make-dirs (file-path t "subdir"))
     (test-equal "completes a directory" (string-append "cd subdir" (if is-win? "\\" "/"))
                 (line-after t "cd sub" 'tab)))))

(test-end "interactive")
