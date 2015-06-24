(defpackage :fxml-system
  (:use :asdf :cl))
(in-package :fxml-system)

(progn
  ;; (format t "~&;;; Checking for wide character support...")
  (flet ((test (code)
           (and (< code char-code-limit) (code-char code))))
    (cond
      ((not (test 50000))
       ;; (format t " no, reverting to octet strings.~%")
       #+rune-is-character
       (error "conflicting unicode configuration.  Please recompile.")
       (pushnew :rune-is-integer *features*))
      ((test 70000)
       ;; (when (test #xD800)
       ;;   (format t " WARNING: Lisp implementation doesn't use UTF-16, ~
       ;;               but accepts surrogate code points.~%"))
       ;; (format t " yes, using code points.~%")
       #+(or rune-is-integer rune-is-utf-16)
       (error "conflicting unicode configuration.  Please recompile.")
       (pushnew :rune-is-character *features*))
      (t
       ;; (format t " yes, using UTF-16.~%")
       #+(or rune-is-integer (and rune-is-character (not rune-is-utf-16)))
       (error "conflicting unicode configuration.  Please recompile.")
       (pushnew :rune-is-utf-16 *features*)
       (pushnew :rune-is-character *features*)))))

#+scl
(pushnew 'uri-is-namestring *features*)

(defsystem :fxml/closure-common
  :serial t
  :pathname "closure-common/"
  :components
  ((:file "package")
   (:file "definline")
   (:file runes
    :pathname
    #-rune-is-character "runes"
    #+rune-is-character "characters")
   #+rune-is-integer (:file "utf8")
   (:file "syntax")
   #-x&y-streams-are-stream (:file "encodings")
   #-x&y-streams-are-stream (:file "encodings-data")
   #-x&y-streams-are-stream (:file "xstream")
   #-x&y-streams-are-stream (:file "ystream")
   #+x&y-streams-are-stream (:file #+scl "stream-scl"))
  :depends-on (#-scl :trivial-gray-streams
               #+rune-is-character :babel
               #:named-readtables))

(asdf:defsystem :fxml/xml
  :pathname "xml/"
  :components
  ((:file "package")
   (:file "util"            :depends-on ("package"))
   (:file "sax-handler")
   (:file "xml-name-rune-p" :depends-on ("package" "util"))
   (:file "split-sequence"  :depends-on ("package"))
   (:file "xml-parse"       :depends-on ("package" "util" "sax-handler" "split-sequence" "xml-name-rune-p"))
   (:file "unparse"         :depends-on ("xml-parse"))
   (:file "xmls-compat"     :depends-on ("xml-parse"))
   (:file "recoder"         :depends-on ("xml-parse"))
   (:file "xmlns-normalizer" :depends-on ("xml-parse"))
   (:file "space-normalizer" :depends-on ("xml-parse"))
   (:file "catalog"         :depends-on ("xml-parse"))
   (:file "sax-proxy"       :depends-on ("xml-parse"))
   (:file "atdoc-configuration" :depends-on ("package")))
  :depends-on (:fxml/closure-common
               :puri #-scl
               :trivial-gray-streams
               :flexi-streams
               #:alexandria))

(asdf:defsystem :fxml/dom
    :pathname "dom/"
    :components
    ((:file "package")
     (:file "dom-impl" :depends-on ("package"))
     (:file "dom-builder" :depends-on ("dom-impl"))
     (:file "dom-sax"         :depends-on ("package")))
    :depends-on (:fxml/xml))

(asdf:defsystem :fxml/klacks
    :pathname "klacks/"
    :serial t
    :components
    ((:file "package")
     (:file "klacks")
     (:file "klacks-impl")
     (:file "tap-source"))
    :depends-on (:fxml/xml))

(asdf:defsystem :fxml/test
  :pathname "test/"
  :serial t
  :perform (test-op (o c) (uiop:symbol-call :fxml.test :run-tests))
  :components ((:file "test")
               (:file "suite"))
  :depends-on (:fxml/xml :fxml/klacks :fxml/dom :fiveam))

(asdf:defsystem :fxml
  :components ()
  :in-order-to ((test-op (test-op #:fxml/test)))
  :depends-on (:fxml/dom :fxml/klacks))

(defsystem :fxml/stp
  :serial t
  :in-order-to ((test-op (test-op #:fxml/stp/test)))
  :pathname "stp/"
  :components
  ((:file "package")
   (:file "classes")
   (:file "node")
   (:file "parent-node")
   (:file "leaf-node")
   (:file "document")
   (:file "element")
   (:file "attribute")
   (:file "document-type")
   (:file "comment")
   (:file "processing-instruction")
   (:file "text")
   (:file "builder")
   (:file "xpath"))
  :depends-on (:fxml :alexandria :xpath))

(defsystem :fxml/stp/test
  :serial t
  :perform (test-op (o c) (uiop:symbol-call :fxml.stp.test :run-tests))
  :pathname "stp/"
  :components
  ((:file "test"))
  :depends-on (:fxml/stp :rt))

(asdf:defsystem #:fxml/html5
  :serial t
  :description "Bridge HTML5 and FXML"
  :author "Paul M. Rodriguez <pmr@ruricolist.com>"
  :license "MIT"
  :pathname "html5/"
  :depends-on (#:alexandria
               #:serapeum
               #:fset
               #:fxml
               #:fxml/stp
               #:cl-html5-parser
               #:puri)
  :components ((:file "package")
               (:file "html5-sax")
               (:file "sink")
               (:file "transform")
               (:file "parse")))

(asdf:defsystem #:fxml/css-selectors
  :description "Bridge css-selectors and FXML."
  :pathname "css/"
  :depends-on (#:fxml #:fxml/stp #:css-selectors)
  :components ((:file "dom")
               (:file "stp")))

(asdf:defsystem #:fxml/cxml
  :description "Bridge FXML and CXML."
  :pathname "cxml/"
  :depends-on (#:fxml #:cxml)
  :components ((:file "package")
               (:file "protocol" :depends-on ("package"))
               (:file "attributes" :depends-on ("package"))))

(defsystem #:fxml/sanitize
  :serial t
  :description "Streaming HTML sanitizer"
  :author "Paul M. Rodriguez"
  :license "LLGPL"
  :depends-on (#:alexandria #:serapeum #:fxml #:quri)
  :pathname "sanitize/"
  :in-order-to ((test-op (test-op #:fxml/sanitize/test)))
  :components ((:file "package")
               (:file "sax-sanitize")))

(defsystem #:fxml/sanitize/test
  :depends-on (#:fxml/sanitize #:fiveam #:fxml/html5)
  :pathname "sanitize/"
  :perform (test-op (o c) (uiop:symbol-call :fxml.sanitize.test :run-tests))
  :components ((:file "test")))
