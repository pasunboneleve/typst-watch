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
;; Typst files.  It also provides compile and preview commands that open the
;; generated PDF in a configurable viewer.  By default, it prefers zathura when
;; available and falls back to evince.

;;; Code:

(require 'cl-lib)

(defgroup typst-watch nil
  "Run Typst watch and preview PDFs from Typst buffers."
  :group 'tools
  :prefix "typst-watch-")

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

(defcustom typst-watch-open-viewer-after-compile t
  "When non-nil, open the PDF viewer after compile commands."
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

(defconst typst-watch--typst-ts-commands
  '(typst-ts-compile typst-ts-preview typst-ts-compile-and-preview)
  "Typst-ts commands that should open the PDF viewer after running.")

(defvar typst-watch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c ! w") #'typst-watch-mode)
    (define-key map (kbd "C-c ! c") #'typst-watch-compile)
    (define-key map (kbd "C-c ! p") #'typst-watch-preview)
    map)
  "Keymap for `typst-watch-mode'.")


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

;;;###autoload
(defun typst-watch-start ()
  "Start `typst watch' for the current Typst buffer."
  (interactive)
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

;;;###autoload
(defun typst-watch-stop ()
  "Stop the buffer-local `typst watch' process."
  (interactive)
  (when (process-live-p typst-watch--watch-process)
    (delete-process typst-watch--watch-process)
    (message "Stopped typst watch"))
  (setq typst-watch--watch-process nil))

;;;###autoload
(defun typst-watch-open-viewer ()
  "Open the current buffer's PDF output in the configured viewer.
If typst-watch already started a live viewer process for this PDF, reuse it."
  (interactive)
  (let* ((source-file (typst-watch--source-file))
         (output-file (typst-watch--output-file source-file))
         (process-buffer (get-buffer-create
                          (typst-watch--process-buffer-name "viewer" source-file))))
    (unless (file-exists-p output-file)
      (user-error "PDF output does not exist: %s" output-file))
    (let ((viewer (typst-watch--select-viewer)))
      (unless (typst-watch--same-viewer-p output-file)
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
(defun typst-watch-compile ()
  "Compile the current Typst file to PDF."
  (interactive)
  (let* ((source-file (typst-watch--source-file))
         (output-file (typst-watch--output-file source-file))
         (process-buffer (get-buffer-create
                          (typst-watch--process-buffer-name "compile" source-file))))
    (typst-watch--executable-or-error typst-watch-typst-command "Typst")
    (with-current-buffer process-buffer
      (erase-buffer))
    (let ((exit-code (call-process typst-watch-typst-command
                                   nil process-buffer nil
                                   "compile" source-file output-file)))
      (unless (eq 0 exit-code)
        (user-error "Typst compile failed.  See %s" (buffer-name process-buffer)))
      (message "Compiled Typst PDF: %s" output-file)
      (when typst-watch-open-viewer-after-compile
        (typst-watch-open-viewer))
      output-file)))

;;;###autoload
(defun typst-watch-preview ()
  "Open the current Typst PDF output in a viewer."
  (interactive)
  (typst-watch-open-viewer))

;;;###autoload
(defun typst-watch-compile-and-preview ()
  "Compile the current Typst file and open the generated PDF."
  (interactive)
  (let ((typst-watch-open-viewer-after-compile t))
    (typst-watch-compile)))

(defun typst-watch--after-typst-ts-command (&rest _args)
  "Open the viewer after a typst-ts command when appropriate."
  (when (and typst-watch-open-viewer-after-compile
             buffer-file-name
             (or (derived-mode-p 'typst-ts-mode)
                 (derived-mode-p 'typst-mode)))
    (typst-watch-open-viewer)))

(defun typst-watch--install-typst-ts-advice ()
  "Install viewer advice for typst-ts commands that are already defined."
  (dolist (command typst-watch--typst-ts-commands)
    (when (fboundp command)
      (advice-add command :after #'typst-watch--after-typst-ts-command))))

(defun typst-watch--remove-typst-ts-advice ()
  "Remove viewer advice from typst-ts commands."
  (dolist (command typst-watch--typst-ts-commands)
    (when (fboundp command)
      (advice-remove command #'typst-watch--after-typst-ts-command))))

;;;###autoload
(define-minor-mode typst-watch-mode
  "Run `typst watch' while the current Typst buffer is alive."
  :lighter " TypstWatch"
  (if typst-watch-mode
      (progn
        (typst-watch-start)
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
        (add-hook 'typst-mode-hook #'typst-watch-mode)
        (typst-watch--install-typst-ts-advice)
        (with-eval-after-load 'typst-ts-mode
          (when typst-watch-auto-mode
            (typst-watch--install-typst-ts-advice))))
    (remove-hook 'typst-ts-mode-hook #'typst-watch-mode)
    (remove-hook 'typst-mode-hook #'typst-watch-mode)
    (typst-watch--remove-typst-ts-advice)))

(provide 'typst-watch)
;;; typst-watch.el ends here
