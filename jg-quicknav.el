;;; jg-quicknav.el --- Quickly navigate the file system to find a file.

;; Copyright (C) 2013 Jeff Gran

;; Author: Jeff Gran <jeff@jeffgran.com>
;; Created: 3 Mar 2013
;; Keywords: navigation
;; Version: 1.0.0
;; Package-Requires: ((s))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Like ido-find-file, lusty-explorer, helm/anything, etc. But none of them
;; did quite what I wanted so I created this. The goal is to navigate the file 
;; system as fast as possible. Like a much faster way of doing the...
;; 
;;  1. cd <foo>
;;  2. ls
;;  3. goto 1
;;  
;;  ...loop in the shell.
;;
;;
;; You'll likely want to change some of the key bindings. Just redefine the keys
;; on jg-quicknav-mode-map. For example, if you use C-n for something else and want
;; to move up and down lines while navigating with M-n instead, use this:
;;
;; (define-key jg-quicknav-mode-map (kbd "C-n") nil)
;; (define-key jg-quicknav-mode-map (kbd "M-n") 'jgqn-next)
;; 
;;
;; TODO:
;; - add a command/keybinding to create new file in current directory
;; - when updating results, clamp the selection index to the number of results
;;   so it doesn't disappear off the end
;; - different face/color for executables? or just the "*"?
;; - hotkey to go directly to dired?
;; - use save-excursion instead of kill-window?
;; - make it work remotely? with TRAMP maybe?
;; - shell-mode plugin to "cd" to a directory chosen via jgqn?

;;; History:

;; 2013-03-03 Initial release v 1.0.0

;;; Code:

(require 's)

(defvar jgqn-pwd nil
  "The current working directory, for jg-quicknav. 
This is kept up-to-date while navigating in the quicknav buffer")

(defvar jgqn-ls nil
  "This is a placeholder for the results of the `ls` command in the current `jgqn-pwd'")

(defvar jg-quicknav-buffer nil
  "The buffer where directory listing is shown during navigation
Gets created on demand when using `jg-quicknav'")

(defvar jgqn-selection-index 1
  "The (1-based) index of the currently selected line in the `jg-quicknav-buffer'")

(defvar jg-quicknav-mode-map (make-sparse-keymap)
  "The mode that is active in the minibuffer when navigating. 
Commands generally control the `jg-quicknav-buffer'

The following keys are defined:
\\{jg-quicknav-mode-map}")

(defvar jgqn-initialized nil
  "Whether the hooks and advice for `jg-quicknav' have been initialized.")

(defvar jgqn-file-or-dir-to-visit nil
  "A string containing the resulting file name or directory name.
This is a single 'token', and needs to be combined with (`jgqn-pwd') to be the 
full path.")

(defvar jgqn-history nil
  "A list holding the current history, like a browser. This enables you
to go `jgqn-downdir' (forwards) after going `jgqn-updir' (backwards)")

(set-keymap-parent jg-quicknav-mode-map minibuffer-local-map)
(define-key jg-quicknav-mode-map (kbd "C-n") 'jgqn-next)
(define-key jg-quicknav-mode-map (kbd "C-p") 'jgqn-prev)
(define-key jg-quicknav-mode-map (kbd "M-<") 'jgqn-first)
(define-key jg-quicknav-mode-map (kbd "M->") 'jgqn-last)

(define-key jg-quicknav-mode-map (kbd "C-e") 'jgqn-show-results)
(define-key jg-quicknav-mode-map (kbd "C-g") 'jgqn-minibuffer-exit)
(define-key jg-quicknav-mode-map (kbd "RET") 'jgqn-visit-file-or-dir)
(define-key jg-quicknav-mode-map (kbd "C-b") 'jgqn-updir)
(define-key jg-quicknav-mode-map (kbd "C-f") 'jgqn-downdir)


(define-minor-mode jg-quicknav-mode
  "Minor mode that is in effect when navigating using `jq-quicknav'"
  :lighter " jgqn"
  :keymap jg-quicknav-mode-map
  :group 'jg-quicknav)

(defun jgqn-ls ()
  "Get the result of `ls` for the current directory (`jgqn-pwd') in a string."
  (or jgqn-ls
      (setq jgqn-ls (shell-command-to-string
                     (concat "cd "
                             (jgqn-pwd)
                             " && ls -1AF")))))

(defun jgqn-pwd ()
  "The current directory while navigating via `jg-quicknav' 

Defaults to the value of `default-directory' if not set.

Must not have a trailing /."
  (or jgqn-pwd (setq jgqn-pwd (s-chop-suffix "/" default-directory))))


(defun jg-quicknavigating-p ()
  "Returns t if in a `jg-quicknav' session, nil otherwise."
  (and (minibufferp)
       (memq jg-quicknav-mode-map (current-minor-mode-maps))
       ))

(defun jgqn-initialize ()
  "Initialize the hooks and advice for `jg-quicknav' mode"
  (or jgqn-initialized
      (progn
        (add-hook 'minibuffer-setup-hook 'jgqn-minibuffer-setup)
        (add-hook 'minibuffer-exit-hook 'jgqn-minibuffer-teardown)

        ;; TODO make this optional? could be annoying
        (defadvice delete-backward-char (around jgqn-delete-backward-char activate)
          "Go up a directory instead of backspacing when the minibuffer is empty during `jg-quicknav'"
          (if (and (jg-quicknavigating-p)
                   (eq 0 (length (jgqn-get-minibuffer-string))))
              (jgqn-updir)
            ad-do-it)
          )
        ;; this wasn't working and seems maybe not necessary
        ;; (defadvice backward-word-kill (around jgqn-delete-backward-word activate)
        ;;   "Go up a directory instead of backspacing when the minibuffer is empty during `jg-quicknav'"
        ;;   (if (and (jg-quicknavigating-p)
        ;;            (eq 0 (length (jgqn-get-minibuffer-string))))
        ;;       (jgqn-updir)
        ;;     ad-do-it)
        ;;   )
        (setq jgqn-initialized t))))

(defun jg-quicknav ()
  "Main entry-point for jg-quicknav. Assign this to your preferred keybinding.

Opens a quicknav buffer with a directory listing, and turns on
`jg-quicknav-mode' in the minibuffer.

The initial directory is set to the variable `default-directory'

The following keys are in effect via `jg-quicknav-mode-map' (whose parent
is the standard `minibuffer-local-map') while navigating:

\\{jg-quicknav-mode-map}"
  (interactive)

  ;; get or create the buffer for showing the list
  (setq jg-quicknav-buffer (get-buffer-create "*quicknav*"))
  
  (with-current-buffer jg-quicknav-buffer
    (setq buffer-read-only t))

  (display-buffer jg-quicknav-buffer)
  (jgqn-show-results)

  (jgqn-initialize)

  (read-string (concat "Current Directory: " (jgqn-pwd) "/"))
  (if jgqn-file-or-dir-to-visit
      (switch-to-buffer jgqn-file-or-dir-to-visit))
  (jgqn-cleanup)
  (jgqn-delete-window))



(defun jgqn-cleanup ()
  "Clean out the cached values set while navigating via `jg-quicknav',
in order to start anew with a new directory"
  (setq jgqn-file-or-dir-to-visit  nil
        jgqn-pwd                   nil
        jgqn-ls                    nil
        jgqn-selection-index       1))

(defun jgqn-show-results ()
  "General purpose function to update the minibuffer prompt and update the
`jg-quicknav-buffer' with the latest (maybe filtered) results. Called when starting a session,
changing directories, or after changing the minibuffer text."

  (interactive)
  (jgqn-update-minibuffer-prompt)

  (let ((query-string (jgqn-get-minibuffer-string)))
    (with-current-buffer jg-quicknav-buffer
      (let* (
             (new-lines (jgqn-sort-and-filter
                         (s-split "\n" (jgqn-ls) t)
                         query-string))
             (buffer-read-only nil)
             )
        (erase-buffer)
        (jgqn-status-line query-string)
        (if new-lines
            (insert (mapconcat 'identity new-lines "\n")))
        (newline)
        (jgqn-update-faces)
        ))))

(defun jgqn-sort-and-filter (list query)
  "Filter LIST by using 'fuzzy-matching' against QUERY.
The filter matches using a regexp with  (.*) between each character.
Then sort ascending by length if the query is not empty.
Turns out this is my favorite fuzzy matching/sorting algorithm."
  (fip-fuzzy-match query 
                   (sort list
                         '(lambda (s1 s2)
                            (if (> (length query) 0)
                                (< (length s1) (length s2))
                              (string< s1 s2))))))

(defun jgqn-status-line (query-string)
  (insert (jgqn-pwd))
  (insert "/")
  (insert (or query-string ""))
  (insert "\n\n")
  )

(defun jgqn-minibuffer-setup ()
  "For assigning to the `minibuffer-setup-hook' to set up for a `jg-quicknav' session"
  (when (eq this-command 'jg-quicknav)
    (jg-quicknav-mode t)
    ;; t for local-only
    (add-hook 'post-command-hook 'jgqn-show-results nil t)))

(defun jgqn-minibuffer-teardown ()
  "For assigning to the `minibuffer-exit-hook' to clean up after a `jg-quicknav' session."
  (when (eq this-command 'jgqn-minibuffer-exit)
    (jg-quicknav-mode nil)
    (remove-hook 'post-command-hook 'jgqn-show-results t)))


(defun jgqn-delete-window ()
  "Called after canceling or selecting a file during `jg-quicknav'

This function will delete the window that the `jg-quicknav-buffer' was in."
  (dolist (win (window-list))                                                                                  
    (when (string= (buffer-name (window-buffer win)) (buffer-name jg-quicknav-buffer))
      (delete-window win)
      (kill-buffer jg-quicknav-buffer))))

(defun jgqn-minibuffer-exit ()
  "Wrapper around `exit-minibuffer' in order to know if we just exited a
`jg-quicknav' session or not (via `this-command')"
  (interactive)
  ;;(ding)
  (exit-minibuffer))


(defun jgqn-update-minibuffer-prompt ()
  "Updates the minibuffer prompt to show the updated current directory."
  (ack-update-minibuffer-prompt (concat "Current Directory: " (jgqn-pwd) "/")))

(defun jgqn-get-minibuffer-string ()
  (and (minibufferp)
       (buffer-substring-no-properties (minibuffer-prompt-end) (point-max))))


(defun jgqn-visit-file-or-dir ()
  "Get the current selection line and take action

Either visit it with `find-file' if it is a file, or reset `jgqn-pwd' if it
is a directory."
  (interactive)
  ;; get the name of the thing we should go to, if possible
  (with-current-buffer jg-quicknav-buffer
    (let ((str (jgqn-get-current-line)))
      (if (not (= 0 (length str)))
          (setq jgqn-file-or-dir-to-visit str)
        (ding))))

  ;; if we got something, find-file it if it's a file,
  ;; or jg-quicknav in it if it's a directory
  
  (when jgqn-file-or-dir-to-visit
    (let ((file-or-dir
           (concat (jgqn-pwd) "/" jgqn-file-or-dir-to-visit)))

      ;;(message (concat "file-or-dir: " file-or-dir))
      (if (file-directory-p file-or-dir)
          (progn
            (delete-minibuffer-contents)
            (jgqn-cleanup)
            (setq jgqn-pwd file-or-dir)
            (setq jgqn-history nil)
            (jgqn-show-results))

        (find-file file-or-dir)
        (exit-minibuffer)
        ))
    )
  )

(defun jgqn-updir ()
  "Change directories up a level, like using `cd ..`"
  (interactive)
  (let* ((tokens (s-split "/" (jgqn-pwd)))
         (olddir (last tokens))
         (tokens (butlast tokens))
         (newdir (s-join "/" tokens)))
    (push olddir jgqn-history)
    (jgqn-cleanup)
    (setq jgqn-pwd newdir))
  
  (delete-minibuffer-contents)
  
  (jgqn-show-results))

(defun jgqn-downdir ()
  "Go back 'forward' after calling `jgqn-updir'"
  (interactive)
  (if (not (null jgqn-history))
      (let ((new-pwd (s-join "/" (cons (jgqn-pwd) (pop jgqn-history)))))
        (jgqn-cleanup)
        (setq jgqn-pwd new-pwd)
        (jgqn-show-results))
    (ding)))


(defun jgqn-set-selection-index (new-index)
  "Generic function to set the selection in `jg-quicknav-buffer' to NEW-INDEX"
  (interactive)
  (cond ((> 1 new-index)
         (jgqn-last))
        ((< (- (jgqn-count-lines) 2) new-index)
         (jgqn-first))
        (t
         (setq jgqn-selection-index new-index)))
  (jgqn-update-faces))

(defun jgqn-change-selection-index (offset)
  "Generic function to change the selection in `jg-quicknav-buffer' by OFFSET"
  (interactive)
  (jgqn-set-selection-index (+ jgqn-selection-index offset))
  )

(defun jgqn-prev ()
  "Go to the previous selection in the `jg-quicknav-buffer'"
  (interactive)
  (jgqn-change-selection-index -1))

(defun jgqn-next ()
  "Go to the next selection in the `jg-quicknav-buffer'"
  (interactive)
  (jgqn-change-selection-index +1))


(defun jgqn-last ()
  "Go to the last selection in the `jg-quicknav-buffer'"
  (interactive)
  (jgqn-set-selection-index (- (jgqn-count-lines) 2)))

(defun jgqn-first ()
  "Go to the last selection in the `jg-quicknav-buffer'"
  (interactive)
  (jgqn-set-selection-index 1))



(defun jgqn-get-current-line ()
  "Return the current line with no properties and no \n or ^J or whatever else at the end,
and without a trailing / if it was there"
  (goto-line (+ 2 jgqn-selection-index)) ;; + 2 to account for the status line and blank line
  (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
    ;; remove the trailing executable or directory indicator
    (s-chop-suffixes '("*" "/") line))
  )


(defun jgqn-count-lines ()
  (with-current-buffer jg-quicknav-buffer
    (count-lines (point-min) (point-max))))


;; ===============================================================================
;; Faces
;; ===============================================================================
(defface jg-quicknav-directory-face
  '((t (:foreground "#FFEA77")))
  "This face is used to color directories in the quicknav buffer")

(defface jg-quicknav-selected-directory-face
  '((t (:foreground "#FFEA77" :background "#004083")))
  "This face is used to color a directory in the quicknav buffer if it is on the selection line")

(defface jg-quicknav-file-face
  '((t (:foreground "#6cb0f3")))
  "This face is used to color files in the quicknav buffer")

(defface jg-quicknav-selected-file-face
  '((t (:foreground "#ccffef" :background "#004083")))
  "This face is used to color a file in the quicknav buffer if it is on the selection line")


(defun jgqn-update-faces ()
  "Updates the faces for the quicknav buffer"
  (with-current-buffer jg-quicknav-buffer
    (let ((buffer-read-only nil))
      (remove-list-of-text-properties (point-min) (point-max) '(face))

      ;; colors for files and dirs
      (goto-line 3)
      (while (progn
               (cond (
                      ;; highlighted directories
                      (and (eq ?/ (char-before (line-end-position )))
                           ;; + 2 to account for the status line and blank line
                           (eq (line-number-at-pos (point)) (+ 2 jgqn-selection-index)))
                      (add-text-properties
                       (line-beginning-position)
                       (+ 1 (line-end-position))
                       '(face jg-quicknav-selected-directory-face)))
                     
                     ;; directories
                     ((eq ?/ (char-before (line-end-position)))
                      (add-text-properties
                       (line-beginning-position)
                       (line-end-position)
                       '(face jg-quicknav-directory-face)))

                     ;; highlighted file
                     ((eq (line-number-at-pos (point))
                          ;; + 2 to account for the status line and blank line
                          (+ 2 jgqn-selection-index))
                      (add-text-properties
                       (line-beginning-position)
                       (+ 1 (line-end-position))
                       '(face jg-quicknav-selected-file-face))
                      )

                     ;; else -- just files
                     (t (add-text-properties
                         (line-beginning-position)
                         (line-end-position)
                         '(face jg-quicknav-file-face)))
                     )
               
               (not (and
                     (> (forward-line 1) 0)
                     (eq (point-max) (point))))
               ))
      
      )
    )
  )
;; ===============================================================================
;; /Faces
;; ===============================================================================




;; -------------------------------------------------------------------------------
;; Library functions I lifted
;; -------------------------------------------------------------------------------

;; from ack.el I think.
(defun ack-update-minibuffer-prompt (prompt)
  "Visually replace minibuffer prompt with PROMPT."
  (when (minibufferp)
    (let ((inhibit-read-only t))
      (put-text-property
       (point-min) (minibuffer-prompt-end) 'display prompt))))

;; ---------------------------------------------------------------------------------------
;; explosion functions (and regexp function, modified) from:
;; https://github.com/smtlaissezfaire/emacs-lisp-experiments/blob/master/fuzzy-matching.el
(defun fip-fuzzy-match (string list)
  (fip-match-with-regexp (explode-to-regexp string) list))

(defun fip-match-with-regexp (regexp lst)
  "Return the elements of list lst which match the regular expression regexp"
  (remove-if-not
   (lambda (str)
     (eql-match-p str regexp))
   lst))
(defun explode-to-regexp (string)
  "Explode a string to a regular expression, where each char has a .* in front and back of it"
  (apply 'concat (explode-to-regexp-list string)))
(defun explode-to-regexp-list (string)
  "Explode a string to a list of chars, where each char has a .* in front and back of it"
  (cons ".*"
        (mapcar 'char-exploded-to-regexp string)))
(defun char-exploded-to-regexp (char)
  (concat (string char) ".*"))

;; https://github.com/smtlaissezfaire/emacs.d/blob/master/etc/utils.el
(defun eql-match-p (string regexp)
  "Tests for regexp equality"
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (search-forward-regexp regexp (point-max) t)))
;; ---------------------------------------------------------------------------------------
;; /Library
;; ---------------------------------------------------------------------------------------

;;; jg-quicknav.el ends here
