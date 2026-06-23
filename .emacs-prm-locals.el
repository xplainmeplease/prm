;;; .emacs-prm-locals.el --- PRM local configuration -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is loaded automatically by .emacs-prm.el and provides per-machine values.
;; It is distributed under the same GPL-3.0-or-later terms as the main package.

(setq prm-owner "example"
      prm-repo-prefix "example-"
      prm-repo-suffix ""
      prm-repo-name ""
      prm-username ""
      prm-base-branch "master"
      prm-repo-path "~/work/example/"
      prm-local-paths '(("example1" . "~/work/review/example1")
                        ("example2" . "~/work/review/example2"))
      prm-presets '(("example-repo / upstream"      "example-org" "example-" "" "example-repo"      "")
                    ("example-repo-test / upstream" "example-org" "example-" "" "example-repo-test" "")
                    ("example-repo / alice"         "example-org" "example-" "" "example-repo"      "alice")
                    ("example-repo / bob"           "example-org" "example-" "" "example-repo"      "bob")))

(provide 'prm-locals)
