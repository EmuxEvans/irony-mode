;;; irony-completion.el --- irony-mode completion interface

;; Copyright (C) 2012-2014  Guillaume Papin

;; Author: Guillaume Papin <guillaume.papin@epitech.eu>
;; Keywords: c, convenience, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Handle the search of completion points, the triggering of the
;; completion when needed and the "parsing" of completion results.

;;; Code:

(require 'irony)
(require 'irony-snippet)

(require 'cl-lib)

(eval-when-compile
  (require 'cc-defs))                   ;for `c-save-buffer-state'


;;
;; Customizable variables
;;

(defcustom irony-completion-trigger-commands '(self-insert-command
                                               newline-and-indent
                                               c-context-line-break
                                               c-scope-operator)
  "List of commands to watch for asynchronous completion triggering.

There are actually some hard-coded regexp as well in
`irony-completion-trigger-command-p', if it causes any trouble
please report a bug."
  :type '(repeat function)
  :group 'irony)

;;;###autoload
(defcustom irony-completion-hook nil
  ;; TODO: proper documentation
  "Function called when new completion data are available."
  :type 'hook
  :group 'irony)


;;
;; Public variables
;;

(defvar-local irony-completion-mode nil
  "Non-nil when irony-mode completion is enabled.

This is usually true when irony-mode is enabled but can be
disable if irony-server isn't available.")


;;
;; Internal variables
;;

(defvar-local irony-completion--context nil)
(defvar-local irony-completion--context-tick 0)
(defvar-local irony-completion--request-callbacks nil)
(defvar-local irony-completion--request-tick 0)
(defvar-local irony-completion--candidates nil)
(defvar-local irony-completion--candidates-tick 0)


;;
;; Utility functions
;;

(defun irony-completion--symbol-bounds ()
  (let ((pt (point)))
    (save-excursion
      (skip-chars-backward "_a-zA-Z0-9")
      (let ((ch (char-after)))
        (if (and (>= ch ?0) (<= ch ?9)) ;symbols can't start with a digit
            (cons pt pt)
          (setq pt (point))
          (skip-chars-forward "_a-zA-Z0-9")
          (cons pt (point)))))))

(defun irony-completion--beginning-of-symbol ()
  (car (irony-completion--symbol-bounds)))

(defun irony-completion--end-of-symbol ()
  (cdr (irony-completion--symbol-bounds)))

(defun irony-completion--context-pos ()
  (let ((syntax (syntax-ppss)))
    ;; no context in strings and comments
    ;; TODO: Use fontlock faces instead? at least
    ;;     #warning In the middle of a warning|
    ;; will be handled properly but things like the link will be messed-up
    ;; (`goto-address-prog-mode' feature):
    ;;     #error see bug report XY: http://example.com/XY
    (unless (or (nth 3 syntax)          ;strings
                (nth 4 syntax))         ;comments
      (save-excursion
        (goto-char (irony-completion--beginning-of-symbol))
        (skip-chars-backward " \t\n\r")
        (point)))))


;;
;; Functions
;;

(defun irony-completion--enter ()
  (add-hook 'post-command-hook 'irony-completion-post-command nil t)
  (add-hook 'completion-at-point-functions 'irony-completion-at-point nil t)
  (setq irony-completion-mode t))

(defun irony-completion--exit ()
  (setq irony-completion-mode nil)
  (remove-hook 'post-command-hook 'irony-completion-post-command t)
  (remove-hook 'completion-at-point-functions 'irony-completion-at-point t)
  (setq irony-completion--context nil
        irony-completion--candidates nil
        irony-completion--context-tick 0
        irony-completion--request-tick 0
        irony-completion--request-callbacks nil
        irony-completion--candidates-tick 0))

(defun irony-completion-post-command ()
  (when (and (irony-completion-trigger-command-p this-command)
             (irony-completion--update-context)
             (irony-completion--trigger-context-p))
    (irony-completion--send-request)))

(defun irony-completion-trigger-command-p (command)
  "Whether or not COMMAND is a completion trigger command.

Stolen from `auto-complete` package."
  (and (symbolp command)
       (or (memq command irony-completion-trigger-commands)
           (string-match-p "^c-electric-" (symbol-name command)))))

(defun irony-completion--update-context ()
  "Update the completion context variables based on the current position.

Return t if the context has been updated, nil otherwise."
  (let ((ctx (irony-completion--context-pos)))
    (if (eq ctx irony-completion--context)
        nil
      (setq irony-completion--context ctx
            irony-completion--candidates nil
            irony-completion--context-tick (1+ irony-completion--context-tick))
      (unless irony-completion--context
        ;; when there is no context, assume that the candidates are available
        ;; even though they are nil
        irony-completion--request-tick irony-completion--context-tick
        irony-completion--request-callbacks nil
        irony-completion--candidates nil
        irony-completion--candidates-tick irony-completion--context-tick)
      t)))

(defun irony-completion--trigger-context-p ()
  "Whether or not completion is expected to be triggered for the
the current context."
  (when irony-completion--context
    (save-excursion
      (goto-char irony-completion--context)
      (re-search-backward
       (format "%s\\="                 ;see Info node `(elisp) Regexp-Backslash'
               (regexp-opt '("."       ;object member access
                             "->"      ;pointer member access
                             "::")))   ;scope operator
       nil t))))

(defun irony-completion--post-complete-yas-snippet (str placeholders)
  (let ((ph-count 0)
        (from 0)
        to snippet)
    (while
        (setq to (car placeholders)
              snippet (concat
                       snippet
                       (substring str from to)
                       (format "${%d:%s}"
                               (cl-incf ph-count)
                               (substring str
                                          (car placeholders)
                                          (cadr placeholders))))
              from (cadr placeholders)
              placeholders (cddr placeholders)))
    ;; handle the remaining non-snippet string, if any.
    (concat snippet (substring str from) "$0")))


;;
;; Interface with irony-server
;;

(defun irony-completion--send-request ()
  (let (line column)
    (save-excursion
      (goto-char (irony-completion--beginning-of-symbol))
      ;; `position-bytes' to handle multibytes and 'multicolumns' (i.e
      ;; tabulations) characters properly
      (irony-without-narrowing
        (setq line (line-number-at-pos)
              column (1+ (- (position-bytes (point))
                            (position-bytes (point-at-bol)))))))
    (setq irony-completion--request-callbacks nil
          irony-completion--request-tick irony-completion--context-tick)
    (irony--send-file-request
     "complete"
     (list 'irony-completion--request-handler irony-completion--context-tick)
     (number-to-string line)
     (number-to-string column))))

(defun irony-completion--request-handler (candidates tick)
  (when (eq tick irony-completion--context-tick)
    (setq
     irony-completion--candidates-tick tick
     irony-completion--candidates candidates)
    (run-hooks 'irony-completion-hook)
    (mapc 'funcall irony-completion--request-callbacks)))

(defun irony-completion--still-completing-p ()
  (unless (irony-completion-candidates-available-p)
    (eq irony-completion--request-tick irony-completion--context-tick)))


;;
;; Irony Completion Interface
;;

(defsubst irony-completion-annotation (candidate)
  (substring (nth 4 candidate) (nth 5 candidate)))

(defsubst irony-completion-brief (candidate)
  (nth 3 candidate))

(defsubst irony-completion-post-comp-str (candidate)
  (car (nth 6 candidate)))

(defsubst irony-completion-post-comp-placeholders (candidate)
  (cdr (nth 6 candidate)))

(defun irony-completion-candidates-available-p ()
  (and (eq (irony-completion--context-pos) irony-completion--context)
       (eq irony-completion--candidates-tick irony-completion--context-tick)))

(defun irony-completion-candidates ()
  "Return the list of candidates at point, if available.

Use the function `irony-completion-candidates-available-p' to
know if the candidate list is available.

A candidate is composed of the following elements:
 0. The typed text. Multiple candidates can share the same string
    because of overloaded functions, default arguments, etc.
 1. The priority.
 2. The [result-]type of the candidate, if any.
 3. If non-nil, contains the Doxygen brief documentation of the
    candidate.
 4. The signature of the candidate excluding the result-type
    which is available separately.
    Example: \"foo(int a, int b) const\"
 5. The annotation start, a 0-based index in the prototype string.
 6. Post-completion data. The text to insert followed by 0 or
    more indices. These indices work by pairs and describe ranges
    of placeholder text.
    Example: (\"(int a, int b)\" 1 6 8 13)"
  (and (irony-completion-candidates-available-p)
       irony-completion--candidates))

(defun irony-completion-candidates-async (callback)
  "Call CALLBACK when asynchronous completion is available.

Note that:
 - If the candidates are already available, CALLBACK is called
   immediately.
 - In some circumstances, CALLBACK may not be called. i.e:
   irony-server crashes, ..."
  (irony-completion--update-context)
  (if (irony-completion-candidates-available-p)
      (funcall callback)
    (when irony-completion--context
      (unless (irony-completion--still-completing-p)
        (irony-completion--send-request))
      (setq irony-completion--request-callbacks
            (cons callback irony-completion--request-callbacks)))))

(defun irony-completion-post-complete (candidate)
  (let ((str (irony-completion-post-comp-str candidate))
        (placeholders (irony-completion-post-comp-placeholders candidate)))
    (if (and placeholders (irony-snippet-available-p))
        (irony-snippet-expand
         (irony-completion--post-complete-yas-snippet str placeholders))
      (insert (substring str 0 (car placeholders))))))


;;
;; Irony CAPF
;;

(defun irony-completion--at-point-annotate (candidate)
  (irony-completion-annotation
   (get-text-property 0 'irony-capf candidate)))

(defun irony-completion-at-point ()
  (when (irony-completion-candidates-available-p)
    (let ((symbol-bounds (irony-completion--symbol-bounds)))
      (list
       (car symbol-bounds)              ;start
       (cdr symbol-bounds)              ;end
       (mapcar #'(lambda (candidate)    ;completion table
                   (propertize (car candidate) 'irony-capf candidate))
               (irony-completion-candidates))
       :annotation-function 'irony-completion--at-point-annotate))))

(defun irony-completion-at-point-async ()
  (interactive)
  (irony-completion-candidates-async 'completion-at-point))

(provide 'irony-completion)

;; Local Variables:
;; byte-compile-warnings: (not cl-functions)
;; End:

;;; irony-completion.el ends here
