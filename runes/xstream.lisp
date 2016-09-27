;;; -*- Mode: Lisp; Syntax: Common-Lisp; readtable: runes; Encoding: utf-8; -*-
;;; ---------------------------------------------------------------------------
;;;     Title: Fast streams
;;;   Created: 1999-07-17
;;;    Author: Gilbert Baumann <unk6@rz.uni-karlsruhe.de>
;;;   License: Lisp-LGPL (See file COPYING for details).
;;; ---------------------------------------------------------------------------
;;;  (c) copyright 1999 by Gilbert Baumann

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the 
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, 
;;; Boston, MA  02111-1307  USA.

(in-package :fxml.runes)
(in-readtable :runes)

;;; API
;; 
;; MAKE-XSTREAM cl-stream &key name! speed initial-speed initial-encoding
;;                                                              [function]
;; MAKE-ROD-XSTREAM rod &key name                               [function]
;; CLOSE-XSTREAM xstream                                        [function]
;; XSTREAM-P object                                             [function]
;;
;; READ-RUNE xstream                                               [macro]
;; PEEK-RUNE xstream                                               [macro]
;; FREAD-RUNE xstream                                           [function]
;; FPEEK-RUNE xstream                                           [function]
;; CONSUME-RUNE xstream                                            [macro]
;; UNREAD-RUNE rune xstream                                     [function]
;;
;; XSTREAM-NAME xstream                                         [accessor]
;; XSTREAM-POSITION xstream                                     [function]
;; XSTREAM-LINE-NUMBER xstream                                  [function]
;; XSTREAM-COLUMN-NUMBER xstream                                [function]
;; XSTREAM-PLIST xstream                                        [accessor]
;; XSTREAM-ENCODING xstream                                     [accessor]  <-- be careful here. [*]
;; SET-TO-FULL-SPEED xstream                                    [function]

;; [*] switching the encoding on the fly is only possible when the
;; stream's buffer is empty; therefore to be able to switch the
;; encoding, while some runes are already read, set the stream's speed
;; to 1 initially (via the initial-speed argument for MAKE-XSTREAM)
;; and later set it to full speed. (The encoding of the runes
;; sequence, you fetch off with READ-RUNE is always UTF-16 though).
;; After switching the encoding, SET-TO-FULL-SPEED can be used to bump the
;; speed up to a full buffer length.

;; An encoding is simply something, which provides the DECODE-SEQUENCE
;; method.

;;; Controller protocol
;;
;; READ-OCTECTS sequence os-stream start end -> first-non-written
;; XSTREAM/CLOSE os-stream
;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *fast* '(optimize (speed 3) (safety 0))))

;; Let us first define fast fixnum arithmetric get rid of type
;; checks. (After all we know what we do here).

(defmacro fx-op (op &rest xs) 
  `(the fixnum (,op ,@(mapcar (lambda (x) `(the fixnum ,x)) xs))))
(defmacro fx-pred (op &rest xs) 
  `(,op ,@(mapcar (lambda (x) `(the fixnum ,x)) xs)))

(defmacro %+   (&rest xs) `(fx-op + ,@xs))
(defmacro %=  (&rest xs)  `(fx-pred = ,@xs))

(deftype buffer-index ()
  `(unsigned-byte ,(integer-length array-total-size-limit)))

(deftype buffer-byte ()
  '(unsigned-byte 32))

(deftype octet ()
  `(unsigned-byte 8))

;; The usage of a special marker for EOF is experimental and
;; considered unhygenic.

(defconstant +end+ #xFFFF
  "Special marker inserted into stream buffers to indicate end of buffered data.")

