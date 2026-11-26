; The part of Scheme the test engine may use: PLAN.md 5.4's list, plus
; current-error-port, so refusals can go to the error output (PLAN.md 3.10).
; The engine runs with only these names, so a name outside them stops it
; before anything runs.

(define-library (small_scheme)
  (import (scheme base) (scheme write) (scheme file) (scheme process-context))
  (export define lambda if cond else let let* letrec and or not quote begin
          cons car cdr list append reverse length map for-each assoc member
          equal? null?
          char=? char->integer string->list list->string string-append
          string=? string->symbol symbol->string
          + - * quotient remainder = < <= > >=
          read-char peek-char eof-object? open-input-file display newline
          exit command-line current-error-port))
