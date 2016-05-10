(defpackage #:fxml.xmlconf
  (:use :cl)
  (:export #:run-all-tests
           #:sax-test
           #:klacks-test
           #:with-cxml
           #:with-fxml))
(in-package :fxml.xmlconf)

(defvar *debug-tests* nil)

(defvar *impl*)
(declaim (type (member :fxml :cxml) *impl*))

(defvar *xml*)
(defvar *runes*)
(defvar *dom*)
(defvar *rune-dom*)
(defvar *klacks*)
(declaim (type keyword *xml* *runes* *dom* *rune-dom* *klacks*))

(defun call/cxml (fn)
  (let ((*impl*     :cxml)
        (*xml*      :cxml)
        (*runes*    :runes)
        (*dom*      :dom)
        (*rune-dom* :rune-dom)
        (*klacks*   :klacks))
    (funcall fn)))

(defun call/fxml (fn)
  (let ((*impl*     :fxml)
        (*xml*      :fxml)
        (*runes*    :fxml.runes)
        (*dom*      :fxml.dom)
        (*rune-dom* :fxml.rune-dom)
        (*klacks*   :fxml.klacks))
    (funcall fn)))

(defmacro with-cxml ((&key) &body body)
  `(call/cxml (lambda () ,@body)))

(defmacro with-fxml ((&key) &body body)
  `(call/fxml (lambda () ,@body)))

(defun get-attribute (element name)
  (case *impl*
    (:cxml
     (runes:rod-string
      (dom:get-attribute element name)))
    (:fxml
     (fxml.runes:rod-string
      (fxml.dom:get-attribute element name)))))

(defparameter *bad-tests*
    '(;; TS14
      ;; http://lists.w3.org/Archives/Public/public-xml-testsuite/2002Mar/0001.html
      "ibm-valid-P28-ibm28v02.xml"
      "ibm-valid-P29-ibm29v01.xml"
      "ibm-valid-P29-ibm29v02.xml"))

(defun test-class (test)
  (cond
    ((not (and (let ((version (get-attribute test "RECOMMENDATION")))
                 (cond
                   ((or (equal version "") ;XXX
                        (equal version "XML1.0")
                        (equal version "NS1.0"))
                     (cond
                       ((equal (get-attribute test "NAMESPACE") "no")
                         (format t "~A: test applies to parsers without namespace support, skipping~%"
                                 (get-attribute test "URI"))
                         nil)
                       (t
                         t)))
                   ((equal version "XML1.1")
                     ;; not supported
                     nil)
                   (t
                     (warn "unrecognized RECOMMENDATION value: ~S" version)
                     nil)))
               (not (member (get-attribute test "ID") *bad-tests* :test 'equal))))
      nil)
    ((equal (get-attribute test "TYPE") "valid") :valid)
    ((equal (get-attribute test "TYPE") "invalid") :invalid)
    ((equal (get-attribute test "TYPE") "not-wf") :not-wf)
    (t nil)))

(defun test-pathnames (directory test)
  (let* ((sub-directory
          (loop
              for parent = test then (uiop:symbol-call *dom* :parent-node parent)
              for base = (get-attribute parent "xml:base")
              until (plusp (length base))
              finally (return (merge-pathnames base directory))))
         (uri (get-attribute test "URI"))
         (output (get-attribute test "OUTPUT")))
    (values (merge-pathnames uri sub-directory)
            (when (plusp (length output))
              (merge-pathnames output sub-directory)))))

(defmethod serialize-document ((document t))
  (uiop:symbol-call *dom* :map-document
                    (uiop:symbol-call *xml* :make-octet-vector-sink :canonical 2)
		    document
		    :include-doctype :canonical-notations
		    :include-default-values t))

(defun file-contents (pathname)
  (with-open-file (s pathname :element-type '(unsigned-byte 8))
    (let ((result
           (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence result s )
      result)))

(defvar *parser-fn* 'sax-test)

(defun sax-test (filename handler &rest args)
  (apply #'uiop:symbol-call
         *xml* :parse
         filename handler
         :allow-other-keys t
         :recode nil
         :forbid-entities nil
         :forbid-dtd nil
         :forbid-external nil
         args))

(defun klacks-test (filename handler &rest args)
  (case *impl*
    (:fxml
     (fxml.klacks:with-open-source
         (s (apply #'fxml:make-source (pathname filename)
                   :forbid-entities nil
                   :forbid-external nil
                   args))
       (fxml.klacks:serialize-source s handler)))
    (:cxml
     (klacks:with-open-source
         (s (apply #'cxml:make-source (pathname filename) args))
       (klacks:serialize-source s handler)))))

(defun run-all-tests (parser-fn
                      &optional
                        (directory
                         (asdf:system-relative-pathname
                          :fxml "test/xmlconf/")))
  (let* ((*parser-fn* parser-fn)
	 (pathname (merge-pathnames "xmlconf.xml" directory))
         (builder (uiop:symbol-call *rune-dom* :make-dom-builder))
         (xmlconf (uiop:symbol-call *xml* :parse
                                    pathname builder
                                    :allow-other-keys t
                                    :recode nil
                                    :forbid-entities nil
                                    :forbid-external nil))
         (ntried 0)
         (nfailed 0)
         (nskipped 0)
         (lines '()))
    (uiop:symbol-call *dom*
                      :map-node-list
                      (lambda (test)
                        (let ((description
                                (apply #'concatenate
                                       'string
                                       (map 'list
                                            (lambda (child)
                                              (if (uiop:symbol-call *dom* :text-node-p child)
                                                  (uiop:symbol-call *runes* :rod-string
                                                                    (uiop:symbol-call *dom* :data child))
                                                  ""))
                                            (uiop:symbol-call *dom* :child-nodes test))))
                              (class (test-class test)))
                          (cond
                            (class
                             (push
                              (with-output-to-string (*standard-output*)
                                (incf ntried)
                                (multiple-value-bind (pathname output)
                                    (test-pathnames directory test)
                                  (princ (enough-namestring pathname directory))
                                  (unless (probe-file pathname)
                                    (error "file not found: ~A" pathname))
                                  (with-simple-restart (skip-test "Skip this test")
                                    (unless (run-test class pathname output description)
                                      (incf nfailed)))))
                              lines))
                            (t
                             (incf nskipped)))))
                      (uiop:symbol-call *dom* :get-elements-by-tag-name xmlconf "TEST"))
    (format t "~&~D/~D tests failed; ~D test~:P were skipped"
            nfailed ntried nskipped)
    (values lines nfailed ntried nskipped)))

(defmethod run-test :around (class pathname output description &rest args)
  (declare (ignore class pathname output args))
  (block nil
    (handler-bind (((or puri:uri-parse-error
                        quri:uri-malformed-string)
                     (lambda (c) (declare (ignore c))
                       (unless *debug-tests*
                         (ignore-errors
                          (format t " FAILED: bad uri: ~a" description))
                         (return nil))))
                   (serious-condition
                     (lambda (c)
                       (unless *debug-tests*
                         (ignore-errors
                          (format t " FAILED:~%  ~A~%[~A]~%" c description))
                         (return nil)))))
      (call-next-method))))

(defmethod run-test ((class null) pathname output description &rest args)
  (declare (ignore description))
  (let ((document (apply *parser-fn*
                         pathname
                         (uiop:symbol-call *rune-dom* :make-dom-builder)
                         args)))
    ;; If we got here, parsing worked.  Let's try to serialize the same
    ;; document.  (We do the same thing in canonical mode below to check the
    ;; content model of the output, but that doesn't even catch obvious
    ;; errors in DTD serialization, so even a simple here is an
    ;; improvement.)
    (apply *parser-fn* pathname (uiop:symbol-call *xml* :make-rod-sink) args)
    (cond
      ((null output)
        (format t " input"))
      ((equalp (file-contents output) (serialize-document document))
        (format t " input/output"))
      (t
        (let ((error-output (make-pathname :type "error" :defaults output)))
          (with-open-file (s error-output
                           :element-type '(unsigned-byte 8)
                           :direction :output
                           :if-exists :supersede)
            (write-sequence (serialize-document document) s))
          (error "well-formed, but output ~S not the expected ~S~%"
                 error-output output))))
    t))

(defmethod run-test
    ((class (eql :valid)) pathname output description &rest args)
  (assert (null args))
  (and (progn
         (format t " [not validating:]")
         (run-test nil pathname output description :validate nil))
       (progn
         (format t " [validating:]")
         (run-test nil pathname output description :validate t))))

(defmethod run-test
    ((class (eql :invalid)) pathname output description &rest args)
  (assert (null args))
  (and (progn
         (format t " [not validating:]")
         (run-test nil pathname output description :validate nil))
       (handler-case
           (progn
             (format t " [validating:]")
             (funcall *parser-fn*
		      pathname
                      (uiop:symbol-call *rune-dom* :make-dom-builder)
		      :validate t)
             (error "validity error not detected")
             nil)
         ((or fxml:validity-error cxml:validity-error) ()
           (format t " invalid")
           t))))

(defmethod run-test
    ((class (eql :not-wf)) pathname output description &rest args)
  (declare (ignore output description))
  (assert (null args))
  (handler-case
      (progn
         (format t " [not validating:]")
	(funcall *parser-fn*
		 pathname
                 (uiop:symbol-call *rune-dom* :make-dom-builder)
		 :validate nil)
	(error "well-formedness violation not detected")
      nil)
    ((or fxml:well-formedness-violation cxml:well-formedness-violation) ()
      (format t " not-wf")
      t))
  (handler-case
      (progn
	(format t " [validating:]")
	(funcall *parser-fn*
		 pathname
                 (uiop:symbol-call *rune-dom* :make-dom-builder)
		 :validate t)
	(error "well-formedness violation not detected")
      nil)
    ((or fxml:well-formedness-violation cxml:well-formedness-violation) ()
      (format t " not-wf")
      t)
    ((or fxml:validity-error cxml:validity-error) ()
      ;; das erlauben wir mal auch, denn valide => wf
      (format t " invalid")
      t)))
