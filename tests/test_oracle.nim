## Property test: `ignored()` verdicts vs `git check-ignore --no-index`,
## which implements the same gitignore semantics (git consults the index
## without --no-index; our core never looks at git). Fixed corpus of
## hand-picked edge cases plus seeded fuzz rounds. The environment is
## isolated so neither git nor nimignore sees a global gitignore.

import std/[os, strutils, osproc, random, tables, sets, sequtils, unittest]
import nimignore

proc gitAvailable(): bool =
  execCmdEx("git --version").exitCode == 0

proc initRepo(repo: string) =
  createDir(repo)
  let r = execCmdEx("git init -q .", workingDir = repo, options = {poStdErrToStdOut})
  doAssert r.exitCode == 0, "git init failed: " & r.output

proc gitVerdicts(repo: string; paths: seq[string]): Table[string, bool] =
  ## -z: input NUL-separated, output is 4 NUL-terminated fields per record
  ## (source, linenum, pattern, pathname); empty source = non-matching,
  ## a pattern starting with '!' = matched-but-negated = not ignored.
  if paths.len == 0:
    return
  let r = execCmdEx("git check-ignore -v -n --no-index -z --stdin",
                    workingDir = repo, input = paths.join("\0"))
  doAssert r.exitCode in {0, 1}, "check-ignore failed: " & r.output
  var outp = r.output
  while outp.len > 0 and outp[^1] == '\n':
    outp.setLen(outp.len - 1)
  var i = 0
  while i < outp.len:
    var f: array[4, string]
    for k in 0 .. 3:
      let z = outp.find('\0', i)
      doAssert z >= 0, "truncated check-ignore output"
      f[k] = outp[i ..< z]
      i = z + 1
    if f[0].len == 0 or f[2].len == 0:
      result[f[3]] = false
    else:
      result[f[3]] = f[2][0] != '!'

proc compareWithGit(repo: string; queries: seq[string]; label: string) =
  var uniq: seq[string] = @[]
  var seen: HashSet[string]
  for q in queries:
    if q.len > 0 and q notin seen:
      seen.incl q
      uniq.add q
  let gv = gitVerdicts(repo, uniq)
  var bad: seq[string] = @[]
  for p in uniq:
    let g = gv.getOrDefault(p, false)
    let ours = ignored(repo, p)
    if g != ours:
      bad.add p & "  git=" & $g & " ours=" & $ours
  if bad.len > 0:
    for b in bad[0 ..< min(12, bad.len)]:
      echo "    MISMATCH [" & label & "] ", b
  check bad.len == 0

