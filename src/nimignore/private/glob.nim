## Gitignore pattern parsing and matching (gitignore(5) semantics).
##
## Patterns are matched against path components relative to the directory
## holding the ignore file that defined them. Matching follows git:
## `*`/`?` never cross `/`, a full `**` component spans zero or more
## directories, non-anchored patterns match the basename at any depth.

import std/strutils

type
  ClassItem* = tuple[lo, hi: char]

  AtomKind* = enum
    aLit      # single literal char
    aStar     # '*': any run of chars within one component
    aAny      # '?': exactly one char
    aClass    # [...] / [!...]: one char
    aDStar    # a full '**' component: zero or more path components

  Atom* = object
    case kind*: AtomKind
    of aLit:
      ch*: char
    of aClass:
      negated*: bool
      items*: seq[ClassItem]
    else:
      discard

  Pattern* = object
    raw*: string        # original line, kept for diagnostics
    neg*: bool          # leading '!'
    dirOnly*: bool      # trailing '/'
    anchored*: bool     # contains '/' besides a trailing one
    comps*: seq[seq[Atom]]
    compLits*: seq[string]  # comps[i] as a plain string when wildcard-free, else ""
    minDepth*: int          # reject any path with fewer components than this

proc trimLine(line: string): string =
  ## Trailing whitespace is ignored unless quoted with a backslash; one
  ## escaped trailing space is restored, the backslash dropped.
  var e = line.len
  while e > 0 and line[e - 1] in {' ', '\t', '\r'}:
    dec e
  result = line[0 ..< e]
  if result.len > 0 and result[^1] == '\\' and line.endsWith("\\ "):
    result = result[0 ..< ^1] & " "

proc foldCh(c: char; fold: bool): char =
  if fold: c.toLowerAscii else: c

proc tokenize(s: string; fold: bool): seq[Atom] =
  var i = 0
  while i < s.len:
    case s[i]
    of '*':
      result.add Atom(kind: aStar)
      inc i
    of '?':
      result.add Atom(kind: aAny)
      inc i
    of '[':
      var j = i + 1
      var negated = false
      if j < s.len and s[j] in {'!', '^'}:
        negated = true
        inc j
      var items: seq[ClassItem] = @[]
      var closed = false
      var first = true
      while j < s.len:
        if s[j] == ']' and not first:
          closed = true
          inc j
          break
        first = false
        var lo = s[j]
        if lo == '\\' and j + 1 < s.len:
          inc j
          lo = s[j]
        var hi = lo
        if j + 2 < s.len and s[j + 1] == '-' and s[j + 2] != ']':
          hi = s[j + 2]
          j += 2
          if hi == '\\' and j + 1 < s.len:
            inc j
            hi = s[j]
        inc j
        items.add (lo.foldCh(fold), hi.foldCh(fold))
      if closed:
        result.add Atom(kind: aClass, negated: negated, items: items)
        i = j
      else:
        # unterminated class: '[' is a literal, rest re-scanned
        result.add Atom(kind: aLit, ch: foldCh('[', fold))
        inc i
    of '\\':
      if i + 1 < s.len:
        result.add Atom(kind: aLit, ch: foldCh(s[i + 1], fold))
        i += 2
      else:
        result.add Atom(kind: aLit, ch: '\\')
        inc i
    else:
      result.add Atom(kind: aLit, ch: foldCh(s[i], fold))
      inc i

proc isDStarAt(comp: seq[Atom]): bool =
  comp.len == 1 and comp[0].kind == aDStar

