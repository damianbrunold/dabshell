(import (scheme base) (scheme process-context) (scm fs) (scm module) (scm test))
(define root (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (append (list (join-path root "src") (join-path root "tests"))
                             (module-search-path)))
(import (srfi 1) (scm system) (scm net http server) (scm net http request) (scm net http response)
        (dabshell util) (dabshell core) (dabshell builtins) (dabshell data) (dabshell testing))
(test-runner-factory scm-test-runner)
(test-begin "data")

(define-syntax shell-test
  (syntax-rules ()
    ((_ name t body ...) (test-group name (with-shell (lambda (t) body ...))))))

;; a minimal cat for piping files into json, unless a real one is loaded
(unless (any (lambda (c) (string=? (cmd-name c) "cat")) (registered-commands))
  (define-command "cat" "<file>   : test helper"
    (lambda (sh args)
      (print-to (shell-outs sh) (utf8->string (read-file-bytes (shell-path sh (car args))))))))

(define (exists? t name) (path-exists?* (file-path t name)))

;; ------------------------------------------------------------------
;; json

(define-syntax json-test
  (syntax-rules ()
    ((_ name t body ...)
     (shell-test name t
       (write-file t "data.json" "{\"name\":\"alice\",\"age\":30,\"tags\":[\"a\",\"b\",\"c\"]}")
       body ...))))

(json-test "test_json_pretty_print" t
  (let ((o (out t "json data.json")))
    (test-assert (string-contains? o "\"name\""))
    (test-assert (string-contains? o "\n  "))))

(json-test "test_json_compact" t
  (test-equal 1 (length (splitlines (out t "json -c data.json")))))

(json-test "test_json_path_string" t
  (test-equal "alice" (out t "json -p name data.json")))

(json-test "test_json_path_index" t
  (test-equal "b" (out t "json -p tags.1 data.json")))

(json-test "test_json_path_object" t
  (write-file t "n.json" "{\"users\":[{\"name\":\"x\"},{\"name\":\"y\"}]}")
  (test-equal "y" (out t "json -p users.1.name n.json")))

(json-test "test_json_invalid" t
  (write-file t "bad.json" "{not json")
  (test-assert (string-contains? (err t "json bad.json") "ERR")))

(json-test "test_json_pipe" t
  (test-equal "30" (out t "cat data.json | json -p age")))

;; tests added in the port

(json-test "test_json_python_output" t
  (test-equal "{\"name\": \"alice\", \"age\": 30, \"tags\": [\"a\", \"b\", \"c\"]}"
              (out t "json -c data.json"))
  (test-equal "{\n    \"name\": \"alice\",\n    \"age\": 30,\n    \"tags\": [\n        \"a\",\n        \"b\",\n        \"c\"\n    ]\n}"
              (out t "json -i 4 data.json"))
  (write-file t "v.json" "{\"f\": [1.0, 1e16, 0.1, 1e-7, -0.0, 2.5E3], \"e\": {}, \"l\": [], \"n\": null, \"b\": [true, false], \"s\": \"\\u00e4\\n\\\"\\ud83d\\ude00\\u0001\", \"a\": 1, \"a\": 2}")
  (test-equal "{\"f\": [1.0, 1e+16, 0.1, 1e-07, -0.0, 2500.0], \"e\": {}, \"l\": [], \"n\": null, \"b\": [true, false], \"s\": \"\x00e4;\\n\\\"\x1F600;\\u0001\", \"a\": 2}"
              (out t "json -c v.json"))
  (test-equal "-0.0" (out t "json -p f.-2 v.json")))

(json-test "test_json_errors" t
  (write-file t "bad.json" "{not json")
  (test-equal "ERR: json: parse error: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"
              (err t "json bad.json"))
  (write-file t "bad2.json" "[1,\n 2,]")
  (test-equal "ERR: json: parse error: Illegal trailing comma before end of array: line 2 column 3 (char 6)"
              (err t "json bad2.json"))
  (write-file t "bad3.json" "[1] x")
  (test-equal "ERR: json: parse error: Extra data: line 1 column 5 (char 4)" (err t "json bad3.json"))
  (test-equal "ERR: json: 'nope'" (err t "json -p nope data.json"))
  (test-equal "ERR: json: list index out of range" (err t "json -p tags.5 data.json"))
  (test-equal "ERR: json: cannot descend into str at 'x'" (err t "json -p name.x data.json"))
  (test-equal "ERR: json: invalid literal for int() with base 10: 'x'" (err t "json -p tags.x data.json"))
  (test-equal "ERR: json: unknown option '-z'" (err t "json -z data.json"))
  (test-equal "ERR: json: invalid indent 'x'" (err t "json -i x data.json"))
  (test-equal "ERR: json: only one file allowed" (err t "json a b"))
  (test-equal "ERR: json: no input" (err t "json"))
  (test-assert (string-ends? (err t "json nope.json") "nope.json not found")))

;; ------------------------------------------------------------------
;; fetch, against a local HTTP server

(define requests '())
(define port (+ 20000 (modulo (current-pid) 20000)))
(define server
  (tcp-http-serve port
                  (lambda (req)
                    (set! requests (cons req requests))
                    (let ((url (http-request-url req)))
                      (cond ((string-ends? url "/x") (http-ok "hello"))
                            ((string-ends? url "/bin")
                             (make-http-response 200 '(("Content-Type" . "application/octet-stream"))
                                                 (bytevector 112 97 121 108 111 97 100 0 255)))
                            ((string-ends? url "/latin")
                             (make-http-response 200 '(("Content-Type" . "text/plain; charset=ISO-8859-1"))
                                                 (bytevector 104 233)))
                            (else (http-not-found)))))
                  4 "127.0.0.1"))
(define base (string-append "http://127.0.0.1:" (number->string port)))

(shell-test "test_fetch_to_stdout" t
  (test-equal "hello" (out t (string-append "fetch " base "/x")))
  (test-equal "/x" (http-request-url (car requests))))

(shell-test "test_fetch_to_file" t
  (run-cmd t (string-append "fetch -o out.bin " base "/bin"))
  (test-equal (bytevector 112 97 121 108 111 97 100 0 255) (read-file t "out.bin")))

(shell-test "test_fetch_headers" t
  (run-cmd t (string-append "fetch -H X-Foo:bar " base "/x"))
  (test-equal "bar" (http-request-header (car requests) "X-Foo")))

(shell-test "test_fetch_missing_url" t
  (test-assert (string-contains? (err t "fetch") "ERR")))

(shell-test "test_fetch_charset_and_errors" t
  (test-equal "h\xE9;" (out t (string-append "fetch " base "/latin")))
  (test-equal "ERR: fetch: HTTP Error 404: Not Found" (err t (string-append "fetch " base "/missing")))
  (test-equal "ERR: fetch: invalid header 'nocolon'" (err t (string-append "fetch -H nocolon " base "/x")))
  (test-equal "ERR: fetch: only one URL allowed" (err t "fetch a b"))
  (test-equal "ERR: fetch: unknown option '-q'" (err t "fetch -q a"))
  (test-equal "ERR: fetch: invalid timeout 'soon'" (err t "fetch --timeout soon a"))
  (test-equal "ERR: fetch: -o requires an argument" (err t "fetch -o")))

;; ------------------------------------------------------------------
;; archives

(define-syntax archive-test
  (syntax-rules ()
    ((_ name t body ...)
     (shell-test name t
       (write-file t "src/a.txt" "alpha")
       (write-file t "src/b.txt" "beta")
       body ...))))

(archive-test "test_tar_create_list_extract" t
  (run-cmd t "tar -c bundle.tar src")
  (test-assert (exists? t "bundle.tar"))
  (test-assert (string-contains? (string-replace* (out t "tar -t bundle.tar") "\\" "/") "src/a.txt"))
  (make-dirs (file-path t "out"))
  (run-cmd t "tar -x bundle.tar -C out")
  (test-assert (exists? t "out/src/a.txt")))

(archive-test "test_tar_gzip" t
  (run-cmd t "tar -c bundle.tar.gz src")
  (test-assert (exists? t "bundle.tar.gz"))
  (let ((bv (read-file t "bundle.tar.gz")))
    (test-equal '(#x1f #x8b) (list (bytevector-u8-ref bv 0) (bytevector-u8-ref bv 1)))))

(archive-test "test_tar_missing_mode" t
  (test-assert (string-contains? (err t "tar bundle.tar") "ERR")))

(archive-test "test_zip_create_list_extract" t
  (run-cmd t "zip -c bundle.zip src")
  (test-assert (exists? t "bundle.zip"))
  (test-assert (string-contains? (string-replace* (out t "zip -t bundle.zip") "\\" "/") "src/a.txt"))
  (make-dirs (file-path t "out"))
  (run-cmd t "zip -x bundle.zip -C out")
  (test-assert (exists? t "out/src/a.txt")))

;; tests added in the port

(archive-test "test_tar_listing_and_roundtrip" t
  (write-file t "src/sub/c.txt" "gamma")
  (run-cmd t "tar -c bundle.tgz src")
  (test-equal "src\nsrc/a.txt\nsrc/b.txt\nsrc/sub\nsrc/sub/c.txt" (out t "tar -t bundle.tgz"))
  (run-cmd t "tar -x bundle.tgz -C out")
  (test-equal "gamma" (read-text t "out/src/sub/c.txt"))
  (run-cmd t "tar -c bundle.tar src")
  (test-equal 0 (modulo (bytevector-length (read-file t "bundle.tar")) 10240)))

(archive-test "test_tar_long_and_unicode_names" t
  (let ((long (string-append "src/" (make-string 120 #\d) "/" (make-string 80 #\f) ".txt")))
    (write-file t long "deep")
    (write-file t "src/\xE4;\x20AC;.txt" "unicode")
    (run-cmd t "tar -c u.tar src")
    (let ((listing (out t "tar -t u.tar")))
      (test-assert (string-contains? listing long))
      (test-assert (string-contains? listing "src/\xE4;\x20AC;.txt")))
    (run-cmd t "tar -x u.tar -C out")
    (test-equal "deep" (read-text t (string-append "out/" long)))
    (test-equal "unicode" (read-text t "out/src/\xE4;\x20AC;.txt"))))

(archive-test "test_tar_bz2_xz" t
  (run-cmd t "tar -c b.tar.bz2 src")
  (run-cmd t "tar -c b.tar.xz src")
  (test-equal "src\nsrc/a.txt\nsrc/b.txt" (out t "tar -t b.tar.bz2"))
  (test-equal "src\nsrc/a.txt\nsrc/b.txt" (out t "tar -t b.tar.xz"))
  (run-cmd t "tar -x b.tar.xz -C out")
  (test-equal "beta" (read-text t "out/src/b.txt")))

(archive-test "test_archive_errors" t
  (test-equal "ERR: tar: specify exactly one of -c/-x/-t" (err t "tar -c -t x.tar"))
  (test-equal "ERR: tar: -C requires an argument" (err t "tar -x x.tar -C"))
  (test-equal "ERR: tar: unknown option '-v'" (err t "tar -v x.tar"))
  (test-equal "ERR: tar: -c requires at least one file" (err t "tar -c x.tar"))
  (test-assert (string-starts? (err t "tar -t nope.tar") "ERR: tar: [Errno 2] No such file or directory: "))
  (test-assert (string-starts? (err t "tar -c x.tar nope") "ERR: tar: [Errno 2] No such file or directory: "))
  (write-file t "bad.tar" (make-string 600 #\x))
  (test-equal "ERR: tar: invalid header" (err t "tar -t bad.tar"))
  (write-file t "bad.tar.gz" "not gzipped")
  (test-equal "ERR: tar: not a gzip file" (err t "tar -t bad.tar.gz"))
  (test-equal "ERR: zip: missing mode or archive" (err t "zip -x"))
  (test-equal "ERR: zip: -c requires at least one file" (err t "zip -c x.zip"))
  (test-equal "ERR: zip: File is not a zip file" (err t "zip -t bad.tar")))

(archive-test "test_archive_refuses_outside_dest" t
  ;; a member named ../evil.txt must not be written outside the destination
  (write-file t "evil.txt" "x")
  (make-dirs (file-path t "w"))
  (run-cmd t "cd w")
  (run-cmd t "zip -c ../e.zip ../evil.txt")
  (run-cmd t "tar -c ../e.tar ../evil.txt")
  (run-cmd t "cd ..")
  (test-equal "../evil.txt" (out t "zip -t e.zip"))
  (test-equal "ERR: zip: refusing to extract outside dest: ../evil.txt" (err t "zip -x e.zip -C d"))
  (test-equal "ERR: tar: refusing to extract outside dest: ../evil.txt" (err t "tar -x e.tar -C d")))

(archive-test "test_zip_directory_names" t
  (write-file t "src/sub/c.txt" "gamma")
  (run-cmd t "zip -c z.zip src src/a.txt")
  (test-equal "src/a.txt\nsrc/b.txt\nsrc/sub/c.txt" (out t "zip -t z.zip"))
  (run-cmd t "zip -c z2.zip src/sub/")
  (test-equal "c.txt" (out t "zip -t z2.zip"))
  (run-cmd t "zip -x z.zip -C out")
  (test-equal "gamma" (read-text t "out/src/sub/c.txt")))

(server-stop server 0)
(test-end "data")
