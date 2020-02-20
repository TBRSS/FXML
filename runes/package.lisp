;;; -*- Mode: Lisp; Syntax: Common-Lisp; Package: CL-USER; -*-
;;; ---------------------------------------------------------------------------
;;;     Title: Generating a sane DEFPACKAGE for RUNES
;;;   Created: 1999-05-25
;;;    Author: Gilbert Baumann <unk6@rz.uni-karlsruhe.de>
;;; ---------------------------------------------------------------------------
;;;  (c) copyright 1999,2000 by Gilbert Baumann

(in-package :cl-user)

(defpackage :fxml.runes
  (:use :cl :named-readtables :trivial-gray-streams)
  (:import-from #:alexandria #:array-index #:emptyp)
  (:import-from #:serapeum #:-> #:do-splits)
  (:export #:definline

           ;; runes.lisp
           #:rune
           #:rod
           #:simple-rod
           #:with-simple-rod
           #:%rune
           #:rod-capitalize
           #:code-rune
           #:rune-code
           #:rune-downcase
           #:rune-upcase
           #:rod-downcase
           #:rod-upcase
           #:white-space-rune-p
           #:digit-rune-p
           #:rune=
           #:rune<=
           #:rune>=
           #:rune-equal
           #:runep
           #:rod=
           #:rod-equal
           #:make-rod
           #:char-rune
           #:rune-char
           #:rod-string
           #:string-rod
           #:rod-subseq
           #:rod<

           ;; xstream.lisp
           #:xstream
           #:make-xstream
           #:make-rod-xstream
           #:close-xstream
           #:xstream-p
           #:read-rune
           #:peek-rune
           #:fread-rune
           #:fpeek-rune
           #:consume-rune
           #:unread-rune
           #:xstream-position
           #:xstream-line-number
           #:xstream-column-number
           #:xstream-encoding
           #:set-to-full-speed
           #:xstream-name

           ;; ystream.lisp
	   #:ystream
	   #:ystream-encoding
	   #:find-output-encoding
	   #:close-ystream
	   #:ystream-write-rune
	   #:ystream-write-rod
	   #:ystream-write-escapable-rune
	   #:ystream-write-escapable-rod
	   #:ystream-column
           #:make-octet-vector-ystream
           #:make-octet-stream-ystream
           #:make-rod-ystream
           #:make-character-stream-ystream
	   #:runes-to-utf8/adjustable-string

	   #:rod-to-utf8-string
	   #:utf8-string-to-rod
	   #:make-octet-input-stream
           #:do-splits))

(defpackage :fxml.utf8-runes
  (:use :cl :named-readtables)
  (:export #:rune #:rod #:simple-rod #:rod-string #:rod= #:make-rod
	   #:string-rod))

(defpackage :fxml.runes-encoding
  (:use :cl :fxml.runes)
  (:export
   #:encoding-error
   #:find-encoding
   #:decode-sequence
   #:decode-sequence*))
