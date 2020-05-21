MODULE Test;
  TYPE P = POINTER TO R;
    R = RECORD q: P END;

  PROCEDURE Go*;
    VAR p, q: P;
  BEGIN q := NIL;
    REPEAT NEW(p); p.q := q; (*traps if p = NIL*) q := p UNTIL p = NIL
  END Go;

END Test.

ORP.Compile Test.Mod/s ~
System.Free Test ~
Test.Go
