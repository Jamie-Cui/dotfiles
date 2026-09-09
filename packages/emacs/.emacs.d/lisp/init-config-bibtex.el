;;; init-config-bibtex.el --- BibTeX configuration -*- lexical-binding: t -*-
;;; Commentary:
;; Generate citation keys from author initials and the four-digit year.
;;; Code:

(require 'bibtex)

;; A negative length requests exactly one character, including vowel initials.
(setopt bibtex-autokey-name-case-convert-function #'upcase)
(setopt bibtex-autokey-names 4)
(setopt bibtex-autokey-additional-names "+")
(setopt bibtex-autokey-name-length -1)
(setopt bibtex-autokey-year-length 4)
(setopt bibtex-autokey-titlewords 0)
(setopt bibtex-autokey-titlewords-stretch 0)
(setopt bibtex-autokey-name-year-separator "")

(provide 'init-config-bibtex)
;;; init-config-bibtex.el ends here
