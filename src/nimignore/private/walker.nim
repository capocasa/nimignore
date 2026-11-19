## Core walker: ignore-file stack, DFS, hidden rule, skipDirs, forceInclude.
##
## The rule stack is ordered lowest precedence first; matching scans it from
## the end (deepest directory, then its ignore files from highest to lowest
## precedence, then their patterns last-line-first), so the first match found
## is the verdict - git's "last match wins" generalized across the stack.

import std/[os, strutils, sets, tables]
import glob

export glob.Pattern

type
  OnError* = proc (path: string; err: ref CatchableError) {.closure.}

  Entry* = object
    path*: string          # relative to the walk root, '/' separators
    kind*: PathComponent

  Verdict* = enum
    vNone, vIgnore, vWhitelist

  RuleFile = object
    ## One ignore file, indexed so per-entry matching only touches patterns
    ## that could actually match: anchored patterns are bucketed by their
    ## literal first component, non-anchored by literal basename.
    pats: seq[Pattern]
    byFirst: Table[string, seq[int]]
    anchoredOpen: seq[int]   # anchored, first comp is '**' or has wildcards
    nodirByLit: Table[string, seq[int]]
    nodirOpen: seq[int]      # non-anchored with wildcards

  RuleDir = object
    above: int             # > 0: the rule dir sits this many levels above root
    anchor: seq[string]    # comps from the anchor dir down to ROOT (above > 0)
    depth: int             # comps from ROOT to the rule dir (above == 0)
    files: seq[RuleFile]   # lowest precedence first

  RuleStack = ref object
    dirs: seq[RuleDir]
    nPats: int

  TrackedSet* = ref object
    ## Ledger-repo knowledge; tracked entries survive all filters except skipDirs.
    files*: HashSet[string]  # tracked rel paths
    dirs*: HashSet[string]   # every ancestor prefix of a tracked path

  Walker* = ref object
    root: string           # absolute, OS separators
    rootComps: seq[string]
    ignoreFiles: seq[string]
    skipDirs: seq[string]
    keepHidden: bool
    force: seq[Pattern]
    fold: bool             # case-insensitive matching (Windows)
    onError: OnError

