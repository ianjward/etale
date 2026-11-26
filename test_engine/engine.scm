;;; The test engine for Etale: phase 1 of PLAN.md.
;;;
;;; It runs the frozen core of PLAN.md section 4 (atoms, restriction, union,
;;; there exists, contained in) on rule files written in the core's part of
;;; Etale, over the facts of the file being checked. It is a test bench, not
;;; part of the chain: it is deleted once the engine in assembly gives the
;;; same verdict on every example (phase 5).
;;;
;;; It uses only the part of Scheme that PLAN.md 5.4 lists. small_scheme.sld
;;; holds it to that part: a name outside it stops the engine before it runs.
;;;
;;; The parts follow PLAN.md 5.2, numbers first since every part uses them:
;;;   part 7, numbers
;;;   part 3, the reader
;;;   part 4, the file as facts
;;;   parts 5 and 6, rule files, the rule loop, unions and there exists
;;;   part 8, verdicts, and the commands

;;; ------------------------------------------------------------------------
;;; Lists

(define (first-of items) (car items))
(define (second items) (car (cdr items)))
(define (third items) (car (cdr (cdr items))))
(define (fourth items) (car (cdr (cdr (cdr items)))))
(define (fifth items) (car (cdr (cdr (cdr (cdr items))))))
(define (sixth items) (car (cdr (cdr (cdr (cdr (cdr items)))))))
(define (seventh items) (car (cdr (cdr (cdr (cdr (cdr (cdr items))))))))

(define (item-at items place)
  (if (= place 0) (car items) (item-at (cdr items) (- place 1))))

(define (replace-at items place value)
  (if (= place 0)
      (cons value (cdr items))
      (cons (car items) (replace-at (cdr items) (- place 1) value))))

