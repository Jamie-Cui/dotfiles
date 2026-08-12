;;; project.el --- project tools and environments -*- lexical-binding: t -*-
;;; Commentary:
;; Project navigation and per-project environments with Projectile and envrc.
;;; Code:


;; -----------------------------------------------------------
;; DONE Projects
;;
;; projectile
;; -----------------------------------------------------------

(use-package projectile
  :ensure t
  :custom
  (projectile-indexing-method 'hybrid)
  ;; DO NOT add / remove project automatically
  (projectile-track-known-projects-automatically nil)
  ;; DO NOT enable cache
  (projectile-enable-caching nil)
  ;; each project has a separate compilation buffer
  (projectile-per-project-compilation-buffer t)
  ;; remote cache is avaliable for 5 min
  (projectile-file-exists-remote-cache-expire (* 5 60))
  ;; only git as project identifier
  (projectile-project-root-files-bottom-up '(".git"))
  ;; auto update cache when files are opened or deleted
  (projectile-auto-update-cache t)
  ;; I prefer citre, do not use built-in tag systm
  (projectile-tags-backend nil)
  :config
  ;; see: https://github.com/syl20bnr/spacemacs/issues/11381#issuecomment-481239700
  ;; (defadvice projectile-project-root (around ignore-remote first activate)
  ;;   (unless (file-remote-p default-directory) ad-do-it))
  ;; Projectile 2.10 auto-adds project type manifests such as CMakeLists.txt to
  ;; the bottom-up root markers during load, so enforce this after registration.
  (setopt projectile-project-root-files-bottom-up '(".git"))
  (projectile-discard-root-cache)
  (projectile-mode +1)

  ;; see: https://metaredux.com/posts/2025/02/03/projectile-introduces-significant-caching-improvements.html
  ;; Defer cache loading to after-init for faster startup
  (add-hook 'after-init-hook
            (lambda ()
              ;; initialize the projects cache if needed
              (unless projectile-projects-cache
                (setq projectile-projects-cache
                      (or (projectile-unserialize projectile-cache-file)
                          (make-hash-table :test 'equal))))
              (unless projectile-projects-cache-time
                (setq projectile-projects-cache-time
                      (make-hash-table :test 'equal)))
              ;; load the known projects
              (projectile-load-known-projects)
              ;; update the list of known projects
              (projectile--cleanup-known-projects)
              (when projectile-auto-discover-projects
                (projectile-discover-projects-in-search-path))))
  )

;; install dir: https://direnv.net/
;; brew install direnv
;; sudo dnf install direnv
(use-package envrc
  :ensure t
  :custom
  (envrc-remote t)
  :hook (after-init . envrc-global-mode))


(provide 'init-project)
;;; project.el ends here
