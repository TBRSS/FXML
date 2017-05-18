;;; (c) 2005 David Lichteblau <david@lichteblau.com>
;;; License: Lisp-LGPL (See file COPYING for details).
;;;
;;; ystream (for lack of a better name): a rune output "stream"

(in-package :fxml.runes)
(in-readtable :runes)

(defconstant +ystream-bufsize+ 1024)

(defun make-ub8-array (n)
  (make-array n :element-type '(unsigned-byte 8)))

(defun make-ub16-array (n)
  (make-array n :element-type '(unsigned-byte 16)))

(defun make-buffer (&key (element-type '(unsigned-byte 8)))
  (make-array 1
              :element-type element-type
              :adjustable t
              :fill-pointer 0))

(defun find-output-encoding (name)
  (etypecase name
    (string
     (or (case (length name)
           (4 (and (string-equal name :utf8)
                   :utf-8))
           (5 (and (member name '(:utf-8 :utf_8) :test #'string-equal)
                   :utf-8)))
         (find-output-encoding
          (find-symbol (string-upcase name) :keyword))))
    (symbol
     (case name
       ((nil)
        (warn "Unknown encoding ~A, falling back to UTF-8" name)
        :utf-8)
       ((:utf-8 :utf_8 :utf8)
        :utf-8)
       (t (handler-case
              (babel-encodings:get-character-encoding name)
            (error ()
              (warn "Unknown encoding ~A, falling back to UTF-8" name)
              :utf-8)))))))

;;; ystream
;;;  +- encoding-ystream
;;;  |    +- octet-vector-ystream
;;;  |    \- %stream-ystream
;;;  |        +- octet-stream-ystream
;;;  |        \- character-stream-ystream/utf8
;;;  |            \- string-ystream/utf8
;;;  +- rod-ystream
;;;  \-- character-stream-ystream

(defstruct ystream
  (encoding)
  (column 0 :type (integer 0 *))
  (in-ptr 0 :type (integer 0 #.most-positive-fixnum))
  (in-buffer (make-rod +ystream-bufsize+) :type simple-rod))

(defun ystream-unicode-p (ystream)
  (let ((enc (ystream-encoding ystream)))
    (or (eq enc :utf-8)
	(eq (babel-encodings:enc-name enc) :utf-16))))

(defstruct (encoding-ystream
	    (:include ystream)
	    (:conc-name "YSTREAM-"))
  (out-buffer (make-ub8-array (* 6 +ystream-bufsize+))
	      :type (simple-array (unsigned-byte 8) (*))))

(defstruct (%stream-ystream
	     (:include encoding-ystream)
	     (:conc-name "YSTREAM-"))
  (os-stream (error "No stream")))

(defun map-splits (fn split-fn string &key start end)
  (let ((start (or start 0))
        (end (or end (length string))))
    (loop with len = (length string)
          for left = start then (1+ right)
          for right = (min (or (position-if split-fn string
                                            :start left)
                               len)
                           end)
          do (let ((char (if (= right end)
                             nil
                             (aref string right))))
               (funcall fn left right char))
          until (>= right end))))

(defmacro do-splits (((l r char)
                      (string &optional (start 0) end)
                      split-fn
                      &optional return)
                     &body body)
  `(block nil
     (map-splits (lambda (,l ,r ,char)
                   (tagbody ,@body))
                 ,split-fn
                 ,string
                 :start ,start :end ,end)
     (let (,l ,r ,char)
       (declare (ignorable ,l ,r ,char))
       (return ,return))))

(definline rune-newline-p (rune)
  (eql rune #/U+000A))

;; writes a rune to the buffer.  If the rune is not encodable, an error
;; might be signalled later during flush-ystream.
(definline ystream-write-rune (rune ystream)
  (with-accessors ((in     ystream-in-buffer)
                   (in-ptr ystream-in-ptr)
                   (column ystream-column))
      ystream
    (when (eql in-ptr (length in))
      (flush-ystream ystream))
    (setf (elt in in-ptr) rune)
    (incf in-ptr)
    (setf column
          (if (rune-newline-p rune)
              0
              (1+ column)))
    rune))

(defun ystream-room (ystream)
  (- (length (ystream-in-buffer ystream))
     (ystream-in-ptr ystream)))

(defmacro with-character-as-temp-string ((string char) &body body)
  "Bind STRING to a stack-allocated string whose sole character is
CHAR."
  (alexandria:once-only (char)
    `(let ((,string (make-string 1)))
       (declare (dynamic-extent ,string))
       (setf (schar ,string 0) ,char)
       ,@body)))

;; Writes a rod to the buffer.  If a rune in the rod not encodable, an error
;; might be signalled later during flush-ystream.
(defun ystream-write-rod (rod ystream &key (start 0) (end (length rod)))
  (with-accessors ((in     ystream-in-buffer)
                   (in-ptr ystream-in-ptr)
                   (column ystream-column))
      ystream
    (do-splits ((l r nl?) (rod start end) #'rune-newline-p)
      (when (= in-ptr (length in))
        (flush-ystream ystream))
      (let* ((room (- (length in) in-ptr))
             (size (- r l))
             (allowed-size (min room size)))
        (replace in rod :start1 in-ptr :start2 l :end2 (+ l allowed-size))
        (incf in-ptr allowed-size)
        (incf column allowed-size)
        (when (< allowed-size size)
          (ystream-write-rod rod ystream :start (+ l room) :end r)))
      (when nl?
        (ystream-write-rune #/U+000A ystream)
        (setf column 0)))))

(defun ystream-write-escapable-rune (rune ystream)
  (with-character-as-temp-string (tmp rune)
    (ystream-write-escapable-rod tmp ystream)))

;; Writes a rod to the buffer.  If a rune in the rod not encodable, it is
;; replaced by a character reference.
;;
(defun ystream-write-escapable-rod (rod ystream &key (start 0) (end (length rod)))
  (if (ystream-unicode-p ystream)
      (ystream-write-rod rod ystream :start start :end end)
      (let ((encoding (ystream-encoding ystream)))
        (flet ((encodablep (rune)
                 (encodablep rune encoding)))
          (do-splits ((l r rune) (rod start end) #'encodablep)
            (unless (= l r)
              (ystream-write-rod rod ystream :start l :end r))
            (when rune
              (ystream-escape-rune rune ystream)))))))

(defun ystream-escape-rune (rune ystream)
  (let ((cr (string-rod (format nil "&#~D;" (rune-code rune)))))
    (ystream-write-rod cr ystream)))

(defun encodablep (character encoding)
  (with-character-as-temp-string (s character)
    (handler-case
        (babel:string-size-in-octets s :encoding encoding)
      (babel-encodings:character-encoding-error ()
        nil))))

(defmethod close-ystream :before ((ystream ystream))
  (flush-ystream ystream))


;;;; ENCODING-YSTREAM (abstract)

(defmethod close-ystream ((ystream %stream-ystream))
  (ystream-os-stream ystream))

(defgeneric ystream-device-write (ystream buf nbytes))

(defun encode-runes (out in ptr encoding)
  (case encoding
    (:utf-8
     (runes-to-utf8 out in ptr))
    (t
     ;; by lucky coincidence, babel::unicode-string is the same as simple-rod
     #+nil (coerce string 'babel::unicode-string)
     ;; XXX
     (let* ((babel-encodings:*suppress-character-coding-errors* nil)
	    (mapping (babel-encodings:lookup-mapping
                      babel::*string-vector-mappings*
                      encoding)))
       (funcall (babel-encodings:encoder mapping) in 0 ptr out 0)
       (funcall (babel-encodings:octet-counter mapping) in 0 ptr -1)))))

(defmethod flush-ystream ((ystream encoding-ystream))
  (let ((ptr (ystream-in-ptr ystream)))
    (when (plusp ptr)
      (let* ((in (ystream-in-buffer ystream))
	     (out (ystream-out-buffer ystream))
             (n (encode-runes out in ptr (ystream-encoding ystream))))
        (ystream-device-write ystream out n)
        (setf (ystream-in-ptr ystream) 0)))))

(defun fast-push (new-element vector)
  (vector-push-extend new-element vector (max 1 (array-dimension vector 0))))

(macrolet ((define-utf8-writer (name (byte &rest aux) result &body body)
	     `(defun ,name (out in n)
		(let (,@aux)
		  (labels
		      ((write0 (,byte)
			 ,@body)
		       (write1 (r)
			 (cond
			   ((<= #x00000000 r #x0000007F) 
			     (write0 r))
			   ((<= #x00000080 r #x000007FF)
			     (write0 (logior #b11000000 (ldb (byte 5 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x00000800 r #x0000FFFF)
			     (write0 (logior #b11100000 (ldb (byte 4 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x00010000 r #x001FFFFF)
			     (write0 (logior #b11110000 (ldb (byte 3 18) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x00200000 r #x03FFFFFF)
			     (write0 (logior #b11111000 (ldb (byte 2 24) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 18) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x04000000 r #x7FFFFFFF)
			     (write0 (logior #b11111100 (ldb (byte 1 30) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 24) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 18) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))))
		       (write2 (r)
			 (if (<= #xD800 r #xDFFF)
                             (error
                              "Surrogates not allowed in this configuration")
                             (write1 r))))
		    (dotimes (j n)
		      (write2 (rune-code (elt in j)))))
		  ,result))))
  (define-utf8-writer runes-to-utf8 (x (i 0))
    i
    (setf (elt out i) x)
    (incf i))
  (define-utf8-writer runes-to-utf8/adjustable-string (x)
    nil
    (fast-push (code-char x) out)))


;;;; ROD-YSTREAM

(defstruct (rod-ystream (:include ystream)))

(defmethod flush-ystream ((ystream rod-ystream))
  (let* ((old (ystream-in-buffer ystream))
	 (new (make-rod (* 2 (length old)))))
    (replace new old)
    (setf (ystream-in-buffer ystream) new)))

(defmethod close-ystream ((ystream rod-ystream))
  (subseq (ystream-in-buffer ystream) 0 (ystream-in-ptr ystream)))


;;;; CHARACTER-STREAM-YSTREAM

(defstruct (character-stream-ystream
            (:constructor make-character-stream-ystream (target-stream))
            (:include ystream)
            (:conc-name "YSTREAM-"))
  (target-stream (error "No target stream")))

(defmethod flush-ystream ((ystream character-stream-ystream))
  (write-string (ystream-in-buffer ystream)
                (ystream-target-stream ystream)
                :end (ystream-in-ptr ystream))
  (setf (ystream-in-ptr ystream) 0))

(defmethod close-ystream ((ystream character-stream-ystream))
  (ystream-target-stream ystream))


;;;; OCTET-VECTOR-YSTREAM

(defstruct (octet-vector-ystream
	    (:include encoding-ystream)
	    (:conc-name "YSTREAM-"))
  (result (make-buffer)))

(defmethod ystream-device-write ((ystream octet-vector-ystream) buf nbytes)
  (let* ((result (ystream-result ystream))
	 (start (length result))
	 (size (array-dimension result 0)))
    (loop while (> (+ start nbytes) size) do
      (setf size (* 2 size)))
    (adjust-array result size :fill-pointer (+ start nbytes))
    (replace result buf :start1 start :end2 nbytes)))

(defmethod close-ystream ((ystream octet-vector-ystream))
  (ystream-result ystream))


;;;; OCTET-STREAM-YSTREAM

(defstruct (octet-stream-ystream
	    (:include %stream-ystream)
	    (:constructor make-octet-stream-ystream (os-stream))
	    (:conc-name "YSTREAM-")))

(defmethod ystream-device-write ((ystream octet-stream-ystream) buf nbytes)
  (write-sequence buf (ystream-os-stream ystream) :end nbytes))


;;;; CHARACTER-STREAM-YSTREAM/UTF8

;;;; STRING-YSTREAM/UTF8

;;;; helper functions

(defun rod-to-utf8-string (rod)
  (let ((out (make-buffer :element-type 'character)))
    (runes-to-utf8/adjustable-string out rod (length rod))
    out))

(defun utf8-string-to-rod (str)
  (let* ((bytes (map '(vector (unsigned-byte 8)) #'char-code str))
         (buffer (make-array (length bytes) :element-type 'buffer-byte))
         (n (fxml.runes-encoding:decode-sequence
	     :utf-8 bytes 0 (length bytes) buffer 0 0 nil))
         (result (make-array n :element-type 'rune)))
    (map-into result #'code-rune buffer)
    result))

(defclass octet-input-stream
    (trivial-gray-stream-mixin fundamental-binary-input-stream)
    ((octets :initarg :octets)
     (pos :initform 0)))

(defmethod close ((stream octet-input-stream) &key &allow-other-keys)
  (values (open-stream-p stream)))

(defmethod stream-read-byte ((stream octet-input-stream))
  (with-slots (octets pos) stream
    (if (>= pos (length octets))
        :eof
        (prog1
            (elt octets pos)
          (incf pos)))))

(defmethod stream-read-sequence
    ((stream octet-input-stream) sequence start end &key &allow-other-keys)
  (with-slots (octets pos) stream
    (let* ((length (min (- end start) (- (length octets) pos)))
           (end1 (+ start length))
           (end2 (+ pos length)))
      (replace sequence octets :start1 start :end1 end1 :start2 pos :end2 end2)
      (setf pos end2)
      end1)))

(defun make-octet-input-stream (octets)
  (make-instance 'octet-input-stream :octets octets))
