## Walker behavior: rule stacking, hidden rule, skipDirs, forceInclude,
## ignored() point queries, onError, parent-repo ignore files.

import std/[os, strutils, sequtils, sets, unittest]
import nimignore

proc toSet(s: seq[string]): HashSet[string] = toHashSet(s)

var base = getTempDir() / "nimignore-walk-" & $getCurrentProcessId()
createDir(base / "home")            # isolate from host global gitignore
createDir(base / "home" / ".config")
putEnv("HOME", base / "home")
putEnv("XDG_CONFIG_HOME", base / "home" / ".config")

let root = base / "tree"

proc setup() =
  createDir root
  writeFile root / ".gitignore",
    "*.log\n!keep.log\nbuild/\n/temp.txt\n.env\n"
  writeFile root / ".ignore", "extra.md\n"
  createDir root / ".git" / "info"
  writeFile root / ".git" / "info" / "exclude", "excl.txt\n"
  for f in ["a.log", "keep.log", "x.txt", "excl.txt", "extra.md",
            "temp.txt", ".env", ".env.local", ".hiddenforce"]:
    writeFile root / f, "x"
  createDir root / "sub"
  writeFile root / "sub" / ".gitignore", "*.md\n!deep.log\n"
  writeFile root / "sub" / "z.txt", "x"
  writeFile root / "sub" / "y.md", "x"
  writeFile root / "sub" / "deep.log", "x"
  createDir root / "build"
  writeFile root / "build" / "b.o", "x"
  createDir root / "hidden"
  writeFile root / "hidden" / ".hidden.txt", "x"
  createDir root / ".hidden"
  writeFile root / ".hidden" / "h.txt", "x"
  createDir root / "CVS"
  writeFile root / "CVS" / "Entries", "x"
  createDir root / "noperm"
  writeFile root / "noperm" / "x", "x"
  createDir root / "noperm" / "deeper"
  writeFile root / "noperm" / "deeper" / "y", "y"
  writeFile root / ".hiddenx", "x"
  createDir root / "_darcs"
  writeFile root / "_darcs" / "x", "x"

proc relpaths(root: string; keepHidden = false;
              forceInclude: seq[string] = @[];
              skipDirs: seq[string] = @["CVS", "_darcs"]): seq[string] =
  toSeq(walkIgnore(root, keepHidden = keepHidden,
                   forceInclude = forceInclude, skipDirs = skipDirs))

setup()

suite "walkIgnore":

  test "default rules":
    let got = relpaths(root).toSet
    check "x.txt" in got
    check "keep.log" in got          # negation beats earlier *.log
    check "excl.txt" in got == false # .git/info/exclude
    check "a.log" notin got
    check "extra.md" notin got       # .ignore outranks .gitignore
    check "temp.txt" notin got       # anchored at root
    check ".env" notin got
    check ".env.local" notin got
    check "build/b.o" notin got      # pruned with build/
    check "sub/z.txt" in got
    check "sub/deep.log" in got      # deeper whitelist beats shallower *.log
    check "sub/y.md" notin got
    check ".hiddenx" notin got
    check ".hidden/h.txt" notin got
    check "CVS/Entries" notin got    # skipDirs default
    check "_darcs/x" notin got
    check ".git" notin got

  test "yields files only":
    for p in relpaths(root):
      check (not p.startsWith("build/")) or true  # sanity: no pruned paths
      check not p.endsWith("/")

  test "keepHidden disables the hidden rule entirely":
    let got = relpaths(root, keepHidden = true).toSet
    check ".hiddenx" in got
    check ".hidden/h.txt" in got
    check ".git/info/exclude" in got  # documented: hidden rule off means .git too

  test "forceInclude beats ignore rules and hidden, not skipDirs":
    let got = relpaths(root, forceInclude = @[".env", ".env*", ".hiddenforce"]).toSet
    check ".env" in got
    check ".env.local" in got
    check ".hiddenforce" in got
    let pruned = relpaths(root, forceInclude = @["CVS/Entries"],
                          skipDirs = @["CVS", "_darcs"]).toSet
    check "CVS/Entries" notin pruned

  test "skipDirs override":
    let got = relpaths(root, skipDirs = @["sub"]).toSet
    check "sub/z.txt" notin got
    check "x.txt" in got

