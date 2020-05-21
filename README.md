# Oberon-handle-recursive-traps-and-aborts
Handle recursive traps and aborts in the Project Oberon 2013 operating system (http://www.projectoberon.com).

Note: In this repository, the term "Project Oberon 2013" refers to a re-implementation of the original "Project Oberon" on an FPGA development board around 2013, as published at www.projectoberon.com.

--------------------------------------------------------------------------
**1. Overview**

In Project Oberon 2013 it is possible for a trap routine to cause another trap. In some cases, this may cause additional (heap) memory to be allocated from within the trap handler - for example, when the trap handler attempts to output text to the Oberon *system log*. If this happens many times (recursively), the system will eventually run out of heap memory - as the garbage collector is not invoked during this process - and freeze or crash.

The code in this repository modifies the trap handler such that it detects whether it is being reentered. In such a case, the trap handling is deferred until the garbage collector has had time to free up enough free heap memory.

Note that this implementation also requires a modification to the *inner core* module *Kernel*, which fixes a problem when a single command uses up all available heap memory in a loop that repeatedly executes NEW, until it returns a NIL pointer. In the original implementation of Project Oberon 2013, this may cause the loop to exit early, leaving the linked list of free memory segments in module *Kernel* in a corrupted state, leading to further issues and errors later. The problem can be solved by modifying the 32, 64 and 128-byte block allocators such that they check for 0 returned from the next larger allocator. If 0, then the corresponding list of memory segments should not be updated. In sum, if there is not enough heap memory left for procedure NEW to succeed, it will simply return NIL, but not corrupt the heap data structure.

--------------------------------------------------------------------------
**2. Comparison with other solutions**

The solution described in this repository is similar to the "first variant" described in [**DoubleTrap**](https://github.com/schierlm/Oberon2013Modifications/tree/master/DoubleTrap), but differs in two main ways: First, our solution preserves the trap information in a global variable (in module *System*) for use by the Oberon background process that outputs it to the *system log*. Second, the background process itself ends the "in the trap" state, so as to put the system back in a clean state *after* writing the trap information.

--------------------------------------------------------------------------
**3. Preparing your Oberon system to be able to handle recursive traps and aborts**

**PREREQUISITES**: A current version of Project Oberon 2013 (see http://www.projectoberon.com). If you use Extended Oberon (see http://github.com/andreaspirklbauer/Oberon-extended), the functionality is already implemented.

Download all files from the [**Sources**](Sources/FPGAOberon2013) directory of this repository. Convert the *source* files to Oberon format (Oberon uses CR as line endings) using the command [**dos2oberon**](dos2oberon), available in this repository (example shown for Linux or macOS):

     for x in *.Mod ; do ./dos2oberon $x $x ; done

Import the files to your Oberon system. If you use an emulator, click on the *PCLink1.Run* link in the *System.Tool* viewer, copy the files to the emulator directory, and execute the following command on the command shell of your host system:

     cd oberon-risc-emu
     for x in *.Mod ; do ./pcreceive.sh $x ; sleep 0.5 ; done

Execute the following commands on your Oberon system:

     ORP.Compile Kernel.Mod/s System.Mod/s ~                       # compile modules Kernel and System
     ORL.Link Modules ~                                            # generate a pre-linked binary file of the "regular" boot file (Modules.bin)
     ORL.Load Modules.bin ~                                        # load the "regular" boot file onto the boot area of the local disk

Restart your Oberon system.

--------------------------------------------------------------------------

# Appendix: Changes made to Project Oberon 2013

**Kernel.Mod**

```diff
--- FPGAOberon2013/Kernel.Mod	2014-02-04 18:26:24.000000000 +0100
+++ Oberon-handle-recursive-traps-and-aborts/Sources/FPGAOberon2013/Kernel.Mod	2019-12-27 08:36:01.000000000 +0100
@@ -41,8 +41,9 @@
     VAR q: LONGINT;
   BEGIN
     IF list1 # 0 THEN p := list1; SYSTEM.GET(list1+8, list1)
-    ELSE GetBlock(q, 256); SYSTEM.PUT(q+128, 128); SYSTEM.PUT(q+132, -1); SYSTEM.PUT(q+136, list1);
-      list1 := q + 128; p := q
+    ELSE GetBlock(q, 256);
+      IF q # 0 THEN SYSTEM.PUT(q+128, 128); SYSTEM.PUT(q+132, -1); SYSTEM.PUT(q+136, list1); list1 := q + 128 END ;
+      p := q
     END
   END GetBlock128;
 
@@ -50,8 +51,9 @@
     VAR q: LONGINT;
   BEGIN
     IF list2 # 0 THEN p := list2; SYSTEM.GET(list2+8, list2)
-    ELSE GetBlock128(q); SYSTEM.PUT(q+64, 64); SYSTEM.PUT(q+68, -1); SYSTEM.PUT(q+72, list2);
-      list2 := q + 64; p := q
+    ELSE GetBlock128(q);
+      IF q # 0 THEN SYSTEM.PUT(q+64, 64); SYSTEM.PUT(q+68, -1); SYSTEM.PUT(q+72, list2); list2 := q + 64 END ;
+      p := q
     END
   END GetBlock64;
 
@@ -59,8 +61,9 @@
     VAR q: LONGINT;
   BEGIN
     IF list3 # 0 THEN p := list3; SYSTEM.GET(list3+8, list3)
-    ELSE GetBlock64(q); SYSTEM.PUT(q+32, 32); SYSTEM.PUT(q+36, -1); SYSTEM.PUT(q+40, list3);
-      list3 := q + 32; p := q
+    ELSE GetBlock64(q);
+      IF q # 0 THEN SYSTEM.PUT(q+32, 32); SYSTEM.PUT(q+36, -1); SYSTEM.PUT(q+40, list3); list3 := q + 32 END ;
+      p := q
     END
   END GetBlock32;
```

**System.Mod**

```diff
--- FPGAOberon2013/System.Mod	2019-12-26 19:46:24.000000000 +0100
+++ Oberon-handle-recursive-traps-and-aborts/Sources/FPGAOberon2013/System.Mod	2020-02-03 11:08:12.000000000 +0100
@@ -6,7 +6,7 @@
     StandardMenu = "System.Close System.Copy System.Grow Edit.Search Edit.Store";
     LogMenu = "Edit.Locate Edit.Search System.Copy System.Grow System.Clear";
 
-  VAR W: Texts.Writer;
+  VAR W: Texts.Writer; T: Oberon.Task; last: INTEGER; defer: BOOLEAN;
     pat: ARRAY 32 OF CHAR;
 
   PROCEDURE GetArg(VAR S: Texts.Scanner);
@@ -395,24 +395,61 @@
 
   PROCEDURE Trap(VAR a: INTEGER; b: INTEGER);
     VAR u, v, w: INTEGER; mod: Modules.Module;
-  BEGIN u := SYSTEM.REG(15); SYSTEM.GET(u - 4, v); w := v DIV 10H MOD 10H; (*trap number*)
+  BEGIN u := SYSTEM.REG(15);  (*return address deposited in register LNK by the trap (=BLR MT) instruction*)
+    SYSTEM.GET(u - 4, v);  (*trap instruction, contains code position and trap number as generated in ORG.Trap*)
+    w := v DIV 10H MOD 10H;  (*trap number*)
     IF w = 0 THEN Kernel.New(a, b)
-    ELSE (*trap*) Texts.WriteLn(W); Texts.WriteString(W, "  pos "); Texts.WriteInt(W, v DIV 100H MOD 10000H, 4);
-      Texts.WriteString(W, "  TRAP"); Texts.WriteInt(W, w, 4); mod := Modules.root;
-      WHILE (mod # NIL) & ((u < mod.code) OR (u >= mod.imp)) DO mod := mod.next END ;
-      IF mod # NIL THEN Texts.WriteString(W, " in "); Texts.WriteString(W, mod.name) END ;
-      Texts.WriteString(W, " at"); Texts.WriteHex(W, u);
-      Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf); Oberon.Reset
+    ELSE (*trap*)
+      IF defer THEN (*defer trap handling*) last := u; Oberon.Install(T)
+      ELSE defer := TRUE;
+        Texts.WriteLn(W); Texts.WriteString(W, "  pos ");
+        Texts.WriteInt(W, v DIV 100H MOD 10000H, 4);  (*code position*)
+        Texts.WriteString(W, "  TRAP"); Texts.WriteInt(W, w, 4); mod := Modules.root;
+        WHILE (mod # NIL) & ((u < mod.code) OR (u >= mod.imp)) DO mod := mod.next END ;
+        IF mod # NIL THEN Texts.WriteString(W, " in "); Texts.WriteString(W, mod.name) END ;
+        Texts.WriteString(W, " at"); Texts.WriteHex(W, u);
+        Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
+        defer := FALSE
+      END ;
+      Oberon.Collect(0); Oberon.Reset
     END
   END Trap;
 
   PROCEDURE Abort;
-    VAR n: INTEGER;
-  BEGIN n := SYSTEM.REG(15); Texts.WriteString(W, "  ABORT  "); Texts.WriteHex(W, n);
-    Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf); Oberon.Reset
+    VAR u: INTEGER; mod: Modules.Module;
+  BEGIN u := SYSTEM.REG(15);  (*return address deposited in register LNK by the abort (=BL 0) instruction*)
+    IF defer THEN (*defer abort handling*) last := u; Oberon.Install(T)
+    ELSE defer := TRUE;
+      Texts.WriteLn(W); Texts.WriteString(W, "  ABORT  "); mod := Modules.root;
+      WHILE (mod # NIL) & ((u < mod.code) OR (u >= mod.imp)) DO mod := mod.next END ;
+      IF mod # NIL THEN Texts.WriteString(W, " in "); Texts.WriteString(W, mod.name) END ;
+      Texts.WriteString(W, " at"); Texts.WriteHex(W, u);
+      Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
+      defer := FALSE
+    END ;
+    Oberon.Collect(0); Oberon.Reset
   END Abort;
-  
-BEGIN Texts.OpenWriter(W);
+
+  PROCEDURE Deferred;  (*handle trap/abort as soon as the garbage collector has freed up enough heap space*)
+    VAR v, w, pos: INTEGER; mod: Modules.Module;
+  BEGIN
+    IF Kernel.allocated < Kernel.heapLim - Kernel.heapOrg - 10000H THEN Oberon.Remove(T);
+      SYSTEM.GET(last - 4, v); (*trap instruction*) pos := v DIV 100H MOD 10000H; (*code position*)
+      Texts.WriteLn(W);
+      IF pos # 0 THEN w := v DIV 10H MOD 10H; (*trap number*)
+        Texts.WriteString(W, "  pos "); Texts.WriteInt(W, pos, 4);
+        Texts.WriteString(W, "  RECURSIVE TRAP"); Texts.WriteInt(W, w, 4)
+      ELSE Texts.WriteString(W, "  RECURSIVE ABORT  ")
+      END ;
+      mod := Modules.root;
+      WHILE (mod # NIL) & ((last < mod.code) OR (last >= mod.imp)) DO mod := mod.next END ;
+      IF mod # NIL THEN Texts.WriteString(W, " in "); Texts.WriteString(W, mod.name) END ;
+      Texts.WriteString(W, " at"); Texts.WriteHex(W, last);
+      Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf); defer := FALSE
+    END
+  END Deferred;
+
+BEGIN Texts.OpenWriter(W); defer := FALSE; T := Oberon.NewTask(Deferred, 500);
   Oberon.OpenLog(TextFrames.Text("")); OpenViewers;
   Kernel.Install(SYSTEM.ADR(Trap), 20H); Kernel.Install(SYSTEM.ADR(Abort), 0);
 END System.
```


