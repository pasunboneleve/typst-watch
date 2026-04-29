;;; typst-watch-tests.el --- Tests for typst-watch  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'typst-watch)

(ert-deftest typst-watch-default-output-file-test ()
  "Default output replaces the source extension with PDF."
  (should (equal (typst-watch-default-output-file "/tmp/paper.typ")
                 "/tmp/paper.pdf"))
  (should (equal (typst-watch-default-output-file "/tmp/paper")
                 "/tmp/paper.pdf")))

(ert-deftest typst-watch-viewer-candidates-test ()
  "Viewer candidates prefer explicit configuration, then zathura, then fallback."
  (let ((typst-watch-pdf-viewer "okular")
        (typst-watch-fallback-pdf-viewer "evince"))
    (should (equal (typst-watch--viewer-candidates)
                   '("okular" "zathura" "evince"))))
  (let ((typst-watch-pdf-viewer nil)
        (typst-watch-fallback-pdf-viewer "evince"))
    (should (equal (typst-watch--viewer-candidates)
                   '("zathura" "evince")))))

(ert-deftest typst-watch-select-viewer-test ()
  "Viewer selection returns the first executable candidate."
  (let ((typst-watch-pdf-viewer nil)
        (typst-watch-fallback-pdf-viewer "evince"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program)
                 (and (equal program "evince") "/usr/bin/evince"))))
      (should (equal (typst-watch--select-viewer) "evince"))))
  (let ((typst-watch-pdf-viewer nil)
        (typst-watch-fallback-pdf-viewer "evince"))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil)))
      (should-error (typst-watch--select-viewer) :type 'user-error))))

(ert-deftest typst-watch-source-file-requires-file-test ()
  "Source file lookup fails clearly for non-file buffers."
  (with-temp-buffer
    (should-error (typst-watch--source-file) :type 'user-error)))

(ert-deftest typst-watch-process-buffer-name-is-path-specific-test ()
  "Process buffer names differ for same-named files in different directories."
  (should-not
   (equal (typst-watch--process-buffer-name "watch" "/tmp/a/main.typ")
          (typst-watch--process-buffer-name "watch" "/tmp/b/main.typ"))))

(ert-deftest typst-watch-start-replaces-live-process-test ()
  "Starting watch stops an existing buffer-local process."
  (let ((new-process 'new-process)
        deleted-process
        started-command)
    (with-temp-buffer
      (setq-local buffer-file-name "/tmp/main.typ")
      (setq-local typst-watch--watch-process 'old-process)
      (let ((typst-watch-typst-command "typst"))
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (program) (and (equal program "typst") "/usr/bin/typst")))
                  ((symbol-function 'process-live-p)
                   (lambda (process) (eq process 'old-process)))
                  ((symbol-function 'delete-process)
                   (lambda (process) (setq deleted-process process)))
                  ((symbol-function 'typst-watch--start-process)
                   (lambda (_name _buffer command)
                     (setq started-command command)
                     new-process)))
          (should (eq (typst-watch-start) new-process))
          (should (eq deleted-process 'old-process))
          (should (equal started-command
                         '("typst" "watch" "/tmp/main.typ" "/tmp/main.pdf"))))))))

(ert-deftest typst-watch-open-viewer-reuses-live-process-test ()
  "Opening a viewer reuses a live process already tied to the same PDF."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/main.typ")
    (setq-local typst-watch--viewer-process 'viewer-process)
    (setq-local typst-watch--viewer-output-file "/tmp/main.pdf")
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (eq process 'viewer-process)))
              ((symbol-function 'file-exists-p)
               (lambda (file) (equal file "/tmp/main.pdf")))
              ((symbol-function 'file-truename) #'identity)
              ((symbol-function 'typst-watch--select-viewer)
               (lambda () "zathura"))
              ((symbol-function 'typst-watch--start-process)
               (lambda (&rest _args)
                 (ert-fail "viewer should be reused"))))
      (should (eq (typst-watch-open-viewer) 'viewer-process)))))

(ert-deftest typst-watch-open-viewer-reports-missing-pdf-first-test ()
  "Opening a viewer reports a missing PDF before checking viewer executables."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/main.typ")
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_file) nil))
              ((symbol-function 'typst-watch--select-viewer)
               (lambda ()
                 (ert-fail "viewer selection should not run"))))
      (should-error (typst-watch-open-viewer) :type 'user-error))))

(ert-deftest typst-watch-truncates-process-buffer-test ()
  "Process buffers keep only the configured amount of output."
  (with-temp-buffer
    (let ((typst-watch-process-buffer-max-size 5))
      (insert "123456789")
      (typst-watch--truncate-current-buffer)
      (should (equal (buffer-string) "56789")))))

(ert-deftest typst-watch-compile-fails-loudly-test ()
  "Compile reports a user-facing error when Typst exits non-zero."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/main.typ")
    (let ((typst-watch-typst-command "typst"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (program) (and (equal program "typst") "/usr/bin/typst")))
                ((symbol-function 'call-process)
                 (lambda (&rest _args) 1)))
        (should-error (typst-watch-compile) :type 'user-error)))))

(ert-deftest typst-watch-compile-signal-fails-loudly-test ()
  "Compile reports a user-facing error when Typst exits from a signal."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/main.typ")
    (let ((typst-watch-typst-command "typst"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (program) (and (equal program "typst") "/usr/bin/typst")))
                ((symbol-function 'call-process)
                 (lambda (&rest _args) "terminated by signal")))
        (should-error (typst-watch-compile) :type 'user-error)))))

(ert-deftest typst-watch-compile-opens-viewer-test ()
  "Successful compile opens the viewer when configured to do so."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/main.typ")
    (let ((typst-watch-typst-command "typst")
          (typst-watch-open-viewer-after-compile t)
          opened-viewer)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (program) (and (equal program "typst") "/usr/bin/typst")))
                ((symbol-function 'call-process)
                 (lambda (&rest _args) 0))
                ((symbol-function 'typst-watch-open-viewer)
                 (lambda () (setq opened-viewer t))))
        (should (equal (typst-watch-compile) "/tmp/main.pdf"))
        (should opened-viewer)))))

(ert-deftest typst-watch-typst-ts-advice-is-idempotent-test ()
  "Installing typst-ts advice twice adds only one advice member."
  (cl-letf (((symbol-function 'typst-ts-compile) (lambda () 'compiled)))
    (unwind-protect
        (progn
          (typst-watch--install-typst-ts-advice)
          (typst-watch--install-typst-ts-advice)
          (let ((count 0))
            (advice-mapc
             (lambda (advice _props)
               (when (eq advice #'typst-watch--after-typst-ts-command)
                 (setq count (1+ count))))
             'typst-ts-compile)
            (should (= count 1))))
      (typst-watch--remove-typst-ts-advice))))

;;; typst-watch-tests.el ends here