proc longPath(p: string): string =
  ## Keep paths under the \\?\ prefix so Windows long paths stay reachable.
  when defined(windows):
    if p.isAbsolute() and not p.startsWith(r"\\?\"):
      if p.startsWith(r"\\"):
        result = r"\\?\UNC" & p[1 .. ^1]
      else:
        result = r"\\?\" & p
    else:
      result = p
  else:
    result = p

proc compsOf(p: string): seq[string] =
  when defined(windows):
    let seps = {'/', '\\'}
  else:
    let seps = {'/'}
  for c in p.split(seps):
    if c.len > 0:
      result.add c

proc joinRel(comps: seq[string]): string =
  comps.join("/")

proc findRepoRoot(start: string): string =
  var d = start
  while true:
    let g = d / ".git"
    if dirExists(g) or fileExists(g):
      return d
    let p = parentDir(d)
    if p == d or p.len == 0:
      return ""
    d = p

proc gitDirFrom(fle, base: string): string =
  ## worktree-style .git file: "gitdir: <path>"
  try:
    let s = readFile(fle)
    for line in s.splitLines():
      if line.startsWith("gitdir:"):
        var p = line[7 .. ^1].strip()
        if p.len == 0:
          return ""
        if not p.isAbsolute():
          p = base / p
        return p
  except IOError:
    discard
  return ""

proc configHome(): string =
  result = getEnv("XDG_CONFIG_HOME")
  if result.len == 0:
    result = getHomeDir() / ".config"

proc iniValue(path, section, key: string): string =
  ## Minimal INI lookup (core.excludesFile) without a git dependency.
  try:
    let s = readFile(path)
    var cur = ""
    for raw in s.splitLines():
      let line = raw.strip()
      if line.len == 0 or line[0] in {'#', ';'}:
        continue
      if line[0] == '[':
        let close = line.find(']')
        if close > 0:
          cur = line[1 ..< close].split('"')[0].strip()
      elif cur == section:
        let eq = line.find('=')
        if eq > 0 and line[0 ..< eq].strip().cmpIgnoreCase(key) == 0:
          var v = line[eq + 1 .. ^1].strip()
          if v.len >= 2 and v[0] == '"' and v[^1] == '"':
            v = v[1 ..< ^1]
          if v.startsWith("~/"):
            v = getHomeDir() / v[2 .. ^1]
          return v
  except IOError:
    discard

proc globalIgnoreFile(): string =
  ## core.excludesFile from ~/.gitconfig or XDG git config; falls back to
  ## git's documented default location.
  let cfg = iniValue(getHomeDir() / ".gitconfig", "core", "excludesfile")
  if cfg.len > 0:
    return cfg
  let xdg = iniValue(configHome() / "git" / "config", "core", "excludesfile")
  if xdg.len > 0:
    return xdg
  result = configHome() / "git" / "ignore"

proc summarize(pats: seq[Pattern]): RuleFile =
  result.pats = pats
  for i, p in pats:
    let lit = p.compLits[0]
    if p.anchored:
      if lit.len > 0:
        result.byFirst.mgetOrPut(lit, @[]).add i
      else:
        result.anchoredOpen.add i
    else:
      if lit.len > 0:
        result.nodirByLit.mgetOrPut(lit, @[]).add i
      else:
        result.nodirOpen.add i

proc readRuleFile(path: string; fold: bool): RuleFile =
  var pats: seq[Pattern] = @[]
  var f: File
  if not f.open(path, fmRead):
    return
  try:
    for line in f.lines:
      let p = parsePattern(line, fold)
      if p.comps.len > 0:
        pats.add p
  finally:
    f.close()
  if pats.len > 0:
    result = summarize(pats)

proc dirRules(w: Walker; absDir: string): seq[RuleFile] =
  ## Per-directory ignore files, lowest precedence first: ignoreFiles in the
  ## order given, then .git/info/exclude.
  result = @[]
  for name in w.ignoreFiles:
    let p = absDir / name
    if fileExists(p):
      let rf = readRuleFile(p, w.fold)
      if rf.pats.len > 0:
        result.add rf
  let g = absDir / ".git"
  var gd = ""
  if dirExists(g):
    gd = g
  elif fileExists(g):
    gd = gitDirFrom(g, absDir)
  if gd.len > 0:
    let exf = gd / "info" / "exclude"
    if fileExists(exf):
      let rf = readRuleFile(exf, w.fold)
      if rf.pats.len > 0:
        result.add rf

proc addDirRules(st: RuleStack; w: Walker; absDir: string;
                 depth = 0; above = 0; anchor: seq[string] = @[]) =
  let files = dirRules(w, absDir)
  if files.len == 0:
    return
  st.dirs.add RuleDir(above: above, anchor: anchor, depth: depth, files: files)
  for f in files:
    inc st.nPats, f.pats.len

proc initStack(w: Walker): RuleStack =
  new(result)
  let repo = findRepoRoot(w.root)
  # global gitignore: lowest precedence overall
  let g = globalIgnoreFile()
  if fileExists(g):
    let rf = readRuleFile(g, w.fold)
    if rf.pats.len > 0:
      var rd = RuleDir(files: @[rf])
      if repo.len > 0:
        let dc = compsOf(repo)
        rd.above = w.rootComps.len - dc.len
        rd.anchor = w.rootComps[dc.len .. ^1]
      result.dirs.add rd
      inc result.nPats, rf.pats.len
  # ignore files in dirs between the repo root and the walk root ("parents")
  if repo.len > 0:
    var chain: seq[string] = @[]
    var d = parentDir(w.root)
    while true:
      chain.add d
      if d == repo:
        break
      let p = parentDir(d)
      if p == d or p.len == 0:
        chain.setLen(0)
        break
      d = p
    for i in countdown(chain.high, 0):
      let dc = compsOf(chain[i])
      addDirRules(result, w, chain[i],
                  above = w.rootComps.len - dc.len,
                  anchor = w.rootComps[dc.len .. ^1])
  addDirRules(result, w, w.root, depth = 0)

proc evalFile(rf: RuleFile; path: seq[string]; lo, hi: int; isDir: bool): Verdict =
  ## Last matching pattern in the file wins (max line index).
  var best = -1
  var neg = false
  template consider(idx: int) {.dirty.} =
    if idx > best and matchPath(rf.pats[idx], path, lo, hi, isDir):
      best = idx
      neg = rf.pats[idx].neg
  for idx in rf.byFirst.getOrDefault(path[lo], @[]):
    consider idx
  for idx in rf.anchoredOpen:
    consider idx
  let base = path[hi - 1]
  for idx in rf.nodirByLit.getOrDefault(base, @[]):
    consider idx
  for idx in rf.nodirOpen:
    consider idx
  if best < 0:
    result = vNone
  elif neg:
    result = vWhitelist
  else:
    result = vIgnore

proc evalVerdict(st: RuleStack; comps: seq[string]; hi: int; isDir: bool): Verdict =
  ## Ignore-file verdict for the entry comps[0 ..< hi] (its parent dirs are
  ## comps[0 ..< hi-1] and are assumed to have survived pruning).
  if st.nPats == 0:
    return vNone
  for i in countdown(st.dirs.high, 0):
    let rd = st.dirs[i]
    if rd.above > 0:
      let rel = rd.anchor & comps[0 ..< hi]
      for fi in countdown(rd.files.high, 0):
        let v = evalFile(rd.files[fi], rel, 0, rel.len, isDir)
        if v != vNone:
          return v
    else:
      if rd.depth >= hi:
        continue  # rule dir at or below the entry: never applies
      for fi in countdown(rd.files.high, 0):
        let v = evalFile(rd.files[fi], comps, rd.depth, hi, isDir)
        if v != vNone:
          return v
  return vNone

proc isHiddenPath(w: Walker; name, absPath: string): bool =
  ## std isHidden: dot-prefixed base name on POSIX, the hidden attribute on
  ## Windows.
  if w.keepHidden:
    false
  else:
    isHidden(absPath)

proc matchAny(pats: seq[Pattern]; comps: seq[string]; isDir: bool): bool =
  for p in pats:
    if matchPath(p, comps, 0, comps.len, isDir):
      return true

proc newWalker*(root: string; ignoreFiles: seq[string]; skipDirs: seq[string];
                keepHidden: bool; forceInclude: seq[string]; onError: OnError): Walker =
  new(result)
  result.root = longPath(absolutePath(root))
  result.rootComps = compsOf(result.root)
  result.ignoreFiles = ignoreFiles
  result.skipDirs = skipDirs
  result.keepHidden = keepHidden
  result.onError = onError
  result.fold = defined(windows)
  for p in forceInclude:
    result.force.add parsePattern(p, result.fold)

type
  Frame = object
    comps: seq[string]
    absPath: string
    underExcluded: bool   # descended into an ignored dir for tracked files
    stackLen: int
    patsLen: int
    entries: seq[(PathComponent, string)]
    idx: int

proc listDir(w: Walker; fr: var Frame): bool =
  try:
    for kind, name in walkDir(fr.absPath, relative = true, checkDir = true):
      fr.entries.add (kind, name)
    result = true
  except CatchableError as e:
    if w.onError.isNil:
      raise
    w.onError(joinRel(fr.comps), e)
    result = false

iterator walkCore*(w: Walker; tracked: TrackedSet = nil): Entry {.closure.} =
  var st = initStack(w)
  var dfs: seq[Frame] = @[]
  var top = Frame(comps: @[], absPath: w.root,
                  stackLen: st.dirs.len, patsLen: st.nPats)
  if listDir(w, top):
    dfs.add top
  while dfs.len > 0:
    if dfs[^1].idx >= dfs[^1].entries.len:
      st.dirs.setLen(dfs[^1].stackLen)
      st.nPats = dfs[^1].patsLen
      dfs.setLen(dfs.len - 1)
      continue
    let (kind, name) = dfs[^1].entries[dfs[^1].idx]
    inc dfs[^1].idx
    let comps = dfs[^1].comps & name
    let isDir = kind == pcDir
    let under = dfs[^1].underExcluded
    var v = vNone
    var skip = isDir and w.skipDirs.contains(name)
    if not skip:
      if under:
        skip = true  # git: nothing below an excluded dir is re-includable
      elif not matchAny(w.force, comps, isDir):
        v = evalVerdict(st, comps, comps.len, isDir)
        var hidden = isHiddenPath(w, name, dfs[^1].absPath / name)
        if v == vWhitelist:
          hidden = false  # ignore-file negations can still whitelist
        skip = hidden or v == vIgnore
    if skip and tracked != nil:
      let rel = joinRel(comps)
      skip = if isDir: not tracked.dirs.contains(rel)
             else: not tracked.files.contains(rel)
    if skip:
      continue
    yield Entry(path: joinRel(comps), kind: kind)
    if isDir:
      # dir symlinks (pcLinkToDir) are yielded as leaves, never followed
      var child = Frame(comps: comps, absPath: dfs[^1].absPath / name,
                        underExcluded: under or v == vIgnore,
                        stackLen: st.dirs.len, patsLen: st.nPats)
      addDirRules(st, w, child.absPath, depth = comps.len)
      if listDir(w, child):
        dfs.add child

proc ignoredCore*(w: Walker; path: string): bool =
  ## Point query mirroring the walk: evaluate each component in order and
  ## stop at the first excluded one (a pruned dir hides everything below).
  var p = path
  if p.isAbsolute():
    p = relativePath(p, w.root)
  let trailing = p.endsWith('/')
  var comps: seq[string] = @[]
  for c in p.split('/'):
    if c.len > 0 and c != ".":
      comps.add c
  if comps.len == 0:
    return false
  var st = initStack(w)
  var cur = w.root
  for i in 0 ..< comps.len:
    let name = comps[i]
    let absP = cur / name
    # intermediate components of a multi-comp path act as dirs (git checks
    # dtype the same way); a missing final component counts as a file
    let isDir = i < comps.high or trailing or
        (dirExists(absP) and not symlinkExists(absP))
    if isDir and w.skipDirs.contains(name):
      return true
    if not matchAny(w.force, comps[0 .. i], isDir):
      var v = evalVerdict(st, comps, i + 1, isDir)
      var hidden = isHiddenPath(w, name, absP)
      if v == vWhitelist:
        hidden = false
      if hidden or v == vIgnore:
        return true
    if isDir:
      cur = absP
      addDirRules(st, w, cur, depth = i + 1)
  return false
