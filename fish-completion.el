;;; fish-completion.el --- Fish completion for pcomplete (shell and Eshell)  -*- lexical-binding: t -*-

;; Copyright (C) 2017-2019 Pierre Neidhardt

;; Author: Pierre Neidhardt <mail@ambrevar.xyz>
;; Homepage: https://gitlab.com/Ambrevar/emacs-fish-completion
;; Version: 1.2
;; Package-Requires: ((emacs "25.1"))

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation; either version 3, or (at your
;; option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; You can setup this package globally with:
;;
;; (when (and (executable-find "fish")
;;            (require 'fish-completion nil t))
;;   (global-fish-completion-mode))
;;
;; Alternatively, you can call the `fish-completion-mode' manually or in shell /
;; Eshell mode hook.
;;
;; The package `bash-completion' is an optional dependency: if available,
;; `fish-completion-complete' can be configured to fall back on bash to further
;; try completing.  See `fish-completion-fallback-on-bash-p'.

;;; Bugs:
;; If the fish user config changes directory on startup, file completion will
;; not be right.  One work-around is to add a "cd default-directory" before the
;; "complete", but that's brittle because of unreliable shell escaping.
;; Upstream does not allow for skipping the user config:
;; https://github.com/fish-shell/fish-shell/issues/4165.

;;; Code:

(require 'em-cmpl)
(require 'subr-x)
(require 'seq)

(defgroup fish-completion nil
  "Settings for fish completion in Eshell and Shell."
  :group 'shell)

(defvar fish-completion-command (executable-find "fish")
  "The `fish' executable.")

(defvar fish-completion--old-completion-function nil)
(make-variable-buffer-local 'fish-completion--old-completion-function)

(defcustom fish-completion-fallback-on-bash-p nil
  "Fall back on bash completion if possible.
If non-nil, Fish file completion is ignored.
This requires the bash-completion package."
  :type 'boolean
  :group 'fish-completion)

(defcustom fish-completion-prefer-bash-completion nil
  "Prefer Bash completion over Fish completion.

If non-nil, Fish completion will be used as a fallback when Bash
completion fails."
  :type 'boolean
  :group 'fish-completion)

(defcustom fish-completion-inhibit-missing-fish-command-warning nil
  "Inhibit emitting a warning when `fish-command' is nil."
  :type 'boolean
  :group 'fish-completion)

;;;###autoload
(define-minor-mode fish-completion-mode
  "Turn on/off fish shell completion in all future shells or Eshells.

In `shell', completion is replaced by fish completion.
In `eshell', fish completion is only used when `pcomplete' fails."
  :init-value nil
  (if (progn
        (unless (or fish-completion-inhibit-missing-fish-command-warning
                    fish-completion-command)
          (warn "Fish is not installed. fish-completion-mode will silently fall back to Bash for completions."))
        (setq pcomplete-default-completion-function fish-completion--old-completion-function))
      (setq pcomplete-default-completion-function fish-completion--old-completion-function)
    (setq fish-completion--old-completion-function pcomplete-default-completion-function
          pcomplete-default-completion-function 'fish-completion-shell-complete)))

(defun turn-on-fish-completion-mode ()
  ;; The first Eshell session will initialize the modules and reload
  ;; `eshell-mode'.  Since the module em-cmpl sets
  ;; `pcomplete-default-completion-function', this will override this global
  ;; minor mode.  To avoid the override, we re-run `fish-completion-mode' in
  ;; `eshell-mode-hook' locally (first session only).  Other Eshell sessions do
  ;; not need this workaround.
  (when (eq major-mode 'eshell-mode)
    (add-hook 'eshell-mode-hook (lambda () (fish-completion-mode 1)) nil t))
  (fish-completion-mode 1))

(define-globalized-minor-mode global-fish-completion-mode
  fish-completion-mode
  turn-on-fish-completion-mode
  :require 'fish-completion)

(defun fish-completion-shell-complete ()
  "Complete `shell' or `eshell' prompt with `fish-completion-complete'.
If we are in a remote location, use the old completion function instead,
since we rely on a local fish instance to suggest the completions."
  (if (file-remote-p default-directory)
      (funcall fish-completion--old-completion-function)
    (fish-completion-complete (buffer-substring-no-properties
                               (save-excursion (if (eq major-mode 'shell-mode)
                                                   (comint-bol)
                                                 (eshell-bol))
                                               (point))
                               (point)))))

(declare-function bash-completion-dynamic-complete-nocomint "ext:bash-completion")

(defun fish-completion--call (command &rest args)
  "Return the output of the call to COMMAND ARGS as a string."
  (with-output-to-string
    (with-current-buffer standard-output
      (apply #'call-process
             command
             nil '(t nil) nil
             args))))

(defvar fish-completion--parent-commands '("sudo" "env")
  "List of commands that that take other commands as argument.
We need to list those commands manually so that we can complete
against their subcommands.  Fish does not support subcommand
completion.  See
https://github.com/fish-shell/fish-shell/issues/4093.")

(defun fish-completion--normalize-prompt (prompt)
  "Return a prompt that can be understood by Fish."
  ;; Eshell supports star-prefixed commands but not Fish:
  ;; remove the star for fish-completion.
  (setq prompt (replace-regexp-in-string "^[[:space:]]*\\*" "" prompt))
  (let (;; We *must* keep spaces at the end because completion on "ls" and "ls "
        ;; is different, so keep OMIT-NULLS to nil in `split-string'.  The first
        ;; non-empty `car' is the command, we can discard leading empty strings.
        (tokens (split-string prompt
                              split-string-default-separators nil)))
    (if (not (member (car tokens) fish-completion--parent-commands))
        prompt
      (setq tokens (cdr tokens))
      ;; Skip env/sudo parameters, like -u and LC_ALL=C.
      (setq tokens (seq-drop-while (lambda (e)
                                     (or (string-match "^-.*" e)
                                         (string-match "=" e)))
                                   tokens))
      (if (and tokens (not (string-empty-p (car tokens))))
          (mapconcat 'identity tokens " ")
        ;; If there is no subcommand, then we
        ;; complete against the parent command.
        prompt))))

(defun fish-completion--list-completions-with-desc (raw-prompt)
  "Return list of completion candidates for RAW-PROMPT.
The candidates include the description."
  (let ((prompt (fish-completion--normalize-prompt raw-prompt)))
    (when fish-completion-command
      (fish-completion--call fish-completion-command
                             "-c" (format "complete -C%s"
                                          (shell-quote-argument prompt))))))

(defun fish-completion--list-completions (raw-prompt)
  "Return list of completion candidates for RAW-PROMPT."
  (mapcar (lambda (e) (car (split-string e "\t")))
          (let ((candidates (fish-completion--list-completions-with-desc raw-prompt)))
            (when candidates (split-string candidates "\n" t)))))

(defun fish-completion--strip-bash-escapes (completions)
  "Remove unnecessary backslashes from COMPLETIONS inserted by bash-completion."
  (mapcar (lambda (s)
            (replace-regexp-in-string (regexp-quote "\\") "" s))
          completions))

(defun fish-completion-get-bash-completions ()
  "Get a list of completions from Bash."
  (when (require 'bash-completion nil 'noerror)
    (fish-completion--strip-bash-escapes
     (nth 2 (bash-completion-dynamic-complete-nocomint
             (save-excursion (eshell-bol)) (point))))))

(defun fish-completion--maybe-use-bash (comp-list)
  "Maybe use Bash for completion if COMP-LIST is not adequate."
  (if (and fish-completion-fallback-on-bash-p
           (not fish-completion-prefer-bash-completion)
           (or (null comp-list)
               (file-exists-p (car comp-list))))
      (fish-completion-get-bash-completions)
    comp-list))

(defun fish-completion-complete (raw-prompt)
  "Complete RAW-PROMPT using Fish with possible fallback or preference to Bash."
  (let ((bash-comp-list (and fish-completion-prefer-bash-completion
                             (fish-completion-get-bash-completions))))
    (while (pcomplete-here
            (or bash-comp-list
                (let ((comp-list (fish-completion--maybe-use-bash
                                  (fish-completion--list-completions raw-prompt))))
                  (if (and comp-list (file-exists-p (car comp-list)))
                      (pcomplete-dirs-or-entries) ;; Use pcomplete for file completion
                    (mapcar 'string-trim-right comp-list))))))))

(provide 'fish-completion)
;;; fish-completion.el ends here
