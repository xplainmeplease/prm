;;; prm.el --- GitHub PR review with dired-like navigation -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Copyright (C) 2026 Oleksandr Fatieiev
;;
;; Author: Oleksandr Fatieiev
;; Version: 0.2
;; Keywords: tools, vc, git, emacs, pr-review
;;
;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Three-level dired-like GitHub PR review mode.
;;
;; Entry points:
;;   prm-select-dired       — repo picker → PR list → diff + comments
;;   prm-select-dired-wc    — same, also checks out PR branch in local repos
;;   prm-select-from-url    — jump directly to review from a GitHub PR URL
;;   prm-select-from-url-wc — same, also checks out PR branch in local repos
;;
;; Navigation:
;;   Level 1 *prm-repos*          n/p move, RET open PR list, g refresh
;;   Level 2 *prm-prs:<repo>*     n/p move, RET open review,  g refresh
;;   Level 3 *prm-review:<r>#<n>* n/p threads, r reply, R resolve,
;;                                 c toggle comments, d toggle diff,
;;                                 v toggle resolved comments, g refetch
;;
;; Requires GITHUB_TOKEN env var.  Uses GraphQL for threads/resolve,
;; REST for PR list and replies.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'url)
(require 'json)

;; To avoid disturbing production environments with rebases.
(defconst prm--locals-file-name ".emacs-prm-locals.el"
  "Configuration file.")

(defun prm--load-locals-file ()
  "Load per-machine overrides from `prm--locals-file-name' if present."
  (load (expand-file-name prm--locals-file-name
                          (file-name-directory
                           (or load-file-name buffer-file-name)))
        t t))

(prm--load-locals-file)

;;; ── Logging ───────────────────────────────────────────────────────────────

(defvar prm-verbose-log t
  "When non-nil, emit step-by-step git and API progress to the minibuffer.
Set to nil to suppress verbose output; generic milestone messages are
always shown regardless of this setting.")

(defconst prm--log-buffer "*prm-log*"
  "Buffer that receives all prm log lines (verbose and generic).")

(defun prm--log-to-buffer (level fmt &rest args)
  "Append a log line to `prm--log-buffer'.
LEVEL is a short tag string such as \"verbose\" or \"info\".
FMT and ARGS are passed to `format'."
  (let ((line (format "[%s] %s\n" level (apply #'format fmt args))))
    (with-current-buffer (get-buffer-create prm--log-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert line)))))

(defmacro prm--vlog (fmt &rest args)
  "Log a verbose step.  Always written to `prm--log-buffer'.
Also echoed to the minibuffer when `prm-verbose-log' is non-nil."
  `(progn
     (prm--log-to-buffer "verbose" ,fmt ,@args)
     (when prm-verbose-log
       (message (concat "prm: " ,fmt) ,@args)
       (redisplay))))

(defmacro prm--log (fmt &rest args)
  "Log a generic milestone.  Always written to `prm--log-buffer' and
always echoed to the minibuffer, regardless of `prm-verbose-log'."
  `(progn
     (prm--log-to-buffer "info" ,fmt ,@args)
     (message (concat "prm: " ,fmt) ,@args)
     (redisplay)))

(defun prm-show-log ()
  "Open the `prm--log-buffer' in another window."
  (interactive)
  (pop-to-buffer (get-buffer-create prm--log-buffer)))

;;; ── Colors and faces ──────────────────────────────────────────────────────

(defvar prm-color-active   "#cd6600" "Color for unresolved thread comments.")
(defvar prm-color-resolved "#00688b" "Color for resolved thread comments.")
(defvar prm-color-code     "#808080" "Color for code blocks and inline code.")
(defvar prm-color-outdated "#8b3a00" "Color for [outdated] tag on comments.")

(defface prm-code-block-face
  '((t :family "monospace"))
  "Face for fenced code blocks in PR comment bodies.")

(defface prm-inline-code-face
  '((t :family "monospace"))
  "Face for inline code spans in PR comment bodies.")

(set-face-attribute 'prm-code-block-face  nil :foreground prm-color-code)
(set-face-attribute 'prm-inline-code-face nil :foreground prm-color-code)


(defun prm--preset-repo-string (preset)
  "Return \"owner/full-repo-name\" for PRESET."
  (let ((user-part (if (string-empty-p (nth 5 preset)) "" (concat "-" (nth 5 preset)))))
    (concat (nth 1 preset) "/"
            (nth 2 preset) (nth 3 preset) "-" (nth 4 preset) user-part)))

;;; ── Repo construction (manual / fallback) ─────────────────────────────────

(defun prm--build-repo ()
  "Build full \"owner/repo\" string from global config vars."
  (let* ((user-part (if (string-empty-p prm-username) "" (concat "-" prm-username)))
         (mid       (if (string-empty-p prm-repo-suffix)
                        prm-repo-name
                      (concat prm-repo-suffix "-" prm-repo-name))))
    (concat prm-owner "/" prm-repo-prefix mid user-part)))

;;; ── Token ─────────────────────────────────────────────────────────────────

(defun prm--token ()
  (or (getenv "GITHUB_TOKEN")
      (let ((tok (string-trim
                  (shell-command-to-string
                   (format "%s -i -c 'echo $GITHUB_TOKEN' 2>/dev/null"
                           (or (getenv "SHELL") "sh"))))))
        (when (and tok (not (string-empty-p tok)))
          (setenv "GITHUB_TOKEN" tok)
          tok))
      (error "GITHUB_TOKEN not set — add it to ~/.zshrc")))

;;; ── HTTP helpers ──────────────────────────────────────────────────────────

(defun prm--http (method url &optional payload)
  (let* ((url-request-method method)
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " (prm--token)))
            ("Content-Type"  . "application/json")
            ("Accept"        . "application/vnd.github+json")))
         (url-request-data
          (when payload (encode-coding-string (json-encode payload) 'utf-8)))
         (buf (url-retrieve-synchronously url t t 30)))
    (with-current-buffer buf
      (goto-char (point-min))
      (re-search-forward "\r?\n\r?\n")
      (let ((json-object-type 'alist)
            (json-array-type  'list))
        (json-read)))))

(defun prm--graphql (query vars)
  (prm--http "POST" "https://api.github.com/graphql"
             `((query . ,query) (variables . ,vars))))

;;; ── GitHub API: review threads ────────────────────────────────────────────

(defconst prm--threads-query
  "query($owner:String!,$repo:String!,$pr:Int!){
     repository(owner:$owner,name:$repo){
       pullRequest(number:$pr){
         author{ login }
         headRefName
         headRefOid
         baseRefName
         baseRefOid
         headRepository{ url sshUrl }
         baseRepository{ url sshUrl }
         reviewThreads(first:100){
           nodes{
             id isResolved path line originalLine
             comments(first:20){
               nodes{ databaseId body author{login} originalCommit{ oid } }
             }
           }
         }
       }
     }
   }")

(defvar prm--head-branch      nil "PR head branch (side-effect of prm--fetch-threads).")
(defvar prm--head-remote-url  nil "PR head repo URL (side-effect of prm--fetch-threads).")
(defvar prm--head-commit      nil "PR head commit OID (side-effect of prm--fetch-threads).")
(defvar prm--base-branch      nil "PR base branch (side-effect of prm--fetch-threads).")
(defvar prm--base-commit      nil "PR base commit OID at the time the PR was opened (side-effect of prm--fetch-threads).")
(defvar prm--base-remote-url  nil "PR base repo URL (side-effect of prm--fetch-threads).")
(defvar prm--pr-author        nil "PR author login (side-effect of prm--fetch-threads).")

(defun prm--fetch-threads (repo number)
  "Fetch review threads for PR NUMBER in REPO (\"owner/name\").
Sets prm--head-branch, prm--head-commit, prm--head-remote-url as side effects."
  (let* ((parts (split-string repo "/"))
         (resp  (prm--graphql prm--threads-query
                              `((owner . ,(car parts))
                                (repo  . ,(cadr parts))
                                (pr    . ,number)))))
    (when (alist-get 'errors resp)
      (error "GraphQL errors: %s" (json-encode (alist-get 'errors resp))))
    (let* ((pr-data   (alist-get 'pullRequest
                        (alist-get 'repository
                          (alist-get 'data resp))))
           (head-repo (alist-get 'headRepository pr-data)))
      (setq prm--pr-author       (alist-get 'login (alist-get 'author pr-data)))
      (setq prm--head-branch     (alist-get 'headRefName pr-data))
      (setq prm--head-commit     (alist-get 'headRefOid  pr-data))
      (setq prm--base-branch     (alist-get 'baseRefName pr-data))
      (setq prm--base-commit     (alist-get 'baseRefOid  pr-data))
      (setq prm--head-remote-url (or (alist-get 'sshUrl head-repo)
                                     (alist-get 'url    head-repo)))
      (let ((base-repo (alist-get 'baseRepository pr-data)))
        (setq prm--base-remote-url (or (alist-get 'sshUrl base-repo)
                                       (alist-get 'url    base-repo))))
      (alist-get 'nodes (alist-get 'reviewThreads pr-data)))))

;;; ── GitHub API: PR list ───────────────────────────────────────────────────

(defun prm--fetch-pr-list (full-repo-name)
  "Fetch open PRs for FULL-REPO-NAME (\"owner/repo\") via REST.
Returns a list of PR alists."
  (prm--http "GET"
             (format "https://api.github.com/repos/%s/pulls?state=open&per_page=100"
                     full-repo-name)))

;;; ── Remote map ────────────────────────────────────────────────────────────
;; Unified map: normalized-url → (dir . remote-name)
;; Built by scanning git remote -v in every dir listed in prm-local-paths.

(defvar prm--remote-map nil
  "Alist mapping normalized remote URL to (dir . remote-name).
Built by `prm--ensure-remote-map'.  Nil means not yet built.")

(defun prm--normalize-remote-url (url)
  "Reduce URL to \"org/repo\" stripping protocol, host, .git suffix."
  (let ((s (replace-regexp-in-string "\\.git$" "" (string-trim url))))
    (cond
     ;; git@github.com:org/repo  or  org-key@github.com:org/repo
     ((string-match "[^/]+:\\(.+\\)" s) (match-string 1 s))
     ;; https://github.com/org/repo
     ((string-match "https?://[^/]+/\\(.+\\)" s) (match-string 1 s))
     (t s))))

(defun prm--build-remote-map ()
  "Scan all dirs in prm-local-paths and build prm--remote-map.
Logs every remote found and every normalization to *prm-remote-map*."
  (let ((log-buf (get-buffer-create "*prm-remote-map*"))
        result)
    (with-current-buffer log-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "prm remote map — built %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S")))))
    (dolist (entry prm-local-paths)
      (let* ((label (car entry))
             (dir   (expand-file-name (cdr entry))))
        (with-current-buffer log-buf
          (insert (format "── %s  (%s)\n" label dir)))
        (if (not (file-directory-p dir))
            (with-current-buffer log-buf
              (insert (format "   SKIP: directory does not exist\n")))
          (let* ((raw   (shell-command-to-string
                         (format "git -C %s remote -v 2>/dev/null"
                                 (shell-quote-argument dir))))
                 (lines (split-string raw "\n" t)))
            (if (null lines)
                (with-current-buffer log-buf
                  (insert "   SKIP: no remotes\n"))
              (dolist (line lines)
                (when (string-match "^\\([^\t]+\\)\t\\([^ ]+\\) (fetch)" line)
                  (let* ((remote-name (match-string 1 line))
                         (raw-url     (match-string 2 line))
                         (norm        (prm--normalize-remote-url raw-url)))
                    (with-current-buffer log-buf
                      (insert (format "   remote %-20s  raw:  %s\n" remote-name raw-url))
                      (insert (format "   %s%-20s  norm: %s\n"
                                      (make-string (length "   remote ") ? )
                                      "" norm)))
                    (push (cons norm (cons dir remote-name)) result)))))))))
    (with-current-buffer log-buf
      (insert (format "\n%d entries total.\n" (length result))))
    (prm--log "remote map built — %d entries. See *prm-remote-map* for details."
              (length result))
    (setq prm--remote-map (nreverse result))))

(defun prm--ensure-remote-map ()
  "Build prm--remote-map if not yet built."
  (unless prm--remote-map
    (prm--build-remote-map)))

(defun prm-rebuild-remote-map ()
  "Rebuild the remote→dir map and show the log buffer."
  (interactive)
  (setq prm--remote-map nil)
  (prm--build-remote-map)
  (pop-to-buffer "*prm-remote-map*"))

(defun prm--lookup-remote (url)
  "Return (dir . remote-name) for URL, or error if not found."
  (prm--ensure-remote-map)
  (let* ((norm (prm--normalize-remote-url url))
         (hit  (assoc norm prm--remote-map)))
    (if hit
        (cdr hit)
      (error "prm: no local remote found for %s (normalized: %s) — run M-x prm-rebuild-remote-map"
             url norm))))

;;; ── PR worktree setup ─────────────────────────────────────────────────────

(defun prm--git (dir &rest args)
  "Run git in DIR with ARGS, return trimmed output."
  (string-trim
   (shell-command-to-string
    (concat "git -C " (shell-quote-argument (expand-file-name dir))
            " " (mapconcat #'shell-quote-argument args " ")
            " 2>&1"))))

(defun prm--ensure-remote (dir remote-name url)
  "Add remote REMOTE-NAME with URL in DIR, or update its URL if already present."
  (let ((existing (split-string
                   (shell-command-to-string
                    (format "git -C %s remote 2>/dev/null"
                            (shell-quote-argument (expand-file-name dir))))
                   "\n" t)))
    (if (member remote-name existing)
        (prm--git dir "remote" "set-url" remote-name url)
      (prm--git dir "remote" "add" remote-name url))))

(defun prm--dir-knows-base-url-p (dir base-url)
  "Return non-nil if DIR already has some remote whose URL normalizes to BASE-URL."
  (prm--ensure-remote-map)
  (let ((norm (prm--normalize-remote-url base-url)))
    (cl-some (lambda (entry)
               (and (string= (car entry) norm)
                    (string= (expand-file-name (cadr entry)) (expand-file-name dir))))
             prm--remote-map)))

(defun prm--prepare-pr-worktree (dir author pr-number
                                 head-url head-branch
                                 base-url base-branch)
  "Set up DIR for reviewing PR PR-NUMBER by AUTHOR.
Adds prm remotes, fetches head+base, creates and checks out a local PR branch.
Returns (LOCAL-BRANCH . BASE-REF) on success, nil if DIR is not a clone of
the PR base repo."
  (cl-block prm--prepare-pr-worktree
    (let ((dir (expand-file-name dir)))
      (unless (prm--dir-knows-base-url-p dir base-url)
        (prm--vlog "[%s] no remote matches %s — skipping" dir base-url)
        (cl-return-from prm--prepare-pr-worktree nil))
      (let* ((head-remote  (format "prm_%s_%d_head" author pr-number))
             (base-remote  (format "prm_%s_%d_base" author pr-number))
             (local-branch (format "prm_%d_head" pr-number))
             (base-ref     (format "%s/%s" base-remote base-branch)))
        (prm--vlog "[%s] ensuring remote %s → %s" dir head-remote head-url)
        (prm--ensure-remote dir head-remote head-url)
        (prm--vlog "[%s] ensuring remote %s → %s" dir base-remote base-url)
        (prm--ensure-remote dir base-remote base-url)
        (prm--vlog "[%s] fetching %s %s" dir base-remote base-branch)
        (prm--git dir "fetch" base-remote base-branch)
        (prm--vlog "[%s] fetching %s %s" dir head-remote head-branch)
        (prm--git dir "fetch" head-remote head-branch)
        (prm--vlog "[%s] branch -f %s %s/%s" dir local-branch head-remote head-branch)
        (prm--git dir "branch" "-f" local-branch
                  (format "%s/%s" head-remote head-branch))
        (prm--vlog "[%s] checkout %s" dir local-branch)
        (prm--git dir "checkout" local-branch)
        (setq prm--remote-map nil)
        (cons local-branch base-ref)))))

;;; ── Cleanup ───────────────────────────────────────────────────────────────

(defun prm-cleanup ()
  "Remove all prm_-prefixed remotes and local PR branches across `prm-local-paths'."
  (interactive)
  (let ((log-buf (get-buffer-create "*prm-cleanup*")))
    (with-current-buffer log-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "prm cleanup — %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S")))))
    (dolist (entry prm-local-paths)
      (let* ((label (car entry))
             (dir   (expand-file-name (cdr entry))))
        (with-current-buffer log-buf
          (insert (format "── %s  (%s)\n" label dir)))
        (if (not (file-directory-p dir))
            (with-current-buffer log-buf (insert "   SKIP: directory does not exist\n"))
          (let* ((remotes (seq-filter
                           (lambda (r) (string-match-p "^prm_.*_\\(head\\|base\\)$" r))
                           (split-string
                            (shell-command-to-string
                             (format "git -C %s remote 2>/dev/null"
                                     (shell-quote-argument dir)))
                            "\n" t)))
                 (branches (seq-filter
                            (lambda (b) (string-match-p "^prm_[0-9]+_head$" b))
                            (split-string
                             (shell-command-to-string
                              (format "git -C %s branch --format=%%(refname:short) 2>/dev/null"
                                      (shell-quote-argument dir)))
                             "\n" t)))
                 (current-branch (string-trim
                                  (shell-command-to-string
                                   (format "git -C %s rev-parse --abbrev-ref HEAD 2>/dev/null"
                                           (shell-quote-argument dir))))))
            (dolist (branch branches)
              (when (string= branch current-branch)
                (let ((fallback (or prm-base-branch "master")))
                  (with-current-buffer log-buf
                    (insert (format "   checkout fallback %s (was on %s)\n" fallback branch)))
                  (prm--vlog "[%s] on prm branch — checkout fallback %s" dir fallback)
                  (prm--git dir "checkout" fallback)))
              (with-current-buffer log-buf
                (insert (format "   delete branch %s\n" branch)))
              (prm--vlog "[%s] delete branch %s" dir branch)
              (prm--git dir "branch" "-D" branch))
            (dolist (remote remotes)
              (with-current-buffer log-buf
                (insert (format "   remove remote %s\n" remote)))
              (prm--vlog "[%s] remove remote %s" dir remote)
              (prm--git dir "remote" "remove" remote))
            (with-current-buffer log-buf
              (insert (format "   done: %d branch(es), %d remote(s) removed\n"
                              (length branches) (length remotes))))))))
    (setq prm--remote-map nil)
    (prm--log "cleanup done — see *prm-cleanup* for details")
    (pop-to-buffer log-buf)))

;;; ── REST: reply / resolve ─────────────────────────────────────────────────

(defun prm--reply (repo number comment-db-id body)
  (prm--http "POST"
             (format "https://api.github.com/repos/%s/pulls/%d/comments/%d/replies"
                     repo (truncate number) (truncate comment-db-id))
             `((body . ,body))))

(defun prm--resolve (thread-node-id)
  (prm--graphql
   "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}"
   `((id . ,thread-node-id))))

;;; ── Diff line mapping ─────────────────────────────────────────────────────

(defun prm--find-diff-line (file-line &optional region-start region-end)
  "Return buffer position of FILE-LINE (new-file numbering) within REGION-START..REGION-END."
  (save-excursion
    (goto-char (or region-start (point-min)))
    (let ((cur   0)
          (limit (or region-end (point-max))))
      (catch 'found
        (while (and (not (eobp)) (<= (point) limit))
          (let ((txt (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
            (cond
             ((string-match "^@@ -[0-9,]+ \\+\\([0-9]+\\)" txt)
              (setq cur (1- (string-to-number (match-string 1 txt)))))
             ((or (string-prefix-p "---" txt) (string-prefix-p "+++" txt)
                  (string-prefix-p "diff " txt) (string-prefix-p "\\\\ " txt)))
             ((string-prefix-p "-" txt))
             (t
              (setq cur (1+ cur))
              (when (= cur file-line)
                (throw 'found (line-beginning-position)))))
            (forward-line 1)))
        nil))))

;;; ── Comment body rendering ────────────────────────────────────────────────

(defun prm--render-inline (text color)
  "Render inline `code` spans in TEXT; plain text gets foreground COLOR."
  (let ((result "") (parts (split-string text "`")))
    (seq-do-indexed
     (lambda (part i)
       (setq result
             (concat result
                     (if (cl-oddp i)
                         (propertize part 'face 'prm-inline-code-face)
                       (propertize part 'face `(:foreground ,color :weight normal))))))
     parts)
    result))

(defun prm--render-body (body color)
  "Render markdown fenced code blocks and inline code in BODY."
  (let ((result "") (parts (split-string body "```")))
    (seq-do-indexed
     (lambda (part i)
       (setq result
             (concat result
                     (if (cl-oddp i)
                         (let* ((lines    (split-string part "\n"))
                                (has-lang (string-match "^[a-zA-Z0-9_+-]*$" (car lines)))
                                (code     (string-join (if has-lang (cdr lines) lines) "\n"))
                                (indented (mapconcat (lambda (l) (concat "    " l))
                                                     (split-string code "\n") "\n")))
                           (propertize (concat "\n" indented "\n")
                                       'face 'prm-code-block-face))
                       (prm--render-inline part color)))))
     parts)
    result))

;;; ── Overlays (review buffer state) ───────────────────────────────────────

(defvar-local prm--overlays           nil)
(defvar-local prm--diff-hide-overlays nil)
(defvar-local prm--comments-visible   t)
(defvar-local prm--diff-visible       t)
(defvar-local prm--resolved-visible   t)
(defvar-local prm--repo               nil "Full \"owner/repo\" for this review buffer.")
(defvar-local prm--pr-number          nil "PR number (integer) for this review buffer.")
(defvar-local prm--local-repo-path    nil "Resolved local repo directory for git diff.")
(defvar-local prm--review-commit      nil "Head commit OID captured when this buffer was loaded.")
(defvar-local prm--review-base-branch nil "PR base branch captured when this buffer was loaded.")

(defun prm--clear-overlays ()
  (mapc #'delete-overlay prm--overlays)
  (setq prm--overlays nil)
  (mapc #'delete-overlay prm--diff-hide-overlays)
  (setq prm--diff-hide-overlays nil)
  (setq prm--comments-visible t)
  (setq prm--diff-visible t)
  (setq prm--resolved-visible t))

(defun prm--add-overlay (thread &optional region-start region-end)
  (let* ((file-line   (or (alist-get 'line thread) (alist-get 'originalLine thread)))
         (pos         (and file-line (prm--find-diff-line file-line region-start region-end)))
         (comments    (alist-get 'nodes (alist-get 'comments thread)))
         (resolved    (eq (alist-get 'isResolved thread) t))
         (color       (if resolved prm-color-resolved prm-color-active))
         (face-bold   `(:foreground ,color :weight bold))
         (comment-oid (alist-get 'oid (alist-get 'originalCommit (car comments))))
         (outdated    (and comment-oid prm--head-commit
                           (not (string= comment-oid prm--head-commit)))))
    (when pos
      (let* ((text  (mapconcat
                     (lambda (c)
                       (concat
                        (propertize (format "  [%s]: "
                                            (alist-get 'login (alist-get 'author c)))
                                    'face face-bold)
                        (prm--render-body (alist-get 'body c) color)))
                     comments "\n"))
             (outdated-tag (when outdated
                             (propertize "[outdated] "
                                         'face `(:foreground ,prm-color-outdated
                                                 :weight bold))))
             (label (concat "  ↳ "
                            (or outdated-tag "")
                            (when resolved (propertize "[resolved] " 'face face-bold))
                            text))
             (str   (concat "\n" label "\n"))
             (ov    (make-overlay pos (save-excursion (goto-char pos) (line-end-position)))))
        (overlay-put ov 'after-string     str)
        (overlay-put ov 'prm-after-string str)
        (overlay-put ov 'prm-thread       thread)
        (push ov prm--overlays)))))

;;; ── Git diff ──────────────────────────────────────────────────────────────

(defun prm--git-diff-files (local-repo-path base-oid head-oid)
  "Return list of files changed between BASE-OID and HEAD-OID in LOCAL-REPO-PATH."
  (split-string
   (string-trim
    (shell-command-to-string
     (format "git -C %s diff %s...%s --name-only"
             (shell-quote-argument (expand-file-name local-repo-path))
             base-oid head-oid)))
   "\n" t))

(defvar-local prm--review-head-commit nil "Head commit OID for the current review buffer.")

(defun prm--git-diff (path)
  "Return git diff output for PATH using buffer-local OIDs."
  (shell-command-to-string
   (format "git -C %s diff %s...%s -- %s"
           (shell-quote-argument (expand-file-name
                                  (or prm--local-repo-path prm-repo-path)))
           (or prm--review-base-branch prm-base-branch)
           (or prm--review-head-commit "HEAD")
           (shell-quote-argument path))))

;;; ── Level 3: diff review buffer ──────────────────────────────────────────

(defun prm--open-review (full-repo-name pr-number &optional _wc refetch)
  "Populate the review buffer for PR-NUMBER in FULL-REPO-NAME.
_WC is accepted for backwards compat but ignored — checkout now always happens.
REFETCH non-nil: do not switch to the buffer."
  (setq pr-number (truncate pr-number))
  (let ((buf-name (format "*prm-review:%s#%d*" full-repo-name pr-number)))
    (prm--log "[%s] PR #%d: fetching threads..." full-repo-name pr-number)
    (let* ((threads (prm--fetch-threads full-repo-name pr-number))
           (total   (length threads))
           (author  (or prm--pr-author "unknown"))
           worktree-result
           local-repo-path
           base-ref)
      (prm--vlog "[%s] PR #%d: author=%s head=%s base=%s"
                 full-repo-name pr-number author prm--head-branch
                 (or prm--base-branch prm-base-branch))
      ;; Set up prm remotes + branch in every eligible local repo.
      (dolist (entry prm-local-paths)
        (let* ((label (car entry))
               (dir   (expand-file-name (cdr entry)))
               (result (progn
                         (prm--vlog "[%s] PR #%d: preparing worktree in %s (%s)..."
                                    full-repo-name pr-number dir label)
                         (prm--prepare-pr-worktree
                          dir author pr-number
                          prm--head-remote-url prm--head-branch
                          prm--base-remote-url (or prm--base-branch prm-base-branch)))))
          (when result
            (prm--vlog "[%s] PR #%d: worktree ready in %s — branch=%s base-ref=%s"
                       full-repo-name pr-number dir (car result) (cdr result)))
          (when (and result (null worktree-result))
            (setq worktree-result result
                  local-repo-path dir
                  base-ref        (cdr result)))))
      (unless local-repo-path
        (error "prm: no local repo found for base URL %s — run M-x prm-rebuild-remote-map"
               prm--base-remote-url))
      ;; Prefer the exact OID the PR was opened against over the branch tip.
      (when prm--base-commit
        (setq base-ref prm--base-commit))
      (prm--vlog "[%s] PR #%d: using local-repo-path=%s base-ref=%s"
                 full-repo-name pr-number local-repo-path base-ref)
      (let* ((head-oid (or prm--head-commit "HEAD"))
             (all-files (prm--git-diff-files local-repo-path base-ref head-oid))
             (threads-by-file (seq-group-by (lambda (th) (alist-get 'path th)) threads))
             (by-file (mapcar (lambda (f)
                                (cons f (cdr (assoc f threads-by-file))))
                              all-files))
             (nfiles  (length by-file))
             (buf     (get-buffer-create buf-name)))
        (prm--log "[%s] PR #%d: %d thread(s) across %d file(s)"
                  full-repo-name pr-number total nfiles)
        (with-current-buffer buf
          (let ((inhibit-read-only t)
                sections)
            (prm--clear-overlays)
            (erase-buffer)
            (let ((idx 0))
              (dolist (grp by-file)
                (setq idx (1+ idx))
                (let* ((path     (car grp))
                       (nthreads (length (cdr grp))))
                  (prm--vlog "[%s] PR #%d: [%d/%d] diff %s (%d thread(s))"
                             full-repo-name pr-number idx nfiles path nthreads)
                  (insert (propertize (format "══ %s ══\n" path)
                                      'face '(:foreground "cyan" :weight bold)))
                  (let ((diff-start (point)))
                    (insert (let ((prm--local-repo-path    local-repo-path)
                                  (prm--review-base-branch base-ref)
                                  (prm--review-head-commit head-oid))
                              (prm--git-diff path)))
                    (unless (bolp) (insert "\n"))
                    (push (list (cdr grp) diff-start (point)) sections)))))
            (diff-mode)
            (prm-review-mode 1)
            (setq prm--repo               full-repo-name
                  prm--pr-number          pr-number
                  prm--local-repo-path    local-repo-path
                  prm--review-commit      prm--head-commit
                  prm--review-base-branch base-ref
                  prm--review-head-commit head-oid)
            (dolist (section (nreverse sections))
              (let ((threads-for-file (nth 0 section))
                    (diff-start       (nth 1 section))
                    (diff-end         (nth 2 section)))
                (dolist (thread threads-for-file)
                  (prm--add-overlay thread diff-start diff-end))))
            (goto-char (point-min)))
          (setq buffer-read-only t))
        (unless refetch
          (pop-to-buffer buf))
        (prm--log "[%s] PR #%d: done — %d thread(s) in %d file(s)"
                  full-repo-name pr-number total nfiles)))))

;;; ── Level 3: interactive commands ────────────────────────────────────────

(defun prm--create-thread (repo number commit path line body)
  "Create a new review comment (thread) via REST."
  (prm--http "POST"
             (format "https://api.github.com/repos/%s/pulls/%d/comments"
                     repo (truncate number))
             `((body      . ,body)
               (commit_id . ,commit)
               (path      . ,path)
               (line      . ,line)
               (side      . "RIGHT"))))

(defun prm--file-at-point ()
  "Return the file path of the diff section containing point, or nil."
  (save-excursion
    (when (re-search-backward "^══ \\(.+\\) ══$" nil t)
      (match-string-no-properties 1))))

(defun prm--diff-line-at-point ()
  "Return the new-file line number at point, or nil if not on a countable line."
  (save-excursion
    (let ((target (line-beginning-position)))
      (catch 'result
        (when (re-search-backward "^@@ -[0-9,]+ \\+\\([0-9]+\\)" nil t)
          (let ((cur (1- (string-to-number (match-string 1)))))
            (forward-line 1)
            (while (not (eobp))
              (let ((lbp (line-beginning-position))
                    (txt (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))))
                (cond
                 ((string-match "^@@ -[0-9,]+ \\+\\([0-9]+\\)" txt)
                  (setq cur (1- (string-to-number (match-string 1 txt)))))
                 ((or (string-prefix-p "---" txt) (string-prefix-p "+++" txt)
                      (string-prefix-p "diff " txt) (string-prefix-p "\\\\ " txt)))
                 ((string-prefix-p "-" txt)
                  (when (= lbp target) (throw 'result nil)))
                 (t
                  (setq cur (1+ cur))
                  (when (= lbp target) (throw 'result cur))))
                (when (> lbp target) (throw 'result nil))
                (forward-line 1))))
        nil)))))

(defun prm-new-thread-at-point ()
  "Spawn a new review thread on the diff line at point."
  (interactive)
  (let ((path   (or (prm--file-at-point)
                    (user-error "Could not determine file at point")))
        (line   (or (prm--diff-line-at-point)
                    (user-error "Point is not on a new-file line (try a context or '+' line)")))
        (commit (or prm--review-commit
                    (user-error "No commit SHA recorded — try refetching with g"))))
    (let ((body (read-string (format "New thread on %s:%d: " path line))))
      (when (string-empty-p body)
        (user-error "Comment body cannot be empty"))
      (prm--create-thread prm--repo prm--pr-number commit path line body)
      (prm--log "thread created on %s:%d — press g to refresh" path line))))

(defun prm--thread-at-point ()
  (cl-some (lambda (ov) (overlay-get ov 'prm-thread))
           (overlays-at (point))))

(defun prm-reply-at-point ()
  "Reply to the PR thread at point."
  (interactive)
  (let* ((thread   (or (prm--thread-at-point) (user-error "No thread at point")))
         (comments (alist-get 'nodes (alist-get 'comments thread)))
         (last-id  (truncate (alist-get 'databaseId (car (last comments)))))
         (body     (read-string "Reply: ")))
    (prm--log "reply sent to thread — press g to refresh")
    (prm--reply prm--repo prm--pr-number last-id body)))

(defun prm-resolve-at-point ()
  "Resolve the PR thread at point via GraphQL."
  (interactive)
  (let* ((thread (or (prm--thread-at-point) (user-error "No thread at point")))
         (tid    (alist-get 'id thread)))
    (prm--resolve tid)
    (prm--log "thread resolved — press g to refresh")))

(defun prm--move-to-overlay (next-fn limit-p limit-msg)
  (let ((pos (funcall next-fn (point))))
    (while (and (funcall limit-p pos)
                (not (cl-some (lambda (o)
                                (and (overlay-get o 'prm-thread)
                                     (or prm--resolved-visible
                                         (not (eq (alist-get 'isResolved
                                                              (overlay-get o 'prm-thread))
                                                   t)))))
                              (overlays-at pos))))
      (setq pos (funcall next-fn pos)))
    (if (funcall limit-p pos)
        (goto-char pos)
      (message limit-msg))))

(defun prm-next-thread ()
  "Jump to the next PR thread overlay."
  (interactive)
  (prm--move-to-overlay #'next-overlay-change
                        (lambda (p) (< p (point-max)))
                        "No more threads."))

(defun prm-prev-thread ()
  "Jump to the previous PR thread overlay."
  (interactive)
  (prm--move-to-overlay #'previous-overlay-change
                        (lambda (p) (> p (point-min)))
                        "No previous threads."))

(defun prm-toggle-comments ()
  "Toggle visibility of PR thread comments (key: c)."
  (interactive)
  (setq prm--comments-visible (not prm--comments-visible))
  (dolist (ov prm--overlays)
    (overlay-put ov 'after-string
                 (if prm--comments-visible
                     (overlay-get ov 'prm-after-string)
                   "")))
  (prm--log "PR comments %s" (if prm--comments-visible "shown" "hidden")))

(defun prm-toggle-resolved ()
  "Toggle visibility of resolved PR thread comments (key: v)."
  (interactive)
  (setq prm--resolved-visible (not prm--resolved-visible))
  (dolist (ov prm--overlays)
    (let* ((thread   (overlay-get ov 'prm-thread))
           (resolved (eq (alist-get 'isResolved thread) t)))
      (when resolved
        (overlay-put ov 'after-string
                     (if prm--resolved-visible
                         (overlay-get ov 'prm-after-string)
                       "")))))
  (prm--log "resolved comments %s" (if prm--resolved-visible "shown" "hidden")))

(defun prm-toggle-diff ()
  "Toggle diff visibility, keeping only comment anchor lines (key: d)."
  (interactive)
  (if prm--diff-visible
      (let ((anchors (mapcar #'overlay-start prm--overlays)))
        (setq prm--diff-visible nil)
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let ((lbp (line-beginning-position))
                  (lep (line-beginning-position 2)))
              (unless (cl-some (lambda (p) (and (>= p lbp) (< p lep))) anchors)
                (let ((ov (make-overlay lbp lep)))
                  (overlay-put ov 'invisible t)
                  (push ov prm--diff-hide-overlays))))
            (forward-line 1))))
    (setq prm--diff-visible t)
    (mapc #'delete-overlay prm--diff-hide-overlays)
    (setq prm--diff-hide-overlays nil))
  (prm--log "diff %s" (if prm--diff-visible "shown" "hidden")))

(defun prm-refetch ()
  "Re-fetch threads and refresh the current review buffer."
  (interactive)
  (prm--open-review prm--repo prm--pr-number nil :refetch))

(defun prm-open-file-at-point ()
  "Open the source file at point.
If point is on a thread overlay, jump to that thread's line.
Otherwise open the file for the current diff section at the diff line at point."
  (interactive)
  (let* ((thread    (prm--thread-at-point))
         (path      (or (and thread (alist-get 'path thread))
                        (prm--file-at-point)
                        (user-error "Could not determine file at point")))
         (line      (or (and thread (or (alist-get 'line thread)
                                        (alist-get 'originalLine thread)))
                        (prm--diff-line-at-point)))
         (local-dir (or prm--local-repo-path
                        (user-error "No local repo path configured for this buffer")))
         (full-path (expand-file-name path (expand-file-name local-dir))))
    (unless (file-exists-p full-path)
      (user-error "File not found: %s" full-path))
    (find-file-other-window full-path)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

;;; ── Debug ─────────────────────────────────────────────────────────────────

(defun prm-debug ()
  "Dump raw GraphQL response for the current review buffer to *prm-debug*."
  (interactive)
  (let* ((repo   (or prm--repo (prm--build-repo)))
         (number (or prm--pr-number 0))
         (parts  (split-string repo "/"))
         (resp   (prm--graphql prm--threads-query
                               `((owner . ,(car parts))
                                 (repo  . ,(cadr parts))
                                 (pr    . ,number))))
         (buf    (get-buffer-create "*prm-debug*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert (json-encode resp))
      (json-pretty-print-buffer)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

;;; ── prm-review-mode ───────────────────────────────────────────────────────

(defvar prm-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'prm-next-thread)
    (define-key map (kbd "p") #'prm-prev-thread)
    (define-key map (kbd "t") #'prm-new-thread-at-point)
    (define-key map (kbd "r") #'prm-reply-at-point)
    (define-key map (kbd "R") #'prm-resolve-at-point)
    (define-key map (kbd "g") #'prm-refetch)
    (define-key map (kbd "o") #'prm-open-file-at-point)
    (define-key map (kbd "c") #'prm-toggle-comments)
    (define-key map (kbd "v") #'prm-toggle-resolved)
    (define-key map (kbd "d") #'prm-toggle-diff)
    (define-key map (kbd "?") #'describe-mode)
    map))

(define-minor-mode prm-review-mode
  "Minor mode for reviewing GitHub PR comments in diff buffers.
\\{prm-review-mode-map}"
  :lighter " PRm"
  :keymap prm-review-mode-map)

;;; ── Level 2: PR list buffer ───────────────────────────────────────────────

(defvar-local prm--prs-repo nil "Full \"owner/repo\" for this PR list buffer.")
(defvar-local prm--prs-list nil "List of PR alists, parallel to display lines.")
(defvar-local prm--wc-mode  nil "Non-nil if checkout-on-open is requested.")

(defun prm--pr-list-fetch-and-render ()
  "Fetch and render open PRs in the current *prm-prs:* buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "Open PRs — %s\n\n" prm--prs-repo)
                        'face '(:weight bold)))
    (prm--log "fetching PRs for %s..." prm--prs-repo)
    (let ((prs (prm--fetch-pr-list prm--prs-repo)))
      (setq prm--prs-list prs)
      (if (null prs)
          (insert "  (no open PRs)\n")
        (dolist (pr prs)
          (let* ((num    (truncate (alist-get 'number pr)))
                 (title  (alist-get 'title  pr))
                 (author (alist-get 'login (alist-get 'user pr)))
                 (line   (format "  #%-5d  %-20s  %s\n" num author title)))
            (add-text-properties 0 (length line) `(prm-index ,num) line)
            (insert line))))
      (goto-char (point-min))
      (forward-line 2)
      (prm--log "fetched %d PR(s) for %s" (length prs) prm--prs-repo)))
  (setq buffer-read-only t))

(defun prm--open-pr-list (full-repo-name &optional wc)
  "Open the PR list buffer for FULL-REPO-NAME."
  (let* ((buf-name (format "*prm-prs:%s*" full-repo-name))
         (buf      (get-buffer-create buf-name)))
    (with-current-buffer buf
      (setq buffer-read-only nil
            prm--prs-repo    full-repo-name
            prm--wc-mode     wc)
      (prm-prs-mode 1)
      (prm--pr-list-fetch-and-render))
    (pop-to-buffer buf)))

(defun prm-prs-refresh ()
  "Re-fetch and re-render the PR list."
  (interactive)
  (prm--pr-list-fetch-and-render))

(defun prm-prs-open-at-point ()
  "Open the diff review buffer for the PR on the current line."
  (interactive)
  (let ((pr-num (get-text-property (line-beginning-position) 'prm-index)))
    (unless pr-num
      (user-error "No PR on this line"))
    (prm--open-review prm--prs-repo pr-num prm--wc-mode)))

(defvar prm-prs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    (define-key map (kbd "g")   #'prm-prs-refresh)
    (define-key map (kbd "RET") #'prm-prs-open-at-point)
    (define-key map (kbd "?")   #'describe-mode)
    map))

(define-minor-mode prm-prs-mode
  "Minor mode for the PRM PR list buffer.
\\{prm-prs-mode-map}"
  :lighter " PRm-PRs"
  :keymap prm-prs-mode-map)

;;; ── Level 1: repo picker buffer ──────────────────────────────────────────

(defvar-local prm--repos-list nil "List of (label full-repo-name) pairs for this buffer.")

(defun prm--build-repos-list ()
  "Return deduplicated list of (label full-repo-name) from prm-presets."
  (let (seen result)
    (dolist (preset prm-presets)
      (let ((full-name (prm--preset-repo-string preset))
            (label     (nth 0 preset)))
        (unless (member full-name seen)
          (push full-name seen)
          (push (list label full-name) result))))
    (nreverse result)))

(defun prm--repos-render ()
  "Render the repo list in the current *prm-repos* buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Repositories\n\n" 'face '(:weight bold)))
    (seq-do-indexed
     (lambda (entry i)
       (let* ((label     (nth 0 entry))
              (full-name (nth 1 entry))
              (line      (format "  %-35s  %s\n" label full-name)))
         (add-text-properties 0 (length line) `(prm-index ,i) line)
         (insert line)))
     prm--repos-list)
    (goto-char (point-min))
    (forward-line 2))
  (setq buffer-read-only t))

(defun prm-repos-refresh ()
  "Rebuild and re-render the repo list."
  (interactive)
  (setq prm--repos-list (prm--build-repos-list))
  (prm--repos-render))

(defun prm-repos-open-at-point ()
  "Open the PR list for the repo on the current line."
  (interactive)
  (let ((idx (get-text-property (line-beginning-position) 'prm-index)))
    (unless idx
      (user-error "No repo on this line"))
    (prm--open-pr-list (nth 1 (nth idx prm--repos-list)) prm--wc-mode)))

(defvar prm-repos-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    (define-key map (kbd "g")   #'prm-repos-refresh)
    (define-key map (kbd "RET") #'prm-repos-open-at-point)
    (define-key map (kbd "?")   #'describe-mode)
    map))

(define-minor-mode prm-repos-mode
  "Minor mode for the PRM repo picker buffer.
\\{prm-repos-mode-map}"
  :lighter " PRm-Repos"
  :keymap prm-repos-mode-map)

;;; ── Top-level entry points ────────────────────────────────────────────────

(defun prm-select-dired ()
  "Open the PRM repo picker (Level 1 → 2 → 3 navigation)."
  (interactive)
  (let ((buf (get-buffer-create "*prm-repos*")))
    (with-current-buffer buf
      (setq buffer-read-only nil
            prm--wc-mode     nil)
      (prm-repos-mode 1)
      (setq prm--repos-list (prm--build-repos-list))
      (prm--repos-render))
    (pop-to-buffer buf)))

(defun prm-select-dired-wc ()
  "Open the PRM repo picker; also checkout the PR branch on entry to Level 3."
  (interactive)
  (let ((buf (get-buffer-create "*prm-repos*")))
    (with-current-buffer buf
      (setq buffer-read-only nil
            prm--wc-mode     t)
      (prm-repos-mode 1)
      (setq prm--repos-list (prm--build-repos-list))
      (prm--repos-render))
    (pop-to-buffer buf)))

(defun prm-select-from-url (url)
  "Open a PR review buffer directly from a GitHub PR URL."
  (interactive "sGitHub PR URL: ")
  (if (string-match
       "https?://github\\.com/\\([^/]+\\)/\\([^/]+\\)/pull/\\([0-9]+\\)" url)
      (prm--open-review (concat (match-string 1 url) "/" (match-string 2 url))
                        (string-to-number (match-string 3 url)))
    (user-error "Could not parse GitHub PR URL: %s" url)))

(defun prm-select-from-url-wc (url)
  "Open a PR review buffer from a GitHub PR URL; also checkout the PR branch."
  (interactive "sGitHub PR URL: ")
  (if (string-match
       "https?://github\\.com/\\([^/]+\\)/\\([^/]+\\)/pull/\\([0-9]+\\)" url)
      (prm--open-review (concat (match-string 1 url) "/" (match-string 2 url))
                        (string-to-number (match-string 3 url))
                        t)
    (user-error "Could not parse GitHub PR URL: %s" url)))

(provide 'prm)