(defvar +null-buffer+ (make-array 0 :element-type 'buffer-byte))
(defvar +null-octet-buffer+ (make-array 0 :element-type 'octet))

(defstruct (xstream 
            (:constructor make-xstream/low)
            (:copier nil)
            (:print-function print-xstream))
  "For reading runes, I defined my own streams, called xstreams,
because we want to be fast. A function call or even a method call
per character is not acceptable, instead of that we define a
buffered stream with an advertised buffer layout, so that we
could use the trick stdio uses: READ-RUNE and PEEK-RUNE are macros,
directly accessing the buffer and only calling some underflow
handler in case of stream underflows. This will yield to quite a
performance boost vs calling READ-BYTE per character.

Also we need to do encoding and character set conversion on input,
this better done at large chunks of data rather than on a character
by character basis. This way we need a dispatch on the active
encoding only once in a while, instead of for each character. This
allows us to use a CLOS interface to do the underflow handling."
  
  ;;; Read buffer
  
  ;; the buffer itself
  (buffer +null-buffer+ 
          :type (simple-array buffer-byte (*)))
  ;; points to the next element of `buffer' containing the next rune
  ;; about to be read.
  (read-ptr      0 :type buffer-index)
  ;; points to the first element of `buffer' not containing a rune to
  ;; be read.
  (fill-ptr      0 :type buffer-index)

  ;;; OS buffer
  
  ;; a scratch pad for READ-SEQUENCE
  (os-buffer +null-octet-buffer+
             :type (simple-array octet (*)))
  
  ;; `os-left-start', `os-left-end' designate a region of os-buffer,
  ;; which still contains some undecoded data. This is needed because
  ;; of the DECODE-SEQUENCE protocol
  (os-left-start 0 :type buffer-index)
  (os-left-end   0 :type buffer-index)
  
  ;; How much to read each time
  (speed         0 :type buffer-index)
  (full-speed    0 :type buffer-index)
  
  ;; Some stream object obeying to a certain protcol
  (os-stream (error "No stream"))

  ;; The external format 
  ;; (some object offering the ENCODING protocol)
  (encoding :utf-8)

  ;;A STREAM-NAME object
  (name nil)

  ;; Stream Position
  ;; TODO Can these be tightened to fixnums? Especially with 64 bits.
  (line-number  1 :type (integer 1 *))  ;current line number
  (line-start   0 :type (integer 0 *)) ;stream position the current line starts at
  (buffer-start 0 :type (integer 0 *)) ;stream position the current buffer starts at
  
  ;; There is no need to maintain a column counter for each character
  ;; read, since we can easily compute it from `line-start' and
  ;; `buffer-start'.
  )

(setf (documentation 'xstream-encoding 'function)
      "Switching the encoding on the fly is only possible when the
stream's buffer is empty; therefore to be able to switch the
encoding, while some runes are already read, set the stream's speed
to 1 initially (via the initial-speed argument for MAKE-XSTREAM)
and later set it to full speed. (The encoding of the runes
sequence, you fetch off with READ-RUNE is always UTF-16 though).
After switching the encoding, SET-TO-FULL-SPEED can be used to bump the
speed up to a full buffer length.

An encoding is simply something, which provides the DECODE-SEQUENCE
method.")

(defun print-xstream (self sink depth)
  (declare (ignore depth))
  (format sink "#<~S ~S>" (type-of self) (xstream-name self)))

(defmacro read-rune (input)
  "Read a single rune off the xstream `input'. In case of end of file :EOF 
   is returned."
  `((lambda (input)
      (declare (type xstream input)
               #.*fast*)
      (let ((rp (xstream-read-ptr input)))
        (declare (type buffer-index rp))
        (let ((ch (aref (the (simple-array buffer-byte (*)) (xstream-buffer input))
                        rp)))
          (declare (type buffer-byte ch))
          (setf (xstream-read-ptr input) (%+ rp 1))
          (cond ((%= ch +end+)
                 (the (or (member :eof) rune)
                      (xstream-underflow input)))
                ((%= ch #x000A)         ;line break
                 (account-for-line-break input)
                 (code-rune ch))
                (t
                 (code-rune ch))))))
    ,input))

(defmacro peek-rune (input)
  "Peek a single rune off the xstream `input'. In case of end of file :EOF
   is returned."
  ;; NB Wrapping this with `the` kills performance in Clozure; why?
  `((lambda (input)
      (declare (type xstream input)
               #.*fast*)
      (let ((rp (xstream-read-ptr input)))
        (declare (type buffer-index rp))
        (let ((ch (aref (the (simple-array buffer-byte (*)) (xstream-buffer input))
                        rp)))
          (declare (type buffer-byte ch))
          (cond ((%= ch +end+)
                 (prog1
                     (the (or (member :eof) rune) (xstream-underflow input))
                   (setf (xstream-read-ptr input) 0)))
                (t
                 (code-rune ch))))))
    ,input))

(defmacro consume-rune (input)
  "Like READ-RUNE, but does not actually return the read rune."
  `((lambda (input)
      (declare (type xstream input)
               #.*fast*)
      (let ((rp (xstream-read-ptr input)))
        (declare (type buffer-index rp))
        (let ((ch (aref (the (simple-array buffer-byte (*)) (xstream-buffer input))
                        rp)))
          (declare (type buffer-byte ch))
          (setf (xstream-read-ptr input) (%+ rp 1))
          (when (%= ch +end+)
            (xstream-underflow input))
          (when (%= ch #x000A)         ;line break
            (account-for-line-break input) )))
      nil)
    ,input))

(definline unread-rune (rune input)
  "Unread the last recently read rune; if there wasn't such a rune, you
   deserve to lose."
  (declare (ignore rune))
  (decf (xstream-read-ptr input))
  (when (rune= (peek-rune input) #/u+000A)   ;was it a line break?
    (unaccount-for-line-break input)))

(defun fread-rune (input)
  "Same as `read-rune', but not a macro."
  (read-rune input))

(defun fpeek-rune (input)
  "Same as `peek-rune', but not a macro."
  (peek-rune input))

;;; Line counting

(defun account-for-line-break (input)
  (declare (type xstream input) #.*fast*)
  (incf (xstream-line-number input))
  (setf (xstream-line-start input)
        (+ (xstream-buffer-start input) (xstream-read-ptr input))))

(defun unaccount-for-line-break (input)
  ;; incomplete! 
  ;; We better use a traditional lookahead technique or forbid unread-rune.
  (decf (xstream-line-number input)))

;; User API:

(defun xstream-position (input)
  "Return the position of the underlying stream in INPUT, an xstream."
  (+ (xstream-buffer-start input) (xstream-read-ptr input)))

;; xstream-line-number is structure accessor
(setf (documentation 'xstream-line-number 'function)
      "The line number of the underlying stream.")

(defun xstream-column-number (input)
  "The column number of the underlying stream in INPUT, an xstream."
  (+ (- (xstream-position input)
        (xstream-line-start input))
     1))

;;; Underflow

(defconstant +default-buffer-size+ 100)

(defmethod xstream-underflow ((input xstream))
  (declare (type xstream input))
  (with-accessors ((buffer-start  xstream-buffer-start)
                   (read-ptr      xstream-read-ptr)
                   (fill-ptr      xstream-fill-ptr)
                   (os-left-start xstream-os-left-start)
                   (os-left-end   xstream-os-left-end)
                   (os-buffer     xstream-os-buffer)
                   (os-stream     xstream-os-stream)
                   (speed         xstream-speed)
                   (buffer        xstream-buffer)
                   (encoding      xstream-encoding))
      input
    ;; we are about to fill new data into the buffer, so we need to
    ;; adjust buffer-start.
    (incf buffer-start (- fill-ptr 0))
    ;; when there is something left in the os-buffer, we move it to
    ;; the start of the buffer.
    (let ((m (- os-left-end os-left-start)))
      (unless (zerop m)
        (replace os-buffer os-buffer
                 :start1 0 :end1 m
                 :start2 os-left-start
                 :end2 os-left-end)
        ;; then we take care that the buffer is large enough to carry at
        ;; least 100 bytes (a random number)
        ;;
        ;; David: My understanding is that any number of octets large enough
        ;; to record the longest UTF-8 sequence or UTF-16 sequence is okay,
        ;; so 100 is plenty for this purpose.
        (assert (>= (length os-buffer) +default-buffer-size+)))
      (let ((n (read-octets os-buffer
                            os-stream
                            m
                            (min (1- (length os-buffer))
                                 (+ m speed)))))
        (cond ((%= n 0)
               (setf read-ptr 0
                     fill-ptr n)
               (setf (aref buffer fill-ptr) +end+)
               :eof)
              (t
               ;; first-not-written, first-not-read
               (multiple-value-bind (fnw fnr) 
                   (fxml.runes-encoding:decode-sequence*
                    :encoding encoding
                    :in os-buffer
                    :in-start 0
                    :in-end n
                    :out buffer
                    :out-start 0
                    :out-end (1- (length buffer))
                    :eof (= n m))
                 (setf os-left-start fnr
                       os-left-end n
                       read-ptr 0
                       fill-ptr fnw
                       (aref buffer fill-ptr) +end+)
                 (read-rune input))))))))

;;; constructor

(defun make-xstream (os-stream &key name
                                    (speed 8192)
                                    (initial-speed 1)
                                    (initial-encoding :guess))
  "Make an xstream from OS-STREAM."
  ;; XXX if initial-speed isn't 1, encoding will me munged up
  (assert (eql initial-speed 1))
  (multiple-value-bind (encoding preread)
      (if (eq initial-encoding :guess)
          (figure-encoding os-stream)
          (values initial-encoding nil))
    (let* ((bufsize (max speed +default-buffer-size+))
	   (osbuf (make-array bufsize :element-type '(unsigned-byte 8))))
      (replace osbuf preread)
      (make-xstream/low
       :buffer (let ((r (make-array bufsize :element-type 'buffer-byte)))
                 (setf (elt r 0) #xFFFF)
                 r)
       :read-ptr 0
       :fill-ptr 0
       :os-buffer osbuf
       :speed initial-speed
       :full-speed speed
       :os-stream os-stream
       :os-left-start 0
       :os-left-end (length preread)
       :encoding encoding
       :name name))))

(defun make-rod-xstream (string &key name)
  "Make an xstream that reads from STRING."
  (unless (typep string 'simple-array)
    (setf string (coerce string 'simple-string)))
  (let* ((n (length string))
         (buffer (make-array (1+ n) :element-type 'buffer-byte)))
    (declare (type (simple-array buffer-byte (*)) buffer))
    ;; copy the rod
    (loop for i of-type fixnum from (1- n) downto 0
          do (setf (aref buffer i) (rune-code (%rune string i))))
    (setf (aref buffer n) +end+)
    (make-xstream/low :buffer buffer
                      :read-ptr 0
                      :fill-ptr n
                      :speed 1
                      :os-stream nil
                      :name name)))

(defmethod figure-encoding ((stream null))
  (values :utf-8 nil))

(defmethod figure-encoding ((stream stream))
  (let ((c0 (read-byte stream nil :eof)))
    (cond ((eq c0 :eof)
           (values :utf-8 nil))
          (t
           (let ((c1 (read-byte stream nil :eof)))
             (cond ((eq c1 :eof)
                    (values :utf-8 (list c0)))
                   (t
                    (cond ((and (= c0 #xFE) (= c1 #xFF)) (values :utf-16-big-endian nil))
                          ((and (= c0 #xFF) (= c1 #xFE)) (values :utf-16-little-endian nil))
                          ((and (= c0 #xEF) (= c1 #xBB))
                           (let ((c2 (read-byte stream nil :eof)))
                             (if (= c2 #xBF)
                                 (values :utf-8 nil)
                                 (values :utf-8 (list c0 c1 c2)))))
                          (t
                           (values :utf-8 (list c0 c1)))))))))))

;;; misc

(defun close-xstream (input)
  "Close INPUT, an xstream."
  (xstream/close (xstream-os-stream input)))

(defun set-to-full-speed (xstream)
  "Cf. `xstream-encoding'."
  (setf (xstream-speed xstream) (xstream-full-speed xstream)))

;;; controller implementations

(defmethod read-octets (sequence (stream stream) start end)
  (declare (type (simple-array octet (*)) sequence))
  (#+CLISP ext:read-byte-sequence
   #-CLISP read-sequence
           sequence stream :start start :end end))

(defmethod read-octets (sequence (stream null) start end)
  (declare (ignore sequence start end))
  0)

(defmethod xstream/close ((stream stream))
  (close stream))

(defmethod xstream/close ((stream null))
  nil)