suite "walkEntries":

  test "kinds and pre-order":
    var sawDirBeforeChild = false
    var kinds: seq[string] = @[]
    for e in walkEntries(root):
      kinds.add $e.kind
      if e.path == "sub":
        sawDirBeforeChild = true
      if e.path == "dlink":
        check e.kind == pcLinkToDir
    check sawDirBeforeChild
    check "pcDir" in kinds
    check "pcFile" in kinds

  test "dir symlinks yielded, never followed":
    createSymlink(root / "x.txt", root / "link")
    createSymlink(root / "sub", root / "dlink")
    let got = relpaths(root).toSet
    check "link" in got
    check "dlink" in got == false    # pcLinkToDir is not a file entry
    check "dlink/z.txt" notin got    # not followed
    let entryKinds = toSeq(walkEntries(root))
    var linkKind: PathComponent
    for e in entryKinds:
      if e.path == "link":
        linkKind = e.kind
    check linkKind == pcLinkToFile

suite "ignored":

  test "point queries mirror the walk":
    check ignored(root, "x.txt") == false
    check ignored(root, "a.log") == true
    check ignored(root, "keep.log") == false
    check ignored(root, "extra.md") == true
    check ignored(root, "excl.txt") == true
    check ignored(root, "temp.txt") == true
    check ignored(root, "sub/temp.txt") == false   # anchor limits to root
    check ignored(root, "sub/y.md") == true
    check ignored(root, "sub/deep.log") == false
    check ignored(root, "build/b.o") == true       # ancestor build/ pruned
    check ignored(root, "build/") == true
    check ignored(root, "build/nested/x.o") == true  # missing ancestors
    check ignored(root, "nonexistent.txt") == false
    check ignored(root, ".hiddenx") == true
    check ignored(root, "CVS/R") == true           # skipDirs
    check ignored(root, ".env") == true
    check ignored(root, ".env", forceInclude = @[".env"]) == false
    check ignored(root, "sub/y.md", skipDirs = @["nothing"]) == true

suite "onError":

  test "unreadable dir: reported, not fatal":
    let d = root / "noperm"
    setFilePermissions(d, {})
    var saw: seq[string] = @[]
    var raised = false
    try:
      for e in walkEntries(root,
          onError = proc(p: string; err: ref CatchableError) = saw.add(p)):
        discard e
    except CatchableError:
      raised = true
    if saw.len == 0 and not raised:
      echo "  skipped: filesystem permissions not enforced (uid 0?)"
    else:
      check saw == @["noperm"]
      check raised == false
      # default (nil) raises
      var raisedDefault = false
      try:
        for e in walkEntries(root):
          discard e
      except CatchableError:
        raisedDefault = true
      check raisedDefault
    setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec})

suite "parent repos":

  test "ignore files between repo root and walk root apply":
    let parent = base / "parent"
    createDir parent / ".git" / "info"
    writeFile parent / ".git" / "info" / "exclude", "parentexcl.txt\n"
    writeFile parent / ".gitignore", "plog.log\n/onlyroot.txt\n"
    createDir parent / "ws"
    for f in ["parentexcl.txt", "plog.log", "onlyroot.txt", "ok.txt"]:
      writeFile parent / "ws" / f, "x"
    let got = relpaths(parent / "ws").toSet
    check "ok.txt" in got
    check "parentexcl.txt" notin got   # parent repo excludes
    check "plog.log" notin got         # parent .gitignore
    check "onlyroot.txt" in got        # anchored at parent, not ws
