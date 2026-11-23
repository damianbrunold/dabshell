;; dabshell editor: the edit command, a small full-screen editor with emacs
;; (default) or vim key bindings. The editor itself is in
;; (dabshell editor-buffer), (dabshell editor-core) and (dabshell editor-vim).

(define-library (dabshell editor)
  (export edit-interactive?)
  (import (scheme base)
          (scm terminal)
          (dabshell util)
          (dabshell core)
          (dabshell keys)
          (dabshell editor-buffer)
          (dabshell editor-core)
          (dabshell editor-vim))
  (begin

    ;; whether the shell writes to an interactive terminal (tests replace it)
    (define edit-interactive?
      (make-parameter
       (lambda (sh)
         (and (eq? (shell-outs sh) console-out)
              (guard (e (#t #f)) (terminal?))))))

    (define-command "edit"
      "[--vim|--emacs] [<file>...]   : edit files in a small editor with emacs (default) or vim key bindings; 'option editor-keys vim' makes vim the default"
      (lambda (sh args)
        (when (stdin-string sh)
          (println (shell-oute sh) "ERR: edit cannot read from a pipe")
          (command-failed!))
        (unless ((edit-interactive?) sh)
          (println (shell-oute sh) "ERR: edit needs an interactive terminal")
          (command-failed!))
        (let loop ((as args) (keys (shell-option sh "editor-keys" "emacs")) (files '()))
          (cond ((pair? as)
                 (if (member (car as) '("--vim" "--emacs"))
                     (loop (cdr as) (substring (car as) 2 (string-length (car as))) files)
                     (loop (cdr as) keys (cons (car as) files))))
                ((not (member keys '("emacs" "vim")))
                 (println (shell-oute sh) "ERR: option editor-keys must be emacs or vim, not " keys)
                 (command-failed!))
                (else
                 (let ((ed (make-editor sh (shell-outs sh) (lambda () (cons (terminal-columns) (terminal-rows)))
                                        keys)))
                   (for-each (lambda (arg)
                               (guard (e ((editor-error? e)
                                          (println (shell-oute sh) "ERR: " (editor-error-message e))
                                          (command-failed!))
                                         ((or (file-error? e) (error-object? e))
                                          (println (shell-oute sh) "ERR: " arg ": " (report-error e))
                                          (command-failed!)))
                                 (editor-open-file! ed arg)))
                             (reverse files))
                   (let ((bufs (editor-buffers ed)))
                     (when (pair? bufs)
                       (editor-select! ed (car bufs))
                       (editor-prev-set! ed (and (pair? (cdr bufs)) (cadr bufs)))))
                   (with-raw-terminal (lambda () (editor-run! ed)))))))))))
