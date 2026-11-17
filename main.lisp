#!/usr/bin/env sbcl --script

;; Copyright © 2023–2025  Hraban Luyat
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, version 3 of the License.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

(setf *compile-verbose* NIL)

(require "asdf")
(require "uiop")

(asdf:load-system "alexandria")
(asdf:load-system "inferior-shell")
(asdf:load-system "str")
(asdf:load-system "trivia")

(defpackage #:script
  (:use #:cl)
  (:local-nicknames (#:alex #:alexandria)
                    (#:sh #:inferior-shell)))

(in-package #:script)

(defun non-empty-env-p (name)
  (str:non-empty-string-p (uiop:getenv name)))

;; Extremely rudimentary support for DRY_RUN. It’s messy output, but what
;; matters is that it doesn’t actually change anything on the system.
(defparameter *dry-run* (non-empty-env-p "DRY_RUN"))

(defun rootp ()
  "Am I the root user?

Checks the real uid: $USER is not reliably set in activation scripts."
  (equal "0" (uiop:run-program '("/usr/bin/id" "-u") :output '(:string :stripped t))))

(defun sh (&rest args)
  (if *dry-run*
      (format T "exec: ~A~%" (prin1-to-string (first args)))
      ;; This is my personal convention; set DEBUGSH to effect set -x
      (apply #'sh:run `(,@args :show ,(non-empty-env-p "DEBUGSH")))))

(defun sh/ss (&rest args)
  (apply #'sh `(,@args :output (:string :stripped t))))

(defgeneric rm-rf (p))

(defmethod rm-rf ((p string))
  (rm-rf (uiop:parse-native-namestring p :ensure-directory t)))

(defmethod rm-rf ((p pathname))
  (if *dry-run*
      (format T "rm -rf ~A~%" p)
      (uiop:delete-directory-tree
       (uiop:ensure-directory-pathname p)
       :validate t
       :if-does-not-exist :ignore)))

(defmacro in-temp-dir (&body body)
  (alex:with-gensyms (dir f)
    `(flet ((,f () ,@body))
       (if *dry-run*
           (,f)
           (let ((,dir (uiop:ensure-directory-pathname (sh/ss '(mktemp #\d)))))
             (uiop:with-current-directory (,dir)
               (unwind-protect (,f)
                 (rm-rf ,dir))))))))


;;; sync-dock

(defun realpath (f)
  "Transform a string, optionally relative, into a an absolute path.

Also resolves symlinks, if relevant.
"
  (uiop:ensure-pathname f
                        :want-pathname t
                        :ensure-absolute t
                        :defaults (uiop:getcwd)
                        :want-existing t
                        :resolve-symlinks t))

(defgeneric path-without-slash (p))

(defmethod path-without-slash ((p string))
  (string-right-trim "/" p))

(defmethod path-without-slash ((p pathname))
  (path-without-slash (namestring p)))

(defun sync-dock (apps)
  "Every element must be a pathname to a real directory, not a symlink"
  ;; dockutil doesn't like acting under sudo and will fall back to the original
  ;; user. That’s sensible when using dockutil as an end user, but because this
  ;; tool /wraps/ it, it leads to unexpected results e.g. when used in a home
  ;; manager activation script. Just stick to the dumb default: act as the user
  ;; that invokes you, no special sudo tricks.
  (setf (uiop:getenv "SUDO_USER") "")
  ;; Filtering for /nix/store is not technically part of the docs but let’s be
  ;; conservative for now.
  (let* ((dockutil-args (when (rootp)
                          ;; When run as root, it’s probably intended to affect every
                          ;; actual end-user’s dock--not the root.
                          '(:allhomes)))
         (persistents (sh `(sh:pipe (dockutil ,@dockutil-args #\L)
                                    (grep "/nix/store")
                                    ;; Whatever, this works.
                                    (grep "persistentApps")
                                    ;; I feel like using the bundle ID would be
                                    ;; cleaner (org.gnu.Emacs etc) but dockutil only
                                    ;; works reliably when I use the “bundle name”,
                                    ;; which is just the file’s basename without
                                    ;; extension. Ok.
                                    (cut #\f 1))
                          :output :lines)))
    (dolist (existing persistents)
      (alex:when-let ((app (find existing
                                 (mapcar #'path-without-slash apps)
                                 :test #'equal
                                 :key #'pathname-name)))
        ;; I was passed an app with the same name as an existing persistent dock
        ;; item.  Yes this restarts after every item but I don’t know how to
        ;; only restart exactly once.
        (sh `(dockutil
              ,@dockutil-args
              :add ,(realpath app)
              :replacing ,existing))))))


;;; sign-copy

(defun default-cert-name ()
  "Default name of the signing certificate.

Root and regular users get different names.  Root's certificate lives in the
System keychain, which users can see too; with a shared name a user could pick
up the system identity, whose private key they cannot use."
  (if (rootp) "mac-app-util system signing" "mac-app-util user signing"))

(defun find-identities (identity)
  "Hashes of the code-signing identities named exactly IDENTITY, or whose SHA-1
hash is IDENTITY.

Deliberately without -v: a self-signed certificate that is not (yet) trusted is
still an identity that exists."
  (let ((out (uiop:run-program '("/usr/bin/security" "find-identity" "-p" "codesigning")
                               :output :string
                               :ignore-error-status t)))
    (remove-duplicates
     (loop for line in (str:lines out)
           for words = (str:words line)
           for q1 = (position #\" line)
           for q2 = (and q1 (position #\" line :start (1+ q1)))
           ;; Lines look like:  1) 6E55…EC "name" [(CSSMERR_TP_NOT_TRUSTED)]
           when (and q2
                     (>= (length words) 2)
                     (str:ends-with-p ")" (first words))
                     (or (string-equal (second words) identity)
                         (string= (subseq line (1+ q1) q2) identity)))
             collect (string-upcase (second words)))
     :test #'string=)))

(defun resolve-identity (identity)
  "The hash of the single code-signing identity matching IDENTITY.

Signing by hash avoids codesign's loose matching of names."
  (let ((hashes (find-identities identity)))
    (cond ((null hashes)
           (error "No code-signing identity named ~S in the keychain (see `security find-identity -p codesigning`).  To create one, run: mac-app-util create-cert ~S" identity identity))
          ((rest hashes)
           (error "Several code-signing identities are named ~S: ~{~A~^, ~}.  Remove the extra ones, or use a hash as the identity." identity hashes))
          (T (first hashes)))))

(defun env-identity ()
  "The signing identity named in $MAC_APP_UTIL_SIGN_IDENTITY, or the default."
  (let ((id (uiop:getenv "MAC_APP_UTIL_SIGN_IDENTITY")))
    (if (str:non-empty-string-p id) id (default-cert-name))))

(defun create-cert (&optional (name (default-cert-name)))
  "Create a self-signed code-signing certificate and install it in the keychain.

Needs a user at the screen: trusting the certificate asks for a password.  When
run as root the System keychain is used, otherwise your login keychain."
  (if (find-identities name)
      (format T "Identity ~S already exists, nothing to do.~%" name)
      (let* ((keychain (if (rootp)
                           "/Library/Keychains/System.keychain"
                           (format NIL "~A/Library/Keychains/login.keychain-db" (uiop:getenv "HOME"))))
             (trust-args (when (rootp) '("-d"))))
        (format T "Creating code-signing identity ~S in ~A; macOS will ask for a password to trust it.~%"
                name keychain)
        (in-temp-dir
          ;; Never let the private key leave this temp dir and the keychain; in
          ;; particular it must not end up in the Nix store.
          (let ((pw (sh/ss '("openssl" "rand" "-hex" "16"))))
            (sh `("openssl" "req" "-x509" "-newkey" "rsa:2048" "-nodes"
                            "-keyout" "key.pem" "-out" "cert.pem" "-days" "3650"
                            "-subj" ,(format NIL "/CN=~A" name)
                            "-addext" "keyUsage=critical,digitalSignature"
                            "-addext" "extendedKeyUsage=critical,codeSigning"))
            ;; macOS cannot import the AES-based PKCS#12 that OpenSSL 3 writes
            ;; by default ("MAC verification failed"); use the old algorithms.
            (sh `("openssl" "pkcs12" "-export" "-inkey" "key.pem" "-in" "cert.pem"
                            "-name" ,name "-out" "id.p12"
                            "-certpbe" "PBE-SHA1-3DES" "-keypbe" "PBE-SHA1-3DES"
                            "-macalg" "sha1" "-passout" ,(format NIL "pass:~A" pw)))
            (sh `("/usr/bin/security" "import" "id.p12" "-k" ,keychain
                                      "-P" ,pw "-T" "/usr/bin/codesign"))
            (sh `("/usr/bin/security" "add-trusted-cert" ,@trust-args
                                      "-r" "trustRoot" "-p" "codeSign"
                                      "-k" ,keychain "cert.pem"))))
        (format T "Created identity ~S in ~A.

The first time codesign uses the key macOS may ask for permission; choose
\"Always Allow\".  To avoid that prompt, run once:
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~A~%"
                name keychain keychain))))

(defun sign-copy (app to identity)
  "Copy the app bundle APP to TO and sign the copy with IDENTITY.

Nix apps are ad-hoc signed, so their designated requirement is a code hash that
changes with every build, and macOS drops privacy grants such as Full Disk
Access whenever the app is updated.  Signing with a fixed certificate makes the
requirement \"this bundle ID, signed by this certificate\", which survives
updates.

APP and TO must be directory pathnames."
  (let ((src (uiop:native-namestring app))
        (dst (uiop:native-namestring to)))
    (sh `(mkdir -p ,dst))
    ;; Store files are read-only; the copy must be writable to be signed.
    ;; Symlinks pointing outside the bundle (typical for Nix) are replaced by
    ;; their targets, otherwise codesign rejects the bundle.
    (sh `(rsync :archive :copy-unsafe-links :chmod "u+w" ,src ,dst))
    (sh `("/usr/bin/codesign" "--force" "--deep" "--sign" ,identity
          "--preserve-metadata=identifier,entitlements,flags,runtime"
          ,(string-right-trim "/" dst)))))


;;; sync-trampolines

(defun symlinked-dir-p (d)
  (let ((resolved (uiop:directory-exists-p d)))
    (and resolved
         (not (equal (uiop:ensure-directory-pathname d)
                     resolved)))))

(defun to-abs-dir (d)
  "Transform d into an absolute directory pathname."
  (uiop:ensure-pathname d
                        :ensure-absolute t
                        :defaults (uiop:getcwd)
                        :ensure-directory t))

(defun directory-name (d)
  ;; Weird lispism
  (first (last (pathname-directory d))))

(defun gather-apps (dir)
  (mapcan (lambda (pattern)
            (directory (merge-pathnames pattern dir)))
          ;; Kind of a cheat, but I’ve noticed some apps nest themselves one
          ;; directory further, e.g. KDE apps in /Applications/Nix
          ;; Apps/KDE/Foo.app.  There are many ways to deal with this, but
          ;; honestly just hard-coding one extra level of search is probably the
          ;; easiest.  This nesting won’t survive in the destination directory,
          ;; but that doesn’t seem to matter.
          '(#p "*.app" #p "*/*.app")))

(defun sync-trampolines (&rest args)
  "Replace TO with a signed copy of every app in FROM; update the dock.

Signs with the identity named in $MAC_APP_UTIL_SIGN_IDENTITY, or the default
one.  With $MAC_APP_UTIL_CREATE_CERT set, a missing identity is created first.

The name is historical: nothing is a trampoline anymore, see sign-copy."
  (destructuring-bind (from to) (mapcar #'to-abs-dir args)
    (rm-rf to)
    ;; Since 25.11 nix-darwin copies .app folders directly to /Applications.
    ;; In that scenario there is nothing to do here.
    ;; https://github.com/nix-darwin/nix-darwin/pull/1396
    (when (symlinked-dir-p from)
      (ensure-directories-exist to)
      (alex:when-let ((apps (gather-apps from)))
        ;; Only touch the keychain when there is something to sign, so that a
        ;; setup without apps never asks for a password.
        (let ((name (env-identity)))
          (when (and (non-empty-env-p "MAC_APP_UTIL_CREATE_CERT")
                     (null (find-identities name)))
            (create-cert name))
          (let ((identity (if (and *dry-run* (null (find-identities name)))
                              name
                              (resolve-identity name))))
            (sync-dock
             (mapcar (lambda (app)
                       (let ((dest (to-abs-dir (merge-pathnames (directory-name app) to))))
                         (sign-copy app dest identity)
                         dest))
                     apps))))))))


;;; CLI

(defun print-usage ()
  (format T "Usage:

    mac-app-util sync-dock Foo.app Bar.app ...
    mac-app-util sync-trampolines /my/nix/Applications /Applications/MyTrampolines/
    mac-app-util sign-copy FROM.app TO.app IDENTITY
    mac-app-util create-cert [NAME]

sync-dock updates persistent items in your dock if any of the given apps has the
same name. This can be used to programmatically keep pinned items in your dock
up to date with potential new versions of an app outside of the /Applications
directory, without having to check which one is pinned etc.

create-cert creates a self-signed code-signing certificate and installs it in the
keychain: your login keychain, or the System keychain when run as root.  Default
name: \"mac-app-util user signing\", or \"mac-app-util system signing\" as root.
Trusting the certificate asks for a password.

sign-copy copies an app and signs the copy with the given code-signing identity.

sync-trampolines is an all-in-1 solution that syncs an entire directory of *.app
files to another by copying every app and signing it, deleting the rest, and
updating the dock.  It signs with the identity named in
$MAC_APP_UTIL_SIGN_IDENTITY, or the create-cert default.  If
$MAC_APP_UTIL_CREATE_CERT is set, a missing identity is created first.  A fixed
signing identity keeps privacy grants (Full Disk Access etc.) across app
updates.
"))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (if (intersection args '("-h" "--help") :test #'equal)
        (progn
          (print-usage)
          (uiop:quit 0))
        (trivia:match args
          ((list* "sync-dock" apps)
           (sync-dock apps))
          ((list "sync-trampolines" from to)
           (sync-trampolines from to))
          ((list "create-cert")
           (create-cert))
          ((list "create-cert" name)
           (create-cert name))
          ((list "sign-copy" from to identity)
           (sign-copy (to-abs-dir from) (to-abs-dir to) (resolve-identity identity)))
          (_
           (print-usage)
           (uiop:quit 1))))))

(main)
