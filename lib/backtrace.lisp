;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 1994-2001 Digitool, Inc
;;;   This file is part of OpenMCL.  
;;;
;;;   OpenMCL is licensed under the terms of the Lisp Lesser GNU Public
;;;   License , known as the LLGPL and distributed with OpenMCL as the
;;;   file "LICENSE".  The LLGPL consists of a preamble and the LGPL,
;;;   which is distributed with OpenMCL as the file "LGPL".  Where these
;;;   conflict, the preamble takes precedence.  
;;;
;;;   OpenMCL is referenced in the preamble as the "LIBRARY."
;;;
;;;   The LLGPL is also available online at
;;;   http://opensource.franz.com/preamble.html

;;; backtrace.lisp
;;; low-level support for stack-backtrace printing

(in-package "CCL")

#+ppc-target (require "PPC-BACKTRACE")
#+x86-target (require "X86-BACKTRACE")


(defparameter *backtrace-show-internal-frames* nil)
(defparameter *backtrace-print-level* 2)
(defparameter *backtrace-print-length* 5)

;;; This PRINTS the call history on *DEBUG-IO*.  It's more dangerous
;;; (because of stack consing) to actually return it.
                               
(defun print-call-history (&key context
                                (origin (%get-frame-ptr))
                                (detailed-p t)
                                (count most-positive-fixnum)
                                (start-frame-number 0))
  (let* ((tcr (if context (bt.tcr context) (%current-tcr))))          
    (if (eq tcr (%current-tcr))
      (%print-call-history-internal context origin detailed-p (or count most-positive-fixnum) start-frame-number)
      (unwind-protect
           (progn
             (%suspend-tcr tcr )
             (%print-call-history-internal context origin  detailed-p
                                           count start-frame-number))
        (%resume-tcr tcr)))
    (values)))

(defun %show-stack-frame (p context lfun pc)
  (handler-case
      (multiple-value-bind (count vsp parent-vsp) (count-values-in-frame p context)
	(declare (fixnum count))
	(dotimes (i count)
	  (multiple-value-bind (var type name) 
			       (nth-value-in-frame p i context lfun pc vsp parent-vsp)
	    (format t "~&  ~D " i)
	    (when name (format t "~s" name))
	    (let* ((*print-length* *backtrace-print-length*)
		   (*print-level* *backtrace-print-level*))
	      (format t ": ~s" var))
	    (when type (format t " (~S)" type)))))
    (error () (format t "#<error printing frame>")))
  (terpri)
  (terpri))

(defun %show-args-and-locals (p context lfun pc)
  (handler-case
      (let* ((unavailable (cons nil nil)))
	(multiple-value-bind (args locals) (arguments-and-locals context p lfun pc unavailable)
	  (format t "~&  ~s" (arglist-from-map lfun))
	  (let* ((*print-length* *backtrace-print-length*)
		 (*print-level* *backtrace-print-level*))
	    (flet ((show-pair (pair prefix)
		     (destructuring-bind (name . val) pair
		       (format t "~&~a~s: " prefix name)
		       (if (eq val unavailable)
			 (format t "#<Unavailable>")
			 (format t "~s" val)))))
	      (dolist (arg args)
		(show-pair arg "   "))
	      (terpri)
	      (terpri)
	      (dolist (loc locals)
		(show-pair loc "  "))))))
    (error () (format t "#<error printing args and locals>")))
  (terpri)
  (terpri))


