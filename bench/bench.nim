## 100k-file tree walk. Target: walkIgnore is I/O-bound, not matcher-bound -
## its time should stay close to a raw stdlib walkDirRec, even with a
## pattern-stressed rule stack.
##
## The tree is generated once and reused; delete it (or pass --fresh) to
## regenerate.

import std/[os, strutils, monotimes, times]
import nimignore

putEnv("HOME", getTempDir() / "nimignore-bench-home")
putEnv("XDG_CONFIG_HOME", getTempDir() / "nimignore-bench-home")

const
  Dirs = 400
  FilesPerDir = 250   # 100k files

let fresh = "--fresh" in commandLineParams()
let tree = if paramCount() > 0 and not commandLineParams()[0].startsWith("--"):
             paramStr(1)
           else:
             "benchtree"

proc genTree(dir: string) =
  echo "generating ", Dirs * FilesPerDir, "-file tree in ", dir, " ..."
  createDir dir
  writeFile dir / ".gitignore", "tmp0/\n*.log\n"
  for i in 0 ..< Dirs:
    let d = dir / "d" & $i
    createDir d
    if i mod 10 == 0:
      writeFile d / ".gitignore", "*.log\n# nested comment line\n"
    for j in 0 ..< FilesPerDir:
      writeFile d / "f" & $j & ".txt", "x\n"
      if j mod 25 == 0:
        writeFile d / "f" & $j & ".log", "x\n"
    createDir d / "tmp0"
    writeFile d / "tmp0" / "junk.bin", "y\n"

if fresh:
  removeDir(tree)
if not dirExists(tree):
  genTree(tree)

proc bench(label: string; f: proc (): int {.closure.}) =
  let t0 = getMonoTime()
  let n = f()
  let ms = (getMonoTime() - t0).inMilliseconds.int
  let rate = if ms > 0: $(n div ms) & "k files/s" else: ">1M files/s"
  echo label.align(28), ": ", ms, " ms  ", n, " entries  ", rate

proc rawWalk(): int =
  for p in walkDirRec(tree):
    inc result

proc walkDefault(): int =
  for p in walkIgnore(tree):
    inc result

# stress file: 400 patterns that miss + 50 that hit, forcing full scans
proc writeStress(dir: string) =
  var lines: seq[string] = @[]
  for i in 0 ..< 400:
    lines.add "zz" & $i & "/*.nomatch"
  for i in 0 ..< 50:
    lines.add "d" & $i & "/f2?.txt"
  writeFile dir / ".stressignore", lines.join("\n") & "\n"

proc walkStress(): int =
  for p in walkIgnore(tree, ignoreFiles = @[".gitignore", ".ignore", ".stressignore"]):
    inc result

bench("raw walkDirRec", rawWalk)
bench("walkIgnore default", walkDefault)
writeStress(tree)
bench("walkIgnore +450 rules", walkStress)

# correctness check baked into the bench: exactly the .txt files survive
var expected = 0
for i in 0 ..< Dirs:
  expected += FilesPerDir
let n = walkDefault()
if n != expected:
  echo "FAIL: walkIgnore yielded ", n, " entries, expected ", expected
  quit(1)
echo "OK: walkIgnore yields exactly the ", expected, " surviving files"
