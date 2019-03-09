;;;; package.lisp

(defpackage #:fxml.html5
  (:use #:cl #:alexandria #:serapeum)
  (:nicknames #:fxml.html)
  (:export #:serialize-dom #:make-html5-sink #:close-sink
           #:xhtml #:dom #:stp #:xmls
           #:parse))