proc parsePattern*(line: string; fold = false): Pattern =
  result.raw = line
  var t = trimLine(line)
  if t.len == 0 or t[0] == '#':
    return
  if t[0] == '!':
    result.neg = true
    t = t[1 .. ^1]
  if t.endsWith('/'):
    result.dirOnly = true
    t.setLen(t.len - 1)
  # a '/' at the start only anchors; a trailing '/' only marks dir-only
  result.anchored = t.contains('/')
  if t.startsWith('/'):
    t = t[1 .. ^1]
  if t.len == 0:
    return
  result.minDepth = 1
  var lit = ""
  for c in t.split('/'):
    # a '**' is only special as a full component of an anchored pattern;
    # otherwise it is regular asterisks (gitignore(5))
    if c == "**" and result.anchored:
      result.comps.add @[Atom(kind: aDStar)]
      result.compLits.add ""
    else:
      let atoms = tokenize(c, fold)
      result.comps.add atoms
      var allLit = true
      lit = ""
      for a in atoms:
        if a.kind == aLit:
          lit.add a.ch
        else:
          allLit = false
          break
      result.compLits.add if allLit: lit else: ""
  if result.anchored:
    # min components a path needs for this pattern to possibly match
    var n = 0
    for comp in result.comps:
      if not comp.isDStarAt:
        inc n
    if result.comps[^1].len == 1 and result.comps[^1][0].kind == aDStar and
        result.comps.len > 1:
      inc n  # trailing '/**' must consume at least one component
    result.minDepth = max(1, n)

proc classMatch(a: Atom; c: char): bool =
  var inside = false
  for it in a.items:
    if c >= it.lo and c <= it.hi:
      inside = true
      break
  result = if a.negated: not inside else: inside

proc matchComp(atoms: openArray[Atom]; s: string): bool =
  # fast path: exactly one '*' and no other wildcards
  var stars = 0
  var wild = false
  for a in atoms:
    case a.kind
    of aStar:
      inc stars
    of aLit:
      discard
    else:
      wild = true
  if stars == 1 and not wild:
    var pre, suf: string
    var seen = false
    for a in atoms:
      if a.kind == aStar:
        seen = true
      elif a.kind == aLit:
        if seen: suf.add a.ch else: pre.add a.ch
    return s.len >= pre.len + suf.len and
        s.startsWith(pre) and s.endsWith(suf)
  # general DP over atoms x positions
  let n = s.len
  let m = atoms.len
  var dp = newSeq[seq[bool]](m + 1)
  for i in 0 .. m:
    dp[i] = newSeq[bool](n + 1)
  dp[m][n] = true
  for i in countdown(m - 1, 0):
    case atoms[i].kind
    of aStar:
      var run = false
      for j in countdown(n, 0):
        if dp[i + 1][j]:
          run = true
        dp[i][j] = run
    of aAny:
      for j in 0 .. n:
        dp[i][j] = j < n and dp[i + 1][j + 1]
    of aLit:
      for j in 0 .. n:
        dp[i][j] = j < n and s[j] == atoms[i].ch and dp[i + 1][j + 1]
    of aClass:
      for j in 0 .. n:
        dp[i][j] = j < n and classMatch(atoms[i], s[j]) and dp[i + 1][j + 1]
    of aDStar:
      discard  # a '**' is never part of a single component
  result = dp[0][0]

proc compMatch(p: Pattern; ci: int; s: string): bool =
  let lit = p.compLits[ci]
  if lit.len > 0:
    return s == lit
  result = matchComp(p.comps[ci], s)

proc matchComps(p: Pattern; lo, hi: int;
                path: seq[string]; plo, phi: int): bool =
  ## p.comps[lo ..< hi] against path[plo ..< phi]
  let pl = hi - lo
  let ql = phi - plo
  if pl == 0:
    return ql == 0
  if p.comps[hi - 1].isDStarAt and pl > 1:
    # trailing '/**' matches everything *inside*: the prefix may end anywhere
    # (interior '**' is variable) but must leave >= 1 component for the '**'
    for k in plo .. phi - 1:
      if matchComps(p, lo, hi - 1, path, plo, k):
        return true
    return false
  if p.comps[lo].isDStarAt:
    if pl == 1:
      return true  # bare '**': matches everything
    for k in plo .. phi:
      if matchComps(p, lo + 1, hi, path, k, phi):
        return true
    return false
  if ql == 0:
    return false
  if not compMatch(p, lo, path[plo]):
    return false
  result = matchComps(p, lo + 1, hi, path, plo + 1, phi)

proc matchPath*(p: Pattern; path: seq[string]; lo, hi: int; isDir: bool): bool =
  ## Match against path[lo ..< hi]; the last component is the entry itself.
  if p.comps.len == 0:
    return false
  if hi - lo < p.minDepth:
    return false
  if p.dirOnly and not isDir:
    return false
  if p.anchored:
    result = matchComps(p, 0, p.comps.len, path, lo, hi)
  else:
    result = compMatch(p, 0, path[hi - 1])
