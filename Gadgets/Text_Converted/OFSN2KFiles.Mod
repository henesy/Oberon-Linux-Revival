(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSN2KFiles;   (* pjm/bsm *)

(* Based on Native 2.3.7 Disk.Mod, FileDir.Mod, Files.Mod *)

IMPORT SYSTEM, Kernel, OFS;

(*
File Directory is a B-tree with its root page at DirRootAdr.
Each entry contains a file name and the disk address of the file's head sector
*)

CONST
	thisModuleName = "OFSN2KFiles";	(* used for kernel log messages *)
	DEBUG = FALSE;
	
	MinVolSize = 4;

(* constants from FileDir *)

	SF = 29;
	FnLength = 32;
	SecTabSize = 64;
	ExTabSize = 12;
	SectorSize = 2048;
	IndexSize = SectorSize DIV 4;
	HeaderSize  = 352;
	DirRootAdr  = 1*SF;
	DirPgSize = 50;
	N = DirPgSize DIV 2;
	DirMark = 9B1EA38DH;
	HeaderMark = 9BA71D86H;
	FillerSize = 36;
	MapIndexSize = (SectorSize-4) DIV 4;
	MapSize = SectorSize DIV 4;	(* {MapSize MOD 32 = 0} *)
	MapMark = 9C2F977FH;
	
(* constants from Files *)

	MaxBufs = 4;
	HS = HeaderSize;
	SS = SectorSize;
	STS = SecTabSize;
	XS = IndexSize;
	InitHint = 200*SF;

TYPE
(* types from Disk *)

	DiskSector = RECORD END;
	
(* types from FileDir *)

	DiskAdr = LONGINT;
	FileName  = ARRAY FnLength OF CHAR;
	SectorTable = ARRAY SecTabSize OF DiskAdr;
	ExtensionTable = ARRAY ExTabSize OF DiskAdr;
	
	FileHeader = RECORD (DiskSector)   (*allocated in the first page of each file on disk*)
		mark: LONGINT;
		name: FileName;
		aleng, bleng: INTEGER;
		date, time: LONGINT;
		ext:  ExtensionTable;
		sec: SectorTable;
		fill: ARRAY SectorSize - HeaderSize OF CHAR;
	END ;

	IndexSector = RECORD (DiskSector)
		x: ARRAY IndexSize OF DiskAdr
	END ;

	DataSector = RECORD (DiskSector)
		B: ARRAY SectorSize OF SYSTEM.BYTE
	END ;

	DirEntry =  (*B-tree node*) RECORD
		name: FileName;
		adr:  DiskAdr; (*sec no of file header*)
		p: DiskAdr  (*sec no of descendant in directory*)
	END ;

	DirPage  = RECORD (DiskSector)
		mark:  LONGINT;
		m:     INTEGER;
		p0:    DiskAdr;  (*sec no of left descendant in directory*)
		fill:  ARRAY FillerSize OF CHAR;
		e:  ARRAY DirPgSize OF DirEntry
	END ;

	MapIndex = RECORD (DiskSector)
		mark: LONGINT;
		index: ARRAY MapIndexSize OF DiskAdr
	END;
		
	MapSector = RECORD (DiskSector)
		map: ARRAY MapSize OF SET
	END;
	
(* types from Files *)

	Buffer = POINTER TO BufferRecord;
	FileHd = POINTER TO FileHeader;
	Index = POINTER TO IndexRecord;
	
	File = POINTER TO RECORD (OFS.File)
		aleng, bleng: INTEGER;
		nofbufs: INTEGER;
		modH, registered: BOOLEAN;
		firstbuf: Buffer;
		sechint: DiskAdr;
		name: FileName;
		time, date: LONGINT;
		ext: ARRAY ExTabSize OF Index; (* indirect: ext->index->data *)
		sec: SectorTable (* direct: sec->data *)
	END;
	
	BufferRecord = RECORD (OFS.HintDesc)
		apos, lim: INTEGER;
		mod: BOOLEAN;
		next: Buffer;
		data: DataSector
	END;

	IndexRecord = RECORD
		adr: DiskAdr;
		mod: BOOLEAN;
		sec: IndexSector
	END;
		
(* new types *)

	FileSystem = POINTER TO RECORD (OFS.FileSystem)	(* our file system type *)
	END;

VAR
	pat: ARRAY 32 OF CHAR;
	pos: INTEGER;
	hp: POINTER TO FileHeader;	(* ptr so as not to take inner core space *)
	fullname: OFS.FileName;
	
(* procedures from Disk *)

PROCEDURE GetSector(vol: OFS.Volume; src: DiskAdr;  VAR dest: DiskSector);
BEGIN
	IF src MOD SF # 0 THEN SYSTEM.HALT(15) END;
	vol.GetBlock(vol, src DIV SF, dest)
END GetSector;

PROCEDURE PutSector(vol: OFS.Volume;  dest: DiskAdr;  VAR src: DiskSector);
BEGIN
	ASSERT(~(OFS.ReadOnly IN vol.flags));
	IF dest MOD SF # 0 THEN SYSTEM.HALT(15) END;
	vol.PutBlock(vol, dest DIV SF, src)
END PutSector;

PROCEDURE AllocSector(vol: OFS.Volume;  hint: DiskAdr;  VAR sec: DiskAdr);
BEGIN
	ASSERT(~(OFS.ReadOnly IN vol.flags));
	vol.AllocBlock(vol, hint DIV SF, sec);
	sec := sec * SF
END AllocSector;

PROCEDURE MarkSector(vol: OFS.Volume;  sec: LONGINT);
BEGIN
	ASSERT(~(OFS.ReadOnly IN vol.flags));
	vol.MarkBlock(vol, sec DIV SF)
END MarkSector;

PROCEDURE FreeSector(vol: OFS.Volume;  sec: LONGINT);
BEGIN
	ASSERT(~(OFS.ReadOnly IN vol.flags));
	vol.FreeBlock(vol, sec DIV SF)
END FreeSector;

PROCEDURE Marked(vol: OFS.Volume;  sec: LONGINT): BOOLEAN;
BEGIN
	ASSERT(~(OFS.ReadOnly IN vol.flags));
	RETURN vol.Marked(vol, sec DIV SF)
END Marked;

PROCEDURE Size(vol: OFS.Volume): LONGINT;
BEGIN
	ASSERT(vol.size >= MinVolSize);
	RETURN vol.size
END Size;

(* procedures from FileDir *)

PROCEDURE Search(vol: OFS.Volume; VAR name: ARRAY OF CHAR; VAR A: DiskAdr);
VAR i, L, R: INTEGER; dadr: DiskAdr; a: DirPage;
BEGIN
	dadr := DirRootAdr;
	LOOP
		GetSector(vol, dadr, a);
		ASSERT(a.mark = DirMark);
		L := 0; R := a.m; (*binary search*)
		WHILE L < R DO
			i := (L+R) DIV 2;
			IF name <= a.e[i].name THEN R := i ELSE L := i+1 END
		END ;
		IF (R < a.m) & (name = a.e[R].name) THEN
			A := a.e[R].adr; EXIT (*found*)
		END ;
		IF R = 0 THEN dadr := a.p0 ELSE dadr := a.e[R-1].p END ;
		IF dadr = 0 THEN A := 0; EXIT  (*not found*) END
	END
END Search;

PROCEDURE insert(vol: OFS.Volume;  VAR name: FileName; dpg0:  DiskAdr; VAR h: BOOLEAN;
		VAR v: DirEntry; fad: DiskAdr; VAR repFad: DiskAdr);(*bsm*)
	(*h = "tree has become higher and v is ascending element"*)
	VAR ch: CHAR;
		i, j, L, R: INTEGER;
		dpg1: DiskAdr;
		u: DirEntry;
		a: DirPage;

BEGIN (*~h*) GetSector(vol, dpg0, a);
	L := 0; R := a.m; (*binary search*)
	WHILE L < R DO
		i := (L+R) DIV 2;
		IF name <= a.e[i].name THEN R := i ELSE L := i+1 END
	END ;
	repFad := 0;
	IF (R < a.m) & (name = a.e[R].name) THEN
		repFad := a.e[R].adr;
		a.e[R].adr := fad; PutSector(vol, dpg0, a)  (*replace*)
	ELSE (*not on this page*)
		IF R = 0 THEN dpg1 := a.p0 ELSE dpg1 := a.e[R-1].p END ;
		IF dpg1 = 0 THEN (*not in tree, insert*)
			u.adr := fad; u.p := 0; h := TRUE; j := 0;
			REPEAT ch := name[j]; u.name[j] := ch; INC(j)
			UNTIL ch = 0X;
			WHILE j < FnLength DO u.name[j] := 0X; INC(j) END
		ELSE
			insert(vol, name, dpg1, h, u, fad, repFad)
		END ;
		IF h THEN (*insert u to the left of e[R]*)
			IF a.m < DirPgSize THEN
				h := FALSE; i := a.m;
				WHILE i > R DO DEC(i); a.e[i+1] := a.e[i] END ;
				a.e[R] := u; INC(a.m)
			ELSE (*split page and assign the middle element to v*)
				a.m := N; a.mark := DirMark;
				IF R < N THEN (*insert in left half*)
					v := a.e[N-1]; i := N-1;
					WHILE i > R DO DEC(i); a.e[i+1] := a.e[i] END ;
					a.e[R] := u; PutSector(vol, dpg0, a);
					AllocSector(vol, dpg0, dpg0); i := 0;
					WHILE i < N DO a.e[i] := a.e[i+N]; INC(i) END
				ELSE (*insert in right half*)
					PutSector(vol, dpg0, a);
					AllocSector(vol, dpg0, dpg0); DEC(R, N); i := 0;
					IF R = 0 THEN v := u
					ELSE v := a.e[N];
						WHILE i < R-1 DO a.e[i] := a.e[N+1+i]; INC(i) END ;
						a.e[i] := u; INC(i)
					END ;
					WHILE i < N DO a.e[i] := a.e[N+i]; INC(i) END
				END ;
				a.p0 := v.p; v.p := dpg0
			END ;
			PutSector(vol, dpg0, a)
		END
	END
END insert;

PROCEDURE Insert(vol: OFS.Volume; VAR name: FileName; fad: DiskAdr; VAR repFad: DiskAdr);
	VAR  oldroot: DiskAdr; h: BOOLEAN; U: DirEntry; a: DirPage;
BEGIN
	h := FALSE;
	insert(vol, name, DirRootAdr, h, U, fad, repFad);(*bsm*)
	IF h THEN (*root overflow*)
		GetSector(vol, DirRootAdr, a);
		AllocSector(vol, DirRootAdr, oldroot); PutSector(vol, oldroot, a);
		a.mark := DirMark; a.m := 1; a.p0 := oldroot; a.e[0] := U;
		PutSector(vol, DirRootAdr, a)
	END
END Insert;

PROCEDURE underflow(vol: OFS.Volume;  VAR c: DirPage;  (*ancestor page*)
	dpg0:  DiskAdr; s: INTEGER;  (*insertion point in c*) VAR h: BOOLEAN); (*c undersize*)
	VAR i, k: INTEGER;
			dpg1: DiskAdr;
			a, b: DirPage;  (*a := underflowing page, b := neighbouring page*)
BEGIN GetSector(vol, dpg0, a);
	(*h & a.m = N-1 & dpg0 = c.e[s-1].p*)
	IF s < c.m THEN (*b := page to the right of a*)
		dpg1 := c.e[s].p; GetSector(vol, dpg1, b);
		k := (b.m-N+1) DIV 2; (*k = no. of items available on page b*)
		a.e[N-1] := c.e[s]; a.e[N-1].p := b.p0;
		IF k > 0 THEN
			(*move k-1 items from b to a, one to c*) i := 0;
			WHILE i < k-1 DO a.e[i+N] := b.e[i]; INC(i) END ;
			c.e[s] := b.e[i]; b.p0 := c.e[s].p;
			c.e[s].p := dpg1; DEC(b.m, k); i := 0;
			WHILE i < b.m DO b.e[i] := b.e[i+k]; INC(i) END ;
			PutSector(vol, dpg1, b); a.m := N-1+k; h := FALSE
		ELSE (*merge pages a and b, discard b*) i := 0;
			WHILE i < N DO a.e[i+N] := b.e[i]; INC(i) END ;
			i := s; DEC(c.m);
			WHILE i < c.m DO c.e[i] := c.e[i+1]; INC(i) END ;
			a.m := 2*N; h := c.m < N
		END ;
		PutSector(vol, dpg0, a)
	ELSE (*b := page to the left of a*) DEC(s);
		IF s = 0 THEN dpg1 := c.p0 ELSE dpg1 := c.e[s-1].p END ;
		GetSector(vol, dpg1, b);
		k := (b.m-N+1) DIV 2; (*k = no. of items available on page b*)
		IF k > 0 THEN
			i := N-1;
			WHILE i > 0 DO DEC(i); a.e[i+k] := a.e[i] END ;
			i := k-1; a.e[i] := c.e[s]; a.e[i].p := a.p0;
			(*move k-1 items from b to a, one to c*) DEC(b.m, k);
			WHILE i > 0 DO DEC(i); a.e[i] := b.e[i+b.m+1] END ;
			c.e[s] := b.e[b.m]; a.p0 := c.e[s].p;
			c.e[s].p := dpg0; a.m := N-1+k; h := FALSE;
			PutSector(vol, dpg0, a)
		ELSE (*merge pages a and b, discard a*)
			c.e[s].p := a.p0; b.e[N] := c.e[s]; i := 0;
			WHILE i < N-1 DO b.e[i+N+1] := a.e[i]; INC(i) END ;
			b.m := 2*N; DEC(c.m); h := c.m < N
		END ;
		PutSector(vol, dpg1, b)
	END
END underflow;

PROCEDURE delete(vol: OFS.Volume; VAR name: FileName; dpg0: DiskAdr;
	VAR h: BOOLEAN; VAR fad: DiskAdr);
(*search and delete entry with key name; if a page underflow arises,
	balance with adjacent page or merge; h := "page dpg0 is undersize"*)

	VAR i, L, R: INTEGER;
		dpg1: DiskAdr;
		a: DirPage;

	PROCEDURE del(dpg1: DiskAdr; VAR h: BOOLEAN);
		VAR dpg2: DiskAdr;  (*global: a, R*)
				b: DirPage;
	BEGIN GetSector(vol, dpg1, b); dpg2 := b.e[b.m-1].p;
		IF dpg2 # 0 THEN del(dpg2, h);
			IF h THEN underflow(vol, b, dpg2, b.m, h); PutSector(vol, dpg1, b) END
		ELSE
			b.e[b.m-1].p := a.e[R].p; a.e[R] := b.e[b.m-1];
			DEC(b.m); h := b.m < N; PutSector(vol, dpg1, b)
		END
	END del;

BEGIN (*~h*) GetSector(vol, dpg0, a);
	L := 0; R := a.m; (*binary search*)
	WHILE L < R DO
		i := (L+R) DIV 2;
		IF name <= a.e[i].name THEN R := i ELSE L := i+1 END
	END ;
	IF R = 0 THEN dpg1 := a.p0 ELSE dpg1 := a.e[R-1].p END ;
	IF (R < a.m) & (name = a.e[R].name) THEN
		(*found, now delete*) fad := a.e[R].adr;
		IF dpg1 = 0 THEN  (*a is a leaf page*)
			DEC(a.m); h := a.m < N; i := R;
			WHILE i < a.m DO a.e[i] := a.e[i+1]; INC(i) END
		ELSE del(dpg1, h);
			IF h THEN underflow(vol, a, dpg1, R, h) END
		END ;
		PutSector(vol, dpg0, a)
	ELSIF dpg1 # 0 THEN
		delete(vol, name, dpg1, h, fad);
		IF h THEN underflow(vol, a, dpg1, R, h); PutSector(vol, dpg0, a) END
	ELSE (*not in tree*) fad := 0
	END
END delete;

PROCEDURE DirDelete(vol: OFS.Volume; VAR name: FileName; VAR fad: DiskAdr);
	VAR h: BOOLEAN; newroot: DiskAdr; a: DirPage;
BEGIN
	h := FALSE;
	delete(vol, name, DirRootAdr, h, fad);
	IF h THEN (*root underflow*)
		GetSector(vol, DirRootAdr, a);
		IF (a.m = 0) & (a.p0 # 0) THEN
			newroot := a.p0; GetSector(vol, newroot, a);
			PutSector(vol, DirRootAdr, a) (*discard newroot*)
		END
	END
END DirDelete;

PROCEDURE match(VAR name: ARRAY OF CHAR): BOOLEAN;
VAR i0, i1, j0, j1: INTEGER;  f: BOOLEAN;
BEGIN
	i0 := pos;  j0 := pos;  f := TRUE;
	LOOP
		IF pat[i0] = "*" THEN
			INC(i0);
			IF pat[i0] = 0X THEN EXIT END
		ELSE
			IF name[j0] # 0X THEN f := FALSE END;
			EXIT
		END;
		f := FALSE;
		LOOP
			IF name[j0] = 0X THEN EXIT END;
			i1 := i0;  j1 := j0;
			LOOP
				IF (pat[i1] = 0X) OR (pat[i1] = "*") THEN f := TRUE; EXIT END;
				IF pat[i1] # name[j1] THEN EXIT END;
				INC(i1);  INC(j1)
			END;
			IF f THEN j0 := j1; i0 := i1; EXIT END;
			INC(j0)
		END;
		IF ~f THEN EXIT END
	END;
	RETURN f & (name[0] # 0X)
END match;

PROCEDURE enumerate(fs: OFS.FileSystem; VAR prefix: ARRAY OF CHAR; dpg: DiskAdr; VAR flags :SET; proc: OFS.EntryHandler);
VAR i, j, diff: INTEGER; dpg1: DiskAdr; a: DirPage;  time, date, size: LONGINT;
BEGIN GetSector(fs.vol, dpg, a); i := 0;
	WHILE (i < a.m) & ~(OFS.EnumStop IN flags) DO
		j := 0;
		LOOP
			IF prefix[j] = 0X THEN diff := 0; EXIT END ;
			diff := ORD(a.e[i].name[j]) - ORD(prefix[j]);
			IF diff # 0 THEN EXIT END ;
			INC(j)
		END ;
		IF i = 0 THEN dpg1 := a.p0 ELSE dpg1 := a.e[i-1].p END ;
		IF diff >= 0 THEN (*matching prefix*)
			IF dpg1 # 0 THEN enumerate(fs, prefix, dpg1, flags, proc) END ;
			IF diff = 0 THEN
				IF ~(OFS.EnumStop IN flags) & ((pos = -1) OR match(a.e[i].name)) THEN
					IF flags * {OFS.EnumSize, OFS.EnumTime} # {} THEN
						GetSector(fs.vol, a.e[i].adr, hp^);
						time := hp.time;  date := hp.date;
						size := LONG(hp.aleng)*SectorSize + hp.bleng - HeaderSize
					ELSE
						time := 0; date := 0; size := MIN(LONGINT)
					END;
					IF fs = OFS.First() THEN
						proc(a.e[i].name, time, date, size, flags)
					ELSE
						OFS.JoinName(fs.prefix, a.e[i].name, fullname);
						proc(fullname, time, date, size, flags)
					END
				END
			ELSE INCL(flags, OFS.EnumStop)
			END
		END ;
		INC(i)
	END ;
	IF ~(OFS.EnumStop IN flags) & (i > 0) & (a.e[i-1].p # 0) THEN
		enumerate(fs, prefix, a.e[i-1].p, flags, proc)
	END
END enumerate;

PROCEDURE Enumerate(fs: OFS.FileSystem; mask: ARRAY OF CHAR; VAR flags: SET; proc: OFS.EntryHandler);
	VAR b: BOOLEAN;
BEGIN
	COPY(mask, pat);
	pos := 0;  WHILE (pat[pos] # 0X) & (pat[pos] # "*") DO INC(pos) END;
	IF pat[pos] # "*" THEN	(* no * found *)
		pos := -1
	ELSIF (pat[pos] = "*") & (pat[pos+1] = 0X) THEN	(* found * at end *)
		mask[pos] := 0X;  pos := -1
	ELSE
		mask[pos] := 0X
	END;
	enumerate(fs, mask, DirRootAdr, flags, proc)
END Enumerate;

PROCEDURE DirInit(vol: OFS.Volume; VAR init: BOOLEAN);
	VAR k: INTEGER;
			A: ARRAY 2000 OF DiskAdr;
			files: LONGINT;  bad: BOOLEAN;

	PROCEDURE MarkSectors;
		VAR L, R, i, j, n: INTEGER; x: DiskAdr;
			hd: FileHeader;
			B: IndexSector;

		PROCEDURE sift(L, R: INTEGER);
			VAR i, j: INTEGER; x: DiskAdr;
		BEGIN j := L; x := A[j];
			LOOP i := j; j := 2*j + 1;
				IF (j+1 < R) & (A[j] < A[j+1]) THEN INC(j) END ;
				IF (j >= R) OR (x > A[j]) THEN EXIT END ;
				A[i] := A[j]
			END ;
			A[i] := x
		END sift;

	BEGIN
		Kernel.WriteString(" marking");
		L := k DIV 2; R := k; (*heapsort*)
		WHILE L > 0 DO DEC(L); sift(L, R) END ;
		WHILE R > 0 DO
			DEC(R); x := A[0]; A[0] := A[R]; A[R] := x; sift(L, R)
		END;
		WHILE L < k DO
			bad := FALSE; INC(files);
			IF files MOD 128 = 0 THEN Kernel.WriteChar(".") END;
			GetSector(vol, A[L], hd);
			IF hd.aleng < SecTabSize THEN j := hd.aleng + 1;
				REPEAT
					DEC(j);
					IF hd.sec[j] # 0 THEN MarkSector(vol, hd.sec[j]) ELSE hd.aleng := j-1; bad := TRUE END
				UNTIL j = 0
			ELSE
				j := SecTabSize;
				REPEAT
					DEC(j);
					IF hd.sec[j] # 0 THEN MarkSector(vol, hd.sec[j]) ELSE hd.aleng := j-1; bad := TRUE END
				UNTIL j = 0;
				n := (hd.aleng - SecTabSize) DIV IndexSize; i := 0;
				WHILE (i <= n) & ~bad DO
					IF hd.ext[i] # 0 THEN
						MarkSector(vol, hd.ext[i]);
						GetSector(vol, hd.ext[i], B); (*index sector*)
						IF i < n THEN j := IndexSize ELSE j := (hd.aleng - SecTabSize) MOD IndexSize + 1 END ;
						REPEAT
							DEC(j);
							IF (B.x[j] MOD SF = 0) & (B.x[j] > 0) THEN MarkSector(vol, B.x[j]) ELSE bad := TRUE END
						UNTIL j = 0;
						INC(i)
					ELSE bad := TRUE
					END;
					IF bad THEN
						IF i = 0 THEN hd.aleng := SecTabSize-1 ELSE hd.aleng := SecTabSize + (i-1) * IndexSize END
					END
				END
			END;
			IF bad THEN
				Kernel.WriteLn; Kernel.WriteString(hd.name); Kernel.WriteString(" truncated");
				hd.bleng := SectorSize;  IF hd.aleng < 0 THEN hd.aleng := 0 (* really bad *) END;
				PutSector(vol, A[L], hd)
			END;
			INC(L)
		END
	END MarkSectors;

	PROCEDURE TraverseDir(dpg: DiskAdr);
		VAR i: INTEGER; a: DirPage;
	BEGIN GetSector(vol, dpg, a); MarkSector(vol, dpg); i := 0;
		WHILE i < a.m DO
			A[k] := a.e[i].adr; INC(k); INC(i);
			IF k = 2000 THEN MarkSectors; k := 0 END
		END ;
		IF a.p0 # 0 THEN
			TraverseDir(a.p0); i := 0;
			WHILE i < a.m DO
				TraverseDir(a.e[i].p); INC(i)
			END
		END
	END TraverseDir;

BEGIN
	IF ~(OFS.ReadOnly IN vol.flags) THEN
		k := 0;  init := FALSE;
		DirStartup(vol, init);
		IF ~init THEN
			files := 0;  
			Kernel.WriteString(thisModuleName);
			Kernel.WriteString(": Scanning ");
			Kernel.WriteString(vol.name);  Kernel.WriteString("...");
			TraverseDir(DirRootAdr); MarkSectors; init := TRUE;
			Kernel.WriteInt(files, 6); Kernel.WriteString(" files");  Kernel.WriteLn
		END
	ELSE
		init := TRUE
	END
END DirInit;

PROCEDURE DirStartup(vol: OFS.Volume;  VAR init: BOOLEAN);
VAR
	j, sec, size, q, free, thres: LONGINT;  mi: MapIndex;  ms: MapSector;
	s: ARRAY 10 OF CHAR;  found: BOOLEAN;
BEGIN
	size := Size(vol);  init := FALSE;  found := FALSE;
	IF (vol.Available(vol) = size) & (size # 0) THEN	(* all sectors available *)
		GetSector(vol, size*SF, mi);
		IF mi.mark = MapMark THEN
			j := 0;	(* check consistency of index *)
			WHILE (j # MapIndexSize) & (mi.index[j] >= 0) & (mi.index[j] MOD SF = 0) DO
				INC(j)
			END;
			IF j = MapIndexSize THEN
				found := TRUE;
				mi.mark := 0;  PutSector(vol, size*SF, mi);	(* invalidate index *)
				j := 0;  sec := 1;  q := 0;
				LOOP
					IF (j = MapIndexSize) OR (mi.index[j] = 0) THEN EXIT END;
					GetSector(vol, mi.index[j], ms);
					REPEAT
						IF (sec MOD 32) IN ms.map[sec DIV 32 MOD MapSize] THEN
							MarkSector(vol, sec*SF);
							INC(q)
						END;
						IF sec = size THEN EXIT END;
						INC(sec)
					UNTIL sec MOD (MapSize*32) = 0;
					INC(j)
				END;
				Kernel.GetConfig("DiskGC", s);
				thres := 0;  j := 0;
				WHILE s[j] # 0X DO thres := thres*10+(ORD(s[j])-48); INC(j) END;
				IF thres < 10 THEN thres := 10
				ELSIF thres > 100 THEN thres := 100
				END;
				ASSERT(q = size-vol.Available(vol));
				free := vol.Available(vol)*100 DIV size;
				IF (free > thres) & (vol.Available(vol)*SectorSize > 100000H) THEN
					init := TRUE
				ELSE	(* undo *)
					FOR j := SF TO size*SF BY SF DO
						IF Marked(vol, j) THEN FreeSector(vol, j) END
					END;
					ASSERT(vol.Available(vol) = size);
					Kernel.WriteString(thisModuleName);
					Kernel.WriteString(": ");  Kernel.WriteInt(free, 1);
					Kernel.WriteString("% free, forcing disk GC on ");  Kernel.WriteString(vol.name);  Kernel.WriteLn
				END
			END
		END;
		(*IF ~found THEN
			Kernel.WriteString(thisModuleName);
			Kernel.WriteString(": Index not found on ");  Kernel.WriteString(vol.name);  Kernel.WriteLn
		END*)
	END
END DirStartup;

PROCEDURE DirCleanup(vol: OFS.Volume);
VAR i, j, p, q, sec, size: LONGINT;  mi: MapIndex;  ms: MapSector;
BEGIN
	size := Size(vol);  i := size*SF;
	IF ~(OFS.ReadOnly IN vol.flags) & ~Marked(vol, i) THEN	(* last sector is free *)
		j := 0;  sec := 1;  q := 0;
		LOOP
			REPEAT DEC(i, SF) UNTIL (i = 0) OR ~Marked(vol, i);	(* find a free sector *)
			IF i = 0 THEN RETURN END;	(* no more space, don't commit *)
			mi.index[j] := i;  INC(j);
			FOR p := 0 TO MapSize-1 DO ms.map[p] := {} END;
			REPEAT
				IF Marked(vol, sec*SF) THEN
					INCL(ms.map[sec DIV 32 MOD MapSize], sec MOD 32);
					INC(q)
				END;
				IF sec = size THEN
					PutSector(vol, i, ms);
					EXIT
				END;
				INC(sec)
			UNTIL sec MOD (MapSize*32) = 0;
			PutSector(vol, i, ms)
		END;
		WHILE j # MapIndexSize DO mi.index[j] := 0; INC(j) END;
		mi.mark := MapMark;
		PutSector(vol, size*SF, mi);	(* commit *)
		Kernel.WriteString(thisModuleName);
		Kernel.WriteString(": Map saved on ");  Kernel.WriteString(vol.name);  Kernel.WriteLn
	END
END DirCleanup;

(* Procedures from Files *)

PROCEDURE Check(VAR s: ARRAY OF CHAR; VAR name: FileName; VAR res: INTEGER);
	VAR i: INTEGER; ch: CHAR;
BEGIN ch := s[0]; i := 0;
	IF ("A" <= CAP(ch)) & (CAP(ch) <= "Z") THEN
		LOOP name[i] := ch; INC(i); ch := s[i];
			IF ch = 0X THEN
				WHILE i < FnLength DO name[i] := 0X; INC(i) END ;
				res := 0; EXIT
			END ;
			IF ~(("A" <= CAP(ch)) & (CAP(ch) <= "Z")
				OR ("0" <= ch) & (ch <= "9") OR (ch = ".")) THEN res := 3; EXIT
			END ;
			IF i = FnLength-1 THEN res := 4; EXIT END
		END
	ELSIF ch = 0X THEN name[0] := 0X; res := -1
	ELSE res := 3
	END
END Check;

(* Creates a new file with the specified name. *)
PROCEDURE New(fs: OFS.FileSystem; name: ARRAY OF CHAR): OFS.File;
	VAR i, res: INTEGER; f: File; buf: Buffer; head: FileHd; namebuf: FileName;
BEGIN f := NIL; Check(name, namebuf, res);
	IF res <= 0 THEN
		NEW(buf); buf.apos := 0; buf.mod := TRUE; buf.lim := HS; buf.next := buf;
		head := SYSTEM.VAL(FileHd, SYSTEM.ADR(buf.data));
		head.mark := HeaderMark;
		head.aleng := 0; head.bleng := HS; head.name := namebuf;
		Kernel.GetClock(head.time, head.date);
		NEW(f); f.fs := fs; f.key := 0; f.aleng := 0; f.bleng := HS; f.modH := TRUE;
		f.time := head.time; f.date := head.date;
		f.firstbuf := buf; f.nofbufs := 1; f.name := namebuf; f.sechint := InitHint;
		f.registered := FALSE;
		i := 0; REPEAT f.ext[i] := NIL; head.ext[i] := 0; INC(i) UNTIL i = ExTabSize;
		i := 0; REPEAT f.sec[i] := 0; head.sec[i] := 0; INC(i) UNTIL i = STS
	END;
	RETURN f
END New;

PROCEDURE UpdateHeader(f: File; VAR h: FileHeader);
	VAR k: INTEGER;
BEGIN h.aleng := f.aleng; h.bleng := f.bleng;
	h.sec := f.sec; k := (f.aleng + (XS-STS)) DIV XS;
	WHILE k > 0 DO DEC(k); h.ext[k] := f.ext[k].adr END;
	h.date := f.date; h.time := f.time
END UpdateHeader;

PROCEDURE ReadBuf(f: File; buf: Buffer; pos: INTEGER);
	VAR sec: DiskAdr;
BEGIN
	IF pos < STS THEN sec := f.sec[pos]
	ELSE sec := f.ext[(pos-STS) DIV XS].sec.x[(pos-STS) MOD XS]
	END ;
	GetSector(f.fs.vol, sec, buf.data);
	IF pos < f.aleng THEN buf.lim := SS ELSE buf.lim := f.bleng END ;
	buf.apos := pos; buf.mod := FALSE
END ReadBuf;

PROCEDURE WriteBuf(f: File; buf: Buffer);
	VAR i, k: INTEGER; secadr: DiskAdr; inx: Index; vol: OFS.Volume;
BEGIN
	vol := f.fs.vol;
	Kernel.GetClock(f.time, f.date);  f.modH := TRUE;
	IF buf.apos < STS THEN
		secadr := f.sec[buf.apos];
		IF secadr = 0 THEN
			AllocSector(vol, f.sechint, secadr);
			f.modH := TRUE; f.sec[buf.apos] := secadr; f.sechint := secadr
		END;
		IF buf.apos = 0 THEN
			UpdateHeader(f, SYSTEM.VAL(FileHeader, buf.data)); f.modH := FALSE
		END
	ELSE i := (buf.apos - STS) DIV XS; inx := f.ext[i];
		IF inx = NIL THEN
			NEW(inx); inx.adr := 0; inx.sec.x[0] := 0; f.ext[i] := inx; f.modH := TRUE
		END ;
		k := (buf.apos - STS) MOD XS; secadr := inx.sec.x[k];
		IF secadr = 0 THEN
			AllocSector(vol, f.sechint, secadr);
			f.modH := TRUE; inx.mod := TRUE; inx.sec.x[k] := secadr; f.sechint := secadr
		END
	END;
	PutSector(vol, secadr, buf.data); buf.mod := FALSE
END WriteBuf;

PROCEDURE SearchBuf(f: File; pos: INTEGER): Buffer;
	VAR buf: Buffer;
BEGIN buf := f.firstbuf;
	LOOP
		IF buf.apos = pos THEN EXIT END ;
		buf := buf.next;
		IF buf = f.firstbuf THEN buf := NIL; EXIT END
	END;
	RETURN buf
END SearchBuf;

PROCEDURE GetBuf(f: File; pos: INTEGER): Buffer;
	VAR buf: Buffer;
BEGIN buf := f.firstbuf;
	LOOP
		IF buf.apos = pos THEN EXIT END ;
		IF buf.next = f.firstbuf THEN
			IF f.nofbufs < MaxBufs THEN (*allocate new buffer*)
				NEW(buf); buf.next := f.firstbuf.next; f.firstbuf.next := buf;
				INC(f.nofbufs)
			ELSE (*take one of the buffers*) f.firstbuf := buf;
				IF buf.mod THEN WriteBuf(f, buf) END
			END;
			buf.apos := pos;
			IF pos <= f.aleng THEN ReadBuf(f, buf, pos) END ;
			EXIT
		END;
		buf := buf.next
	END;
	RETURN buf
END GetBuf;

(* Return unique id for file, or 0 if it does not exist. *)
PROCEDURE FileKey(fs: OFS.FileSystem; name: ARRAY OF CHAR): LONGINT;
	VAR res: INTEGER; namebuf: FileName; header: DiskAdr;
BEGIN
	header := 0;
	Check(name, namebuf, res);
	IF res = 0 THEN
		Search(fs.vol, namebuf, header)
	END;
	RETURN header
END FileKey;

(* Open an existing file *)
PROCEDURE Old(fs: OFS.FileSystem; name: ARRAY OF CHAR): OFS.File;
	VAR i, k, res: INTEGER; f: File; header: DiskAdr; buf: Buffer; head: FileHd;
		namebuf: FileName; inxpg: Index; vol: OFS.Volume;
BEGIN
	f := NIL; Check(name, namebuf, res);
	IF res = 0 THEN
		vol := fs.vol;
		Search(vol, namebuf, header);
		IF header # 0 THEN
			NEW(buf); buf.apos := 0; buf.next := buf; buf.mod := FALSE;
			
			GetSector(vol, header, buf.data);
			head := SYSTEM.VAL(FileHd, SYSTEM.ADR(buf.data));

			NEW(f); f.fs := fs; f.key := header;
			f.aleng := head.aleng; f.bleng := head.bleng;
			f.time := head.time; f.date := head.date;
			IF f.aleng = 0 THEN buf.lim := f.bleng ELSE buf.lim := SS END ;
			f.firstbuf := buf; f.nofbufs := 1;
			f.name := namebuf;  f.registered := TRUE;
			f.sec := head.sec;
			k := (f.aleng + (XS-STS)) DIV XS; i := 0;
			WHILE i < k DO
				NEW(inxpg); inxpg.adr := head.ext[i]; inxpg.mod := FALSE;
				GetSector(vol, inxpg.adr, inxpg.sec); f.ext[i] := inxpg; INC(i)
			END;
			WHILE i < ExTabSize DO f.ext[i] := NIL; INC(i) END ;
			f.sechint := header; f.modH := FALSE
		END
	END;
	RETURN f
END Old;

PROCEDURE Unbuffer(f: File);
	VAR i, k: INTEGER; buf: Buffer; inx: Index; head: FileHeader; vol: OFS.Volume;
BEGIN
	vol := f.fs.vol;
	buf := f.firstbuf;
	REPEAT
		IF buf.mod THEN WriteBuf(f, buf) END;
		buf := buf.next
	UNTIL buf = f.firstbuf;
	k := (f.aleng + (XS-STS)) DIV XS; i := 0;
	WHILE i < k DO
		inx := f.ext[i]; INC(i);
		IF inx.mod THEN
			IF inx.adr = 0 THEN
				AllocSector(vol, f.sechint, inx.adr); f.sechint := inx.adr; f.modH := TRUE
			END;
			PutSector(vol, inx.adr, inx.sec); inx.mod := FALSE
		END
	END ;
	IF f.modH THEN
		GetSector(vol, f.sec[0], head); UpdateHeader(f, head);
		PutSector(vol, f.sec[0], head); f.modH := FALSE
	END
END Unbuffer;

(* Register a file created with New in the directory, replacing the previous file in the 
directory with the same name. The file is automatically closed. *)
PROCEDURE Register(f: OFS.File; VAR res: INTEGER);(*bsm*)
	VAR repAdr: DiskAdr; repFile: OFS.File;
BEGIN
	WITH f: File DO
		Unbuffer(f);
		IF ~f.registered & (f.name # "") THEN
			Insert(f.fs.vol, f.name, f.sec[0], repAdr);
			f.registered := TRUE; f.key := f.sec[0];
			IF (repAdr # 0) & (f.sec[0] # repAdr) THEN (*bsm*)
				repFile := OFS.FindOpenFile(f.fs, repAdr);
				IF repFile # NIL THEN 
					repFile(File).registered := FALSE
				ELSE 
					PurgeOnDisk(f.fs(FileSystem), repAdr)
				END;
			END;
			res := 0
		ELSE
			res := 1
		END
	END
END Register;

(* Flushes the changes made to a file to disk. Register will automatically Close a file. *) 
PROCEDURE Close(f: OFS.File);
BEGIN
	Unbuffer(f(File))
END Close;

(* Returns the current length of a file. *)
PROCEDURE Length(f: OFS.File): LONGINT;
BEGIN
	WITH f: File DO
		RETURN LONG(f.aleng)*SS + f.bleng - HS
	END
END Length;

(* Returns the time (t) and date (d) when a file was last modified. *)
PROCEDURE GetDate(f: OFS.File; VAR t, d: LONGINT);
BEGIN
	WITH f: File DO t := f.time; d := f.date END
END GetDate;

(* Sets the modification time (t) and date (d) of a file. *)
PROCEDURE SetDate(f: OFS.File; t, d: LONGINT);
BEGIN
	WITH f: File DO f.modH := TRUE; f.time := t; f.date := d END
END SetDate;

(* Positions a Rider at a certain position in a file. Multiple Riders can be positioned 
at different locations in a file. A Rider cannot be positioned beyond the end of a file. *)
PROCEDURE Set(VAR r: OFS.Rider; f: OFS.File; pos: LONGINT);
	VAR a, b: INTEGER;
BEGIN
	WITH f: File DO
		r.eof := FALSE; r.res := 0; r.file := f; r.fs := f.fs;
		IF pos < 0 THEN
			a := 0; b := HS
		ELSIF pos < LONG(f.aleng)*SS + f.bleng - HS THEN
			a := SHORT((pos + HS) DIV SS); b := SHORT((pos + HS) MOD SS)
		ELSE
			a := f.aleng; b := f.bleng
		END;
		r.apos := a; r.bpos := b; r.hint := f.firstbuf
	END
END Set;

(* Returns the offset of a Rider positioned on a file. *)
PROCEDURE Pos(VAR r: OFS.Rider): LONGINT;
BEGIN RETURN r.apos*SS + r.bpos - HS
END Pos;

(* Read a byte from a file, advancing the Rider one byte further.  R.eof indicates if the end 
of the file has been passed. *)
PROCEDURE Read(VAR r: OFS.Rider; VAR x: SYSTEM.BYTE);
	VAR buf: Buffer; f: File;
BEGIN
	buf := r.hint(Buffer); f := r.file(File);
	IF r.apos # buf.apos THEN buf := GetBuf(f, SHORT(r.apos)); r.hint := buf END;
	IF r.bpos < buf.lim THEN
		x := buf.data.B[r.bpos]; INC(r.bpos)
	ELSIF r.apos < f.aleng THEN
		INC(r.apos);
		buf := SearchBuf(f, SHORT(r.apos));
		IF buf = NIL THEN
			buf := r.hint(Buffer);
			IF buf.mod THEN WriteBuf(f, buf) END;
			ReadBuf(f, buf, SHORT(r.apos))
		ELSE r.hint := buf
		END;
		x := buf.data.B[0]; r.bpos := 1
	ELSE
		x := 0X; r.eof := TRUE
	END
END Read;

(* Reads a sequence of length n bytes into the buffer x, advancing the Rider. Less bytes 
will be read when reading over the length of the file. r.res indicates the number of unread bytes. 
x must be big enough to hold n bytes. *)
PROCEDURE ReadBytes(VAR r: OFS.Rider; VAR x: ARRAY OF SYSTEM.BYTE; n: LONGINT);
	VAR src, dst, m: LONGINT; buf: Buffer; f: File;
BEGIN
	IF LEN(x) < n THEN SYSTEM.HALT(19) END;
	IF n > 0 THEN
		dst := SYSTEM.ADR(x[0]);
		buf := r.hint(Buffer); f := r.file(File);
		IF r.apos # buf.apos THEN buf := GetBuf(f, SHORT(r.apos)); r.hint := buf END ;
		LOOP
			IF n <= 0 THEN EXIT END;
			src := SYSTEM.ADR(buf.data.B[0]) + r.bpos; m := r.bpos + n;
			IF m <= buf.lim THEN
				SYSTEM.MOVE(src, dst, n); r.bpos := SHORT(m); r.res := 0; EXIT
			ELSIF buf.lim = SS THEN
				m := buf.lim - r.bpos;
				IF m > 0 THEN SYSTEM.MOVE(src, dst, m); INC(dst, m); DEC(n, m) END ;
				IF r.apos < f.aleng THEN
					INC(r.apos); r.bpos := 0; buf := SearchBuf(f, SHORT(r.apos));
					IF buf = NIL THEN
						buf := r.hint(Buffer);
						IF buf.mod THEN WriteBuf(f, buf) END;
						ReadBuf(f, buf, SHORT(r.apos))
					ELSE r.hint := buf
					END
				ELSE r.bpos := buf.lim; r.res := n; r.eof := TRUE; EXIT
				END
			ELSE m := buf.lim - r.bpos;
				IF m > 0 THEN SYSTEM.MOVE(src, dst, m); r.bpos := buf.lim END ;
				r.res := n - m; r.eof := TRUE; EXIT
			END
		END
	ELSE
		r.res := 0
	END
END ReadBytes;

PROCEDURE NewExt(f: File);
	VAR i, k: INTEGER; ext: Index;
BEGIN k := (f.aleng - STS) DIV XS;
	IF k = ExTabSize THEN SYSTEM.HALT(18) END ;
	NEW(ext); ext.adr := 0; ext.mod := TRUE; f.ext[k] := ext; i := XS;
	REPEAT DEC(i); ext.sec.x[i] := 0 UNTIL i = 0
END NewExt;

(* Writes a byte into the file at the Rider position, advancing the Rider by one. *)
PROCEDURE Write(VAR r: OFS.Rider; x: SYSTEM.BYTE);
	VAR f: File; buf: Buffer;
BEGIN
	buf := r.hint(Buffer); f := r.file(File);
	IF r.apos # buf.apos THEN buf := GetBuf(f, SHORT(r.apos)); r.hint := buf END ;
	IF r.bpos >= buf.lim THEN
		IF r.bpos < SS THEN
			INC(buf.lim); INC(f.bleng); f.modH := TRUE
		ELSE WriteBuf(f, buf); INC(r.apos); buf := SearchBuf(f, SHORT(r.apos));
			IF buf = NIL THEN
				buf := r.hint(Buffer);
				IF r.apos <= f.aleng THEN ReadBuf(f, buf, SHORT(r.apos))
				ELSE buf.apos := SHORT(r.apos); buf.lim := 1; INC(f.aleng); f.bleng := 1; f.modH := TRUE;
					IF (f.aleng - STS) MOD XS = 0 THEN NewExt(f) END
				END
			ELSE r.hint := buf
			END;
			r.bpos := 0
		END
	END;
	buf.data.B[r.bpos] := x; INC(r.bpos); buf.mod := TRUE
END Write;

(* Writes the buffer x containing n bytes into a file at the Rider position. *)
PROCEDURE WriteBytes(VAR r: OFS.Rider; VAR x: ARRAY OF SYSTEM.BYTE; n: LONGINT);
	VAR src, dst, m: LONGINT; f: File; buf: Buffer;
BEGIN
	IF LEN(x) < n THEN SYSTEM.HALT(19) END ;
	IF n > 0 THEN
		src := SYSTEM.ADR(x[0]);
		buf := r.hint(Buffer); f := r.file(File);
		IF r.apos # buf.apos THEN buf := GetBuf(f, SHORT(r.apos)); r.hint := buf  END ;
		LOOP
			IF n <= 0 THEN EXIT END ;
			buf.mod := TRUE; dst := SYSTEM.ADR(buf.data.B[0]) + r.bpos; m := r.bpos + n;
			IF m <= buf.lim THEN
				SYSTEM.MOVE(src, dst, n); r.bpos := SHORT(m); EXIT
			ELSIF m <= SS THEN
				SYSTEM.MOVE(src, dst, n); r.bpos := SHORT(m);
				f.bleng := SHORT(m); buf.lim := SHORT(m); f.modH := TRUE; EXIT
			ELSE m := SS - r.bpos;
				IF m > 0 THEN SYSTEM.MOVE(src, dst, m); INC(src, m); DEC(n, m) END ;
				WriteBuf(f, buf); INC(r.apos); r.bpos := 0; buf := SearchBuf(f, SHORT(r.apos));
				IF buf = NIL THEN
					buf := r.hint(Buffer);
					IF r.apos <= f.aleng THEN ReadBuf(f, buf, SHORT(r.apos))
					ELSE buf.apos := SHORT(r.apos); buf.lim := 0; INC(f.aleng); f.bleng := 0; f.modH := TRUE;
						IF (f.aleng - STS) MOD XS = 0 THEN NewExt(f) END
					END
				ELSE r.hint := buf
				END
			END
		END
	END
END WriteBytes;

PROCEDURE Free(vol: OFS.Volume; sec: LONGINT);
BEGIN
	IF (sec # 0) & Marked(vol, sec) THEN FreeSector(vol, sec) END;
END Free;

PROCEDURE LogGC(procname, prefix, name: ARRAY OF CHAR);
BEGIN
	Kernel.WriteString(thisModuleName);
	Kernel.WriteString(".");
	Kernel.WriteString(procname);
	Kernel.WriteString(" ");
	Kernel.WriteString(prefix);
	Kernel.WriteString(":");
	Kernel.WriteString(name);
	Kernel.WriteLn;
END LogGC;

PROCEDURE Purge(fs: OFS.FileSystem; f: OFS.File);(*bsm*)
	VAR secCount, i, j, aleng: LONGINT;
BEGIN ASSERT(fs IS FileSystem, 101); ASSERT(fs = f.fs, 102);
	WITH f : File DO
		IF DEBUG THEN LogGC("Purge", fs.prefix, f.name) END;
		aleng := f.aleng;
		secCount := aleng + 1; 
		IF secCount > SecTabSize THEN secCount := SecTabSize END;
		FOR i := 0 TO secCount - 1 DO 
			Free(fs.vol, f.sec[i]) 
		END;
		DEC(aleng, secCount);
		i := 0; 
		WHILE aleng >= IndexSize DO
			FOR j := 0 TO IndexSize - 1 DO 
				Free(fs.vol, f.ext[i].sec.x[j]) 
			END;
			Free(fs.vol, f.ext[i].adr);
			INC(i); DEC(aleng, IndexSize);
		END;
		IF aleng >= 0 THEN 
			FOR j := 0 TO aleng DO 
				Free(fs.vol, f.ext[i].sec.x[j]) 
			END;
			Free(fs.vol, f.ext[i].adr);
		END;
	END;
END Purge;

PROCEDURE PurgeOnDisk(fs: FileSystem; hdadr: DiskAdr); (*bsm*)
	VAR hd: FileHeader; ix: IndexSector; secCount, aleng, i, j: LONGINT; vol: OFS.Volume;
BEGIN 
	ASSERT(fs.vol # NIL, 101);
	GetSector(fs.vol, hdadr, hd);
	IF DEBUG THEN LogGC("PurgeOnDisk", fs.prefix, hd.name) END;
	aleng := hd.aleng; secCount := aleng + 1;
	IF secCount > SecTabSize THEN secCount := SecTabSize END;
	FOR i := 0 TO secCount - 1 DO 
		Free(fs.vol, hd.sec[i]) 
	END;
	DEC(aleng, secCount);
	i := 0;
	WHILE aleng >= IndexSize DO
		GetSector(fs.vol, hd.ext[i], ix);
		FOR j := 0 TO IndexSize - 1 DO 
			Free(fs.vol, ix.x[j]) 
		END;
		Free(fs.vol, hd.ext[i]);
		INC(i); DEC(aleng, IndexSize);
	END;
	IF aleng >= 0 THEN
		GetSector(fs.vol, hd.ext[i], ix);
		FOR j := 0 TO aleng DO 
			Free(fs.vol, ix.x[j]) 
		END;
		Free(fs.vol, hd.ext[i]);
	END;
END PurgeOnDisk;

PROCEDURE Registered(fs: OFS.FileSystem; f: OFS.File): BOOLEAN;(*bsm*)
	VAR aleng: LONGINT; i: LONGINT;
BEGIN 
	ASSERT(fs = f.fs, 102);
	RETURN f(File).registered;
END Registered;

(* Deletes a file. res = 0 indicates success. *)
PROCEDURE Delete(fs: OFS.FileSystem; name: ARRAY OF CHAR; VAR key: LONGINT; VAR res: INTEGER);
	VAR adr: DiskAdr;  namebuf: FileName;  head: FileHeader; vol: OFS.Volume;
		delFile: OFS.File; (*bsm*)
BEGIN
	Check(name, namebuf, res);
	IF res = 0 THEN
		vol := fs.vol;
		DirDelete(vol, namebuf, adr);
		key := adr;
		IF adr # 0 THEN
			GetSector(vol, adr, head); 
			head.mark := HeaderMark+1; 
			PutSector(vol, adr, head);
			delFile := OFS.FindOpenFile(fs, key);(*bsm*)
			IF delFile # NIL THEN
				delFile(File).registered := FALSE
			ELSE
				PurgeOnDisk(fs(FileSystem), adr);
			END
		ELSE
			res := 2
		END
	ELSE
		key := 0
	END
END Delete;

(* Renames a file. res = 0 indicates success. *)
PROCEDURE Rename(fs: OFS.FileSystem; old, new: ARRAY OF CHAR; VAR res: INTEGER);
	VAR adr: DiskAdr; oldbuf, newbuf: FileName; head: FileHeader; vol: OFS.Volume; f: OFS.File;
	VAR repFile: OFS.File; repAdr: DiskAdr;
BEGIN
	Check(old, oldbuf, res);
	IF res = 0 THEN
		Check(new, newbuf, res);
		IF res = 0 THEN
			vol := fs.vol;
			DirDelete(vol, oldbuf, adr);
			IF adr # 0 THEN
				f := OFS.FindOpenFile(fs, adr);
				IF f # NIL THEN f(File).name := newbuf END;
				Insert(vol, newbuf, adr, repAdr);
				GetSector(vol, adr, head); 
				head.name := newbuf; 
				PutSector(vol, adr, head);
				IF (repAdr # 0) & (adr # repAdr) THEN (*bsm*)
					repFile := OFS.FindOpenFile(fs, repAdr);
					IF (repFile # NIL) THEN 
						repFile(File).registered := FALSE
					ELSE 
						PurgeOnDisk(fs(FileSystem), repAdr)
					END
				END
			ELSE res := 2
			END
		END
	END
END Rename;

PROCEDURE GetName(f: OFS.File; VAR name: ARRAY OF CHAR);
BEGIN
	COPY(f(File).name, name)
END GetName;

(* File system initialization and finalization *)

PROCEDURE Finalize(fs: OFS.FileSystem);
BEGIN
	WITH fs: FileSystem DO
		DirCleanup(fs.vol);
		fs.vol.Finalize(fs.vol);
		fs.vol := NIL	(* prevent access in case user still has file handles *)
	END
END Finalize;

(** Generate a new file system object.  OFS.NewVol has volume parameter, OFS.Par has mount prefix. *)
PROCEDURE NewFS*;
VAR
	vol: OFS.Volume;  fs: FileSystem;  init: BOOLEAN;  i: LONGINT;  ch: CHAR;  prefix: OFS.Prefix;
	s: ARRAY 64 OF CHAR;
BEGIN
	vol := OFS.NewVol; Kernel.SetLogMark;
	REPEAT OFS.ReadPar(ch) UNTIL ch # " ";
	i := 0;  WHILE (ch # 0X) & (ch # " ") DO prefix[i] := ch; INC(i); OFS.ReadPar(ch) END;
	IF OFS.This(prefix) = NIL THEN
		IF (vol.blockSize = SectorSize) & (vol.size >= MinVolSize) THEN
			GetSector(vol, DirRootAdr, hp^);
			IF hp.mark = DirMark THEN	(* assume it is an old-format Native filesystem *)
				NEW(fs);  fs.vol := vol;
				fs.desc := "GCN2KFS";
				fs.FileKey := FileKey; fs.New := New; fs.Old := Old;
				fs.Delete := Delete;  fs.Rename := Rename;  fs.Enumerate := Enumerate;
				fs.Close := Close;  fs.Register := Register;  fs.Length := Length;
				fs.GetDate := GetDate;  fs.SetDate := SetDate;  fs.GetName := GetName;
				fs.Set := Set;  fs.Pos := Pos;
				fs.Read := Read;  fs.Write := Write;
				fs.ReadBytes := ReadBytes; fs.WriteBytes := WriteBytes;
				fs.Finalize := Finalize;
				fs.Purge := Purge; fs.Registered := Registered; (*bsm*)
				DirInit(vol, init);
				ASSERT(init);	(* will have to undo changes to vol before continuing *)
				OFS.Add(fs, prefix)
			ELSE
				Kernel.WriteString(thisModuleName);
				Kernel.WriteString(": FS not found on ");
				Kernel.WriteString(vol.name);  Kernel.WriteLn
			END
		ELSE
			Kernel.WriteString(thisModuleName);
			Kernel.WriteString(": Bad volume size");  Kernel.WriteLn
		END
	ELSE
		Kernel.WriteString(thisModuleName);
		Kernel.WriteString(": ");  Kernel.WriteString(prefix);
		Kernel.WriteString(" already in use");  Kernel.WriteLn
	END;
	Kernel.GetMarkedLog(s); OFS.SetPar(s)
END NewFS;

(* Clean up when module freed. *)
PROCEDURE Cleanup;
VAR fs: OFS.FileSystem;
BEGIN
	IF Kernel.shutdown = 0 THEN
		REPEAT	(* unmount all AosFSs *)
			fs := OFS.First();	(* look for fs to unmount *)
			WHILE (fs # NIL) & ~(fs IS FileSystem) DO
				fs := OFS.Next(fs)
			END;
			IF fs # NIL THEN OFS.Remove(fs) END
		UNTIL fs = NIL
	END
END Cleanup;

BEGIN
	NEW(hp);
	Kernel.InstallTermHandler(Cleanup)
END OFSN2KFiles.

(*
	aleng * SS + bleng = length (including header)
	apos * SS + bpos = current position
	0 <= bpos <= lim <= SS
	0 <= apos <= aleng < PgTabSize
	(apos < aleng) & (lim = SS) OR (apos = aleng)
*)

(*
to do:
o NCFSDiskVolumes.Mod - reserved set
*)
