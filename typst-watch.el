;;; typst-watch.el --- Run typst watch from Typst buffers  -*- lexical-binding: t; -*-

;; Author: Daniel Vianna and contributors
;; Maintainer: Daniel Vianna <dmlvianna@gmail.com>
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, tex, processes
;; URL: https://github.com/pasunboneleve/typst-watch
;; SPDX-License-Identifier: MIT
;; Version: 0.1.0

;;; Commentary:

;; typst-watch keeps a buffer-local `typst watch' process alive while editing
;; Typst files.  While `typst-watch-mode' is active, major-mode preview
;; keybindings open the generated PDF in a configurable viewer.  By default, it
;; prefers zathura when available and falls back to evince.

;;; Code:

(require 'cl-lib)

(defgroup typst-watch nil
  "Run Typst watch and preview PDFs from Typst buffers."
  :group 'tools
  :prefix "typst-watch-")

(defvar typst-watch-mode-map (make-sparse-keymap)
  "Keymap for `typst-watch-mode'.")

(defvar typst-watch--remapped-preview-commands nil
  "Preview commands currently remapped in `typst-watch-mode-map'.")

(defun typst-watch--populate-mode-map (preview-commands)
  "Mutate `typst-watch-mode-map' to remap PREVIEW-COMMANDS."
  (dolist (command typst-watch--remapped-preview-commands)
    (define-key typst-watch-mode-map (vector 'remap command) nil))
  (dolist (command preview-commands)
    (define-key typst-watch-mode-map
                (vector 'remap command)
                #'typst-watch-preview))
  (setq typst-watch--remapped-preview-commands preview-commands))

(defun typst-watch--set-preview-commands (symbol value)
  "Set SYMBOL to VALUE and rebuild `typst-watch-mode-map'."
  (set-default symbol value)
  (typst-watch--populate-mode-map value))

(defcustom typst-watch-typst-command "typst"
  "Path to the Typst executable."
  :type 'string
  :group 'typst-watch)

(defcustom typst-watch-pdf-viewer nil
  "Preferred PDF viewer executable.
When nil, `typst-watch' uses zathura when available, then falls back to
`typst-watch-fallback-pdf-viewer'."
  :type '(choice (const :tag "Auto" nil)
                 (string :tag "Executable"))
  :group 'typst-watch)

(defcustom typst-watch-fallback-pdf-viewer "evince"
  "Fallback PDF viewer executable."
  :type 'string
  :group 'typst-watch)

(defcustom typst-watch-start-on-enable t
  "When non-nil, start `typst watch' when `typst-watch-mode' is enabled."
  :type 'boolean
  :group 'typst-watch)

(defcustom typst-watch-preview-commands
  '(typst-ts-preview
    typst-ts-compile-and-preview
    typst-ts-mode-preview
    typst-ts-mode-compile-and-preview
    typst-preview
    typst-compile-and-preview)
  "Major-mode preview commands remapped to `typst-watch-preview'."
  :type '(repeat symbol)
  :set #'typst-watch--set-preview-commands
  :group 'typst-watch)

(defcustom typst-watch-detect-existing-viewer t
  "When non-nil, detect external PDF viewers already showing the output file."
  :type 'boolean
  :group 'typst-watch)

(defcustom typst-watch-output-file-function #'typst-watch-default-output-file
  "Function that returns the PDF output path for a Typst source file."
  :type 'function
  :group 'typst-watch)

(defcustom typst-watch-process-buffer-max-size 65536
  "Maximum characters kept in typst-watch process buffers."
  :type 'natnum
  :group 'typst-watch)

(defvar-local typst-watch--watch-process nil
  "Buffer-local `typst watch' process.")

(defvar-local typst-watch--viewer-process nil
  "Buffer-local PDF viewer process started by typst-watch.")

(defvar-local typst-watch--viewer-output-file nil
  "PDF file currently associated with `typst-watch--viewer-process'.")

(typst-watch--populate-mode-map typst-watch-preview-commands)

(defun typst-watch-default-output-file (source-file)
  "Return the default PDF path for SOURCE-FILE."
  (concat (file-name-sans-extension source-file) ".pdf"))

(defun typst-watch--source-file ()
  "Return the current buffer file or signal a user-facing error."
  (or buffer-file-name
      (user-error "Current buffer is not visiting a file")))

(defun typst-watch--output-file (&optional source-file)
  "Return the PDF output path for SOURCE-FILE or the current buffer."
  (funcall typst-watch-output-file-function
           (or source-file (typst-watch--source-file))))

(defun typst-watch--process-buffer-name (kind source-file)
  "Return a process buffer name for KIND and SOURCE-FILE."
  (format "*typst-watch-%s:%s:%s*"
          kind
          (file-name-nondirectory source-file)
          (substring (secure-hash 'sha1 (expand-file-name source-file)) 0 8)))

(defun typst-watch--executable-or-error (program label)
  "Return PROGRAM when executable, otherwise signal a user-facing LABEL error."
  (or (executable-find program)
      (user-error "%s executable not found: %s" label program)))

(defun typst-watch--viewer-candidates ()
  "Return PDF viewer candidates in preference order."
  (delete-dups
   (delq nil
         (list typst-watch-pdf-viewer
               "zathura"
               typst-watch-fallback-pdf-viewer))))

(defun typst-watch--select-viewer ()
  "Return the first executable PDF viewer candidate."
  (let ((viewer (cl-find-if #'executable-find (typst-watch--viewer-candidates))))
    (or viewer
        (user-error "No PDF viewer found.  Set typst-watch-pdf-viewer or install zathura/evince"))))

(defun typst-watch--same-viewer-p (output-file)
  "Return non-nil when the current viewer process is live for OUTPUT-FILE."
  (and (process-live-p typst-watch--viewer-process)
       typst-watch--viewer-output-file
       (string= (file-truename typst-watch--viewer-output-file)
                (file-truename output-file))))

(defun typst-watch--process-args (pid)
  "Return command-line arguments for PID, or nil when unavailable."
  (let ((args (cdr (assq 'args (process-attributes pid)))))
    (cond
     ((stringp args) (split-string-and-unquote args))
     ((listp args) args)
     (t nil))))

(defun typst-watch--arg-matches-file-p (arg output-file)
  "Return non-nil when ARG names OUTPUT-FILE."
  (and (stringp arg)
       (let ((arg-truename (ignore-errors (file-truename arg)))
             (output-truename (file-truename output-file)))
         (or (string= arg output-file)
             (and arg-truename
                  (string= arg-truename output-truename))))))

(defun typst-watch--args-reference-file-p (args output-file)
  "Return non-nil when ARGS reference OUTPUT-FILE."
  (cl-some
   (lambda (arg)
     (typst-watch--arg-matches-file-p arg output-file))
   args))

(defun typst-watch--viewer-program-p (program)
  "Return non-nil when PROGRAM names a configured PDF viewer."
  (let ((program-name (and (stringp program)
                           (file-name-nondirectory program))))
    (and program-name
         (member program-name
                 (mapcar #'file-name-nondirectory
                         (typst-watch--viewer-candidates))))))

(defun typst-watch--viewer-args-reference-file-p (args output-file)
  "Return non-nil when ARGS are a PDF viewer command for OUTPUT-FILE."
  (and (typst-watch--viewer-program-p (car args))
       (typst-watch--args-reference-file-p (cdr args) output-file)))

(defun typst-watch--external-viewer-p (output-file)
  "Return non-nil when an external viewer already references OUTPUT-FILE."
  (and typst-watch-detect-existing-viewer
       (cl-some
        (lambda (pid)
          (typst-watch--viewer-args-reference-file-p
           (typst-watch--process-args pid)
           output-file))
        (list-system-processes))))

(defun typst-watch--viewer-running-p (output-file)
  "Return non-nil when OUTPUT-FILE already has a known live viewer."
  (or (typst-watch--same-viewer-p output-file)
      (typst-watch--external-viewer-p output-file)))

(defun typst-watch--truncate-current-buffer ()
  "Trim the current process buffer to `typst-watch-process-buffer-max-size'."
  (when (and (natnump typst-watch-process-buffer-max-size)
             (> (buffer-size) typst-watch-process-buffer-max-size))
    (let ((delete-count (- (buffer-size) typst-watch-process-buffer-max-size)))
      (delete-region (point-min)
                     (+ (point-min) delete-count)))))

(defun typst-watch--process-filter (process output)
  "Append PROCESS OUTPUT and keep the process buffer bounded."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((moving (= (point) (process-mark process))))
          (save-excursion
            (goto-char (process-mark process))
            (insert output)
            (set-marker (process-mark process) (point))
            (typst-watch--truncate-current-buffer))
          (when moving
            (goto-char (process-mark process))))))))

(defun typst-watch--start-process (name buffer command)
  "Start NAME in BUFFER with COMMAND and return the process."
  (make-process
   :name name
   :buffer buffer
   :command command
   :filter #'typst-watch--process-filter
   :noquery t))

(defun typst-watch-start ()
  "Start `typst watch' for the current Typst buffer."
  (let* ((source-file (typst-watch--source-file))
         (output-file (typst-watch--output-file source-file))
         (process-buffer (get-buffer-create
                          (typst-watch--process-buffer-name "watch" source-file))))
    (typst-watch--executable-or-error typst-watch-typst-command "Typst")
    (when (process-live-p typst-watch--watch-process)
      (delete-process typst-watch--watch-process))
    (setq typst-watch--watch-process
          (typst-watch--start-process
           "typst-watch"
           process-buffer
           (list typst-watch-typst-command "watch" source-file output-file)))
    (message "Started typst watch: %s" output-file)
    typst-watch--watch-process))

(defun typst-watch-stop ()
  "Stop the buffer-local `typst watch' process."
  (when (process-live-p typst-watch--watch-process)
    (delete-process typst-watch--watch-process)
    (message "Stopped typst watch"))
  (setq typst-watch--watch-process nil))

(defun typst-watch-open-viewer ()
  "Open the current buffer's PDF output in the configured viewer.
If a live viewer process already shows this PDF, reuse it."
  (let* ((source-file (typst-watch--source-file))
         (output-file (typst-watch--output-file source-file))
         (process-buffer (get-buffer-create
                          (typst-watch--process-buffer-name "viewer" source-file))))
    (unless (file-exists-p output-file)
      (user-error "PDF output does not exist: %s" output-file))
    (unless (typst-watch--viewer-running-p output-file)
      (let ((viewer (typst-watch--select-viewer)))
        (when (process-live-p typst-watch--viewer-process)
          (delete-process typst-watch--viewer-process))
        (setq typst-watch--viewer-process
              (typst-watch--start-process
               "typst-watch-viewer"
               process-buffer
               (list viewer output-file)))
        (setq typst-watch--viewer-output-file output-file)
        (message "Opened Typst PDF with %s: %s" viewer output-file)))
    typst-watch--viewer-process))

;;;###autoload
(defun typst-watch-preview ()
  "Open the current Typst PDF output in the configured viewer."
  (interactive)
  (typst-watch-open-viewer))

;;;###autoload
(define-minor-mode typst-watch-mode
  "Run `typst watch' while the current Typst buffer is alive."
  :lighter " TypstWatch"
  (if typst-watch-mode
      (progn
        (when typst-watch-start-on-enable
          (typst-watch-start))
        (add-hook 'kill-buffer-hook #'typst-watch-stop nil t))
    (remove-hook 'kill-buffer-hook #'typst-watch-stop t)
    (typst-watch-stop)))

;;;###autoload
(define-minor-mode typst-watch-auto-mode
  "Automatically enable `typst-watch-mode' in Typst buffers."
  :global t
  :lighter ""
  (if typst-watch-auto-mode
      (progn
        (add-hook 'typst-ts-mode-hook #'typst-watch-mode)
        (add-hook 'typst-mode-hook #'typst-watch-mode))
    (remove-hook 'typst-ts-mode-hook #'typst-watch-mode)
    (remove-hook 'typst-mode-hook #'typst-watch-mode)))

(provide 'typst-watch)
;;; typst-watch.el ends here