suite "oracle: git check-ignore":

  test "fixed corpus of edge cases":
    if not gitAvailable():
      echo "  skipped: no git binary"
    else:
      let base = getTempDir() / "nimignore-oracle-" & $getCurrentProcessId()
      createDir base / "home"
      writeFile base / "home" / "gitconfig", ""
      putEnv("HOME", base / "home")
      putEnv("XDG_CONFIG_HOME", base / "home" / ".config")
      putEnv("GIT_CONFIG_NOSYSTEM", "1")
      putEnv("GIT_CONFIG_GLOBAL", base / "home" / "gitconfig")
      putEnv("GIT_CONFIG_SYSTEM", "/dev/null")
      let repo = base / "repo"
      initRepo(repo)
      writeFile repo / ".gitignore",
        "*.log\n!important.log\nbuild/\n/doc/*.tmp\n**/deep\na/**/b\n*.[oa]\n" &
        "foo?ar\n[abc].txt\n[!0-9].md\ntrailing\\ \n\\#hash\n" &
        "very/deep/nested/**/x\n!keep/\nkeep/deep/*\n**/*.gen\nsub/*.md\n"
      createDir repo / "sub"
      writeFile repo / "sub" / ".gitignore", "!sub2.log\n/local.txt\n"
      let paths = [
        "a.log", "sub/deep.log", "important.log", "keep.log",
        "build", "build/", "build/f.o", "build/inner/x.o", "build/keep.log",
        "doc/x.tmp", "doc/y.tmp", "doc/sub/z.tmp", "doc/readme",
        "deep", "deep/", "sub/deep", "sub/deep/", "sub/deep/f.log", "x/deep/y",
        "a/b", "a/x/b", "a/x/y/b", "a/b/c",
        "x.o", "y.a", "z.c", "plain.txt",
        "foobar", "foozar", "foo/ar",
        "a.txt", "b.txt", "d.txt",
        "5.md", "a.md",
        "trailing ", "#hash", "hash",
        "very/deep/nested/x", "very/deep/nested/m/x", "very/x",
        "keep", "keep/deep", "keep/deep/f", "keep/other",
        "one.gen", "a/one.gen", "x/y/one.gen",
        "sub/a.md", "sub/b.md", "sub/readme.md", "sub/z",
        "sub/sub2.log", "sub/local.txt", "sub/sub/local.txt",
        "sub/plain.txt",
      ]
      let dirPaths = ["build", "build/inner", "doc", "doc/sub", "deep",
        "sub/deep", "x", "x/deep", "x/y", "a", "a/x", "a/b", "a/x/y",
        "very", "very/deep", "very/deep/nested", "very/deep/nested/m",
        "keep", "keep/deep"]
      let dirSet = dirPaths.toHashSet
      for d in dirPaths:
        createDir repo / d
      for p in paths:
        if p.endsWith('/') or p in dirSet:
          discard
        else:
          createDir repo / p.splitFile.dir
          writeFile repo / p, "x"
      compareWithGit(repo, paths.toSeq & @[
        "ghost.log", "doc/ghost.tmp", "a/ghost/b", "build/ghost/x"],
        "corpus")
      removeDir base

  test "fuzz rounds":
    if not gitAvailable():
      echo "  skipped: no git binary"
    else:
      for seed in 1 .. 5:
        let base = getTempDir() / "nimignore-fuzz-" & $seed & "-" &
                   $getCurrentProcessId()
        createDir base
        let repo = base / "repo"
        initRepo(repo)
        var r = initRand(seed * 777 + 13)
        let names = ["a", "b", "foo", "bar", "c", "x.y", "deep", "t", "gen"]
        let atoms = ["*", "?", "a", "b", "foo", "x.y", "*.t", "a*", "*a",
                     "a?c", "[ab]", "[!0-9]*", "c", "deep", "gen*", "t[a]r"]
        proc genPattern(r: var Rand): string =
          result = ""
          if r.rand(0 .. 3) == 0:
            result.add "!"
          if r.rand(0 .. 3) == 0:
            result.add "/"
          let n = r.rand(1 .. 2)
          for i in 0 ..< n:
            if i > 0:
              result.add "/"
            if r.rand(0 .. 5) == 0:
              result.add "**/"
            result.add r.sample(atoms)
          case r.rand(0 .. 4)
          of 0:
            result.add "/"
          of 1:
            result.add "/**"
          else:
            discard
        proc genPath(r: var Rand): string =
          let n = r.rand(1 .. 3)
          for i in 0 ..< n:
            if i > 0:
              result.add "/"
            result.add r.sample(names)
        # queries carry no trailing slash on purpose: check-ignore's CLI keeps
        # the slash inside anchored matches (a traversal artifact git status
        # never hits); trailing-slash semantics are covered by the corpus

        var rootPats: seq[string] = @[]
        var subPats: seq[string] = @[]
        for i in 1 .. 180:
          rootPats.add genPattern(r)
        for i in 1 .. 30:
          subPats.add genPattern(r)
        writeFile repo / ".gitignore", rootPats.join("\n") & "\n"
        createDir repo / "sub"
        writeFile repo / "sub" / ".gitignore", subPats.join("\n") & "\n"

        var queries: seq[string] = @[]
        var seen: HashSet[string]
        var i = 0
        while queries.len < 220 and i < 600:
          inc i
          let p = genPath(r)
          if p in seen:
            continue
          seen.incl p
          try:
            if r.rand(0 .. 2) == 0:
              createDir repo / p          # dir-typed query
            else:
              createDir repo / p.splitFile.dir
              if r.rand(0 .. 2) == 0:
                writeFile repo / p, "x"   # existing file or missing path
          except CatchableError:
            continue  # dtype collision with an earlier path: drop the query
          queries.add p
        compareWithGit(repo, queries, "fuzz seed " & $seed)
        removeDir base