(define (keep test items)
  (cond ((null? items) '())
        ((test (car items)) (cons (car items) (keep test (cdr items))))
        (else (keep test (cdr items)))))

(define (all test items)
  (cond ((null? items) #t)
        ((test (car items)) (all test (cdr items)))
        (else #f)))

(define (any test items)
  (cond ((null? items) #f)
        ((test (car items)) #t)
        (else (any test (cdr items)))))

(define (any-of-two test left right)
  ;; whether test holds for some item of left with the item of right at its place
  (cond ((null? left) #f)
        ((test (car left) (car right)) #t)
        (else (any-of-two test (cdr left) (cdr right)))))

(define (all-of-two test left right)
  (cond ((null? left) #t)
        ((test (car left) (car right)) (all-of-two test (cdr left) (cdr right)))
        (else #f)))

(define (count-of test items)
  (let loop ((items items) (count 0))
    (cond ((null? items) count)
          ((test (car items)) (loop (cdr items) (+ count 1)))
          (else (loop (cdr items) count)))))

(define (take items count)
  (if (= count 0) '() (cons (car items) (take (cdr items) (- count 1)))))

(define (drop items count)
  (if (= count 0) items (drop (cdr items) (- count 1))))

(define (index-of item items)
  (let loop ((items items) (place 0))
    (cond ((null? items) #f)
          ((equal? (car items) item) place)
          (else (loop (cdr items) (+ place 1))))))

(define (join-lists lists)
  (if (null? lists) '() (append (car lists) (join-lists (cdr lists)))))

(define (without-repeats items)
  (let loop ((items items) (kept '()))
    (cond ((null? items) (reverse kept))
          ((member (car items) kept) (loop (cdr items) kept))
          (else (loop (cdr items) (cons (car items) kept))))))

(define (set-entry entries key value)
  ;; the entries with key's entry replaced, or added at the end
  (cond ((null? entries) (list (cons key value)))
        ((equal? (car (car entries)) key) (cons (cons key value) (cdr entries)))
        (else (cons (car entries) (set-entry (cdr entries) key value)))))

(define (entry-value entries key missing)
  (let ((entry (assoc key entries)))
    (if entry (cdr entry) missing)))

(define (sort-items items comes-before)
  ;; a merge sort that keeps the order of items that tie
  (let ((count (length items)))
    (if (< count 2)
        items
        (let ((half (quotient count 2)))
          (merge-sorted (sort-items (take items half) comes-before)
                        (sort-items (drop items half) comes-before)
                        comes-before)))))

(define (merge-sorted left right comes-before)
  (cond ((null? left) right)
        ((null? right) left)
        ((comes-before (car right) (car left))
         (cons (car right) (merge-sorted left (cdr right) comes-before)))
        (else (cons (car left) (merge-sorted (cdr left) right comes-before)))))

;;; ------------------------------------------------------------------------
;;; Characters

(define (code-of character) (char->integer character))

(define (digit-character? character)
  (let ((code (code-of character)))
    (and (>= code 48) (<= code 57))))

(define (letter-character? character)
  (let ((code (code-of character)))
    (or (and (>= code 65) (<= code 90))
        (and (>= code 97) (<= code 122)))))

(define (digit-value character) (- (code-of character) 48))

(define digit-characters (string->list "0123456789"))

(define (digit-character digit) (item-at digit-characters digit))

(define (small-characters count)
  ;; the digits of a count below 100,000,000
  (if (< count 10)
      (list (digit-character count))
      (append (small-characters (quotient count 10))
              (list (digit-character (remainder count 10))))))

(define (small-number-from-string text)
  ;; a count written in at most 8 digits, or #f
  (let ((characters (string->list text)))
    (if (and (not (null? characters))
             (<= (length characters) 8)
             (all digit-character? characters))
        (let loop ((characters characters) (count 0))
          (if (null? characters)
              count
              (loop (cdr characters)
                    (+ (* count 10) (digit-value (car characters))))))
        #f)))

;;; ------------------------------------------------------------------------
;;; Values
;;;
;;; Every value is a list whose first item says what it is:
;;;   (number negative limbs)  a whole number: whether it is below 0, and its
;;;                            digits in base 10000, lowest first
;;;   (text characters)        a text
;;;   (name symbol)            True, False or Newline
;;;   (element id)             a Line, Word, Paragraph or Input_Character, or
;;;                            a value of a rule type
;;; Two values are the same exactly when equal? says so.

(define (number-value? value) (equal? (car value) 'number))
(define (text-value? value) (equal? (car value) 'text))
(define (name-value? value) (equal? (car value) 'name))
(define (element-value? value) (equal? (car value) 'element))

(define (make-text characters) (list 'text characters))
(define (text-from-string text) (make-text (string->list text)))
(define (text-characters value) (second value))
(define (make-name symbol) (list 'name symbol))
(define (name-symbol value) (second value))
(define (make-element id) (list 'element id))
(define (element-id value) (second value))

;;; ------------------------------------------------------------------------
;;; Part 7: numbers
;;;
;;; Whole numbers of any size, as lists of digits in base 10000, so no step
;;; works with a number of 100,000,000 or more (PLAN.md 5.4). These are atoms
;;; (PLAN.md 5.2): comparing, adding, multiplying, and dividing with its
;;; remainder, which gives divisible_by and wrap_at.

(define limb-base 10000)

(define (make-number negative limbs)
  (let ((trimmed (trim-limbs limbs)))
    (list 'number (if (null? trimmed) #f negative) trimmed)))

(define (number-negative value) (second value))
(define (number-limbs value) (third value))
(define (zero-number? value) (null? (number-limbs value)))

(define (small-number count)
  ;; the number of a count below 100,000,000
  (make-number #f (list (remainder count limb-base) (quotient count limb-base))))

(define (number-to-small value)
  ;; the count of a number from 0 to 99,999,999
  (let loop ((limbs (reverse (number-limbs value))) (count 0))
    (if (null? limbs)
        count
        (loop (cdr limbs) (+ (* count limb-base) (car limbs))))))

(define (number-from-digits digits negative)
  ;; digits: the value of each digit, highest first
  (let loop ((digits digits) (limbs '()))
    (if (null? digits)
        (make-number negative limbs)
        (loop (cdr digits)
              (add-limbs (multiply-limbs-by-small limbs 10 0) (list (car digits)) 0)))))

(define (trim-limbs limbs) (reverse (drop-zero-limbs (reverse limbs))))

(define (drop-zero-limbs limbs)
  (cond ((null? limbs) '())
        ((= (car limbs) 0) (drop-zero-limbs (cdr limbs)))
        (else limbs)))

(define (first-limb limbs) (if (null? limbs) 0 (car limbs)))
(define (later-limbs limbs) (if (null? limbs) '() (cdr limbs)))

(define (compare-limbs left right)
  ;; -1, 0 or 1, for two trimmed lists of limbs
  (let ((left-length (length left)) (right-length (length right)))
    (cond ((< left-length right-length) -1)
          ((> left-length right-length) 1)
          (else (compare-highest-first (reverse left) (reverse right))))))

(define (compare-highest-first left right)
  (cond ((null? left) 0)
        ((< (car left) (car right)) -1)
        ((> (car left) (car right)) 1)
        (else (compare-highest-first (cdr left) (cdr right)))))

(define (add-limbs left right carry)
  (if (and (null? left) (null? right))
      (if (= carry 0) '() (list carry))
      (let ((total (+ (first-limb left) (first-limb right) carry)))
        (cons (remainder total limb-base)
              (add-limbs (later-limbs left) (later-limbs right)
                         (quotient total limb-base))))))

(define (subtract-limbs left right borrow)
  ;; left minus right, where right is not larger
  (if (null? left)
      '()
      (let ((difference (- (car left) (first-limb right) borrow)))
        (if (< difference 0)
            (cons (+ difference limb-base)
                  (subtract-limbs (cdr left) (later-limbs right) 1))
            (cons difference (subtract-limbs (cdr left) (later-limbs right) 0))))))

(define (multiply-limbs-by-small limbs small carry)
  ;; small is below 10000, so each product is below 100,000,000
  (if (null? limbs)
      (if (= carry 0) '() (list carry))
      (let ((product (+ (* (car limbs) small) carry)))
        (cons (remainder product limb-base)
              (multiply-limbs-by-small (cdr limbs) small (quotient product limb-base))))))

(define (multiply-limbs left right)
  (if (null? right)
      '()
      (add-limbs (multiply-limbs-by-small left (car right) 0)
                 (cons 0 (multiply-limbs left (cdr right)))
                 0)))

(define (divide-limbs dividend divisor)
  ;; long division by a divisor that is not 0: the quotient and the
  ;; remainder, as a pair of trimmed lists of limbs
  (let loop ((highest-first (reverse dividend)) (quotient-limbs '()) (left-over '()))
    (if (null? highest-first)
        (cons (trim-limbs quotient-limbs) left-over)
        (let* ((current (trim-limbs (cons (car highest-first) left-over)))
               (digit (largest-digit divisor current 0 (- limb-base 1)))
               (taken (trim-limbs (multiply-limbs-by-small divisor digit 0))))
          (loop (cdr highest-first)
                (cons digit quotient-limbs)
                (trim-limbs (subtract-limbs current taken 0)))))))

(define (largest-digit divisor current low high)
  ;; the largest digit from low to high whose multiple of divisor fits
  (if (= low high)
      low
      (let ((middle (quotient (+ low high 1) 2)))
        (if (<= (compare-limbs (trim-limbs (multiply-limbs-by-small divisor middle 0))
                               current)
                0)
            (largest-digit divisor current middle high)
            (largest-digit divisor current low (- middle 1))))))

(define (negate-number value)
  (make-number (not (number-negative value)) (number-limbs value)))

(define (add-numbers left right)
  (cond ((equal? (number-negative left) (number-negative right))
         (make-number (number-negative left)
                      (add-limbs (number-limbs left) (number-limbs right) 0)))
        ((>= (compare-limbs (number-limbs left) (number-limbs right)) 0)
         (make-number (number-negative left)
                      (subtract-limbs (number-limbs left) (number-limbs right) 0)))
        (else
         (make-number (number-negative right)
                      (subtract-limbs (number-limbs right) (number-limbs left) 0)))))

(define (subtract-numbers left right) (add-numbers left (negate-number right)))

(define (multiply-numbers left right)
  (make-number (not (equal? (number-negative left) (number-negative right)))
               (multiply-limbs (number-limbs left) (number-limbs right))))

(define (compare-numbers left right)
  (let ((left-negative (number-negative left)) (right-negative (number-negative right)))
    (cond ((and left-negative (not right-negative)) -1)
          ((and right-negative (not left-negative)) 1)
          (left-negative (compare-limbs (number-limbs right) (number-limbs left)))
          (else (compare-limbs (number-limbs left) (number-limbs right))))))

(define (divide-exactly left right)
  ;; the quotient, when right is not 0 and divides left; otherwise #f
  (if (zero-number? right)
      #f
      (let ((division (divide-limbs (number-limbs left) (number-limbs right))))
        (if (null? (cdr division))
            (make-number (not (equal? (number-negative left) (number-negative right)))
                         (car division))
            #f))))

(define (wrap-number value divisor)
  ;; the value wrapped into 0 up to one below the divisor, for a divisor
  ;; above 0; otherwise #f
  (if (or (zero-number? divisor) (number-negative divisor))
      #f
      (let ((left-over (make-number #f (cdr (divide-limbs (number-limbs value)
                                                          (number-limbs divisor))))))
        (if (and (number-negative value) (not (zero-number? left-over)))
            (subtract-numbers divisor left-over)
            left-over))))

(define (divisible? value divisor)
  (and (number-value? value) (number-value? divisor) (not (zero-number? divisor))
       (null? (cdr (divide-limbs (number-limbs value) (number-limbs divisor))))))

(define (calculate how left right)
  ;; a calculation's value, or #f when it has none
  (if (and (number-value? left) (number-value? right))
      (cond ((equal? how 'plus) (add-numbers left right))
            ((equal? how 'minus) (subtract-numbers left right))
            ((equal? how 'times) (multiply-numbers left right))
            ((equal? how 'divided) (divide-exactly left right))
            ((equal? how 'wrap) (wrap-number left right))
            (else #f))
      #f))

(define (limb-characters limb)
  ;; four digits, with zeros in front
  (list (digit-character (quotient limb 1000))
        (digit-character (remainder (quotient limb 100) 10))
        (digit-character (remainder (quotient limb 10) 10))
        (digit-character (remainder limb 10))))

(define (number-characters value)
  (let ((highest-first (reverse (number-limbs value))))
    (append (if (number-negative value) (list #\-) '())
            (if (null? highest-first)
                (list #\0)
                (append (small-characters (car highest-first))
                        (join-lists (map limb-characters (cdr highest-first))))))))

;;; ------------------------------------------------------------------------
;;; Part 3: the reader
;;;
;;; Lines to lists: indentation becomes nesting, and words, numbers and quoted
;;; texts become atoms. A step of indentation is two spaces.
;;;
;;; A line record: (number depth words length) for a line with words in it,
;;; (number blank) for a blank line, and (number set-aside) for a line the
;;; reader refused.
;;; A word record: (kind characters number places): kind is name, number,
;;; quoted or mark; number and places are only for a number, so 19.99 has
;;; the number 1999 and 2 places.
;;; A refusal: (reading reason line place), or (rule source line place) from
;;; a rule; line is the line of the Etale file, place the character's place
;;; in the text being read, each #f when there is none.

(define (line-number line) (car line))
(define (blank-line? line) (equal? (second line) 'blank))
(define (set-aside-line? line) (equal? (second line) 'set-aside))
(define (line-depth line) (second line))
(define (line-words line) (third line))
(define (line-length line) (fourth line))

(define (written-lines lines)
  (keep (lambda (line) (not (or (blank-line? line) (set-aside-line? line)))) lines))

(define (word-kind word) (car word))
(define (word-characters word) (second word))
(define (word-number word) (third word))
(define (word-places word) (fourth word))

(define (reading-refusal reason line place) (list 'reading reason line place))
(define (refusal-line refusal) (third refusal))
(define (refusal-place refusal) (fourth refusal))

(define (read-characters path)
  ;; every character of a file, or of standard input when path is #f
  (let ((port (if path (open-input-file path) #f)))
    (let loop ((characters '()))
      (let ((character (if port (read-char port) (read-char))))
        (if (eof-object? character)
            (reverse characters)
            (loop (cons character characters)))))))

(define (split-lines characters)
  ;; the lines of a text, each without its newline
  (let loop ((characters characters) (line '()) (lines '()))
    (cond ((null? characters)
           (reverse (if (null? line) lines (cons (reverse line) lines))))
          ((char=? (car characters) #\newline)
           (loop (cdr characters) '() (cons (reverse line) lines)))
          (else (loop (cdr characters) (cons (car characters) line) lines)))))

(define (etale-character-reason character)
  ;; why a character cannot be in an Etale file, or #f (PLAN.md 3.5)
  (let ((code (code-of character)))
    (cond ((= code 9) "a tab")
          ((= code 13) "a carriage return")
          ((or (< code 32) (> code 126))
           (string-append "a character outside printable ASCII, code "
                          (list->string (small-characters code))))
          (else #f))))

(define (unused-character-reason character)
  ;; why a character outside a quoted text cannot be read, or #f
  (cond ((or (letter-character? character) (digit-character? character)) #f)
        ((member character (string->list "_+-/<>=")) #f)
        ((char=? character #\#) "a hash: comments are refused")
        (else (string-append "a character no form uses: "
                             (list->string (list character))))))

(define (count-leading-spaces characters)
  (if (and (not (null? characters)) (char=? (car characters) #\space))
      (+ 1 (count-leading-spaces (cdr characters)))
      0))

(define (read-line-record number characters)
  ;; returns (cons line-record refusals)
  (let ((refused (keep etale-character-reason characters)))
    (if (not (null? refused))
        (cons (list number 'set-aside)
              (map (lambda (character)
                     (reading-refusal (etale-character-reason character) number #f))
                   refused))
        (let* ((indent (count-leading-spaces characters))
               (rest (drop characters indent)))
          (cond ((null? rest) (cons (list number 'blank) '()))
                ((= (remainder indent 2) 1)
                 (cons (list number 'set-aside)
                       (list (reading-refusal
                              "indentation that is not a whole number of steps of two spaces"
                              number #f))))
                (else
                 (let ((split (split-words rest)))
                   (cons (list number (quotient indent 2) (car split) (length characters))
                         (map (lambda (reason) (reading-refusal reason number #f))
                              (cdr split))))))))))

(define (split-words characters)
  ;; returns (cons words reasons): a line's words in order, and why any part
  ;; of it cannot be read (PLAN.md 5.3 says how a line splits into words)
  (let loop ((characters characters) (current '()) (words '()) (reasons '()))
    (if (null? characters)
        (cons (reverse (finish-word current words)) (reverse reasons))
        (let ((character (car characters)) (later (cdr characters)))
          (cond ((char=? character #\space)
                 (loop later '() (finish-word current words) reasons))
                ((char=? character #\")
                 (let ((quoted (read-quoted later)))
                   (if quoted
                       (loop (cdr quoted) '()
                             (cons (make-word 'quoted (car quoted))
                                   (finish-word current words))
                             reasons)
                       (cons (reverse (finish-word current words))
                             (reverse (cons "a quoted text with no closing quote" reasons))))))
                ((member character (string->list ":(),|*"))
                 (loop later '()
                       (cons (make-word 'mark (list character)) (finish-word current words))
                       reasons))
                ((and (char=? character #\.) (decimal-point? current later))
                 (loop later (cons character current) words reasons))
                ((char=? character #\.)
                 (let ((run (read-dots characters)))
                   (loop (cdr run) '()
                         (cons (make-word 'mark (car run)) (finish-word current words))
                         reasons)))
                (else
                 (let ((reason (unused-character-reason character)))
                   (loop later (cons character current) words
                         (if reason (cons reason reasons) reasons)))))))))

(define (read-quoted characters)
  ;; the characters up to the closing quote, and those after it, or #f
  (let loop ((characters characters) (text '()))
    (cond ((null? characters) #f)
          ((char=? (car characters) #\") (cons (reverse text) (cdr characters)))
          (else (loop (cdr characters) (cons (car characters) text))))))

(define (read-dots characters)
  ;; a run of points, and the characters after it
  (let loop ((characters characters) (dots '()))
    (if (and (not (null? characters)) (char=? (car characters) #\.))
        (loop (cdr characters) (cons #\. dots))
        (cons dots characters))))

(define (decimal-point? current later)
  ;; a single point between two digits stays in its number
  (and (not (null? later))
       (digit-character? (car later))
       (not (null? current))
       (whole-number-characters? (reverse current))))

(define (whole-number-characters? characters)
  ;; digits, with a minus right before them if any
  (let ((digits (if (and (not (null? characters)) (char=? (car characters) #\-))
                    (cdr characters)
                    characters)))
    (and (not (null? digits)) (all digit-character? digits))))

(define (finish-word current words)
  (if (null? current)
      words
      (let ((characters (reverse current)))
        (cons (make-word (word-kind-of characters) characters) words))))

(define (word-kind-of characters)
  (cond ((number-word-characters? characters) 'number)
        ((name-characters? characters) 'name)
        (else 'mark)))

(define (number-word-characters? characters)
  ;; digits, with a minus right before them if any, and a point between
  ;; digits if any
  (let* ((unsigned (if (char=? (car characters) #\-) (cdr characters) characters))
         (whole (leading-digits unsigned))
         (after (drop unsigned (length whole))))
    (and (not (null? whole))
         (or (null? after)
             (and (char=? (car after) #\.)
                  (not (null? (cdr after)))
                  (all digit-character? (cdr after)))))))

(define (leading-digits characters)
  (if (and (not (null? characters)) (digit-character? (car characters)))
      (cons (car characters) (leading-digits (cdr characters)))
      '()))

(define (name-characters? characters)
  (and (letter-character? (car characters))
       (all (lambda (character)
              (or (letter-character? character)
                  (digit-character? character)
                  (char=? character #\_)))
            characters)))

(define (make-word kind characters)
  (if (equal? kind 'number)
      (list kind characters
            (number-from-digits (map digit-value (keep digit-character? characters))
                                (char=? (car characters) #\-))
            (let ((after (member #\. characters)))
              (if after (- (length after) 1) 0)))
      (list kind characters #f #f)))

(define (structure-refusals lines)
  ;; a line two steps deeper than the one above, two blank lines together,
  ;; and a blank line inside an item (one followed by a line two or more
  ;; steps in)
  (let loop ((lines lines) (depth-above -1) (blank-above #f) (refusals '()))
    (if (null? lines)
        (reverse refusals)
        (let ((line (car lines)))
          (cond ((set-aside-line? line) (loop (cdr lines) depth-above #f refusals))
                ((blank-line? line)
                 (loop (cdr lines) depth-above (line-number line)
                       (if blank-above
                           (cons (reading-refusal "two blank lines together"
                                                  (line-number line) #f)
                                 refusals)
                           refusals)))
                (else
                 (let* ((depth (line-depth line))
                        (refusals
                         (if (> depth (+ depth-above 1))
                             (cons (reading-refusal "a line two steps deeper than the one above"
                                                    (line-number line) #f)
                                   refusals)
                             refusals))
                        (refusals
                         (if (and blank-above (>= depth 2))
                             (cons (reading-refusal "a blank line inside an item" blank-above #f)
                                   refusals)
                             refusals)))
                   (loop (cdr lines) depth #f refusals))))))))

(define (read-etale-file path)
  ;; returns (cons lines refusals): a record for every line, and the reader's
  ;; refusals in line order
  (let loop ((texts (split-lines (read-characters path))) (number 1) (lines '()) (refusals '()))
    (if (null? texts)
        (let ((lines (reverse lines)))
          (cons lines (sort-refusals (append (reverse refusals) (structure-refusals lines)))))
        (let ((record (read-line-record number (car texts))))
          (loop (cdr texts) (+ number 1) (cons (car record) lines)
                (append (reverse (cdr record)) refusals))))))

(define (sort-refusals refusals)
  (sort-items refusals
              (lambda (left right)
                (let ((left-line (or (refusal-line left) 0))
                      (right-line (or (refusal-line right) 0)))
                  (or (< left-line right-line)
                      (and (= left-line right-line)
                           (< (or (refusal-place left) 0) (or (refusal-place right) 0))))))))

;;; The tree: a node is (line children), for the written lines.

(define (build-tree lines) (car (build-nodes lines 0)))

(define (build-nodes lines depth)
  ;; returns (cons nodes the-lines-after-them)
  (let loop ((lines lines) (nodes '()))
    (if (or (null? lines) (< (line-depth (car lines)) depth))
        (cons (reverse nodes) lines)
        (let ((children (build-nodes (cdr lines) (+ depth 1))))
          (loop (cdr children) (cons (list (car lines) (car children)) nodes))))))

(define (node-line node) (car node))
(define (node-children node) (second node))
(define (node-words node) (line-words (node-line node)))
(define (node-number node) (line-number (node-line node)))

(define (tree-characters nodes)
  ;; the tree as bracketed lists, one line of the file to a line
  (join-lists (map (lambda (node) (append (node-characters node 0) (list #\newline)))
                   nodes)))

(define (node-characters node indent)
  (append (spaces indent)
          (list #\()
          (words-characters (node-words node))
          (join-lists (map (lambda (child)
                             (cons #\newline (node-characters child (+ indent 2))))
                           (node-children node)))
          (list #\))))

(define (spaces count) (if (= count 0) '() (cons #\space (spaces (- count 1)))))

(define (words-characters words)
  (cond ((null? words) '())
        ((null? (cdr words)) (word-written (car words)))
        (else (append (word-written (car words)) (list #\space)
                      (words-characters (cdr words))))))

(define (word-written word)
  (if (equal? (word-kind word) 'quoted)
      (append (list #\") (word-characters word) (list #\"))
      (word-characters word)))

;;; ------------------------------------------------------------------------
;;; Part 4: the file as facts
;;;
;;; The facts the rules match are kept in a store:
;;;   (next-id types elements made refusals steps budget added index changes)
;;; types:    for each type, how many elements it has, and their ids, newest
;;;           first, in a keyed tree
;;; elements: for each id, its type and its fields; a field may hold more
;;;           than one value
;;; made:     for each type, each value a rule made, found by its parts, so
;;;           that it is made only once; a keyed tree
;;; refusals: each refusal found
;;; steps:    the steps counted so far, and budget the most allowed
;;; added:    how many facts have been added, so the rule loop sees when a
;;;           pass adds nothing new
;;; index:    for each type and field a rule looks elements up by (given
;;;           word.line is line), the elements with each value in that
;;;           field, newest first, so such a part is found without looking
;;;           at every element of its type; a keyed tree
;;; changes:  when, counted in facts added, each type last got a new element
;;;           and each field a new value, so the rule loop runs again only
;;;           the rules that read something new; a keyed tree

(define (empty-store budget indexed)
  ;; indexed: the (type field) pairs the rules look elements up by
  (list 0 '() '() '() '() 0 budget 0
        (let loop ((pairs indexed) (index '()))
          (if (null? pairs) index (loop (cdr pairs) (keyed-store index (car pairs) '()))))
        '()))
(define (store-next-id store) (item-at store 0))
(define (store-types store) (item-at store 1))
(define (store-elements store) (item-at store 2))
(define (store-made store) (item-at store 3))
(define (store-refusals store) (item-at store 4))
(define (store-steps store) (item-at store 5))
(define (store-budget store) (item-at store 6))
(define (store-added store) (item-at store 7))
(define (store-index store) (item-at store 8))
(define (store-changes store) (item-at store 9))

(define (stamp-change store key)
  ;; key is (element Type), (field name), or (field-of Type name) for a field
  ;; of one type
  (replace-at store 9 (keyed-store (store-changes store) key (store-added store))))

(define (hashed-change-stamp store key hash)
  ;; when, counted in facts added, key last changed, or -1; hash is the
  ;; key's, worked out once when the rule was read
  (let ((found (tree-find (store-changes store) hash)))
    (if (null? found) -1 (entry-value (car found) key -1))))

;;; A keyed tree: a tree of buckets by the hash of a key that is a list of
;;; symbols, each bucket holding (key . value) entries, so that the store's
;;; tables for types, the index and changes are found in a few steps however
;;; many types the rule files have.

(define (keyed-find tree key)
  ;; the value stored under key, or #f
  (let ((found (tree-find tree (hash-symbols key 0))))
    (if (null? found) #f (entry-value (car found) key #f))))

(define (keyed-store tree key value)
  (let* ((hash (hash-symbols key 0))
         (found (tree-find tree hash))
         (bucket (if (null? found) '() (car found))))
    (tree-store tree hash (set-entry bucket key value))))

(define (hash-symbols symbols hash)
  (if (null? symbols)
      hash
      (hash-symbols (cdr symbols)
                    (hash-characters (string->list (symbol->string (car symbols)))
                                     (hash-step hash 6)))))

(define (store-out-of-steps? store) (> (store-steps store) (store-budget store)))
(define (count-step store) (replace-at store 5 (+ 1 (store-steps store))))
(define (count-added store) (replace-at store 7 (+ 1 (store-added store))))

;;; A tree keyed by a whole number from 0, so that an element is found in a
;;; few steps without a table. The node for a key is reached by the bits of
;;; the key plus 1, lowest first, leaving out its highest bit, so a tree of
;;; the keys below n is about as deep as the number of bits in n. A node is
;;; (box zero one): box is a list holding the node's value, or empty, and
;;; zero and one are the trees for the next bit.

(define (tree-find tree key)
  ;; a list holding the value stored at key, or the empty list
  (let loop ((tree tree) (path (+ key 1)))
    (cond ((null? tree) '())
          ((= path 1) (car tree))
          ((= (remainder path 2) 0) (loop (second tree) (quotient path 2)))
          (else (loop (third tree) (quotient path 2))))))

(define (tree-store tree key value)
  (let loop ((tree tree) (path (+ key 1)))
    (let ((node (if (null? tree) (list '() '() '()) tree)))
      (cond ((= path 1) (list (list value) (second node) (third node)))
            ((= (remainder path 2) 0)
             (list (car node) (loop (second node) (quotient path 2)) (third node)))
            (else (list (car node) (second node) (loop (third node) (quotient path 2))))))))

(define hash-size 65536)

(define (hash-step hash part)
  ;; both stay below 65536, so no step reaches 100,000,000
  (remainder (+ (* hash 31) (remainder part hash-size)) hash-size))

(define (hash-characters characters hash)
  (if (null? characters)
      hash
      (hash-characters (cdr characters) (hash-step hash (code-of (car characters))))))

(define (hash-limbs limbs hash)
  (if (null? limbs) hash (hash-limbs (cdr limbs) (hash-step hash (car limbs)))))

(define (hash-value value hash)
  (let ((kind (car value)))
    (cond ((equal? kind 'element) (hash-step (hash-step hash 1) (element-id value)))
          ((equal? kind 'number)
           (hash-limbs (number-limbs value) (hash-step hash (if (number-negative value) 2 3))))
          ((equal? kind 'text) (hash-characters (text-characters value) (hash-step hash 4)))
          (else (hash-characters (string->list (symbol->string (name-symbol value)))
                                 (hash-step hash 5))))))

(define (hash-values values)
  (let loop ((values values) (hash 0))
    (if (null? values) hash (loop (cdr values) (hash-value (car values) hash)))))

(define (bucket-find tree key)
  ;; a tree of buckets, each holding (key . item) entries whose keys share
  ;; a hash: the item for key, or #f
  (let ((found (tree-find tree (hash-values key))))
    (if (null? found) #f (entry-value (car found) key #f))))

(define (bucket-store tree key item)
  (let* ((hash (hash-values key))
         (found (tree-find tree hash))
         (bucket (if (null? found) '() (car found))))
    (tree-store tree hash (set-entry bucket key item))))

(define (index-add index type field value id)
  ;; the index with id under value, if the rules look up type by field
  (let ((values (keyed-find index (list type field))))
    (if values
        (keyed-store index (list type field)
                     (bucket-store values (list value)
                                   (cons id (let ((ids (bucket-find values (list value))))
                                              (if ids ids '())))))
        index)))

(define (store-indexed store type field value)
  ;; the ids of the elements of type with value in field, newest first
  (let ((values (keyed-find (store-index store) (list type field))))
    (if values
        (let ((ids (bucket-find values (list value)))) (if ids ids '()))
        '())))

(define (store-elements-of store type)
  (let ((entry (keyed-find (store-types store) (list type))))
    (if entry (cdr entry) '())))

(define (store-count-of store type)
  (let ((entry (keyed-find (store-types store) (list type))))
    (if entry (car entry) 0)))

(define (add-to-types types type id)
  ;; types: a keyed tree giving each type (count . ids), ids newest first
  (let ((entry (keyed-find types (list type))))
    (keyed-store types (list type)
                 (if entry (cons (+ 1 (car entry)) (cons id (cdr entry))) (cons 1 (list id))))))

(define (store-new-element store type fields)
  ;; a new element with these fields, each given as (name value);
  ;; returns (cons store element)
  (let* ((id (store-next-id store))
         (record (list type (map (lambda (field) (cons (car field) (list (second field))))
                                 fields)))
         (store (replace-at store 0 (+ id 1)))
         (store (replace-at store 1 (add-to-types (store-types store) type id)))
         (store (replace-at store 2 (tree-store (store-elements store) id record)))
         (store (if (null? (store-index store))
                    store
                    (replace-at store 8
                                (let loop ((fields fields) (index (store-index store)))
                                  (if (null? fields)
                                      index
                                      (loop (cdr fields)
                                            (index-add index type (car (car fields))
                                                       (second (car fields)) id))))))))
    (cons (stamp-change (count-added (count-step store)) (list 'element type))
          (make-element id))))

(define (store-record store element)
  (car (tree-find (store-elements store) (element-id element))))

(define (store-type-of store element) (car (store-record store element)))
(define (store-fields store element) (second (store-record store element)))

(define (store-field-values store element field)
  (entry-value (store-fields store element) field '()))

(define (store-add-field store element field value)
  (let* ((record (store-record store element))
         (values (entry-value (second record) field '())))
    (if (member value values)
        store
        (let ((store (replace-at store 2
                                 (tree-store (store-elements store) (element-id element)
                                             (list (car record)
                                                   (set-entry (second record) field
                                                              (append values (list value))))))))
          (stamp-change
           (stamp-change
            (count-added
             (if (null? (store-index store))
                 store
                 (replace-at store 8 (index-add (store-index store) (car record) field value
                                                (element-id element)))))
            (list 'field field))
           (list 'field-of (car record) field))))))

(define (store-find-made store type values)
  ;; the value of type already made with these parts, or #f
  (let ((made (keyed-find (store-made store) (list type))))
    (if made (bucket-find made values) #f)))

(define (store-remember-made store type values element)
  (let ((made (keyed-find (store-made store) (list type))))
    (replace-at store 3 (keyed-store (store-made store) (list type)
                                     (bucket-store (if made made '()) values element)))))

;;; The built-in types the rule files see (PLAN.md 5.3), one element for
;;;   each line that is not blank (Line), each run of lines with no blank
;;;   line in it (Paragraph), each word of a line (Word), each character of
;;;   a quoted word (Quoted_Character), the text being read (Input_Text), and
;;;   each character of it (Input_Character).
;;; A field that does not apply is absent. Lines, then paragraphs, then words
;;; are given ids one after another, so each can name the others.

(define (place-lines lines)
  ;; for each written line: (holder place type-holder), where holder is the
  ;; line it sits under, place its place among the lines under that holder,
  ;; and type-holder the line at depth 0 it is under; holders are positions
  ;; in lines, or #f
  (let loop ((lines lines) (position 0) (latest '()) (counts '()) (top #f) (placed '()))
    (if (null? lines)
        (reverse placed)
        (let* ((depth (line-depth (car lines)))
               (holder (if (= depth 0) #f (entry-value latest (- depth 1) #f)))
               (key (if holder holder 'top))
               (place (+ 1 (entry-value counts key 0)))
               (top (if (= depth 0) position top)))
          (loop (cdr lines) (+ position 1)
                (set-entry latest depth position)
                (set-entry counts key place)
                top
                (cons (list holder place (if (= depth 0) #f top)) placed))))))

(define (blank-before-flags lines)
  ;; for each written line, whether a blank line lies between it and the
  ;; written line above it
  (let loop ((lines lines) (blank #f) (flags '()))
    (cond ((null? lines) (reverse flags))
          ((blank-line? (car lines)) (loop (cdr lines) #t flags))
          ((set-aside-line? (car lines)) (loop (cdr lines) blank flags))
          (else (loop (cdr lines) #f (cons blank flags))))))

(define (group-paragraphs lines placed flags)
  ;; returns (cons paragraph-of-each-line paragraphs): a paragraph is a run of
  ;; written lines with no blank line in it and one type holder; it is
  ;; (holder place first last item-count before), as positions or #f
  (let loop ((lines lines) (placed placed) (flags flags) (position 0)
             (previous-key 'none) (counts '()) (latest '()) (paragraphs '()) (of-lines '()))
    (if (null? lines)
        (cons (reverse of-lines) (reverse paragraphs))
        (let* ((depth (line-depth (car lines)))
               (type-holder (third (car placed)))
               (key (if type-holder type-holder 'top))
               (item (if type-holder (= depth 1) #t)))
          (if (or (car flags) (not (equal? key previous-key)))
              (let ((place (+ 1 (entry-value counts key 0)))
                    (number (length paragraphs)))
                (loop (cdr lines) (cdr placed) (cdr flags) (+ position 1) key
                      (set-entry counts key place)
                      (set-entry latest key number)
                      (cons (list type-holder place position position (if item 1 0)
                                  (entry-value latest key #f))
                            paragraphs)
                      (cons number of-lines)))
              (let ((current (car paragraphs)))
                (loop (cdr lines) (cdr placed) (cdr flags) (+ position 1) key counts latest
                      (cons (list (first-of current) (second current) (third current) position
                                  (+ (fifth current) (if item 1 0)) (sixth current))
                            (cdr paragraphs))
                      (cons (- (length paragraphs) 1) of-lines))))))))

(define (type-places lines)
  ;; for each written line that starts a type (a line at depth 0 with lines
  ;; under it), its place among the file's types; #f for the others
  (let loop ((lines lines) (count 0) (places '()))
    (if (null? lines)
        (reverse places)
        (let ((starts-type (and (= (line-depth (car lines)) 0)
                                (not (null? (cdr lines)))
                                (= (line-depth (second lines)) 1))))
          (loop (cdr lines) (if starts-type (+ count 1) count)
                (cons (if starts-type (+ count 1) #f) places))))))

(define (choice-count line)
  ;; the choices joined by | on a line: one more than its | marks
  (+ 1 (count-of (lambda (word) (word-is? word 'mark "|")) (line-words line))))

(define (name-word-count characters)
  ;; the words of a name between underscores
  (let loop ((characters characters) (inside #f) (count 0))
    (cond ((null? characters) count)
          ((char=? (car characters) #\_) (loop (cdr characters) #f count))
          (inside (loop (cdr characters) #t count))
          (else (loop (cdr characters) #t (+ count 1))))))

(define (under-counts placed)
  ;; for each written line, how many lines sit directly under it
  (let loop ((position 0) (left placed) (counts '()))
    (if (null? left)
        (reverse counts)
        (loop (+ position 1) (cdr left)
              (cons (count-of (lambda (place) (equal? (first-of place) position)) placed)
                    counts)))))

(define (store-with-file store all-lines)
  (let* ((lines (written-lines all-lines))
         (placed (place-lines lines))
         (grouped (group-paragraphs lines placed (blank-before-flags all-lines)))
         (first-line-id (store-next-id store))
         (first-paragraph-id (+ first-line-id (length lines)))
         (first-word-id (+ first-paragraph-id (length (cdr grouped))))
         (line-element (lambda (position) (make-element (+ first-line-id position))))
         (paragraph-element (lambda (number) (make-element (+ first-paragraph-id number))))
         (store (add-lines store lines placed (under-counts placed) (car grouped)
                           (type-places lines) line-element paragraph-element))
         (store (add-paragraphs store (cdr grouped) line-element paragraph-element))
         (store (add-words store lines line-element first-word-id)))
    (add-quoted-characters store lines first-word-id)))

(define (add-lines store lines placed unders paragraphs types line-element paragraph-element)
  (let loop ((lines lines) (placed placed) (unders unders) (paragraphs paragraphs)
             (types types) (position 0) (store store))
    (if (null? lines)
        store
        (let* ((line (car lines))
               (holder (first-of (car placed)))
               (fields
                (append
                 (list (list 'number (small-number (line-number line)))
                       (list 'depth (small-number (line-depth line))))
                 (if holder (list (list 'holder (line-element holder))) '())
                 (if (> position 0) (list (list 'above (line-element (- position 1)))) '())
                 (list (list 'length (small-number (line-length line)))
                       (list 'place (small-number (second (car placed))))
                       (list 'word_count (small-number (length (line-words line))))
                       (list 'under_count (small-number (car unders)))
                       (list 'choice_count (small-number (choice-count line))))
                 (if (car types) (list (list 'type_place (small-number (car types)))) '())
                 (list (list 'paragraph (paragraph-element (car paragraphs)))))))
          (loop (cdr lines) (cdr placed) (cdr unders) (cdr paragraphs) (cdr types)
                (+ position 1)
                (car (store-new-element store 'Line fields)))))))

(define (add-paragraphs store paragraphs line-element paragraph-element)
  (if (null? paragraphs)
      store
      (let* ((paragraph (car paragraphs))
             (fields
              (append
               (if (first-of paragraph)
                   (list (list 'holder (line-element (first-of paragraph))))
                   '())
               (list (list 'place (small-number (second paragraph))))
               (if (sixth paragraph)
                   (list (list 'before (paragraph-element (sixth paragraph))))
                   '())
               (list (list 'first_line (line-element (third paragraph)))
                     (list 'last_line (line-element (fourth paragraph)))
                     (list 'item_count (small-number (fifth paragraph)))))))
        (add-paragraphs (car (store-new-element store 'Paragraph fields)) (cdr paragraphs)
                        line-element paragraph-element))))

(define (add-words store lines line-element first-word-id)
  (let loop ((lines lines) (position 0) (id first-word-id) (store store))
    (if (null? lines)
        store
        (let ((words (line-words (car lines))))
          (loop (cdr lines) (+ position 1) (+ id (length words))
                (add-line-words store words (line-element position) id 1))))))

(define (add-line-words store words line id place)
  (if (null? words)
      store
      (let* ((word (car words))
             (kind (word-kind word))
             (fields
              (append
               (list (list 'line line) (list 'place (small-number place)))
               (if (null? (cdr words)) '() (list (list 'next (make-element (+ id 1)))))
               (list (list 'kind (text-from-string (symbol->string kind)))
                     (list 'text (make-text (word-characters word)))
                     (list 'length (small-number (length (word-characters word)))))
               (if (equal? kind 'name)
                   (list (list 'name_word_count
                               (small-number (name-word-count (word-characters word)))))
                   '())
               (if (equal? kind 'number)
                   (list (list 'number (word-number word))
                         (list 'places (small-number (word-places word))))
                   '()))))
        (add-line-words (car (store-new-element store 'Word fields)) (cdr words)
                        line (+ id 1) (+ place 1)))))

(define (input-character-reason character)
  ;; why a character cannot be in a text being read, or #f (PLAN.md 3.5)
  (let ((code (code-of character)))
    (cond ((or (= code 9) (= code 10)) #f)
          ((= code 13) "a carriage return")
          ((or (< code 32) (> code 126))
           (string-append "a character outside printable ASCII, code "
                          (list->string (small-characters code))))
          (else #f))))

(define (input-refusals characters)
  (let loop ((characters characters) (place 1) (refusals '()))
    (if (null? characters)
        (reverse refusals)
        (let ((reason (input-character-reason (car characters))))
          (loop (cdr characters) (+ place 1)
                (if reason (cons (reading-refusal reason #f place) refusals) refusals))))))

(define (add-text-characters store type characters owner)
  ;; an element of type for each character, with owner's fields first:
  ;; its place, its value (a one-character text, or Newline), its code
  ;; number, and the next character, absent for the last
  (let ((first-id (store-next-id store)))
    (let loop ((characters characters) (place 1) (store store))
      (if (null? characters)
          store
          (let* ((character (car characters))
                 (fields
                  (append
                   owner
                   (list (list 'place (small-number place))
                         (list 'value (if (char=? character #\newline)
                                          (make-name 'Newline)
                                          (make-text (list character))))
                         (list 'code (small-number (code-of character))))
                   (if (null? (cdr characters))
                       '()
                       (list (list 'next (make-element (+ first-id place))))))))
            (loop (cdr characters) (+ place 1)
                  (car (store-new-element store type fields))))))))

(define (add-quoted-characters store lines first-word-id)
  ;; a Quoted_Character for each character of each quoted word, between
  ;; its quotes; words have their ids in order from first-word-id
  (let loop ((words (join-lists (map line-words lines))) (id first-word-id) (store store))
    (cond ((null? words) store)
          ((equal? (word-kind (car words)) 'quoted)
           (loop (cdr words) (+ id 1)
                 (add-text-characters store 'Quoted_Character (word-characters (car words))
                                      (list (list 'word (make-element id))))))
          (else (loop (cdr words) (+ id 1) store)))))

(define (store-with-text store characters type-name printed-as)
  ;; the text being read: one Input_Text, naming the type it is read as and
  ;; the text it is printed with, then each of its characters
  (let ((store (car (store-new-element
                     store 'Input_Text
                     (list (list 'type (text-from-string type-name))
                           (list 'printed_as (text-from-string printed-as))
                           (list 'length (small-number (length characters))))))))
    (add-text-characters store 'Input_Character characters '())))

(define (text-line-of characters place)
  ;; the line of a text that its character at place is on
  (let loop ((characters characters) (at 1) (line 1))
    (if (or (null? characters) (= at place))
        line
        (loop (cdr characters) (+ at 1)
              (if (char=? (car characters) #\newline) (+ line 1) line)))))

;;; ------------------------------------------------------------------------
;;; Parts 5 and 6: rule files, the rule loop, unions and there exists
;;;
;;; A rule file is written in the core's part of Etale (PLAN.md section 4):
;;; one-line definitions, and types made of parts with given lines, fields
;;; worked out by calculation, by a call or by cases, and impossible blocks.
;;; Each type becomes rules of one shape: steps that find every match among
;;; the facts, then what follows from each match:
;;;   (make Type parts link)       there exists: the value with these parts,
;;;                                made once; link names a field pointing to it
;;;   (set-field self field value) a worked-out field
;;;   (refuse self)                contained in nothing: a refusal
;;;
;;; The steps:
;;;   (each-of-type variable Type)         every element of a type
;;;   (each-of-types variable Types)       every element of any of them
;;;   (each-indexed variable Type field v) every element of a type whose
;;;                                        field holds the value of v
;;;   (each-value variable values)         a union: each member is a branch
;;;   (each-field variable owner field)    every value of a field
;;;   (bind variable value)                a constant
;;;   (calculate variable how left right)  +, -, *, / or wrap_at
;;;   (check-type variable Type)           an element of this type
;;;   (test relation left right)           is, <, <=, >, >=, divisible_by,
;;;                                        not_divisible_by
;;;   (test-range variable low high)       in a range; high may be #f
;;;   (test-in variable members)           in a choice
;;; A variable is the number of the step that gives it its value.

(define (problem line reason) (list 'problem line reason))
(define (problem? value) (and (not (null? value)) (equal? (car value) 'problem)))

(define (not-defined line name)
  (problem line (string-append (symbol->string name)
                               " is used above its definition, or is not defined")))

(define (word-is? word kind text)
  (and (equal? (word-kind word) kind) (equal? (word-characters word) (string->list text))))
(define (mark-word? word text) (word-is? word 'mark text))
(define (word-symbol word) (string->symbol (list->string (word-characters word))))
(define (word-string word) (list->string (word-characters word)))

;;; Reading a rule file's lines into blocks

(define (parse-term words line)
  ;; a value: returns (cons term the-words-after-it) or a problem
  (if (null? words)
      (problem line "a value is missing")
      (let ((word (car words)) (rest (cdr words)))
        (cond ((equal? (word-kind word) 'number)
               (if (> (word-places word) 0)
                   (problem line "a rule file uses whole numbers only")
                   (cons (list 'literal (word-number word)) rest)))
              ((equal? (word-kind word) 'quoted)
               (cons (list 'literal (make-text (word-characters word))) rest))
              ((equal? (word-kind word) 'name)
               (if (and (not (null? rest)) (mark-word? (car rest) ".")
                        (not (null? (cdr rest))) (equal? (word-kind (second rest)) 'name))
                   (cons (list 'path (word-symbol word) (word-symbol (second rest)))
                         (cdr (cdr rest)))
                   (cons (list 'name (word-symbol word)) rest)))
              (else (problem line (string-append "a value is needed, not "
                                                 (word-string word))))))))

(define calculation-marks '(("+" . plus) ("-" . minus) ("*" . times) ("/" . divided)))

(define (calculation-mark word)
  (if (equal? (word-kind word) 'mark)
      (entry-value calculation-marks (word-string word) #f)
      #f))

(define (parse-definition words line)
  ;; what follows a colon: nothing, a value, a choice, a range, a calculation
  ;; or a call; returns it, or a problem
  (cond ((null? words) (list 'nothing))
        ((and (equal? (word-kind (car words)) 'name)
              (not (null? (cdr words)))
              (mark-word? (second words) "("))
         (parse-call (word-symbol (car words)) (cdr (cdr words)) line '()))
        (else
         (let ((found (parse-term words line)))
           (if (problem? found)
               found
               (let ((term (car found)) (rest (cdr found)))
                 (cond ((null? rest) term)
                       ((mark-word? (car rest) "|") (parse-choice rest line (list term)))
                       ((mark-word? (car rest) "..") (parse-range term (cdr rest) line))
                       ((calculation-mark (car rest))
                        (let ((right (parse-term (cdr rest) line)))
                          (cond ((problem? right) right)
                                ((not (null? (cdr right)))
                                 (problem line "a calculation is one of + - * / between two values"))
                                (else (list 'calculation (calculation-mark (car rest))
                                            term (car right))))))
                       (else (problem line "this is not a definition rule files can have")))))))))

(define (parse-choice words line terms)
  ;; words start at a |
  (cond ((null? words) (list 'choice (reverse terms)))
        ((mark-word? (car words) "|")
         (let ((next (parse-term (cdr words) line)))
           (if (problem? next)
               next
               (parse-choice (cdr next) line (cons (car next) terms)))))
        (else (problem line "a choice is values joined by |"))))

(define (parse-range low words line)
  (if (null? words)
      (list 'range low #f)
      (let ((high (parse-term words line)))
        (cond ((problem? high) high)
              ((not (null? (cdr high))) (problem line "a range is two values joined by .."))
              (else (list 'range low (car high)))))))

(define (parse-call callee words line arguments)
  ;; words follow the opening bracket
  (if (or (null? words) (null? (cdr words))
          (not (equal? (word-kind (car words)) 'name))
          (not (mark-word? (second words) ":")))
      (problem line "a call gives each starred part by name, as name: value")
      (let ((value (parse-term (cdr (cdr words)) line)))
        (if (problem? value)
            value
            (let ((argument (cons (word-symbol (car words)) (car value)))
                  (rest (cdr value)))
              (cond ((null? rest) (problem line "a call ends with )"))
                    ((mark-word? (car rest) ",")
                     (parse-call callee (cdr rest) line (cons argument arguments)))
                    ((and (mark-word? (car rest) ")") (null? (cdr rest)))
                     (list 'call callee (reverse (cons argument arguments))))
                    (else (problem line "a call ends with )"))))))))

(define relation-words
  '(("is" . is) ("in" . in) ("divisible_by" . divisible_by)
    ("not_divisible_by" . not_divisible_by)
    ("<" . less) ("<=" . at_most) (">" . greater) (">=" . at_least)))

(define (parse-fact words line)
  ;; returns (fact left relation right), or a problem
  (let ((left (parse-term words line)))
    (cond ((problem? left) left)
          ((or (null? (cdr left))
               (equal? (word-kind (car (cdr left))) 'quoted)
               (not (assoc (word-string (car (cdr left))) relation-words)))
           (problem line "a fact has a word such as is, in or < after its first value"))
          (else
           (let ((relation (entry-value relation-words (word-string (car (cdr left))) #f))
                 (rest (cdr (cdr left))))
             (if (equal? relation 'in)
                 (let ((right (parse-definition rest line)))
                   (cond ((problem? right) right)
                         ((member (car right) '(nothing calculation call))
                          (problem line "in takes a choice, a range or a name"))
                         (else (list 'fact (car left) 'in right))))
                 (let ((right (parse-term rest line)))
                   (cond ((problem? right) right)
                         ((not (null? (cdr right)))
                          (problem line "a fact has one value on each side"))
                         (else (list 'fact (car left) relation (car right)))))))))))

(define (parse-fact-lines nodes)
  ;; facts one a line, each as (line . fact)
  (if (null? nodes)
      '()
      (let* ((node (car nodes)) (line (node-number node)))
        (if (not (null? (node-children node)))
            (problem line "a fact has no lines under it")
            (let ((fact (parse-fact (node-words node) line)))
              (if (problem? fact)
                  fact
                  (let ((rest (parse-fact-lines (cdr nodes))))
                    (if (problem? rest) rest (cons (cons line fact) rest)))))))))

(define (wrap-line? nodes)
  ;; one line under an item, and it is a wrap_at line
  (and (not (null? nodes)) (null? (cdr nodes))
       (word-is? (car (node-words (car nodes))) 'name "wrap_at")))

(define (given-node? node)
  (and (not (null? (node-words node)))
       (word-is? (car (node-words node)) 'name "given")))

(define (parse-givens nodes)
  (if (null? nodes)
      '()
      (let* ((node (car nodes)) (line (node-number node)))
        (if (not (null? (node-children node)))
            (problem line "a given line has no lines under it")
            (let ((fact (parse-fact (cdr (node-words node)) line)))
              (if (problem? fact)
                  fact
                  (let ((rest (parse-givens (cdr nodes))))
                    (if (problem? rest) rest (cons (cons line fact) rest)))))))))

(define (parse-cases nodes)
  ;; each case as (line value facts)
  (if (null? nodes)
      '()
      (let* ((node (car nodes)) (line (node-number node)) (words (node-words node)))
        (if (not (and (= (length words) 2) (mark-word? (second words) ":")))
            (problem line "a case is a value and a colon, with its facts under it")
            (let ((value (parse-term (list (car words)) line))
                  (facts (parse-fact-lines (node-children node))))
              (cond ((problem? value) value)
                    ((problem? facts) facts)
                    ((null? facts) (problem line "a case has its facts under it"))
                    (else
                     (let ((rest (parse-cases (cdr nodes))))
                       (if (problem? rest)
                           rest
                           (cons (list line (car value) facts) rest))))))))))

(define (parse-wrap nodes)
  ;; the wrap_at line under a worked-out field: returns (list term) or
  ;; (list #f), or a problem
  (cond ((null? nodes) (list #f))
        ((and (null? (cdr nodes))
              (null? (node-children (car nodes)))
              (word-is? (car (node-words (car nodes))) 'name "wrap_at"))
         (let* ((line (node-number (car nodes)))
                (term (parse-term (cdr (node-words (car nodes))) line)))
           (cond ((problem? term) term)
                 ((not (null? (cdr term))) (problem line "wrap_at takes one value"))
                 (else (list (car term))))))
        (else (problem (node-number (car nodes))
                       "a worked-out field has only a wrap_at line under it"))))

;;; Items of a type:
;;;   (part line name starred definition givens)
;;;   (worked line name definition wrap)
;;;   (call line name callee arguments)
;;;   (cases line name definition cases)
;;;   (impossible line facts)

(define (item-name item) (if (equal? (car item) 'impossible) #f (third item)))

(define (parse-item node)
  (let ((words (node-words node)) (line (node-number node)) (children (node-children node)))
    (cond ((and (= (length words) 2) (word-is? (car words) 'name "impossible")
                (mark-word? (second words) ":"))
           (let ((facts (parse-fact-lines children)))
             (cond ((problem? facts) facts)
                   ((null? facts) (problem line "an impossible block has its facts under it"))
                   (else (list 'impossible line facts)))))
          ((and (>= (length words) 2) (equal? (word-kind (car words)) 'name))
           (let* ((starred (mark-word? (second words) "*"))
                  (after-name (if starred (cdr (cdr words)) (cdr words))))
             (if (or (null? after-name) (not (mark-word? (car after-name) ":")))
                 (problem line "an item is a name, a colon and its definition")
                 (let ((definition (parse-definition (cdr after-name) line)))
                   (if (problem? definition)
                       definition
                       (parse-item-body (word-symbol (car words)) starred definition
                                        children line))))))
          (else (problem line "this is not a form rule files can have")))))

(define (parse-item-body name starred definition children line)
  (let ((kind (car definition)))
    (cond ((equal? kind 'nothing) (problem line "an item needs a definition after its colon"))
          ((and starred (member kind '(call calculation path)))
           (problem line "a starred part is given by a call, so it is not worked out"))
          ((equal? kind 'call)
           (if (null? children)
               (list 'call line name (second definition) (third definition))
               (problem line "a call has no lines under it")))
          ((or (member kind '(calculation path))
               (and (member kind '(name literal)) (not starred) (wrap-line? children)))
           (let ((wrap (parse-wrap children)))
             (if (problem? wrap) wrap (list 'worked line name definition (car wrap)))))
          ((null? children) (list 'part line name starred definition '()))
          ((all given-node? children)
           (let ((givens (parse-givens children)))
             (if (problem? givens) givens (list 'part line name starred definition givens))))
          (starred (problem line "a starred part has only given lines under it"))
          (else
           (let ((cases (parse-cases children)))
             (if (problem? cases) cases (list 'cases line name definition cases)))))))

(define (parse-items nodes)
  (if (null? nodes)
      '()
      (let ((item (parse-item (car nodes))))
        (if (problem? item)
            item
            (let ((rest (parse-items (cdr nodes))))
              (if (problem? rest) rest (cons item rest)))))))

;;; Blocks of a rule file:
;;;   (definition line name definition)   a one-line definition
;;;   (type line name items)

(define (parse-block node)
  (let ((words (node-words node)) (line (node-number node)))
    (if (not (and (>= (length words) 2) (equal? (word-kind (car words)) 'name)
                  (mark-word? (second words) ":")))
        (problem line "a block starts with a name and a colon")
        (let ((name (word-symbol (car words))))
          (cond ((null? (node-children node))
                 (let ((definition (parse-definition (cdr (cdr words)) line)))
                   (cond ((problem? definition) definition)
                         ((member (car definition) '(nothing call path))
                          (problem line "a one-line definition is a value, a choice, a range or a calculation"))
                         (else (list 'definition line name definition)))))
                ((not (null? (cdr (cdr words))))
                 (problem line "a type has nothing after its colon"))
                (else
                 (let ((items (parse-items (node-children node))))
                   (if (problem? items) items (list 'type line name items)))))))))

(define (parse-blocks nodes)
  (if (null? nodes)
      '()
      (let ((block (parse-block (car nodes))))
        (if (problem? block)
            block
            (let ((rest (parse-blocks (cdr nodes))))
              (if (problem? rest) rest (cons block rest)))))))

;;; Definitions, for every rule file in turn: (name kind data)
;;;   kind built-in:  data is its fields, as (name type) with the type of a
;;;                   field holding an element, or #f
;;;   kind constant:  data is a value
;;;   kind choice:    data is its members: (value v), (type T) or (class C)
;;;   kind range:     data is (low high), high #f for no end
;;;   kind rule-type: data is (name path parts fields), parts as
;;;                   (name starred allowed givens line) and fields as (name type)

(define built-in-fields
  '((Line (number #f) (depth #f) (holder Line) (above Line) (length #f) (place #f)
          (word_count #f) (under_count #f) (choice_count #f) (type_place #f)
          (paragraph Paragraph))
    (Word (line Line) (place #f) (next Word) (kind #f) (text #f) (length #f)
          (name_word_count #f) (number #f) (places #f))
    (Paragraph (holder Line) (place #f) (before Paragraph) (first_line Line)
               (last_line Line) (item_count #f))
    (Quoted_Character (word Word) (place #f) (value #f) (code #f) (next Quoted_Character))
    (Input_Text (type #f) (printed_as #f) (length #f))
    (Input_Character (place #f) (value #f) (code #f) (next Input_Character))))

(define (starting-definitions)
  (append (map (lambda (entry) (list (car entry) 'built-in (cdr entry))) built-in-fields)
          (list (list 'True 'constant (make-name 'True))
                (list 'False 'constant (make-name 'False))
                (list 'Newline 'constant (make-name 'Newline))
                (list 'Letter 'choice (list (list 'class 'Letter)))
                (list 'Digit 'choice (list (list 'class 'Digit)))
                (list 'Number 'choice (list (list 'class 'Number)))
                (list 'Text 'choice (list (list 'class 'Text))))))

(define (open-class? choice)
  ;; Number and Text: classes with no end, so only a starred part has them
  (and (equal? (car choice) 'class) (member (second choice) '(Number Text))))

(define (type-info-name info) (first-of info))
(define (type-info-parts info) (third info))
(define (type-info-fields info) (fourth info))

(define (type-fields type definitions)
  ;; the fields of a built-in or rule type, as (name type), or #f
  (let ((found (assoc type definitions)))
    (cond ((not found) #f)
          ((equal? (second found) 'built-in) (third found))
          ((equal? (second found) 'rule-type) (type-info-fields (third found)))
          (else #f))))

(define (field-type fields name)
  (let ((entry (assoc name fields))) (if entry (second entry) #f)))

(define (constant-value term line definitions)
  (cond ((equal? (car term) 'literal) (second term))
        ((equal? (car term) 'name)
         (let ((found (assoc (second term) definitions)))
           (cond ((not found) (not-defined line (second term)))
                 ((equal? (second found) 'constant) (third found))
                 (else (problem line (string-append (symbol->string (second term))
                                                    " is not a value"))))))
        (else (problem line "a constant is needed here"))))

(define (constant-number term line definitions)
  (let ((value (constant-value term line definitions)))
    (cond ((problem? value) value)
          ((number-value? value) value)
          (else (problem line "a number is needed here")))))

(define (choice-members terms line definitions members)
  (if (null? terms)
      (reverse members)
      (let ((term (car terms)))
        (cond ((equal? (car term) 'literal)
               (choice-members (cdr terms) line definitions
                               (cons (list 'value (second term)) members)))
              ((equal? (car term) 'name)
               (let ((found (assoc (second term) definitions)))
                 (cond ((not found) (not-defined line (second term)))
                       ((equal? (second found) 'constant)
                        (choice-members (cdr terms) line definitions
                                        (cons (list 'value (third found)) members)))
                       ((equal? (second found) 'choice)
                        (choice-members (cdr terms) line definitions
                                        (append (reverse (third found)) members)))
                       ((member (second found) '(built-in rule-type))
                        (choice-members (cdr terms) line definitions
                                        (cons (list 'type (second term)) members)))
                       (else (problem line "a range cannot be a member of a choice")))))
              (else (problem line "a choice is values and names joined by |"))))))

(define (compile-definition definition line definitions)
  ;; a one-line definition: returns (kind data), or a problem
  (let ((kind (car definition)))
    (cond ((equal? kind 'literal) (list 'constant (second definition)))
          ((equal? kind 'name)
           (let ((found (assoc (second definition) definitions)))
             (cond ((not found) (not-defined line (second definition)))
                   ((member (second found) '(constant choice range)) (cdr found))
                   (else (problem line "a one-line definition cannot only name a type")))))
          ((equal? kind 'choice)
           (let ((members (choice-members (second definition) line definitions '())))
             (if (problem? members) members (list 'choice members))))
          ((equal? kind 'range)
           (let ((low (constant-number (second definition) line definitions))
                 (high (if (third definition)
                           (constant-number (third definition) line definitions)
                           #f)))
             (cond ((problem? low) low)
                   ((and high (problem? high)) high)
                   (else (list 'range (list low high))))))
          (else
           (let ((left (constant-number (third definition) line definitions))
                 (right (constant-number (fourth definition) line definitions)))
             (cond ((problem? left) left)
                   ((problem? right) right)
                   (else
                    (let ((result (calculate (second definition) left right)))
                      (if result
                          (list 'constant result)
                          (problem line "this calculation has no value: a division by 0, or one that is not exact"))))))))))

(define (class-values class)
  (map (lambda (character) (make-text (list character)))
       (string->list (if (equal? class 'Letter)
                         "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                         "0123456789"))))

(define (members-allowed members)
  (cond ((all (lambda (choice) (equal? (car choice) 'type)) members)
         (list 'elements (map second members)))
        ((and (all (lambda (choice) (member (car choice) '(value class))) members)
              (not (any open-class? members)))
         (list 'values (join-lists (map (lambda (choice)
                                          (if (equal? (car choice) 'value)
                                              (list (second choice))
                                              (class-values (second choice))))
                                        members))))
        (else (list 'members members))))

(define (part-allowed definition self line definitions)
  ;; what a part's values are: (element T), (elements (T ...)), (values (v ...)),
  ;; (members (m ...)) or (range low high); or a problem
  (let ((kind (car definition)))
    (cond ((equal? kind 'literal) (list 'values (list (second definition))))
          ((equal? kind 'name)
           (let* ((name (second definition)) (found (assoc name definitions)))
             (cond ((equal? name self) (problem line "a type refers to itself only through a call"))
                   ((not found) (not-defined line name))
                   ((member (second found) '(built-in rule-type)) (list 'element name))
                   ((equal? (second found) 'constant) (list 'values (list (third found))))
                   ((equal? (second found) 'choice) (members-allowed (third found)))
                   (else (cons 'range (third found))))))
          ((equal? kind 'choice)
           (let ((members (choice-members (second definition) line definitions '())))
             (if (problem? members) members (members-allowed members))))
          ((equal? kind 'range)
           (let ((range (compile-definition definition line definitions)))
             (if (problem? range) range (cons 'range (second range)))))
          (else (problem line "this is not a type a part can have")))))

(define (reread-copies items)
  ;; a part whose definition only names an item above it is a copy of that
  ;; item, so it is a worked-out field
  (let loop ((items items) (seen '()) (result '()))
    (if (null? items)
        (reverse result)
        (let* ((item (car items))
               (copy (and (equal? (car item) 'part)
                          (not (fourth item))
                          (null? (sixth item))
                          (equal? (car (fifth item)) 'name)
                          (member (second (fifth item)) seen)))
               (item (if copy (list 'worked (second item) (third item) (fifth item) #f) item)))
          (loop (cdr items)
                (if (item-name item) (cons (item-name item) seen) seen)
                (cons item result))))))

(define (repeated-item items)
  ;; a problem for the first name defined twice in a type, or #f
  (let loop ((items items) (seen '()))
    (cond ((null? items) #f)
          ((not (item-name (car items))) (loop (cdr items) seen))
          ((member (item-name (car items)) seen)
           (problem (second (car items))
                    (string-append (symbol->string (item-name (car items)))
                                   " is defined twice in its type")))
          (else (loop (cdr items) (cons (item-name (car items)) seen))))))

(define (worked-type definition fields definitions)
  ;; the type of the element a worked-out copy holds, if known
  (cond ((equal? (car definition) 'name) (field-type fields (second definition)))
        ((equal? (car definition) 'path)
         (let* ((owner (field-type fields (second definition)))
                (owner-fields (if owner (type-fields owner definitions) #f)))
           (if owner-fields (field-type owner-fields (third definition)) #f)))
        (else #f)))

(define (type-info name path items definitions)
  (let loop ((items items) (parts '()) (fields '()))
    (if (null? items)
        (list name path (reverse parts) (reverse fields))
        (let* ((item (car items)) (kind (car item)) (line (second item)))
          (cond ((equal? kind 'part)
                 (let ((allowed (part-allowed (fifth item) name line definitions)))
                   (if (problem? allowed)
                       allowed
                       (loop (cdr items)
                             (cons (list (third item) (fourth item) allowed (sixth item) line) parts)
                             (cons (list (third item)
                                         (if (equal? (car allowed) 'element) (second allowed) #f))
                                   fields)))))
                ((equal? kind 'call)
                 (loop (cdr items) parts (cons (list (third item) (fourth item)) fields)))
                ((equal? kind 'worked)
                 (loop (cdr items) parts
                       (cons (list (third item) (worked-type (fourth item) fields definitions))
                             fields)))
                ((equal? kind 'cases)
                 (loop (cdr items) parts (cons (list (third item) #f) fields)))
                (else (loop (cdr items) parts fields)))))))

;;; Compiling a rule: its steps so far, newest first, and for each scope the
;;; names found so far, so that a name used twice is found once and means
;;; the same value. A name is found as (variable v type), or still as
;;; (field self type): a field of the value the rule is about.

(define (empty-state) (list '() '()))
(define (state-steps state) (car state))
(define (state-scopes state) (second state))
(define (next-variable state) (+ 1 (length (state-steps state))))
(define (with-step state step) (list (cons step (state-steps state)) (state-scopes state)))
(define (scope-of state tag) (entry-value (state-scopes state) tag '()))
(define (with-scope-entry state tag key found)
  (list (state-steps state)
        (set-entry (state-scopes state) tag (set-entry (scope-of state tag) key found))))

(define (add-variable-step state make-step)
  ;; make-step makes the step from its new variable; returns (cons state variable)
  (let ((variable (next-variable state)))
    (cons (with-step state (make-step variable)) variable)))

(define (with-line context line) (list (first-of context) line))
(define (context-definitions context) (first-of context))
(define (context-line context) (second context))

(define (compile-name name tag state context)
  ;; returns (cons state variable), or a problem
  (let ((found (entry-value (scope-of state tag) name #f)))
    (cond ((and found (equal? (car found) 'variable)) (cons state (second found)))
          (found
           (let ((added (add-variable-step state (lambda (variable)
                                                   (list 'each-field variable (second found) name
                                                         (fourth found))))))
             (cons (with-scope-entry (car added) tag name (list 'variable (cdr added) (third found)))
                   (cdr added))))
          (else
           (let ((defined (assoc name (context-definitions context))))
             (cond ((not defined) (not-defined (context-line context) name))
                   ((equal? (second defined) 'constant)
                    (add-variable-step state (lambda (variable) (list 'bind variable (third defined)))))
                   (else (problem (context-line context)
                                  (string-append (symbol->string name) " is not a value here")))))))))

(define (compile-path owner field tag state context)
  (let ((cached (entry-value (scope-of state tag) (list 'path owner field) #f)))
    (if cached
        (cons state (second cached))
        (let ((found (compile-name owner tag state context)))
          (if (problem? found)
              found
              (let* ((owner-entry (entry-value (scope-of (car found) tag) owner #f))
                     (owner-type (if owner-entry (third owner-entry) #f))
                     (fields (if owner-type (type-fields owner-type (context-definitions context)) #f)))
                (if (and fields (not (assoc field fields)))
                    (problem (context-line context)
                             (string-append (symbol->string owner-type) " has no field "
                                            (symbol->string field)))
                    (let ((added (add-variable-step (car found)
                                                    (lambda (variable)
                                                      (list 'each-field variable (cdr found) field
                                                            owner-type)))))
                      (cons (with-scope-entry (car added) tag (list 'path owner field)
                                              (list 'variable (cdr added)
                                                    (if fields (field-type fields field) #f)))
                            (cdr added))))))))))

(define (compile-term term tag state context)
  (let ((kind (car term)))
    (cond ((equal? kind 'literal)
           (add-variable-step state (lambda (variable) (list 'bind variable (second term)))))
          ((equal? kind 'name) (compile-name (second term) tag state context))
          (else (compile-path (second term) (third term) tag state context)))))

(define (compile-facts facts tag state context)
  ;; facts: each as (line . fact); returns a state, or a problem
  (if (null? facts)
      state
      (let ((next (compile-fact (car facts) tag state context)))
        (if (problem? next) next (compile-facts (cdr facts) tag next context)))))

(define (compile-fact fact tag state context)
  (let* ((context (with-line context (car fact)))
         (left (compile-term (second (cdr fact)) tag state context)))
    (if (problem? left)
        left
        (let ((relation (third (cdr fact))) (right (fourth (cdr fact))))
          (if (equal? relation 'in)
              (compile-in (cdr left) right tag (car left) context)
              (let ((right-found (compile-term right tag (car left) context)))
                (if (problem? right-found)
                    right-found
                    (with-step (car right-found)
                               (list 'test relation (cdr left) (cdr right-found))))))))))

(define (outside-name? term tag state)
  ;; a name not found in the scope, so defined outside the type
  (and (equal? (car term) 'name) (not (entry-value (scope-of state tag) (second term) #f))))

(define (compile-in variable right tag state context)
  (let ((kind (car right)) (definitions (context-definitions context)))
    (cond ((equal? kind 'range)
           (let ((low (compile-term (second right) tag state context)))
             (cond ((problem? low) low)
                   ((third right)
                    (let ((high (compile-term (third right) tag (car low) context)))
                      (if (problem? high)
                          high
                          (with-step (car high) (list 'test-range variable (cdr low) (cdr high))))))
                   (else (with-step (car low) (list 'test-range variable (cdr low) #f))))))
          ((and (outside-name? right tag state)
                (assoc (second right) definitions)
                (equal? (second (assoc (second right) definitions)) 'range))
           (range-test-steps state variable
                             (first-of (third (assoc (second right) definitions)))
                             (second (third (assoc (second right) definitions)))))
          (else
           (let ((members (in-members (if (equal? kind 'choice) (second right) (list right))
                                      tag state context '())))
             (if (problem? members)
                 members
                 (with-step (car members) (list 'test-in variable (cdr members)))))))))

(define (range-test-steps state variable low high)
  (let ((low-bound (add-variable-step state (lambda (new) (list 'bind new low)))))
    (if high
        (let ((high-bound (add-variable-step (car low-bound) (lambda (new) (list 'bind new high)))))
          (with-step (car high-bound) (list 'test-range variable (cdr low-bound) (cdr high-bound))))
        (with-step (car low-bound) (list 'test-range variable (cdr low-bound) #f)))))

(define (in-members terms tag state context members)
  ;; returns (cons state members): (value v), (type T), (class C) or
  ;; (variable v)
  (if (null? terms)
      (cons state (reverse members))
      (let ((term (car terms)) (line (context-line context)))
        (cond ((equal? (car term) 'literal)
               (in-members (cdr terms) tag state context (cons (list 'value (second term)) members)))
              ((outside-name? term tag state)
               (let ((found (assoc (second term) (context-definitions context))))
                 (cond ((not found) (not-defined line (second term)))
                       ((equal? (second found) 'constant)
                        (in-members (cdr terms) tag state context
                                    (cons (list 'value (third found)) members)))
                       ((equal? (second found) 'choice)
                        (in-members (cdr terms) tag state context
                                    (append (reverse (third found)) members)))
                       ((member (second found) '(built-in rule-type))
                        (in-members (cdr terms) tag state context
                                    (cons (list 'type (second term)) members)))
                       (else (problem line "a range cannot be a member of a choice")))))
              (else
               (let ((found (compile-term term tag state context)))
                 (if (problem? found)
                     found
                     (in-members (cdr terms) tag (car found) context
                                 (cons (list 'variable (cdr found)) members)))))))))

(define (direct-given name givens)
  ;; for a first given of the form name is value, where value does not name
  ;; the part, that value; the part is then that value and need not be
  ;; looked for among every element of its type
  (if (null? givens)
      #f
      (let ((fact (cdr (car givens))))
        (if (and (equal? (third fact) 'is)
                 (equal? (second fact) (list 'name name))
                 (not (and (member (car (fourth fact)) '(name path))
                           (equal? (second (fourth fact)) name))))
            (fourth fact)
            #f))))

(define (indexed-given name givens)
  ;; for a first given of the form name.field is value, where value does not
  ;; name the part: (field . value), so the part is found through the index
  (if (null? givens)
      #f
      (let ((fact (cdr (car givens))))
        (if (and (equal? (third fact) 'is)
                 (equal? (car (second fact)) 'path)
                 (equal? (second (second fact)) name)
                 (not (and (member (car (fourth fact)) '(name path))
                           (equal? (second (fourth fact)) name))))
            (cons (third (second fact)) (fourth fact))
            #f))))

(define (compile-unstarred-part part tag state context)
  ;; part: (name starred allowed givens line); returns a state, or a problem
  (let* ((name (first-of part)) (allowed (third part)) (givens (fourth part))
         (context (with-line context (fifth part)))
         (kind (car allowed))
         (direct (if (equal? kind 'element) (direct-given name givens) #f))
         (indexed (if (and (equal? kind 'element) (not direct)) (indexed-given name givens) #f))
         (fields (if indexed (type-fields (second allowed) (context-definitions context)) #f)))
    (cond ((and indexed fields (not (assoc (car indexed) fields)))
           (problem (car (car givens))
                    (string-append (symbol->string (second allowed)) " has no field "
                                   (symbol->string (car indexed)))))
          (indexed
           (let ((found (compile-term (cdr indexed) tag state (with-line context (car (car givens))))))
             (if (problem? found)
                 found
                 (let ((added (add-variable-step (car found)
                                                 (lambda (variable)
                                                   (list 'each-indexed variable (second allowed)
                                                         (car indexed) (cdr found))))))
                   (compile-facts (cdr givens) tag
                                  (with-scope-entry (car added) tag name
                                                    (list 'variable (cdr added) (second allowed)))
                                  context)))))
          (direct
           (let ((found (compile-term direct tag state (with-line context (car (car givens))))))
             (if (problem? found)
                 found
                 (compile-facts (cdr givens) tag
                                (with-scope-entry (with-step (car found)
                                                             (list 'check-type (cdr found) (second allowed)))
                                                  tag name (list 'variable (cdr found) (second allowed)))
                                context))))
          ((member kind '(element elements values))
           (let ((added (add-variable-step state
                                           (lambda (variable)
                                             (cond ((equal? kind 'element)
                                                    (list 'each-of-type variable (second allowed)))
                                                   ((equal? kind 'elements)
                                                    (list 'each-of-types variable (second allowed)))
                                                   (else (list 'each-value variable (second allowed))))))))
             (compile-facts givens tag
                            (with-scope-entry (car added) tag name
                                              (list 'variable (cdr added)
                                                    (if (equal? kind 'element) (second allowed) #f)))
                            context)))
          (else (problem (fifth part)
                         "a part matched among facts has a type or values: only a starred part can be a range")))))

(define (compile-starred-part part variable tag state context)
  ;; the value a call gives a starred part: checked against the part's type,
  ;; then its given lines
  (let* ((name (first-of part)) (allowed (third part)) (kind (car allowed))
         (context (with-line context (fifth part)))
         (state
          (cond ((equal? kind 'element) (with-step state (list 'check-type variable (second allowed))))
                ((equal? kind 'elements)
                 (with-step state (list 'test-in variable
                                        (map (lambda (type) (list 'type type)) (second allowed)))))
                ((equal? kind 'values)
                 (with-step state (list 'test-in variable
                                        (map (lambda (value) (list 'value value)) (second allowed)))))
                ((equal? kind 'members) (with-step state (list 'test-in variable (second allowed))))
                (else (range-test-steps state variable (second allowed) (third allowed))))))
    (compile-facts (fourth part) tag
                   (with-scope-entry state tag name
                                     (list 'variable variable
                                           (if (equal? kind 'element) (second allowed) #f)))
                   context)))

(define (bind-parts parts arguments state context bound)
  ;; the parts of the type being made: starred ones from the call's
  ;; arguments, the others matched among facts; returns (cons state bound),
  ;; bound as (name . variable), or a problem
  (if (null? parts)
      (cons state (reverse bound))
      (let* ((part (car parts)) (name (first-of part))
             (next (if (second part)
                       (compile-starred-part part (cdr (assoc name arguments)) 'made state context)
                       (compile-unstarred-part part 'made state context))))
        (if (problem? next)
            next
            (bind-parts (cdr parts) arguments next context
                        (cons (cons name (second (entry-value (scope-of next 'made) name #f)))
                              bound))))))

(define (self-state info above)
  ;; a rule about each value of a type: the value is variable 1, and the
  ;; items above are found as its fields
  (let loop ((names above)
             (state (with-step (empty-state) (list 'each-of-type 1 (type-info-name info)))))
    (if (null? names)
        state
        (loop (cdr names)
              (with-scope-entry state 'self (car names)
                                (list 'field 1 (field-type (type-info-fields info) (car names))
                                      (type-info-name info)))))))

(define (sequent source state conclusion)
  ;; (sequent source steps conclusion reads first-type hashes): reads are the
  ;; types whose new elements, and the fields whose new values, could give
  ;; the rule a new match, and hashes their keys' hashes; first-type is the
  ;; type its first step goes through when no later step goes through it
  ;; too, or #f, so that the rule can run on that type's new elements only
  ;; (part 5)
  (let* ((steps (reverse (state-steps state))) (reads (steps-read steps)))
    (list 'sequent source steps conclusion reads (only-first-type steps)
          (map (lambda (key) (hash-symbols key 0)) reads))))

(define (only-first-type steps)
  (if (and (not (null? steps)) (equal? (car (car steps)) 'each-of-type)
           (not (member (list 'element (third (car steps))) (steps-read (cdr steps)))))
      (third (car steps))
      #f))

(define (steps-read steps)
  (without-repeats
   (join-lists
    (map (lambda (step)
           (let ((kind (car step)))
             (cond ((equal? kind 'each-of-type) (list (list 'element (third step))))
                   ((equal? kind 'each-of-types)
                    (map (lambda (type) (list 'element type)) (third step)))
                   ((equal? kind 'each-indexed)
                    (list (list 'element (third step)) (list 'field-of (third step) (fourth step))))
                   ((equal? kind 'each-field)
                    ;; a field of a known type, or of any type
                    (list (if (fifth step)
                              (list 'field-of (fifth step) (fourth step))
                              (list 'field (fourth step)))))
                   (else '()))))
         steps))))

(define (made-sequent info source context)
  ;; there exists: a value of a type with no starred parts for each match
  ;; of its parts
  (let ((bound (bind-parts (type-info-parts info) '() (empty-state) context '())))
    (if (problem? bound)
        bound
        (sequent source (car bound) (list 'make (type-info-name info) (cdr bound) #f)))))

(define (call-sequent item info above source context)
  (let* ((line (second item)) (callee-name (fourth item)) (arguments (fifth item))
         (found (assoc callee-name (context-definitions context))))
    (cond ((not found) (not-defined line callee-name))
          ((not (equal? (second found) 'rule-type))
           (problem line "only a type of a rule file can be called"))
          (else
           (let* ((parts (type-info-parts (third found)))
                  (starred (map first-of (keep second parts)))
                  (given (map car arguments)))
             (cond ((null? starred)
                    (problem line "a call gives starred parts, and this type has none"))
                   ((not (and (= (length given) (length (without-repeats given)))
                              (all (lambda (name) (member name given)) starred)
                              (all (lambda (name) (member name starred)) given)))
                    (problem line "a call gives every starred part by name, once, and nothing else"))
                   (else
                    (let ((values (compile-arguments arguments (self-state info above) context '())))
                      (if (problem? values)
                          values
                          (let ((bound (bind-parts parts (cdr values) (car values) context '())))
                            (if (problem? bound)
                                bound
                                (list (sequent source (car bound)
                                               (list 'make callee-name (cdr bound)
                                                     (cons 1 (third item))))))))))))))))

(define (compile-arguments arguments state context done)
  (if (null? arguments)
      (cons state (reverse done))
      (let ((found (compile-term (cdr (car arguments)) 'self state context)))
        (if (problem? found)
            found
            (compile-arguments (cdr arguments) (car found) context
                               (cons (cons (car (car arguments)) (cdr found)) done))))))

(define (worked-sequent item info above source context)
  (let* ((definition (fourth item)) (wrap (fifth item)) (state (self-state info above))
         (found (if (equal? (car definition) 'calculation)
                    (let ((left (compile-term (third definition) 'self state context)))
                      (if (problem? left)
                          left
                          (let ((right (compile-term (fourth definition) 'self (car left) context)))
                            (if (problem? right)
                                right
                                (add-variable-step (car right)
                                                   (lambda (variable)
                                                     (list 'calculate variable (second definition)
                                                           (cdr left) (cdr right))))))))
                    (compile-term definition 'self state context)))
         (wrapped (cond ((problem? found) found)
                        ((not wrap) found)
                        (else
                         (let ((divisor (compile-term wrap 'self (car found) context)))
                           (if (problem? divisor)
                               divisor
                               (add-variable-step (car divisor)
                                                  (lambda (variable)
                                                    (list 'calculate variable 'wrap
                                                          (cdr found) (cdr divisor))))))))))
    (if (problem? wrapped)
        wrapped
        (list (sequent source (car wrapped) (list 'set-field 1 (third item) (cdr wrapped)))))))

(define (case-sequents item info above source context)
  ;; a union: each case is a rule of its own, giving the field its value
  ;; for the values its facts hold for
  (let loop ((cases (fifth item)) (sequents '()))
    (if (null? cases)
        (reverse sequents)
        (let* ((one-case (car cases))
               (line (first-of one-case))
               (value (constant-value (second one-case) line (context-definitions context)))
               (state (if (problem? value)
                          value
                          (compile-facts (third one-case) 'self (self-state info above)
                                         (with-line context line)))))
          (cond ((problem? value) value)
                ((problem? state) state)
                (else
                 (let ((bound (add-variable-step state (lambda (variable)
                                                         (list 'bind variable value)))))
                   (loop (cdr cases)
                         (cons (sequent (replace-at source 2 line) (car bound)
                                        (list 'set-field 1 (third item) (cdr bound)))
                               sequents)))))))))

(define (impossible-sequent item info above source context)
  (let ((state (compile-facts (third item) 'self (self-state info above) context)))
    (if (problem? state)
        state
        (list (sequent source state (list 'refuse 1))))))

(define (item-sequents item info above path definitions)
  (let* ((kind (car item)) (line (second item))
         (context (list definitions line))
         (source (list path (type-info-name info) line
                       (if (item-name item) (symbol->string (item-name item)) "impossible"))))
    (cond ((equal? kind 'part) '())
          ((equal? kind 'worked) (worked-sequent item info above source context))
          ((equal? kind 'call) (call-sequent item info above source context))
          ((equal? kind 'cases) (case-sequents item info above source context))
          (else (impossible-sequent item info above source context)))))

(define (compile-type name line items path definitions)
  ;; returns (cons info sequents), or a problem
  (let* ((items (reread-copies items))
         (repeated (repeated-item items)))
    (if repeated
        repeated
        (let ((info (type-info name path items definitions)))
          (if (problem? info)
              info
              (let* ((definitions (append definitions (list (list name 'rule-type info))))
                     (made (if (any second (type-info-parts info))
                               '()
                               (list (made-sequent info (list path name line "its values")
                                                   (list definitions line))))))
                (if (and (not (null? made)) (problem? (car made)))
                    (car made)
                    (let loop ((items items) (above '()) (sequents made))
                      (if (null? items)
                          (cons info sequents)
                          (let ((new (item-sequents (car items) info above path definitions)))
                            (if (problem? new)
                                new
                                (loop (cdr items)
                                      (if (item-name (car items))
                                          (append above (list (item-name (car items))))
                                          above)
                                      (append sequents new)))))))))))))

(define (compile-blocks blocks path definitions sequents)
  ;; returns (cons definitions sequents), or a problem
  (if (null? blocks)
      (cons definitions sequents)
      (let* ((block (car blocks)) (line (second block)) (name (third block)))
        (cond ((assoc name definitions)
               (problem line (string-append (symbol->string name) " is defined twice")))
              ((equal? (car block) 'definition)
               (let ((definition (compile-definition (fourth block) line definitions)))
                 (if (problem? definition)
                     definition
                     (compile-blocks (cdr blocks) path
                                     (append definitions (list (cons name definition)))
                                     sequents))))
              (else
               (let ((compiled (compile-type name line (fourth block) path definitions)))
                 (if (problem? compiled)
                     compiled
                     (compile-blocks (cdr blocks) path
                                     (append definitions
                                             (list (list name 'rule-type (car compiled))))
                                     (append sequents (cdr compiled))))))))))

(define (compile-rule-files paths)
  ;; returns the program, (sequents definitions), or (problem line reason path)
  (let loop ((paths paths) (definitions (starting-definitions)) (sequents '()))
    (if (null? paths)
        (list sequents definitions)
        (let* ((read (read-etale-file (car paths)))
               (compiled
                (if (null? (cdr read))
                    (let ((blocks (parse-blocks (build-tree (written-lines (car read))))))
                      (if (problem? blocks)
                          blocks
                          (compile-blocks blocks (car paths) definitions '())))
                    (problem (refusal-line (car (cdr read))) (second (car (cdr read)))))))
          (if (problem? compiled)
              (list 'problem (second compiled) (third compiled) (car paths))
              (loop (cdr paths) (car compiled) (append sequents (cdr compiled))))))))

(define (program-sequents program) (first-of program))
(define (program-definitions program) (second program))

(define (program-indexed program)
  ;; the (type field) pairs the rules look elements up by
  (without-repeats
   (join-lists (map (lambda (sequent)
                      (map (lambda (step) (list (third step) (fourth step)))
                           (keep (lambda (step) (equal? (car step) 'each-indexed)) (third sequent))))
                    (program-sequents program)))))

;;; Matching. The environment holds each variable's value. Each step that
;;; matches goes on to the steps after it; finish gets every full match.

(define (lookup environment variable) (cdr (assoc variable environment)))

(define (match-steps steps environment store finish)
  (cond ((store-out-of-steps? store) store)
        ((null? steps) (finish environment (count-step store)))
        (else
         (let* ((step (car steps)) (kind (car step)) (later (cdr steps)))
           (cond ((equal? kind 'each-of-type)
                  (match-elements-of-type (second step) (third step) later environment store finish))
                 ((equal? kind 'each-of-types)
                  (match-elements-of-types (second step) (third step) later environment store finish))
                 ((equal? kind 'each-indexed)
                  (match-ids (second step)
                             (store-indexed store (third step) (fourth step)
                                            (lookup environment (fifth step)))
                             later environment store finish))
                 ((equal? kind 'each-value)
                  (match-values (second step) (third step) later environment store finish))
                 ((equal? kind 'each-field)
                  (let ((owner (lookup environment (third step))))
                    (if (element-value? owner)
                        (match-each-value (second step)
                                          (store-field-values store owner (fourth step))
                                          later environment store finish)
                        store)))
                 ((equal? kind 'bind)
                  (match-steps later (cons (cons (second step) (third step)) environment)
                               store finish))
                 ((equal? kind 'calculate)
                  (let ((result (calculate (third step)
                                           (lookup environment (fourth step))
                                           (lookup environment (fifth step)))))
                    (if result
                        (match-steps later (cons (cons (second step) result) environment)
                                     store finish)
                        store)))
                 ((equal? kind 'check-type)
                  (if (element-of-type? store (lookup environment (second step)) (third step))
                      (match-steps later environment store finish)
                      store))
                 ((equal? kind 'test)
                  (if (relation-holds? (second step)
                                       (lookup environment (third step))
                                       (lookup environment (fourth step)))
                      (match-steps later environment store finish)
                      store))
                 ((equal? kind 'test-range)
                  (if (in-range? (lookup environment (second step))
                                 (lookup environment (third step))
                                 (if (fourth step) (lookup environment (fourth step)) #f))
                      (match-steps later environment store finish)
                      store))
                 ((equal? kind 'test-in)
                  (if (any (lambda (choice)
                             (member-holds? choice (lookup environment (second step))
                                            environment store))
                           (third step))
                      (match-steps later environment store finish)
                      store))
                 (else store))))))

(define (match-elements-of-type variable type later environment store finish)
  ;; every element of the type, then any made while matching, until no more
  ;; are made
  (let loop ((ids (store-elements-of store type)) (seen (store-count-of store type)) (store store))
    (let* ((store (match-ids variable ids later environment store finish))
           (now (store-count-of store type)))
      (if (and (> now seen) (not (store-out-of-steps? store)))
          (loop (take (store-elements-of store type) (- now seen)) now store)
          store))))

(define (match-ids variable ids later environment store finish)
  (if (or (null? ids) (store-out-of-steps? store))
      store
      (match-ids variable (cdr ids) later environment
                 (match-steps later (cons (cons variable (make-element (car ids))) environment)
                              store finish)
                 finish)))

(define (match-elements-of-types variable types later environment store finish)
  (if (null? types)
      store
      (match-elements-of-types variable (cdr types) later environment
                               (match-elements-of-type variable (car types) later environment
                                                       store finish)
                               finish)))

(define (match-values variable values later environment store finish)
  ;; part 6, union: each member is a branch of the match, and each branch
  ;; counts as a step
  (if (or (null? values) (store-out-of-steps? store))
      store
      (match-values variable (cdr values) later environment
                    (match-steps later (cons (cons variable (car values)) environment)
                                 (count-step store) finish)
                    finish)))

(define (match-each-value variable values later environment store finish)
  (if (or (null? values) (store-out-of-steps? store))
      store
      (match-each-value variable (cdr values) later environment
                        (match-steps later (cons (cons variable (car values)) environment)
                                     store finish)
                        finish)))

(define (element-of-type? store value type)
  (and (element-value? value) (equal? (store-type-of store value) type)))

(define (relation-holds? relation left right)
  (cond ((equal? relation 'is) (equal? left right))
        ((equal? relation 'divisible_by) (divisible? left right))
        ((equal? relation 'not_divisible_by)
         (and (number-value? left) (number-value? right) (not (zero-number? right))
              (not (divisible? left right))))
        (else
         (let ((order (compare-values left right)))
           (cond ((not order) #f)
                 ((equal? relation 'less) (< order 0))
                 ((equal? relation 'at_most) (<= order 0))
                 ((equal? relation 'greater) (> order 0))
                 (else (>= order 0)))))))

(define (compare-values left right)
  ;; -1, 0 or 1 for two numbers, or for two texts in the order of their
  ;; characters' code numbers (PLAN.md 3.5); #f for anything else
  (cond ((and (number-value? left) (number-value? right)) (compare-numbers left right))
        ((and (text-value? left) (text-value? right))
         (compare-character-lists (text-characters left) (text-characters right)))
        (else #f)))

(define (compare-character-lists left right)
  (cond ((and (null? left) (null? right)) 0)
        ((null? left) -1)
        ((null? right) 1)
        ((< (code-of (car left)) (code-of (car right))) -1)
        ((> (code-of (car left)) (code-of (car right))) 1)
        (else (compare-character-lists (cdr left) (cdr right)))))

(define (in-range? value low high)
  (and (number-value? value) (number-value? low)
       (>= (compare-numbers value low) 0)
       (or (not high) (and (number-value? high) (<= (compare-numbers value high) 0)))))

(define (member-holds? choice value environment store)
  (let ((kind (car choice)))
    (cond ((equal? kind 'value) (equal? value (second choice)))
          ((equal? kind 'variable) (equal? value (lookup environment (second choice))))
          ((equal? kind 'type) (element-of-type? store value (second choice)))
          ((equal? (second choice) 'Number) (number-value? value))
          ((equal? (second choice) 'Text) (text-value? value))
          (else
           (and (text-value? value)
                (not (null? (text-characters value)))
                (null? (cdr (text-characters value)))
                (if (equal? (second choice) 'Letter)
                    (letter-character? (car (text-characters value)))
                    (digit-character? (car (text-characters value)))))))))

;;; What follows from a match

(define (apply-conclusion conclusion source environment store program)
  (let ((kind (car conclusion)))
    (cond ((equal? kind 'make)
           (make-value (second conclusion) (third conclusion) (fourth conclusion) environment store))
          ((equal? kind 'set-field)
           (store-add-field store (lookup environment (second conclusion)) (third conclusion)
                            (lookup environment (fourth conclusion))))
          (else (add-refusal store source (lookup environment (second conclusion)) program)))))

(define (make-value type parts link environment store)
  ;; part 6, there exists: the value of the type with these parts, a new
  ;; element the first time and the same element after that
  (let* ((values (map (lambda (part) (lookup environment (cdr part))) parts))
         (found (store-find-made store type values))
         (made (if found
                   (cons store found)
                   (let ((created (store-new-element store type
                                                     (map (lambda (part value) (list (car part) value))
                                                          parts values))))
                     (cons (store-remember-made (car created) type values (cdr created))
                           (cdr created))))))
    (if link
        (store-add-field (car made) (lookup environment (car link)) (cdr link) (cdr made))
        (car made))))

(define (add-refusal store source value program)
  (let* ((place (locate value store (program-definitions program)))
         (refusal (list 'rule source (car place) (cdr place))))
    (if (member refusal (store-refusals store))
        store
        (replace-at store 4 (cons refusal (store-refusals store))))))

(define (locate value store definitions)
  ;; the line of the checked file, and the place in the text being read, that
  ;; a refusal names: from the first part, in order, that is or holds a Line,
  ;; Word (its line), Paragraph (its first line) or Input_Character
  (if (not (element-value? value))
      (cons #f #f)
      (let ((type (store-type-of store value)))
        (cond ((equal? type 'Line)
               (cons (number-to-small (car (store-field-values store value 'number))) #f))
              ((equal? type 'Word)
               (locate (car (store-field-values store value 'line)) store definitions))
              ((equal? type 'Paragraph)
               (locate (car (store-field-values store value 'first_line)) store definitions))
              ((equal? type 'Quoted_Character)
               (locate (car (store-field-values store value 'word)) store definitions))
              ((equal? type 'Input_Character)
               (cons #f (number-to-small (car (store-field-values store value 'place)))))
              (else
               (let ((found (assoc type definitions)))
                 (if (and found (equal? (second found) 'rule-type))
                     (locate-parts (map first-of (type-info-parts (third found)))
                                   value store definitions (cons #f #f))
                     (cons #f #f))))))))

(define (locate-parts names value store definitions place)
  (if (or (null? names) (and (car place) (cdr place)))
      place
      (let* ((values (store-field-values store value (car names)))
             (found (if (null? values) (cons #f #f) (locate (car values) store definitions))))
        (locate-parts (cdr names) value store definitions
                      (cons (if (car place) (car place) (car found))
                            (if (cdr place) (cdr place) (cdr found)))))))

;;; Part 5: the rule loop. Every rule runs on the facts, in the order of the
;;; rule files, until a whole pass adds nothing new or the steps run out. A
;;; rule runs again only when something it reads has changed since it last
;;; started: facts are only ever added, so with nothing new to read it can
;;; find no new match. And when the only thing new is elements of the type
;;; its first step goes through, it runs on those new elements only: every
;;; match with an older one was found when the rule last ran.

(define (run-rules program store)
  (let pass ((store store)
             (started (map (lambda (sequent) (cons -1 0)) (program-sequents program))))
    (let* ((before (store-added store))
           (result (run-sequents (program-sequents program) started store program '()))
           (store (car result)))
      (if (or (store-out-of-steps? store) (= before (store-added store)))
          store
          (pass store (cdr result))))))

(define (run-sequents sequents started store program now-started)
  ;; started: for each rule, the facts added when it last started, or -1,
  ;; and how many elements its first step's type had when it last finished;
  ;; returns (cons store started)
  (cond ((null? sequents) (cons store (reverse now-started)))
        ((or (store-out-of-steps? store)
             (not (reads-something-new? (car sequents) (car (car started)) store)))
         (run-sequents (cdr sequents) (cdr started) store program (cons (car started) now-started)))
        (else
         (let ((ran (run-sequent (car sequents) (car started) store program)))
           (run-sequents (cdr sequents) (cdr started) ran program
                         (cons (cons (store-added store) (first-type-count (car sequents) ran))
                               now-started))))))

(define (reads-something-new? sequent started store)
  (or (< started 0)
      (any-of-two (lambda (key hash) (> (hashed-change-stamp store key hash) started))
                  (fifth sequent) (seventh sequent))))

(define (first-type-count sequent store)
  ;; how many elements the rule's first-type has, or 0
  (if (sixth sequent) (store-count-of store (sixth sequent)) 0))

(define (only-new-first? sequent started store)
  ;; whether only new elements of the rule's first-type can give it a new
  ;; match: it has run before, and nothing else it reads has changed since
  ;; it last started
  (and (>= (car started) 0)
       (sixth sequent)
       (let ((first-key (list 'element (sixth sequent))))
         (all-of-two (lambda (key hash)
                       (or (equal? key first-key)
                           (<= (hashed-change-stamp store key hash) (car started))))
                     (fifth sequent) (seventh sequent)))))

(define (run-sequent sequent started store program)
  (let ((steps (third sequent))
        (finish (lambda (environment store)
                  (apply-conclusion (fourth sequent) (second sequent) environment store program))))
    (if (only-new-first? sequent started store)
        (match-new-elements (second (car steps)) (third (car steps)) (cdr steps) store finish
                            (cdr started))
        (match-steps steps '() store finish))))

(define (match-new-elements variable type later store finish seen)
  ;; the elements of type made since it had seen of them, then any made
  ;; while matching, until no more are made
  (let loop ((seen seen) (store store))
    (let ((now (store-count-of store type)))
      (if (or (<= now seen) (store-out-of-steps? store))
          store
          (loop now (match-ids variable (take (store-elements-of store type) (- now seen))
                               later '() store finish))))))

;;; ------------------------------------------------------------------------
;;; Part 8: verdicts
;;;
;;; A verdict is one of
;;;   (accepted printed steps)           printed: the characters to print
;;;   (refused refusals exit-value text) exit value 1 or 2
;;;   (ran-out steps)                    exit value 3
;;;   (rule-file-refused path line reason)

(define whole-rule-set
  ;; the rule files every file is checked by, in order (PLAN.md 5.3); the
  ;; paths are from the top of the repo
  '("rules/limits.etale" "rules/terms.etale" "rules/definitions.etale"
    "rules/compounds.etale" "rules/facts.etale" "rules/blocks.etale"
    "rules/fact_lines.etale" "rules/settings.etale" "rules/positions.etale"
    "rules/uses.etale" "rules/name_search.etale" "rules/name_steps.etale"
    "rules/values.etale" "rules/operands.etale" "rules/case_facts.etale"
    "rules/case_ranges.etale" "rules/boundaries.etale" "rules/starts.etale"
    "rules/multiples.etale" "rules/representatives.etale" "rules/case_tests.etale"
    "rules/choice_tests.etale" "rules/case_walks.etale" "rules/case_answers.etale"
    "rules/case_overlaps.etale" "rules/classes.etale" "rules/name_gaps.etale"
    "rules/states.etale" "rules/reading.etale" "rules/line_ways.etale"
    "rules/item_ways.etale" "rules/under_ways.etale" "rules/definition_ways.etale"
    "rules/term_ways.etale" "rules/list_ways.etale" "rules/call_ways.etale"
    "rules/content_ways.etale" "rules/fact_ways.etale" "rules/left_ways.etale"
    "rules/right_ways.etale" "rules/contexts.etale" "rules/moves.etale"
    "rules/line_shapes.etale" "rules/numbering.etale" "rules/text_types.etale"
    "rules/item_ranks.etale" "rules/field_ranks.etale" "rules/list_ranks.etale"
    "rules/paragraphs.etale" "rules/code_checks.etale"))

(define default-budget 10000000)

(define default-printed-as "text")

(define (check-file file-path type-name text-path printed-as rule-paths budget)
  ;; text-path: #f for no text, "-" for standard input; type-name: the type
  ;; the text is read as; printed-as: the name of the text it is printed with
  (let ((program (compile-rule-files rule-paths)))
    (if (problem? program)
        (list 'rule-file-refused (fourth program) (second program) (third program))
        (let ((read (read-etale-file file-path)))
          (if (not (null? (cdr read)))
              (list 'refused (cdr read) 2 '())
              (let* ((text (cond ((not text-path) '())
                                 ((equal? text-path "-") (read-characters #f))
                                 (else (read-characters text-path))))
                     (refused-characters (input-refusals text)))
                (if (not (null? refused-characters))
                    (list 'refused refused-characters 1 text)
                    (let* ((store (store-with-file (empty-store budget (program-indexed program)) (car read)))
                           (store (if text-path
                                      (store-with-text store text type-name printed-as)
                                      store))
                           (store (run-rules program store))
                           (refusals (sort-refusals (reverse (store-refusals store)))))
                      (cond ((store-out-of-steps? store) (list 'ran-out (store-steps store)))
                            ((not (null? refusals))
                             (list 'refused refusals
                                   (if (any (lambda (refusal) (not (refusal-place refusal))) refusals)
                                       2
                                       1)
                                   text))
                            (else (list 'accepted (printed-characters store)
                                        (store-steps store))))))))))))

(define (printed-characters store)
  ;; the value of each Printed_Character a rule made, in the order of their
  ;; places
  (let* ((printed (map make-element (reverse (store-elements-of store 'Printed_Character))))
         (placed (keep (lambda (element)
                         (let ((places (store-field-values store element 'place)))
                           (and (not (null? places)) (number-value? (car places)))))
                       printed))
         (sorted (sort-items placed
                             (lambda (left right)
                               (< (compare-numbers (car (store-field-values store left 'place))
                                                   (car (store-field-values store right 'place)))
                                  0)))))
    (join-lists (map (lambda (element)
                       (value-printed (store-field-values store element 'value)))
                     sorted))))

(define (value-printed values)
  (if (null? values)
      '()
      (let ((value (car values)))
        (cond ((text-value? value) (text-characters value))
              ((and (name-value? value) (equal? (name-symbol value) 'Newline)) (list #\newline))
              ((number-value? value) (number-characters value))
              (else '())))))

(define (display-refusal refusal text port)
  (let ((line (refusal-line refusal)) (place (refusal-place refusal)))
    (display "refused" port)
    (cond ((and line place)
           (display " by " port) (display line port)
           (display " at " port) (display (text-line-of text place) port))
          (line (display " at " port) (display line port))
          (place (display " at text line " port) (display (text-line-of text place) port))
          (else #f))
    (display ": " port)
    (if (equal? (car refusal) 'reading)
        (display (second refusal) port)
        (let ((source (second refusal)))
          (display (symbol->string (second source)) port)
          (display ", " port)
          (display (fourth source) port)
          (display ", " port)
          (display (first-of source) port)
          (display " line " port)
          (display (third source) port)))
    (if place
        (begin (display ", character " port) (display place port))
        #f)
    (newline port)))

(define (show-verdict verdict)
  (let ((kind (car verdict)) (port (current-error-port)))
    (cond ((equal? kind 'accepted)
           (display (list->string (second verdict)))
           (exit 0))
          ((equal? kind 'ran-out)
           (display "ran out of steps after " port)
           (display (second verdict) port)
           (display " steps" port)
           (newline port)
           (exit 3))
          ((equal? kind 'rule-file-refused)
           (display-rule-file-problem verdict port)
           (exit 2))
          (else
           (for-each (lambda (refusal) (display-refusal refusal (fourth verdict) port))
                     (second verdict))
           (exit (third verdict))))))

(define (display-rule-file-problem verdict port)
  (display "rule file " port)
  (display (second verdict) port)
  (display " refused at " port)
  (display (third verdict) port)
  (display ": " port)
  (display (fourth verdict) port)
  (newline port))

;;; ------------------------------------------------------------------------
;;; The facts command: every built-in fact, to check part 4 by eye

(define (display-facts store)
  (for-each (lambda (type)
              (for-each (lambda (id) (display-element (make-element id) store))
                        (reverse (store-elements-of store type))))
            '(Line Paragraph Word Quoted_Character Input_Text Input_Character)))

(define (display-element element store)
  (display (element-name element store))
  (display ":")
  (let loop ((fields (store-fields store element)) (first #t))
    (if (null? fields)
        (newline)
        (begin
          (display (if first " " ", "))
          (display (symbol->string (car (car fields))))
          (for-each (lambda (value) (display " ") (display (value-name value store)))
                    (cdr (car fields)))
          (loop (cdr fields) #f)))))

(define (value-name value store)
  (cond ((number-value? value) (list->string (number-characters value)))
        ((text-value? value) (string-append "\"" (list->string (text-characters value)) "\""))
        ((name-value? value) (symbol->string (name-symbol value)))
        (else (element-name value store))))

(define (element-name element store)
  (let ((type (store-type-of store element)))
    (cond ((equal? type 'Line) (string-append "line " (number-field element 'number store)))
          ((equal? type 'Word)
           (string-append "word " (number-field element 'place store) " of "
                          (element-name (car (store-field-values store element 'line)) store)))
          ((equal? type 'Input_Character)
           (string-append "character " (number-field element 'place store)))
          ((equal? type 'Quoted_Character)
           (string-append "quoted character " (number-field element 'place store) " of "
                          (element-name (car (store-field-values store element 'word)) store)))
          ((equal? type 'Input_Text) "the text")
          (else (string-append (symbol->string type) " "
                               (list->string (small-characters (ordinal-of element store))))))))

(define (number-field element field store)
  (list->string (number-characters (car (store-field-values store element field)))))

(define (ordinal-of element store)
  ;; its place among the elements of its type, from 1
  (let ((ids (store-elements-of store (store-type-of store element))))
    (- (length ids) (index-of (element-id element) ids))))

;;; ------------------------------------------------------------------------
;;; The test command
;;;
;;; A test list has the lines of PLAN.md section 6, and three more:
;;;   rules FILE ...   the rule files for the tests below it, in place of the
;;;                    whole set; none if no files follow
;;;   steps N          the step budget for the tests below it
;;;   tree FILE TREE   the reader's tree of FILE is exactly the text in TREE
;;; and more verdicts: "ran out of steps"; "rule file refused at N", for a
;;; rule file the engine cannot read; and "refused at N" for a text, naming a
;;; line of the text when no line of the Etale file is named.

(define (split-at-spaces characters)
  (let loop ((characters characters) (current '()) (words '()))
    (cond ((null? characters)
           (reverse (if (null? current) words (cons (list->string (reverse current)) words))))
          ((char=? (car characters) #\space)
           (loop (cdr characters) '()
                 (if (null? current) words (cons (list->string (reverse current)) words))))
          (else (loop (cdr characters) (cons (car characters) current) words)))))

(define (command-test arguments)
  (if (null? arguments)
      (usage)
      (let ((counts (run-test-lines (split-lines (read-characters (car arguments)))
                                    whole-rule-set default-budget #f (list 0 0 0))))
        (display (first-of counts)) (display " passed, ")
        (display (second counts)) (display " failed, ")
        (display (third counts)) (display " not run")
        (newline)
        (exit (if (= (second counts) 0) 0 1)))))

(define (run-test-lines lines rules budget file counts)
  (if (null? lines)
      counts
      (let* ((line (car lines))
             (words (split-at-spaces line))
             (indented (and (not (null? line)) (char=? (car line) #\space))))
        (cond ((null? words) (run-test-lines (cdr lines) rules budget file counts))
              ((and (not indented) (equal? (car words) "rules"))
               (run-test-lines (cdr lines) (cdr words) budget file counts))
              ((and (not indented) (equal? (car words) "steps") (= (length words) 2))
               (run-test-lines (cdr lines) rules (small-number-from-string (second words)) file counts))
              ((and (not indented) (equal? (car words) "tree") (= (length words) 3))
               (run-test-lines (cdr lines) rules budget file
                               (report line (tree-test (second words) (third words)) counts)))
              ((not indented)
               (run-test-lines (cdr lines) rules budget (car words)
                               (report line
                                       (verdict-test (check-file (car words) #f #f
                                                                 default-printed-as rules budget)
                                                     (cdr words) #f)
                                       counts)))
              ((and file (>= (length words) 3))
               (run-test-lines (cdr lines) rules budget file
                               (report line (text-test file words rules budget) counts)))
              (else (run-test-lines (cdr lines) rules budget file
                                    (report line (list 'failed "a test line this runner cannot read") counts)))))))

(define (text-test file words rules budget)
  ;; words: TYPE TEXT, then the verdict; "printed as NAME FILE" asks for the
  ;; text to be accepted and printed, with its text named NAME, as FILE holds
  (let ((type-name (first-of words)) (text-path (second words)) (expected (cdr (cdr words))))
    (if (and (= (length expected) 4) (equal? (first-of expected) "printed")
             (equal? (second expected) "as"))
        (verdict-test (check-file file type-name text-path (third expected) rules budget)
                      (list "accepted") (fourth expected))
        (verdict-test (check-file file type-name text-path default-printed-as rules budget)
                      expected text-path))))

(define (report line outcome counts)
  ;; outcome: (passed), (failed what-happened) or (not-run why)
  (let ((kind (car outcome)))
    (display (cond ((equal? kind 'passed) "pass  ")
                   ((equal? kind 'failed) "FAIL  ")
                   (else "skip  ")))
    (display (list->string line))
    (if (equal? kind 'passed) #f (begin (display "  (") (display (second outcome)) (display ")")))
    (newline)
    (cond ((equal? kind 'passed) (list (+ 1 (first-of counts)) (second counts) (third counts)))
          ((equal? kind 'failed) (list (first-of counts) (+ 1 (second counts)) (third counts)))
          (else (list (first-of counts) (second counts) (+ 1 (third counts)))))))

(define (tree-test file expected)
  (let ((read (read-etale-file file)))
    (cond ((not (null? (cdr read))) (list 'failed "the reader refused the file"))
          ((equal? (tree-characters (build-tree (written-lines (car read))))
                   (read-characters expected))
           (list 'passed))
          (else (list 'failed "a different tree")))))

(define (verdict-test verdict expected text-path)
  ;; expected: the words of the verdict wanted
  (let ((got (verdict-summary verdict)))
    (if (verdict-matches? verdict expected text-path)
        (list 'passed)
        (list 'failed (string-append "got: " got)))))

(define (verdict-matches? verdict expected text-path)
  (let ((kind (car verdict)))
    (cond ((equal? expected (list "accepted"))
           (and (equal? kind 'accepted)
                (or (not text-path) (equal? (second verdict) (read-characters text-path)))))
          ((equal? expected (list "ran" "out" "of" "steps")) (equal? kind 'ran-out))
          ((and (= (length expected) 5) (equal? (first-of expected) "rule")
                (equal? (second expected) "file") (equal? (third expected) "refused")
                (equal? (fourth expected) "at"))
           (and (equal? kind 'rule-file-refused)
                (equal? (third verdict) (small-number-from-string (fifth expected)))))
          ((not (equal? kind 'refused)) #f)
          ((and (= (length expected) 3) (equal? (first-of expected) "refused")
                (equal? (second expected) "at"))
           (let ((at (small-number-from-string (third expected))))
             (if text-path
                 (and (= (third verdict) 1)
                      (equal? (refusal-pairs verdict) (list (cons #f at))))
                 (and (= (third verdict) 2)
                      (equal? (without-repeats (map refusal-line (second verdict))) (list at))))))
          ((and (= (length expected) 5) (equal? (first-of expected) "refused")
                (equal? (second expected) "by") (equal? (fourth expected) "at"))
           (and (= (third verdict) 1)
                (equal? (refusal-pairs verdict)
                        (list (cons (small-number-from-string (third expected))
                                    (small-number-from-string (fifth expected)))))))
          (else #f))))

(define (refusal-pairs verdict)
  ;; each refusal's line of the Etale file and line of the text, once
  (without-repeats
   (map (lambda (refusal)
          (cons (refusal-line refusal)
                (if (refusal-place refusal)
                    (text-line-of (fourth verdict) (refusal-place refusal))
                    #f)))
        (second verdict))))

(define (verdict-summary verdict)
  (let ((kind (car verdict)))
    (cond ((equal? kind 'accepted)
           (string-append "accepted, printing " (list->string (small-characters (length (second verdict))))
                          " characters"))
          ((equal? kind 'ran-out) "ran out of steps")
          ((equal? kind 'rule-file-refused)
           (string-append "rule file " (second verdict) " refused at "
                          (list->string (small-characters (third verdict))) ": " (fourth verdict)))
          (else
           (string-append "exit value " (list->string (small-characters (third verdict)))
                          ", refused at"
                          (join-strings (map (lambda (pair)
                                               (string-append
                                                " "
                                                (if (car pair) (list->string (small-characters (car pair))) "-")
                                                (if (cdr pair)
                                                    (string-append "/text " (list->string (small-characters (cdr pair))))
                                                    "")))
                                             (refusal-pairs verdict))))))))

(define (join-strings strings)
  (if (null? strings) "" (string-append (car strings) (join-strings (cdr strings)))))

;;; ------------------------------------------------------------------------
;;; The commands

(define (usage)
  (let ((port (current-error-port)))
    (for-each (lambda (line) (display line port) (newline port))
              '("usage: chibi-scheme -I test_engine -x small_scheme test_engine/engine.scm COMMAND"
                "  tree FILE                    print the reader's tree of an Etale file"
                "  facts FILE [TYPE [TEXT]]     print the built-in facts the rules see"
                "  check FILE [TYPE [TEXT]] [print NAME] [steps N] [rules RULE_FILE ...]"
                "                               check a file, and a text read as TYPE,"
                "                               printed with its text named NAME"
                "  made FILE [TYPE [TEXT]] [print NAME] [steps N] [rules RULE_FILE ...]"
                "                               print every value the rules made"
                "  test TEST_LIST               run a list of tests"
                "A TYPE with no TEXT reads the text from standard input."))
    (exit 2)))

(define (refused-reading refusals)
  (for-each (lambda (refusal) (display-refusal refusal '() (current-error-port))) refusals)
  (exit 2))

(define (command-tree arguments)
  (if (null? arguments)
      (usage)
      (let ((read (read-etale-file (car arguments))))
        (if (null? (cdr read))
            (begin
              (display (list->string (tree-characters (build-tree (written-lines (car read))))))
              (exit 0))
            (refused-reading (cdr read))))))

(define (command-facts arguments)
  (if (null? arguments)
      (usage)
      (let ((read (read-etale-file (car arguments))))
        (if (not (null? (cdr read)))
            (refused-reading (cdr read))
            (let* ((text-path (cond ((null? (cdr arguments)) #f)
                                    ((null? (cdr (cdr arguments))) "-")
                                    (else (third arguments))))
                   (text (cond ((not text-path) '())
                               ((equal? text-path "-") (read-characters #f))
                               (else (read-characters text-path))))
                   (store (store-with-file (empty-store default-budget (quote ())) (car read)))
                   (store (if text-path
                              (store-with-text store text (second arguments) default-printed-as)
                              store)))
              (display-facts store)
              (exit 0))))))

(define (check-options arguments positions budget printed-as)
  ;; returns (positions budget rules printed-as); rules is #f for the whole set
  (cond ((null? arguments) (list (reverse positions) budget #f printed-as))
        ((and (equal? (car arguments) "steps") (not (null? (cdr arguments)))
              (small-number-from-string (second arguments)))
         (check-options (cdr (cdr arguments)) positions
                        (small-number-from-string (second arguments)) printed-as))
        ((and (equal? (car arguments) "print") (not (null? (cdr arguments))))
         (check-options (cdr (cdr arguments)) positions budget (second arguments)))
        ((equal? (car arguments) "rules")
         (list (reverse positions) budget (cdr arguments) printed-as))
        (else (check-options (cdr arguments) (cons (car arguments) positions) budget
                             printed-as))))

(define (command-made arguments)
  ;; every value the rules made, type by type in the order of the rule files
  (if (null? arguments)
      (usage)
      (let* ((options (check-options (cdr arguments) '() default-budget default-printed-as))
             (positions (first-of options))
             (type-name (if (null? positions) #f (first-of positions)))
             (text-path (cond ((null? positions) #f)
                              ((null? (cdr positions)) "-")
                              (else (second positions))))
             (program (compile-rule-files (if (third options) (third options) whole-rule-set)))
             (read (read-etale-file (car arguments))))
        (cond ((problem? program)
               (display-rule-file-problem (list 'rule-file-refused (fourth program) (second program)
                                                (third program))
                                          (current-error-port))
               (exit 2))
              ((not (null? (cdr read))) (refused-reading (cdr read)))
              (else
               (let* ((text (cond ((not text-path) '())
                                  ((equal? text-path "-") (read-characters #f))
                                  (else (read-characters text-path))))
                      (store (store-with-file (empty-store (second options) (program-indexed program))
                                              (car read)))
                      (store (if text-path
                                 (store-with-text store text type-name (fourth options))
                                 store))
                      (store (run-rules program store)))
                 (for-each (lambda (definition)
                             (if (equal? (second definition) 'rule-type)
                                 (for-each (lambda (id) (display-element (make-element id) store))
                                           (reverse (store-elements-of store (first-of definition))))
                                 #f))
                           (program-definitions program))
                 (for-each (lambda (refusal) (display-refusal refusal text (current-error-port)))
                           (sort-refusals (reverse (store-refusals store))))
                 (exit 0)))))))

(define (command-check arguments)
  (if (null? arguments)
      (usage)
      (let* ((options (check-options (cdr arguments) '() default-budget default-printed-as))
             (positions (first-of options))
             (type-name (if (null? positions) #f (first-of positions)))
             (text-path (cond ((null? positions) #f)
                              ((null? (cdr positions)) "-")
                              (else (second positions)))))
        (show-verdict (check-file (car arguments) type-name text-path (fourth options)
                                  (if (third options) (third options) whole-rule-set)
                                  (second options))))))

(define (main arguments)
  (cond ((null? arguments) (usage))
        ((equal? (car arguments) "tree") (command-tree (cdr arguments)))
        ((equal? (car arguments) "facts") (command-facts (cdr arguments)))
        ((equal? (car arguments) "check") (command-check (cdr arguments)))
        ((equal? (car arguments) "made") (command-made (cdr arguments)))
        ((equal? (car arguments) "test") (command-test (cdr arguments)))
        (else (usage))))

(main (cdr (command-line)))
