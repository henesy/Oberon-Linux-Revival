(* ETH Oberon, Copyright 2001 ETH Zuerich Institut fuer Computersysteme, ETH Zentrum, CH-8092 Zuerich.
Refer to the "General ETH Oberon System Source License" contract available at: http://www.oberon.ethz.ch/ *)

(*
		2015-03-28		renamed to OLR.System.Mod, used for X86, MIPS, ARMv7 and ARM; ShowModules crippled for ARM
		2015-04-14		made Gadgets compatible, optimized Directory
		2015-05-12		showing correct procedure in MIPS FindProc
		2015-05-17		made changes to traverse stack frame on MIPS
		2015-05-26		WritProc writing correct PC
		2015-10-06		increased length of pat in Directory from 64 to 256, changed Cleanup error message
		2015-10-29		changed MaxString from 64 to 256
		2016-04-12		added CopyClip and PasteClip
		2016-04-16		CopyClip PasteClip: CR/LF conversion
		2017-02-14		disabled task in OpenKernelLog
	2017-03-24	WIP changing data layout Linux0.ARCH=ARM broken

ToDo: use System.Mod 
	
*)

MODULE System; (** portable, except where noted *) (* pjm *)

(* contributions: JG 3.10.90 / NW 26.11.91 / ARD 4. 2. 93 / nm / jm / ejz *)

IMPORT SYSTEM, Linux0, Kernel, Files, FileDir, Modules, Objects, Display, Input, Fonts, 
	Viewers, Reals, Texts, Oberon, TextFrames;

CONST
	CR = 0DX; LF = 0AX;
	MaxString = 256;
	MaxArray = 8;
	ARM="ARM";
	X86="X86";
	ARMv7="ARMv7";
	MIPS="MIPS";
	RISCV="RISC-V";
	
	EnumReverse = FileDir.EnumUserMin;
	EnumFixedFont = FileDir.EnumUserMin+1;
	
VAR
	W: Texts.Writer;
	trapped: SHORTINT; 
	ch: CHAR;

	count, total, trap: LONGINT;
	task: Oberon.Task;
	log: Texts.Text;
	time0, date0: LONGINT;
	init: BOOLEAN;

PROCEDURE OpenText(title: ARRAY OF CHAR; T: Texts.Text; system: BOOLEAN);
VAR W: INTEGER;
BEGIN	
	IF system THEN W := Display.Width DIV 8*3 ELSE W := 400 END;
	Oberon.OpenText(title, T, W, 240);
END OpenText;

(* --- Toolbox for system control *)

PROCEDURE SetFont*;
VAR beg, end, time: LONGINT; T: Texts.Text; S: Texts.Scanner; f: Fonts.Font;
BEGIN
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN
			Texts.OpenScanner(S, T, beg); Texts.Scan(S);
			IF S.class = Texts.Name THEN
				f := Fonts.This(S.s);
				IF f # NIL THEN Oberon.SetFont(f) END
			END
		END
	ELSIF S.class = Texts.Name THEN 
		f := Fonts.This(S.s);
		IF f # NIL THEN Oberon.SetFont(f) END
	END
END SetFont;

PROCEDURE SetColor*;
VAR beg, end, time: LONGINT; T: Texts.Text; S: Texts.Scanner; ch: CHAR;
BEGIN
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN
			Texts.OpenReader(S, T, beg); Texts.Read(S, ch); Oberon.SetColor(S.col)
		END
	ELSIF S.class = Texts.Int THEN Oberon.SetColor(SHORT(SHORT(S.i)))
	END
END SetColor;

PROCEDURE SetOffset*;
VAR beg, end, time: LONGINT; T: Texts.Text;S: Texts.Scanner; ch: CHAR;
BEGIN
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN
			Texts.OpenReader(S, T, beg); Texts.Read(S, ch); Oberon.SetOffset(S.voff)
		END
	ELSIF S.class = Texts.Int THEN Oberon.SetOffset(SHORT(SHORT(S.i)))
	END
END SetOffset;

PROCEDURE Time*;
VAR par: Oberon.ParList; S: Texts.Scanner; t, d, hr, min, sec, yr, mo, day: LONGINT;
	
	PROCEDURE WritePair(ch: CHAR; x: LONGINT);
	BEGIN Texts.Write(W, ch);
		Texts.Write(W, CHR(x DIV 10 + 30H)); Texts.Write(W, CHR(x MOD 10 + 30H))
	END WritePair;

BEGIN
	par := Oberon.Par;
	Texts.OpenScanner(S, par.text, par.pos); Texts.Scan(S);
	IF S.class = Texts.Int THEN (*set date*)
		day := S.i; Texts.Scan(S); mo := S.i; Texts.Scan(S); yr := S.i; Texts.Scan(S);
		hr := S.i; Texts.Scan(S); min := S.i; Texts.Scan(S); sec := S.i;
		IF yr > 1900 THEN DEC(yr, 1900) END;	(* compatible with old two-digit format *)
		t := (hr*64 + min)*64 + sec; d := (yr*16 + mo)*32 + day;
		Oberon.SetClock(t, d)
	ELSE (*read date*)
		Texts.WriteString(W, "System.Time");
		Oberon.GetClock(t, d); Texts.WriteDate(W, t, d);
		IF (S.class = Texts.Name) & (S.s = "start") THEN
			Texts.WriteString(W, ", started");
			time0 := t; date0 := d
		ELSIF (S.class = Texts.Name) & (S.s = "lap") THEN
			hr := t DIV 4096 MOD 32; min := t DIV 64 MOD 64; sec := t MOD 64;
			DEC(sec, time0 MOD 64);
			IF sec < 0 THEN INC(sec, 60); DEC(min) END;
			DEC(min, time0 DIV 64 MOD 64);
			IF min < 0 THEN INC(min, 60); DEC(hr) END;
			DEC(hr, time0 DIV 4096 MOD 32);
			IF hr < 0 THEN INC(hr, 24) END;	(* assume one day passed *)
			Texts.WriteString(W, ", "); WritePair(" ", hr);
			WritePair(":", min); WritePair(":", sec);
			Texts.WriteString(W, " elapsed");
			IF d # date0 THEN
				Texts.WriteString(W, " (may be incorrect due to date change)")
			END
		END;
		Texts.WriteLn(W);
		Texts.Append(Oberon.Log, W.buf)
	END
END Time;

PROCEDURE Collect*;
BEGIN
	Oberon.Collect
END Collect;

(* --- Toolbox for standard display *)

PROCEDURE Open*;
VAR par: Oberon.ParList; T: Texts.Text; S: Texts.Scanner; beg, end, time: LONGINT;
BEGIN
	par := Oberon.Par;
	Texts.OpenScanner(S, par.text, par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") OR (S.line # 0) THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN Texts.OpenScanner(S, T, beg); Texts.Scan(S) END
	END;
	IF S.class IN {Texts.Name, Texts.String} THEN
		OpenText(S.s, TextFrames.Text(S.s), TRUE)
	END
END Open;

PROCEDURE OpenLog*;
BEGIN
	OpenText("System.Log", Oberon.Log, TRUE);
END OpenLog;

PROCEDURE Clear*;
VAR S: Texts.Scanner; par: Oberon.ParList; F: Display.Frame; L: Objects.LinkMsg; A: Objects.AttrMsg;
BEGIN
	par := Oberon.Par; F := NIL;
	L.id := Objects.get; L.name := "Model"; L.obj := NIL;
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "*") THEN
		F := Oberon.MarkedFrame()
	ELSIF (par.vwr # NIL) & (par.vwr.dsc # NIL) THEN
		F := par.vwr.dsc.next;
		F.handle(F, L);
		IF (L.obj # NIL) & (L.obj IS Display.Frame) THEN
			A.id := Objects.get; A.name := "Gen"; L.obj.handle(L.obj, A);
			IF A.s = "PanelDocs.NewDoc" THEN (* Desktop *)
				F := Oberon.Par.obj(Display.Frame);
				F := F.dlink(Display.Frame);
				F := F.next.dsc
			ELSE
				F := L.obj(Display.Frame)
			END
		END
	END;
	IF F # NIL THEN
		F.handle(F, L);
		IF (L.obj # NIL) & (L.obj IS Texts.Text) THEN
			Texts.Delete(L.obj(Texts.Text), 0, L.obj(Texts.Text).len)
		END
	END
END Clear;

PROCEDURE Close*;
VAR par: Oberon.ParList; V: Viewers.Viewer; 
BEGIN
	par := Oberon.Par;
	IF par.frame = par.vwr.dsc THEN V := par.vwr
	ELSE V := Oberon.MarkedViewer()
	END;
	Viewers.Close(V)
END Close;

PROCEDURE CloseTrack*;
VAR V: Viewers.Viewer;
BEGIN
	V := Oberon.MarkedViewer(); Viewers.CloseTrack(V.X)
END CloseTrack;

PROCEDURE Recall*;
VAR V: Viewers.Viewer; M: Display.ControlMsg;
BEGIN
	Viewers.Recall(V);
	IF (V # NIL) & (V.state = 0) THEN
		Viewers.Open(V, V.X, V.Y + V.H); M.F := NIL; M.id := Display.restore; V.handle(V, M)
	END
END Recall;

PROCEDURE Copy*;
VAR V, V1: Viewers.Viewer; M: Objects.CopyMsg; N: Display.ControlMsg;
BEGIN
	M.id := Objects.shallow;
	V := Oberon.Par.vwr; V.handle(V, M); V1 := M.obj(Viewers.Viewer);
	Viewers.Open(V1, V.X, V.Y + V.H DIV 2);
	N.F := NIL; N.id := Display.restore; V1.handle(V1, N)
END Copy;

PROCEDURE Grow*;
VAR par: Oberon.ParList; V, V1: Viewers.Viewer; M: Objects.CopyMsg; N: Display.ControlMsg; DW, DH: INTEGER;
BEGIN
	par := Oberon.Par;
	IF par.frame = par.vwr.dsc THEN V := par.vwr
	ELSE V := Oberon.MarkedViewer()
	END;
	DW := Oberon.DisplayWidth(V.X); DH := Oberon.DisplayHeight(V.X);
	IF V.H < DH - Viewers.minH THEN Oberon.OpenTrack(V.X, V.W)
	ELSIF V.W < DW THEN Oberon.OpenTrack(Oberon.UserTrack(V.X), DW)
	END;
	IF (V.H < DH - Viewers.minH) OR (V.W < DW) THEN
		M.id := Objects.shallow;
		V.handle(V, M); V1 := M.obj(Viewers.Viewer);
		Viewers.Open(V1, V.X, DH);
		N.F := NIL; N.id := Display.restore; V1.handle(V1, N)
	END
END Grow;

(* --- Toolbox for module management *)

PROCEDURE Free*;
VAR par: Oberon.ParList; S: Texts.Scanner; F: TextFrames.Frame; time, beg, end, pos: LONGINT; T: Texts.Text;

	PROCEDURE FreeFile;
	VAR i: LONGINT;
	BEGIN
		(*IF S.nextCh # "*" THEN Modules.Free(S.s, FALSE)
		ELSE Modules.Free(S.s, TRUE); Texts.Scan(S)
		END*);
		i := 0;  WHILE (S.s[i] # 0X) & (S.s[i] # ".") DO INC(i) END;
		S.s[i] := 0X;
		Modules.Free(S.s, FALSE);
		IF Modules.res = 0 THEN
			Texts.WriteString(W, S.s); Texts.WriteString(W, " unloaded")
		ELSE
			Texts.WriteString(W, Modules.resMsg)
		END;
		Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
	END FreeFile;

BEGIN
	par := Oberon.Par;
	Oberon.GetSelection(T, beg, end, time);
	Texts.WriteString(W, "System.Free"); Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
	IF (par.vwr.dsc # par.frame) OR ~(par.vwr.dsc.next IS TextFrames.Frame) THEN
		Texts.OpenScanner(S, par.text, par.pos); Texts.Scan(S);
		IF (S.class = Texts.Char) & (S.c = "^") OR (S.class = Texts.Inval) THEN
			IF time # -1 THEN
				Texts.OpenScanner(S, T, beg); pos := Texts.Pos(S)-1; Texts.Scan(S);
				WHILE ~S.eot & (S.class = Texts.Name) & (pos < end) DO
					FreeFile;  pos := Texts.Pos(S); Texts.Scan(S);
					WHILE ~S.eot & (S.class = Texts.Int) DO pos := Texts.Pos(S); Texts.Scan(S) END
				END
			END
		ELSE
			WHILE S.class = Texts.Name DO FreeFile; Texts.Scan(S) END
		END
	ELSE
		F := par.vwr.dsc.next(TextFrames.Frame);
		IF F.sel > 0 THEN
			Texts.OpenScanner(S, F.text, F.selbeg.pos);
			WHILE ~S.eot & (Texts.Pos(S) < F.selend.pos) DO
				Texts.Scan(S); 
				IF S.class = Texts.Name THEN FreeFile;
					IF Modules.res = 0 THEN
						Texts.OpenReader(S, F.text, F.selbeg.pos); 
						REPEAT Texts.Read(S, S.nextCh) UNTIL S.eot OR (S.nextCh = 0DX);
						Texts.Delete(F.text, F.selbeg.pos, Texts.Pos(S)); 
						DEC(F.selend.pos, Texts.Pos(S) - F.selbeg.pos);
						Texts.OpenScanner(S, F.text, F.selbeg.pos);
					END
				ELSE F.selbeg.pos := Texts.Pos(S)
				END
			END
		END
	END
END Free;

PROCEDURE ShowModules*;
VAR T: Texts.Text; M: Modules.Module; dsize, csize, n, var, const, code: LONGINT;
BEGIN
	T := TextFrames.Text("");
(*
	Texts.WriteString(W, "MODULE"); Texts.Write(W, 9X);
	Texts.WriteString(W, "VAR"); Texts.Write(W, 9X);
	Texts.WriteString(W, "CONST"); Texts.Write(W, 9X);
	Texts.WriteString(W, "CODE"); Texts.Write(W, 9X);
	Texts.WriteString(W, "REFCNT"); Texts.Write(W, 9X);
	Texts.WriteLn(W);
*)
	M := Kernel.modules; n := 0; var := 0; const := 0; code := 0;
	WHILE M # NIL DO
		Texts.WriteString(W, M.name);  Texts.Write(W, 9X);
		IF ~(Linux0.ARCH=ARM) THEN	(* currently does not work on ARM ... *)
(*			dsize := M.sb - SYSTEM.ADR(M.data[0]);	(* data size *)
			(*Texts.WriteInt(W, dsize, 1);  Texts.Write(W, 9X);*)
			INC(var, dsize);  csize := LEN(M.data^)-dsize;
			(*Texts.WriteInt(W, csize, 1);  Texts.Write(W, 9X);*)	(* const size *)
			INC(const, csize);
			(*Texts.WriteInt(W, LEN(M.code), 1);  Texts.Write(W, 9X);*)	(* code size *)
			INC(code, LEN(M.code^));
			Texts.WriteInt(W, dsize + csize + LEN(M.code^), 1);  Texts.Write(W, 9X);
*)
		END;
		Texts.WriteInt(W, M.refcnt, 1); 
		Texts.WriteLn(W);
		M := M.next; INC(n)
	END;
	IF n > 1 THEN
		Texts.WriteString(W, "TOTAL"); Texts.Write(W, 9X);
(*
		Texts.WriteInt(W, var, 1); Texts.Write(W, 9X);
		Texts.WriteInt(W, const, 1); Texts.Write(W, 9X);
		Texts.WriteInt(W, code, 1); Texts.Write(W, 9X);
*)
		Texts.WriteInt(W, var + const + code, 1);  Texts.Write(W, 9X);
		Texts.WriteInt(W, n, 1); Texts.Write(W, 9X)
	END;
	Texts.WriteLn(W); Texts.Append(T, W.buf);
	OpenText("Modules|System.Close System.Free Edit.Search Edit.Store", T, TRUE)
END ShowModules;

(* --- Toolbox for library management *)

PROCEDURE ListLibrary (L: Objects.Library);
BEGIN
	Texts.WriteString(W, L.name); Texts.WriteLn(W); INC(count)
END ListLibrary;

PROCEDURE ShowLibraries*;
VAR t: Texts.Text;
BEGIN
	t := TextFrames.Text(""); count := 0;
	Objects.Enumerate(ListLibrary);
	IF count > 1 THEN
		Texts.WriteLn(W);  Texts.WriteInt(W, count, 1);  Texts.WriteString(W, " public libraries")
	END;
	Texts.WriteLn(W);  Texts.Append(t, W.buf);
	OpenText("Libraries", t, TRUE)
END ShowLibraries;

PROCEDURE FreeLibraries*;
VAR par: Oberon.ParList; T: Texts.Text; S: Texts.Scanner; beg, end, time: LONGINT;
BEGIN		
	par := Oberon.Par;
	Texts.WriteString(W, "System.FreeLibraries "); Texts.WriteLn(W);
	Texts.OpenScanner(S, par.text, par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN Texts.OpenScanner(S, T, beg); Texts.Scan(S)
		ELSE S.class := Texts.Inval
		END
	ELSE end := MAX(LONGINT)
	END;
	WHILE (S.class = Texts.Name) & (Texts.Pos(S) <= end) DO
		Objects.FreeLibrary(S.s); Texts.WriteString(W,S.s); Texts.WriteLn(W);
		Texts.Scan(S)
	END;
	Texts.Append(Oberon.Log, W.buf)
END FreeLibraries;

(* --- Toolbox of file system *)

PROCEDURE *List(name: ARRAY OF CHAR;  time, date, size: LONGINT; VAR flags: SET);
BEGIN
	INC(count);
	IF ~(EnumReverse IN flags) THEN Texts.WriteString(W, name) END;
	IF FileDir.EnumTime IN flags THEN
		IF ~(EnumReverse IN flags) THEN Texts.Write(W, " ") END;
		Texts.WriteDate(W, time, date)
	END;
	IF FileDir.EnumSize IN flags THEN
		IF flags * {EnumReverse, FileDir.EnumTime} # {EnumReverse} THEN Texts.Write(W, " ") END;
		Texts.WriteInt(W, size, 7); INC(total, size)
	END;
	IF EnumReverse IN flags THEN
		IF flags * {FileDir.EnumTime, FileDir.EnumSize} # {} THEN Texts.WriteString(W, "  ") END;
		Texts.WriteString(W, name)
	END;
	Texts.WriteLn(W)
END List;

PROCEDURE WriteK(VAR W: Texts.Writer;  k: LONGINT);
VAR suffix: CHAR;
BEGIN
	IF k < 100*1024 THEN suffix := "K"
	ELSIF k < 100*1024*1024 THEN suffix := "M"; k := k DIV 1024
	ELSE suffix := "G"; k := k DIV (1024*1024)
	END;
	Texts.WriteInt(W, k, 1);  Texts.Write(W, suffix);  Texts.Write(W, "B")
END WriteK;

PROCEDURE Directory*;
VAR
	par: Oberon.ParList; R: Texts.Reader; T, t: Texts.Text; beg, end, time: LONGINT; flags: SET;
	i: INTEGER; ch: CHAR; pat: ARRAY MaxString OF CHAR;
BEGIN
	par := Oberon.Par; 
	Texts.OpenReader(R, par.text, par.pos); Texts.Read(R, ch);
	WHILE (ch <= " ") & (ch # 0DX) DO Texts.Read(R, ch) END;
	IF (ch = "^") OR (ch = 0DX) THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN
			Texts.OpenReader(R, T, beg); Texts.Read(R, ch);
			WHILE ch <= " " DO Texts.Read(R, ch) END
		END
	END;
	i := 0;
	WHILE (ch > " ") & (ch # Oberon.OptionChar) DO
		pat[i] := ch; INC(i); Texts.Read(R, ch)
	END;
	pat[i] := 0X;
	WHILE ch = " " DO Texts.Read(R, ch) END;
	flags := {};
	WHILE ch = Oberon.OptionChar DO
		Texts.Read(R, ch);
		WHILE (CAP(ch) >= "A") & (CAP(ch) <= "Z") DO
			IF ch = "d" THEN flags := flags + {FileDir.EnumTime, FileDir.EnumSize}
			ELSIF ch = "t" THEN INCL(flags, FileDir.EnumTime)
			ELSIF ch = "s" THEN INCL(flags, FileDir.EnumSize)
(*			ELSIF ch = "r" THEN INCL(flags, OFS.EnumRecursive)*)
			ELSIF ch = "f" THEN flags := flags + {EnumFixedFont, EnumReverse}
			ELSIF ch = "l" THEN flags := flags / {EnumReverse}
			ELSE (* skip *)
			END;
			Texts.Read(R, ch)
		END;
		WHILE ch = " " DO Texts.Read(R, ch) END
	END;

	IF EnumFixedFont IN flags THEN
		Texts.SetFont(W, Fonts.This("Courier10.Scn.Fnt"))
	ELSE
		Texts.SetFont(W, Fonts.Default)
	END;
	t := TextFrames.Text("");
	count := 0; total := 0;
	FileDir.Enumerate(pat, flags, List);
	Texts.SetFont(W, Fonts.Default);
	IF (count > 1) THEN
		Texts.WriteLn(W);  Texts.WriteInt(W, count, 1); Texts.WriteString(W, " files");
		IF FileDir.EnumSize IN flags THEN
			Texts.WriteString(W, " use "); WriteK(W, (total+1023) DIV 1024)
		END
	END;
	Texts.WriteLn(W); Texts.Append(t, W.buf);
	OpenText("Directory", t, TRUE)
END Directory;

PROCEDURE CopyFile(name: ARRAY OF CHAR; VAR S: Texts.Scanner);
CONST BufLen = 8192;
VAR f, g: Files.File; Rf, Rg: Files.Rider; buf : ARRAY BufLen OF CHAR; i: LONGINT;
BEGIN
	Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "=") THEN
		Texts.Scan(S);
		IF (S.class = Texts.Char) & (S.c = ">") THEN
			Texts.Scan(S);
			IF S.class IN {Texts.Name, Texts.String} THEN
				Texts.WriteString(W, name); Texts.WriteString(W, " => "); Texts.WriteString(W, S.s);
				Texts.WriteString(W, " copying"); Texts.Append(Oberon.Log, W.buf);
				f := Files.Old(name);
				IF f # NIL THEN g := Files.New(S.s) END;
				IF (f # NIL) & (g # NIL) THEN
					Files.Set(Rf, f, 0); Files.Set(Rg, g, 0); 
					i := 0;
					WHILE i < Files.Length(f) DIV BufLen DO
						Files.ReadBytes(Rf,buf,BufLen); Files.WriteBytes(Rg,buf,BufLen); INC(i) 
					END;
					Files.ReadBytes(Rf, buf, Files.Length(f) MOD BufLen);
					Files.WriteBytes(Rg, buf, Files.Length(f) MOD BufLen);
					Files.Register(g)
				ELSE
					Texts.WriteString(W, " failed"); S.eot := TRUE
				END;
				Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
			END
		END
	END
END CopyFile;

PROCEDURE CopyFiles*;
VAR beg, end, time: LONGINT; T: Texts.Text; S: Texts.Scanner;
BEGIN
	Texts.WriteString(W, "System.CopyFiles"); Texts.WriteLn(W);
	Texts.Append(Oberon.Log, W.buf);
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN
			Texts.OpenScanner(S, T, beg); Texts.Scan(S);
			IF S.class IN {Texts.Name, Texts.String} THEN CopyFile(S.s, S) END
		END
	ELSE
		WHILE ~S.eot & (S.class IN {Texts.Name, Texts.String}) DO
			CopyFile(S.s, S); IF ~S.eot THEN Texts.Scan(S) END
		END
	END
END CopyFiles;

PROCEDURE RenameFile (name: ARRAY OF CHAR; VAR S: Texts.Scanner);
VAR res: INTEGER;
BEGIN
	Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "=") THEN
		Texts.Scan(S);
		IF (S.class = Texts.Char) & (S.c = ">") THEN
			Texts.Scan(S);
			IF S.class IN {Texts.Name, Texts.String} THEN
				Texts.WriteString(W, name); Texts.WriteString(W, " => "); Texts.WriteString(W, S.s);
				Texts.WriteString(W, " renaming"); Texts.Append(Oberon.Log, W.buf);
				Files.Rename(name, S.s, res);
				IF (res < 0) OR (res > 1) THEN Texts.WriteString(W, " failed"); S.eot := TRUE END;
				Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
			END
		END
	END
END RenameFile;

PROCEDURE RenameFiles*;
VAR beg, end, time: LONGINT; T: Texts.Text; S: Texts.Scanner;
BEGIN
	Texts.WriteString(W, "System.RenameFiles"); Texts.WriteLn(W);
	Texts.Append(Oberon.Log, W.buf);
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN
			Texts.OpenScanner(S, T, beg); Texts.Scan(S);
			IF S.class IN {Texts.Name, Texts.String} THEN RenameFile(S.s, S) END
		END
	ELSE
		WHILE ~S.eot & (S.class IN {Texts.Name, Texts.String}) DO
			RenameFile(S.s, S); IF ~S.eot THEN Texts.Scan(S) END
		END
	END
END RenameFiles;

PROCEDURE DeleteFile(VAR name: ARRAY OF CHAR;  VAR S: Texts.Scanner);
VAR res: INTEGER;
BEGIN
	Texts.WriteString(W, name); Texts.WriteString(W, " deleting");
	Texts.Append(Oberon.Log, W.buf); Files.Delete(name, res);
	IF res # 0 THEN Texts.WriteString(W, " failed"); S.eot := TRUE END;
	Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
END DeleteFile;

PROCEDURE DeleteFiles*;
VAR beg, end, time: LONGINT; T: Texts.Text; S: Texts.Scanner;
BEGIN
	Oberon.GetSelection(T, beg, end, time);
	Texts.WriteString(W, "System.DeleteFiles"); Texts.WriteLn(W);
	Texts.Append(Oberon.Log, W.buf);
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		IF time # -1 THEN
			Texts.OpenScanner(S, T, beg); Texts.Scan(S);
			IF S.class IN {Texts.Name, Texts.String} THEN DeleteFile(S.s, S) END
		END
	ELSE
		WHILE ~S.eot & (S.class IN {Texts.Name, Texts.String}) DO
			DeleteFile(S.s, S); IF ~S.eot THEN Texts.Scan(S) END
		END
	END
END DeleteFiles;

(* --- Toolbox for system inspection *)

PROCEDURE Watch*;
VAR free, total, largest: LONGINT;  
BEGIN
	Texts.WriteString(W, "System.Watch");  Texts.WriteLn(W);
(*
	fs := OFS.First();
	WHILE fs # NIL DO
		Texts.Write(W, 9X);  Texts.WriteString(W, fs.prefix);  Texts.WriteString(W, ": ");
		IF fs.vol # NIL THEN
			free := ENTIER(fs.vol.Available(fs.vol)/1024.0D0 * fs.vol.blockSize);
			total := ENTIER(fs.vol.size/1024.0D0 * fs.vol.blockSize);
			WriteK(W, free);  Texts.WriteString(W, " of ");
			WriteK(W, total);  Texts.WriteString(W, " free")
		END;
		Texts.WriteLn(W);
		fs := OFS.Next(fs)
	END;
*)
	free := (Kernel.Available()+512) DIV 1024;
	total := (Kernel.Available()+Kernel.Used()+512) DIV 1024;
	largest := (Kernel.LargestAvailable()+512) DIV 1024;
	Texts.Write(W, 9X);  Texts.WriteString(W, "Heap has ");
	WriteK(W, free);  Texts.WriteString(W, " of ");
	WriteK(W, total);  Texts.WriteString(W, " free (");
	WriteK(W, largest);  Texts.WriteString(W, " contiguous)");  Texts.WriteLn(W);
	Texts.Append(Oberon.Log, W.buf)
END Watch;

PROCEDURE WriteProc(mod: Modules.Module;  pc, fp: LONGINT;  VAR refs: Kernel.Bytes;  VAR refpos, base: LONGINT);
VAR ch: CHAR;
BEGIN
	refpos := -1;
	IF mod = NIL THEN
		Texts.WriteString(W, "Unknown PC =");  Texts.WriteHex(W, pc);  Texts.Write(W, "H");
		IF fp # -1 THEN
			Texts.WriteString(W, " FP =");  Texts.WriteHex(W, fp);  Texts.Write(W, "H")
		END
	ELSE
		Texts.WriteString(W, mod.name);
		refs := mod.refs;
		IF (refs # NIL) & (LEN(mod.refs^) # 0) THEN
			IF Linux0.ARCH=ARM THEN (*DEC(pc, mod.sb );*)
			ELSE DEC(pc, mod.cb );
			END;
			refpos := Kernel.FindProc(refs, pc, fp#-1);
			IF refpos # -1 THEN
				Texts.Write(W, ".");
				ch := refs[refpos];  INC(refpos);
				IF (ch = "$") THEN base := mod.sb ELSE base := fp END;	(* for variables *)
				WHILE ch # 0X DO Texts.Write(W, ch);  ch := refs[refpos];  INC(refpos) END
			END
		END;
		Texts.WriteString(W, "  PC = "); Texts.WriteInt(W, pc, 1)
	END
END WriteProc;

PROCEDURE Variables(refs: Kernel.Bytes;  i, base: LONGINT);
VAR
	mode, ch: CHAR;  adr, type, n, lval, size, tmp1, tmp2, tdadr : LONGINT;  etc: BOOLEAN;
	sval: SHORTINT;  ival: INTEGER;  tmp: Kernel.Bytes;  set: SET;
	rval: REAL;  lrval: LONGREAL;
BEGIN
	mode := refs[i];  INC(i);
	WHILE (i < LEN(refs^)) & (mode >= 1X) & (mode <= 3X) DO	(* var *)
		type := ORD(refs[i]);  INC(i);  etc := FALSE;
		IF type > 80H THEN
			IF type = 83H THEN type := 15 ELSE DEC(type, 80H) END;
			Kernel.GetNum(refs, i, n)
		ELSIF (type = 16H) OR (type = 1DH) THEN
			Kernel.GetNum(refs, i, tdadr); n := 1
		ELSE
			IF type = 15 THEN n := MaxString (* best guess *) ELSE n := 1 END
		END;
		Kernel.GetNum(refs, i, adr);
		Texts.Write(W, 9X);  ch := refs[i];  INC(i);

		WHILE (ch # 0X) & (i < LEN(refs^)) DO Texts.Write(W, ch);  ch := refs[i];  INC(i) END;
		Texts.WriteString(W, " = ");

		IF (Linux0.ARCH#ARM) & (Linux0.ARCH#X86) THEN (*Texts.WriteHex(W, adr); *)
			IF (adr>=0) THEN
				IF (adr<64) THEN SYSTEM.PUT( SYSTEM.ADR( lval), Linux0.Regs[ adr MOD 32]); adr:=SYSTEM.ADR( lval);
				ELSE INC(adr, base-64);
				END;
			ELSE INC(adr, base);
			END;
(*			Texts.WriteHex(W, adr); Texts.WriteHex(W, base); Texts.Write( W, " ");*)
		ELSE INC(adr, base);
		END;

		IF n = 0 THEN	(* open array *)	
			SYSTEM.GET(adr+4, n)	(* real LEN from stack *)
		END;
		IF type = 15 THEN
			IF n > MaxString THEN etc := TRUE;  n := MaxString END
		ELSE
			IF n > MaxArray THEN etc := TRUE;  n := MaxArray END
		END;
		IF mode # 1X THEN SYSTEM.GET(adr, adr); (*Texts.WriteHex(W, adr); Texts.WriteString( W, "H ");*) END;	(* indirect *)

		IF (adr >= -4) & (adr < 4096) THEN
			Texts.WriteString(W, "NIL reference (");  Texts.WriteHex(W, adr);  Texts.WriteString(W, "H )")
		ELSE
			IF type = 15 THEN
				Texts.Write(W, 22X);
				LOOP
					IF n = 0 THEN EXIT END;
					SYSTEM.GET(adr, ch);  INC(adr);
					IF (ch < " ") OR (ch > "~") THEN EXIT END;
					Texts.Write(W, ch);  DEC(n)
				END;
				Texts.Write(W, 22X);  etc := (ch # 0X)
			ELSE
				CASE type OF
					1..4: size := 1
					|5: size := 2
					|6..7,9,13,14,29: size := 4
					|8: size := 8
					|22: size := 0; ASSERT(n <= 1)
				ELSE
					Texts.WriteString(W, "bad type ");  Texts.WriteInt(W, type, 1);  n := 0
				END;
				WHILE n > 0 DO
					CASE type OF
						1,3:	(* BYTE, CHAR *)
							SYSTEM.GET(adr, ch);
							IF (ch > " ") & (ch <= "~") THEN Texts.Write(W, ch)
							ELSE Texts.WriteHex(W, ORD(ch));  Texts.Write(W, "X")
							END
						|2:	(* BOOLEAN *)
							SYSTEM.GET(adr, ch);
							IF ch = 0X THEN Texts.WriteString(W, "FALSE")
							ELSIF ch = 1X THEN Texts.WriteString(W, "TRUE")
							ELSE Texts.WriteInt(W, ORD(ch), 1)
							END
						|4:	(* SHORTINT *)
							SYSTEM.GET(adr, sval);  Texts.WriteInt(W, sval, 1)
						|5:	(* INTEGER *) 
							SYSTEM.GET(adr, ival);  Texts.WriteInt(W, ival, 1);
						|6:	(* LONGINT *)
							SYSTEM.GET(adr, lval);  Texts.WriteInt(W, lval, 1);
						|7:	(* REAL *)
							SYSTEM.GET(adr, rval);  Texts.WriteReal(W, rval, 15)
						|8:	(* LONGREAL *)
							SYSTEM.GET(adr, lrval);  Texts.WriteLongReal(W, lrval, 24)
						|9:	(* SET *)
							SYSTEM.GET(adr, set);  Texts.WriteSet(W, set)
						|13, 29:	(* POINTER *)
							SYSTEM.GET(adr, lval);  Texts.WriteHex(W, lval);  Texts.Write(W, "H")
						|22:	(* RECORD *)
							Texts.WriteHex(W, tdadr);  Texts.WriteString(W, "H (Type Descriptor Adr) ")
						|14:	(* PROC *)
							SYSTEM.GET(adr, lval);
							IF lval = 0 THEN Texts.WriteString(W, "NIL")
							ELSE WriteProc(Kernel.GetMod(lval), lval, -1, tmp, tmp1, tmp2)  (*this changes procedure stack!*)
							END;
						ELSE Texts.WriteString(W, "Variables ELSE ")
					END;
					DEC(n);  INC(adr, size);
					IF n > 0 THEN Texts.WriteString(W, ", ") END
				END 
			END
		END;
		IF etc THEN Texts.WriteString(W, " ...") END;
		Texts.WriteLn(W);
		IF i<LEN(refs^) THEN mode := refs[i] END;  INC(i);
	END
END Variables;

PROCEDURE OutState (VAR name: ARRAY OF CHAR; t: Texts.Text);
VAR mod: Modules.Module; refpos, i: LONGINT; refs: Kernel.Bytes;  ch: CHAR;
BEGIN
	i := 0;  WHILE (name[i] # 0X) & (name[i] # ".") DO INC(i) END;
	name[i] := 0X;
	Texts.WriteString(W, name); mod := Kernel.modules;
	WHILE (mod # NIL) & (mod.name # name) DO mod := mod.next END;
	IF mod # NIL THEN
		Texts.WriteString(W, "  SB ="); Texts.WriteHex(W, mod.sb); Texts.Write(W, "H");  Texts.WriteLn(W);
		refs := mod.refs;
		IF (refs # NIL) & (LEN(refs^) # 0) THEN
			IF Linux0.ARCH=ARM THEN 
				i:=0;
				Texts.WriteHex(W, LEN(mod.refs^)); Texts.WriteLn(W);
				WHILE i<LEN(mod.refs^) DO
					Texts.Write(W,mod.refs[i]); INC(i);
				END;
				Texts.WriteLn(W);
			ELSE
				refpos := Kernel.FindProc(refs, 0, TRUE);	(* assume module body is at PC = 0 (not true for OMI and ARM) *)
				IF refpos # -1 THEN
					REPEAT ch := refs[refpos];  INC(refpos) UNTIL ch = 0X;
					Variables(refs, refpos, mod.sb)
				END
			END;
		END
	ELSE
		Texts.WriteString(W, " not loaded");  Texts.WriteLn(W)
	END;
	Texts.Append(t, W.buf)
END OutState;

PROCEDURE State*;
VAR T: Texts.Text; S: Texts.Scanner; beg, end, time: LONGINT;
BEGIN
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN Texts.OpenScanner(S, T, beg); Texts.Scan(S) END
	END;
	IF S.class = Texts.Name THEN
		T := TextFrames.Text(""); OutState(S.s, T);
		OpenText("State", T, TRUE)
	END
END State;

PROCEDURE ShowCommands*;
VAR M: Modules.Module; beg, end, time: LONGINT; T: Texts.Text; S: Texts.Scanner; i: INTEGER;
BEGIN
	Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
	IF (S.class = Texts.Char) & (S.c = "^") THEN
		Oberon.GetSelection(T, beg, end, time);
		IF time # -1 THEN Texts.OpenScanner(S, T, beg); Texts.Scan(S) END
	END;
	IF S.class = Texts.Name THEN
		i := 0; WHILE (S.s[i] # 0X) & (S.s[i] # ".") DO INC(i) END; S.s[i] := 0X;
		M := Modules.ThisMod(S.s);
		IF M # NIL THEN
			T := TextFrames.Text("");
			i := 0; 
			WHILE i < LEN(M.cmds^) DO
				Texts.WriteString(W, S.s); Texts.Write(W, "."); 
				Texts.WriteString(W, M.cmds[i].name); 
				Texts.WriteLn(W); INC(i)
			END;
			Texts.Append(T, W.buf);
			OpenText("Commands", T, TRUE)
		ELSE
			Texts.WriteString(W, Modules.resMsg);  Texts.WriteLn(W);  
			Texts.Append(Oberon.Log, W.buf)
		END
	END
END ShowCommands;

PROCEDURE ShowTasks*;
VAR T: Texts.Text;  n: Oberon.Task;  ofs, t: LONGINT;  m: Modules.Module;
BEGIN
	n := Oberon.NextTask;  t := Input.Time();
	REPEAT
		ofs := SYSTEM.VAL(LONGINT, n.handle);  m := Kernel.GetMod(ofs);
		Texts.WriteString(W, m.name);  Texts.WriteString(W, "  PC = ");
		IF Linux0.ARCH=ARM THEN (*Texts.WriteInt(W, ofs-m.sb, 1);*)
		ELSE Texts.WriteInt(W, ofs-m.cb, 1);
		END;
		IF n.safe THEN Texts.WriteString(W, "  safe  ")
		ELSE Texts.WriteString(W, "  unsafe  ")
		END;
		Texts.WriteInt(W, n.time, 1);
		IF n.time - t <= 0 THEN 
			Texts.WriteString(W, " ready")
		ELSE
			Texts.WriteString(W, " waiting ");  Texts.WriteInt(W, (n.time-t)*1000 DIV Input.TimeUnit, 1);  
			Texts.WriteString(W, "ms")
		END;
		Texts.WriteLn(W);
		n := n.next
	UNTIL n = Oberon.NextTask;
	T := TextFrames.Text("");
	Texts.Append(T, W.buf);
	OpenText("Tasks", T, TRUE)
END ShowTasks;

PROCEDURE WriteTrap(VAR W: Texts.Writer;  error, page: LONGINT);
BEGIN
	Texts.WriteString(W, "TRAP "); Texts.WriteInt(W, error, 1);
	Texts.WriteString(W, "  ");
	CASE error OF
		1: Texts.WriteString(W, "WITH guard failed")
		|2: Texts.WriteString(W, "CASE invalid")
		|3: Texts.WriteString(W, "RETURN missing")
		|4: Texts.WriteString(W, "Overflow")
		|5: Texts.WriteString(W, "Implicit type guard failed")
		|6: Texts.WriteString(W, "Type guard failed")
		|7: Texts.WriteString(W, "Index out of range")
		|8: Texts.WriteString(W, "ASSERT failed")
		|9: Texts.WriteString(W, "Array dimension error")
		|10: Texts.WriteString(W, "Division by zero")
		|11: Texts.WriteString(W, "General protection fault")
		|12: Texts.WriteString(W, "Stack overflow")
		|13: Texts.WriteString(W, "Keyboard interrupt")
		|14: Texts.WriteString(W, "Out of memory")
		|15: Texts.WriteString(W, "Bad sector number")
		|16: Texts.WriteString(W, "Disk full")
		|17: Texts.WriteString(W, "Disk error")
		|18: Texts.WriteString(W, "File too large")
		|19: Texts.WriteString(W, "Buffer overflow")
(*				(* for NCFS/OFS *)
		|20: Texts.WriteString(W, "Volume full")
		|21: Texts.WriteString(W, "Volume write-protected")
		|22: Texts.WriteString(W, "Volume not found")
		|23: Texts.WriteString(W, "Illegal Access")
		|24: Texts.WriteString(W, "Volume in use")
		|25: Texts.WriteString(W, "Volume modified")
		|26: Texts.WriteString(W, "Not a valid volume")
		|27: Texts.WriteString(W, "Cannot contact server ")
*)
		|28: Texts.WriteString(W, "Invalid instruction")
		|29:	(* page fault *)
			IF (page >= -4) & (page < 4096) THEN Texts.WriteString(W, "NIL reference (")
			ELSIF (page >= 10000000H) & (page < Kernel.StackOrg) THEN Texts.WriteString(W, "Stack overflow (")	(* stack overflow detection would need sigaltstack	*)
			ELSE Texts.WriteString(W, "Page fault (")
			END;
			Texts.WriteHex(W, page); Texts.WriteString(W, " H )")
	ELSE
		IF error = MAX(INTEGER) THEN Texts.WriteString(W, "Trace ");  Texts.WriteInt(W, trap, 1);  INC(trap)
		ELSIF error>=0 THEN Texts.WriteString(W, "HALT statement")
		ELSE Texts.WriteString(W, "negative Linux Signal")
		END
	END;
	Texts.WriteString(W, " ("); Texts.WriteString(W, Kernel.version); Texts.Write(W, ")")
END WriteTrap;

PROCEDURE Trap*(error, fp, pc, page: LONGINT);	(** non-portable *)	(* exported for Debug debugger *)
VAR
	T: Texts.Text;  refpos: LONGINT;
	mod: Modules.Module;  lastfp, base: LONGINT;  refs: Kernel.Bytes;
BEGIN
	INC(trapped);
	IF trapped = 1 THEN
		Display.ResetClip;
		IF error # MAX(INTEGER) THEN Viewers.Close(NIL) END;	(* close offending viewer, if any *)
		T := TextFrames.Text("");
		WriteTrap(W, error, page); Texts.WriteLn(W);
		LOOP
			mod := Kernel.GetMod(pc);
			WriteProc(mod, pc, fp, refs, refpos, base);  Texts.WriteLn(W);
			lastfp := fp;
 			Kernel.GetFrame0( fp);
			IF ((Linux0.ARCH#ARM) OR (Linux0.ARCH#X86))  THEN base := fp END;	(* for variables *)
			IF refpos # -1 THEN Variables(refs, refpos, base) END;
			Kernel.GetFrame( fp, pc);
			IF (fp < lastfp) OR (fp >= Kernel.StackOrg) THEN EXIT END; (* not called from stack *)
		END;
		Texts.Append(T, W.buf);
		OpenText("Trap", T, TRUE)
	ELSIF trapped = 2 THEN
		T := TextFrames.Text(""); Texts.WriteLn(W);
		Texts.WriteString(W, "TRAP "); Texts.WriteInt(W, error, 3);  Texts.WriteString(W, " (recursive)");
		Texts.WriteLn(W); Texts.Append(T, W.buf);
		OpenText("Trap", T, TRUE)
	ELSIF trapped = 3 THEN
		Texts.WriteLn(W);  Texts.WriteString(W, "TRAP "); Texts.WriteInt(W, error, 3);
		Texts.WriteString(W, " (recursive)");  Texts.WriteLn(W);  Texts.Append(Oberon.Log, W.buf)
	ELSE (* skip *)
	END;
	trapped := 0
END Trap;

PROCEDURE Quit*;
BEGIN
(*
	Oberon.OpenTrack(0, Display.Width);
	Display.ReplConst(Display.FG, 0, 0, Display.Width, Display.Height, Display.replace);
*)
	Kernel.Shutdown(1)
END Quit;

PROCEDURE Reboot*;	(** non-portable *)
BEGIN
	Kernel.Shutdown(2)
END Reboot;

PROCEDURE Cleanup;
BEGIN
		(* this message should really appear after shutting down all file systems, but writing it may need a file system! *)
	IF (*Kernel.shutdown*) 1 = 1 THEN
		Texts.SetColor(W, 1); Texts.WriteString(W, "System module unloaded. This makes Oberon instable. Please execute System.Quit !");
		Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
	END
END Cleanup;

PROCEDURE LogHandler(me: Oberon.Task);
VAR s: ARRAY 80 OF CHAR;  i: LONGINT;
BEGIN
(*	Kernel.GetLog(s);
*)	i := 0;
	WHILE s[i] # 0X DO
		IF s[i] = 0DX THEN Texts.WriteLn(W)
		ELSIF s[i] # 0AX THEN Texts.Write(W, s[i])
		ELSE (* skip *)
		END;
		INC(i)
	END;
	IF i # 0 THEN Texts.Append(log, W.buf) END
END LogHandler;

PROCEDURE OpenKernelLog*;	(** non-portable *)
CONST KernelLog="Kernel.Log";
BEGIN
	IF log = NIL THEN
		NEW(log);  Texts.Open(log, KernelLog)
	END;
	ASSERT(log#NIL, 70);
(*
	IF task = NIL THEN
		NEW(task);  task.safe := TRUE;  task.handle := LogHandler;  Oberon.Install(task)
	END;
*)
	OpenText(KernelLog, log, TRUE);
END OpenKernelLog;

(* Copy selected text to input clipboard buffer *)
PROCEDURE CopyClip;
	VAR t: Texts.Text; beg, end, time, i, size: LONGINT; r: Texts.Reader; 
BEGIN
	Oberon.GetSelection(t, beg, end, time);
	IF time >= 0 THEN
		Texts.OpenReader(r, t, beg);
		size:=end-beg;
		NEW(Input.clip, size);
		i:=0;
		WHILE i < size DO
			Texts.Read(r, Input.clip[i]);
			IF Input.clip[i]=CR THEN Input.clip[i]:=LF END;
			INC(i);
		END;
	END;
END CopyClip;

(* Paste input buffer to caret*)
PROCEDURE PasteClip;
	VAR i: LONGINT; M: Oberon.InputMsg;
BEGIN
	i:=0;
	WHILE i<LEN(Input.clip^) DO
		IF Input.clip[i]=LF THEN Input.clip[i]:=CR END;
		 M.F := NIL; M.id := Oberon.consume; M.ch := Input.clip[i]; M.fnt := Oberon.CurFnt; M.col := Oberon.CurCol; M.voff := Oberon.CurOff;
	     Display.Broadcast(M); INC(i);
	END;
END PasteClip;

PROCEDURE Init*;	(** non-portable, for internal use *)	(* called from Oberon init, when Oberon Text is ready *)
VAR
	S: Texts.Scanner;  Wt: Texts.Writer;  ok: BOOLEAN;
	T: Texts.Text;  F: TextFrames.Frame; f: Fonts.Font;
BEGIN 
	IF ~init THEN
		init := TRUE;	(* avoid user call *)
		Texts.OpenWriter(Wt);
		Oberon.OpenScanner(S, "System.InitCommands");
		IF S.class = Texts.Inval THEN
			OpenLog;
			OpenText("System.Tool", TextFrames.Text("System.Tool"), TRUE);
		ELSE
			WHILE ~S.eot & (S.class = Texts.Char) & (S.c = "{") DO
				ok := FALSE;  Texts.Scan(S);
				IF S.class = Texts.Name THEN
					ok := TRUE;  Texts.WriteString(Wt, S.s)
				END;
				IF ~((S.class = Texts.Char) & (S.c = "}")) THEN
					WHILE ~S.eot & (S.nextCh # "}") DO
						IF ok THEN Texts.Write(Wt, S.nextCh) END;
						Texts.Read(S, S.nextCh)
					END
				END;
				IF ok THEN
					Texts.WriteLn(Wt);  T := TextFrames.Text("");  Texts.Append(T, Wt.buf);
					F := TextFrames.NewText(T, 0);  TextFrames.Call(F, 0, FALSE)
				END;
				Texts.Scan(S);  Texts.Scan(S)
			END
		END;
		Oberon.OpenScanner(S, "System.DefaultFont");
		IF S.class IN {Texts.Name, Texts.String} THEN
			f := Fonts.This(S.s);
			IF f # NIL THEN Fonts.Default := f; Oberon.SetFont(NIL) END
		END;
		Oberon.Loop	(* should never return *)
	END;
END Init;

PROCEDURE Greetings;
BEGIN
	Oberon.GetClock(time0, date0); Texts.WriteString(W, "System.Time");
	Texts.WriteDate(W, time0, date0);  Texts.WriteLn(W);
	Texts.WriteString(W, Kernel.version);  Texts.WriteString(W, Linux0.ARCH); Texts.WriteString(W, Kernel.DATE); Texts.WriteLn(W);
	Texts.Append(Oberon.Log, W.buf);
END Greetings;

BEGIN
	Kernel.EnableGC;
	Texts.OpenWriter(W);
	init := FALSE;  trapped := 0;  trap := 0;
	task := NIL;  log := NIL;
	Kernel.InstallLoop(Oberon.Loop);
	Kernel.InstallTrap(Trap);
	Oberon.Log := TextFrames.Text("");
	Modules.InstallTermHandler(Cleanup);
	Greetings;
	Input.CopyClip:=CopyClip;
	Input.PasteClip:= PasteClip;
END System.

System.Directory Oberon*
System.Directory Oberon*\d
System.Directory Oberon*\t
System.Directory Oberon*\s
System.Directory Oberon*\df
System.Directory Oberon*\tf
System.Directory Oberon*\sf