(defun backtrace-call-arguments (context cfp lfun pc)
  (collect ((call))
    (let* ((name (function-name lfun)))
      (if (function-is-current-definition? lfun)
        (call name)
        (progn
          (call 'funcall)
          (call `(function ,(concatenate 'string "#<" (%lfun-name-string lfun) ">")))))
      (if (and pc (<= pc target::arg-check-trap-pc-limit))
        (append (call) (arg-check-call-arguments cfp lfun))
        (multiple-value-bind (req opt restp keys)
            (function-args lfun)
          (when (or (not (eql 0 req)) (not (eql 0 opt)) restp keys)
            (let* ((arglist (arglist-from-map lfun)))
              (if (or (null arglist) (null pc))
                (call "???")
                (progn
                  (dotimes (i req)
                    (let* ((val (argument-value context cfp lfun pc (pop arglist))))
                      (if (eq val (%unbound-marker))
                        (call "?")
                        (call (let* ((*print-length* *backtrace-print-length*)
                                     (*print-level* *backtrace-print-level*))
                                (format nil "~s" val))))))
                  (if (or restp keys (not (eql opt 0)))
                    (call "[...]"))))))
          (call))))))


;;; Return a list of "interesting" frame addresses in context, most
;;; recent first.
(defun %stack-frames-in-context (context &optional (include-internal *backtrace-show-internal-frames*))
  (collect ((frames))
    (do* ((p (bt.youngest context) (parent-frame p context))
          (q (bt.oldest context)))
         ((eql p q) (frames))
      (when (or (not (catch-csp-p p context)) include-internal)
        (when (or (cfp-lfun p) include-internal)
          (frames p))))))
    
(defun %print-call-history-internal (context origin detailed-p
                                             &optional (count most-positive-fixnum) (skip-initial 0))
  (let ((*standard-output* *debug-io*)
        (*print-circle* nil)
        (*print-catch-errors* t)
        (p origin)
        (q (last-frame-ptr context)))
    (dotimes (i skip-initial)
      (setq p (parent-frame p context))
      (when (or (null p) (eq p q) (%stack< q p context))
        (return (setq p nil))))
    (do* ((frame-number (or skip-initial 0) (1+ frame-number))
          (i 0 (1+ i))
          (p p (parent-frame p context)))
         ((or (null p) (eq p q) (%stack< q p context)
              (>= i count))
          (values))
      (declare (fixnum frame-number i))
      (when (or (not (catch-csp-p p context))
                *backtrace-show-internal-frames*)
        (multiple-value-bind (lfun pc) (cfp-lfun p)
          (when (or lfun *backtrace-show-internal-frames*)
            (unless (and (typep detailed-p 'fixnum)
                         (not (= (the fixnum detailed-p) frame-number)))
              (format t "~&~c(~x) : ~D ~a ~d"
                      (if (exception-frame-p p)  #\* #\space)
                      (index->address p) frame-number
                      (if lfun (backtrace-call-arguments context p lfun pc))
                      pc)
              (when detailed-p
                (if (eq detailed-p :raw)
                  (%show-stack-frame p context lfun pc)
                  (%show-args-and-locals p context lfun pc))))))))))


(defun %access-lisp-data (vstack-index)
  (%fixnum-ref vstack-index))

(defun %store-lisp-data (vstack-index value)
  (setf (%fixnum-ref vstack-index) value))

(defun closed-over-value (data)
  (if (closed-over-value-p data)
    (uvref data 0)
    data))

(defun set-closed-over-value (value-cell value)
  (setf (uvref value-cell 0) value))



;;; Act as if VSTACK-INDEX points at some lisp data & return that data.
(defun access-lisp-data (vstack-index)
  (closed-over-value (%access-lisp-data vstack-index)))

(defun find-local-name (cellno lfun pc)
  (let* ((n cellno))
    (when lfun
      (multiple-value-bind (mask where) (registers-used-by lfun pc)
        (if (and where (< (1- where) n (+ where (logcount mask))))
          (let ((j *saved-register-count*))
            (decf n where)
            (loop (loop (if (logbitp (decf j) mask) (return)))
                  (if (< (decf n) 0) (return)))
            (values (format nil "saved ~a" (aref *saved-register-names* j))
                    nil))
          (multiple-value-bind (nreq nopt restp nkeys junk optinitp junk ncells nclosed)
                               (if lfun (function-args lfun))
            (declare (ignore junk optinitp))
            (if nkeys (setq nkeys (+ nkeys nkeys)))
            (values
             (if (and ncells (< n ncells))
               (if (< n nclosed)
                 :inherited
                 (if (< (setq n (- n nclosed)) nreq)
                   "required"
                   (if (< (setq n (- n nreq)) nopt)
                     "optional"
                     (progn
                       (setq n (- n nopt))
                       (progn
                         (if (and nkeys (< n nkeys))
                           (if (not (logbitp 0 n)) ; a keyword
                             "keyword"
                             "key-supplied-p")
                           (progn
                             (if nkeys (setq n (- n nkeys)))
                             (if (and restp (zerop n))
                               "rest"
                               "opt-supplied-p")))))))))
             (match-local-name cellno (function-symbol-map lfun) pc))))))))

(defun map-entry-value (context cfp lfun pc idx unavailable)
  (declare (fixnum pc idx))
  (let* ((info (function-symbol-map lfun)))
    (if (null info)
      unavailable
      (let* ((addrs (cdr info))
             (i (* 3 idx))
             (addr (svref addrs i))
             (startpc (svref addrs (the fixnum (+ i 1))))
             (endpc (svref addrs (the fixnum (+ i 2)))))
        (declare (fixnum i addr startpc endpc))
        (if (or (< pc startpc)
                (>= pc endpc))
          unavailable
          (let* ((value (if (= #o77 (ldb (byte 6 0) addr))
                          (raw-frame-ref cfp context (ash addr (- (+ target::word-shift 6)))
                                         unavailable)
                          (find-register-argument-value context cfp addr unavailable))))
            (if (typep value 'value-cell)
              (uvref value 0)
              value)))))))

;;; Returns non-nil on success (not newval)
(defun set-map-entry-value (context cfp lfun pc idx newval)
  (declare (fixnum pc idx))
  (let* ((unavailable (cons nil nil))
         (value (map-entry-value context cfp lfun pc idx unavailable)))
    (if (eq value unavailable)
      nil
      (if (typep value 'value-cell)
        (progn (setf (uvref value 0) newval) t)

        (let* ((addrs (cdr (function-symbol-map lfun)))
               (addr (svref addrs (the fixnum (* 3 idx)))))
          (declare (fixnum  addr))
          (if (= #o77 (ldb (byte 6 0) addr))
            (raw-frame-set cfp context (ash addr (- (+ target::word-shift 6))) newval)
            (set-register-argument-value context cfp addr newval))
          t)))))

          
(defun argument-value (context cfp lfun pc name &optional (quote t))
  (declare (fixnum pc))
  (let* ((info (function-symbol-map lfun))
         (unavailable (%unbound-marker)))
    (if (null info)
      unavailable
      (let* ((names (car info))
             (addrs (cdr info)))
        (do* ((nname (1- (length names)) (1- nname))
              (naddr (- (length addrs) 3) (- naddr 3)))
             ((or (< nname 0) (< naddr 0)) unavailable)
          (declare (fixnum nname naddr))
          (when (eq (svref names nname) name)
            (let* ((value
                    (let* ((addr (svref addrs naddr))
                           (startpc (svref addrs (the fixnum (1+ naddr))))
                           (endpc (svref addrs (the fixnum (+ naddr 2)))))
                      (declare (fixnum addr startpc endpc))
                      (if (or (< pc startpc)
                              (>= pc endpc))
                        unavailable
                        (if (= #o77 (ldb (byte 6 0) addr))
                          (raw-frame-ref cfp context (ash addr (- (+ target::word-shift 6)))
                                         unavailable)
                          (find-register-argument-value context cfp addr unavailable))))))
              (if (typep value 'value-cell)
                (setq value (uvref value 0)))
              (if (or (not quote) (self-evaluating-p value))
                (return value)
                (return (list 'quote value))))))))))



(defun raw-frame-ref (cfp context index bad)
  (%raw-frame-ref cfp context index bad))

(defun raw-frame-set (cfp context index new)
  (%raw-frame-set cfp context index new))
  
(defun find-register-argument-value (context cfp regval bad)
  (%find-register-argument-value context cfp regval bad))

(defun set-register-argument-value (context cfp regval newval)
  (%set-register-argument-value context cfp regval newval))

    

(defun dbg-form (frame-number)
  (when *break-frame*
    (let* ((cfp (nth-raw-frame frame-number *break-frame* nil)))
      (if (and cfp (not (catch-csp-p cfp nil)))
        (multiple-value-bind (function pc)
            (cfp-lfun cfp)
          (if (and function
                   (function-is-current-definition? function))
            (block %cfp-form
              (collect ((form))
                (multiple-value-bind (nreq nopt restp keys allow-other-keys
                                           optinit lexprp ncells nclosed)
                    (function-args function)
                  (declare (ignore ncells))
                  (unless (or lexprp restp (> 0 nclosed) (> 0 nopt) keys allow-other-keys
                              optinit)
                    (let* ((name (function-name function)))
                      (multiple-value-bind (arglist win)
                          (arglist-from-map function)
                      (when (and win name (symbolp name))
                        (form name)
                        (dotimes (i nreq)
                          (let* ((val (argument-value nil cfp function pc (pop arglist))))
                            (if (closed-over-value-p val)
                              (setq val (%svref val target::value-cell.value-cell)))
                            (if (eq val (%unbound-marker))
                              (return-from %cfp-form nil))
                            (form val))))))))
                (form)))))))))

(defun function-args (lfun)
  "Returns 9 values, as follows:
     req = number of required arguments
     opt = number of optional arguments
     restp = t if rest arg
     keys = number of keyword arguments or NIL if &key not mentioned
     allow-other-keys = t if &allow-other-keys present
     optinit = t if any optional arg has non-nil default value or supplied-p
               variable
     lexprp = t if function is a lexpr, in which case all other values are
              undefined.
     ncells = number of stack frame cells used by all arguments.
     nclosed = number of inherited values (now counted distinctly from required)
     All numeric values (but ncells) are mod 64."
  (let* ((bits (lfun-bits lfun))
         (req (ldb $lfbits-numreq bits))
         (opt (ldb $lfbits-numopt bits))
         (restp (logbitp $lfbits-rest-bit bits))
         (keyvect (lfun-keyvect lfun))
         (keys (and keyvect (length keyvect)))
         (allow-other-keys (logbitp $lfbits-aok-bit bits))
         (optinit (logbitp $lfbits-optinit-bit bits))
         (lexprp (logbitp $lfbits-restv-bit bits))
         (nclosed (ldb $lfbits-numinh bits)))
    (values req opt restp keys allow-other-keys optinit lexprp
            (unless (or lexprp)
              (+ req opt (if restp 1 0) (if keys (+ keys keys) 0)
                 (if optinit opt 0) nclosed))
            nclosed)))

;;; If we can tell reliably, return the function's minimum number of
;;; non-inherited arguments, the maximum number of such arguments (or NIL),
;;; and the actual number of such arguments.  We "can't tell" if either
;;; of the arguments to this function are null, and we can't tell reliably
;;; if any of the lfbits fields are full.
(defun min-max-actual-args (fn nargs)
  (let* ((lfbits (if (and fn nargs)
		   (lfun-bits fn)
		   -1))
	 (raw-req (ldb $lfbits-numreq lfbits))
	 (raw-opt (ldb $lfbits-numopt lfbits))
	 (raw-inh (ldb $lfbits-numinh lfbits)))
    (declare (fixnum raw-req raw-opt raw-inh))
    (if (or (eql raw-req (1- (ash 1 (byte-size $lfbits-numreq))))
	    (eql raw-opt (1- (ash 1 (byte-size $lfbits-numopt))))
	    (eql raw-inh (1- (ash 1 (byte-size $lfbits-numinh)))))
      (values nil nil nil)
      (values raw-req
	      (unless (or (lfun-keyvect fn)
			  (logbitp $lfbits-rest-bit lfbits)
			  (logbitp $lfbits-restv-bit lfbits))
		(+ raw-req raw-opt))
	      (- nargs raw-inh)))))



(defun closed-over-value-p (value)
  (eql target::subtag-value-cell (typecode value)))


(defun variables-in-scope (lfun pc)
  ;; Return a list of all symbol names "in scope" in the function lfun
  ;; at relative program counter PC, using the function's symbol map.
  ;; The list will be ordered so that least-recent bindings appear first.
  ;; Return a list of the matching symbol map entries as a second value
  (when pc
    (locally (declare (fixnum pc))
      (let* ((map (function-symbol-map lfun))
             (names (car map))
             (info (cdr map)))
        (when map
          (let* ((vars ())
                 (indices ()))
            (dotimes (i (length names) (values vars indices))
              (let* ((start-pc (aref info (1+ (* 3 i))))
                     (end-pc (aref info (+ 2 (* 3 i)))))
                (declare (fixnum start-pc end-pc))
                (when (and (>= pc start-pc)
                           (< pc end-pc))
                  (push i indices)
                  (push (svref names i) vars))))))))))


(defun arg-value (context cfp lfun pc unavailable name)
  (multiple-value-bind (vars map-indices) (variables-in-scope lfun pc)
    (multiple-value-bind (valid req opt rest keys)
        (arg-names-from-map lfun pc)
      (if valid
        (let* ((nargs (+ (length req) (length opt) (if rest 1 0) (length keys)))
               (pos (position name vars)))
          (if (and pos (< pos nargs))
            (map-entry-value context cfp lfun pc (nth pos map-indices) unavailable)
            unavailable))
        unavailable))))

(defun local-value (context cfp lfun pc unavailable name)
  (multiple-value-bind (vars map-indices) (variables-in-scope lfun pc)
    (multiple-value-bind (valid req opt rest keys)
        (arg-names-from-map lfun pc)
      (if valid
        (let* ((nargs (+ (length req) (length opt) (if rest 1 0) (length keys)))
               (names (nthcdr nargs vars))
               (indices (nthcdr nargs map-indices))
               (pos (if (typep name 'unsigned-byte)
                      name
                      (position name names :from-end t))))
          (if pos
            (map-entry-value context cfp lfun pc (nth pos indices) unavailable)
            unavailable))
        unavailable))))

(defun set-arg-value (context cfp lfun pc name new)
  (multiple-value-bind (vars map-indices) (variables-in-scope lfun pc)
    (multiple-value-bind (valid req opt rest keys)
        (arg-names-from-map lfun pc)
      (if valid
        (let* ((nargs (+ (length req) (length opt) (if rest 1 0) (length keys)))
               (pos (position name vars)))
          (when (and pos (< pos nargs))
            (set-map-entry-value context cfp lfun pc (nth pos map-indices) new)))))))

(defun set-local-value (context cfp lfun pc name new)
  (multiple-value-bind (vars map-indices) (variables-in-scope lfun pc)
    (multiple-value-bind (valid req opt rest keys)
        (arg-names-from-map lfun pc)
      (if valid
        (let* ((nargs (+ (length req) (length opt) (if rest 1 0) (length keys)))
               (names (nthcdr nargs vars))
               (indices (nthcdr nargs map-indices))
               (pos (if (typep name 'unsigned-byte)
                      name
                      (position name names :from-end t))))
          (if (and pos (< pos nargs))
            (set-map-entry-value context cfp lfun pc (nth pos indices) new)))))))


(defun arguments-and-locals (context cfp lfun pc &optional unavailable)
  (multiple-value-bind (vars map-indices) (variables-in-scope lfun pc)
    (collect ((args)
              (locals))
      (multiple-value-bind (valid req opt rest keys)
          (arg-names-from-map lfun pc)
        (when valid
          (let* ((nargs (+ (length req) (length opt) (if rest 1 0) (length keys)))
                 (nlocals (- (length vars) nargs))
                 (local-vars (nthcdr nargs vars))
                 (local-indices (nthcdr nargs map-indices))
                 (arg-vars (nbutlast vars nlocals))
                 (arg-indices (nbutlast map-indices nlocals)))
            (flet ((get-arg-value (name)
                     (let* ((pos (position name arg-vars :test #'eq)))
                       (when pos
                         (args (cons name (map-entry-value context cfp lfun pc (nth pos arg-indices) unavailable))))))
                   (get-local-value (name)
                     (when name
                       (locals (cons name (map-entry-value context cfp lfun pc (pop local-indices) unavailable))))))
              (dolist (name req)
                (get-arg-value name))
              (dolist (name opt)
                (get-arg-value name))
              (when rest
                (get-arg-value rest))
              (dolist (name keys)
                (get-arg-value name))
              #+no
              (setq local-vars (nreverse local-vars)
                    local-indices (nreverse local-indices))
              (dolist (name local-vars)
                (get-local-value name)))))
        (values (args) (locals))))))
                   
            

(defun safe-cell-value (val)
  val)

(defun closure-closed-over-values (closure)
  (when (typep closure 'compiled-lexical-closure)
    (let* ((inner (closure-function closure))
           (nclosed (nth-value 8 (function-args inner)))
           (names (car (function-symbol-map inner))))
      (when nclosed
        (collect ((cells))
          (do* ((i (1- (length names)) (1- i))
                (k 0 (1+ k))
                (idx 2 (1+ idx)))
               ((= k nclosed) (reverse (cells)))
            (let* ((name (svref names i))
                   (imm (nth-immediate closure idx)))
              (cells (list name (if (closed-over-value-p imm)
                                  (closed-over-value imm)
                                  imm))))))))))

      
;;; Find the oldest binding frame that binds the same symbol as
;;; FRAME in context.  If found, return the saved value of that
;;; binding, else the value of the symbol in the context's thread.
(defun oldest-binding-frame-value (context frame)
  (let* ((oldest nil)
         (binding-index (%fixnum-ref frame (ash 1 target::fixnum-shift))))
    (do* ((db (db-link context) (%fixnum-ref db 0)))
         ((eq frame db)
          (if oldest
            (%fixnum-ref oldest (ash 2 target::fixnum-shift))
            (let* ((symbol (binding-index-symbol binding-index)))
              (if context
                (symbol-value-in-tcr symbol (bt.tcr context))
                (%sym-value symbol)))))
      (if (eq (%fixnum-ref db (ash 1 target::fixnum-shift)) binding-index)
        (setq oldest db)))))

(defun (setf oldest-binding-frame-value) (new context frame)
  (let* ((oldest nil)
         (binding-index (%fixnum-ref frame (ash 1 target::fixnum-shift))))
    (do* ((db (db-link context) (%fixnum-ref db 0)))
         ((eq frame db)
          (if oldest
            (setf (%fixnum-ref oldest (ash 2 target::fixnum-shift)) new)
            (let* ((symbol (binding-index-symbol binding-index)))
              (if context
                (setf (symbol-value-in-tcr symbol (bt.tcr context)) new)
                (%set-sym-value symbol new)))))
      (if (eq (%fixnum-ref db (ash 1 target::fixnum-shift)) binding-index)
        (setq oldest db)))))
    


;;; End of backtrace.lisp
