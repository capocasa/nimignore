## Git glue for ledger-repo callers. The core walker has zero git
## dependency; this module shells out to `git ls-files` so tracked files
## always copy regardless of ignore rules (gitignore only governs
## untracked files in real git).

import std/[os, strutils, sets, osproc]
import nimignore/private/walker

export OnError, PathComponent

proc trackedSet*(root: string): TrackedSet =
  ## All tracked paths in the repo at `root`, plus every ancestor prefix of
  ## those paths (so ignored dirs containing tracked files still descend).
  let res = execCmdEx("git ls-files -z", workingDir = root,
                      options = {poStdErrToStdOut})
  if res.exitCode != 0:
    raise newException(IOError,
      "git ls-files failed in " & root & ": " & res.output.strip())
  result = TrackedSet()
  for p in res.output.split('\0'):
    if p.len == 0:
      continue
    result.files.incl p
    var comps = p.split('/')
    comps.setLen(comps.len - 1)
    var acc = ""
    for c in comps:
      if acc.len > 0:
        acc.add '/'
      acc.add c
      result.dirs.incl acc

iterator walkTrackedFirst*(root: string;
                           ignoreFiles: seq[string] = @[".gitignore", ".ignore"];
                           skipDirs: seq[string] = @["CVS", "_darcs"];
                           keepHidden = false;
                           forceInclude: seq[string] = @[];
                           onError: OnError = nil): string =
  ## Like walkIgnore, but tracked files (including force-added ones the
  ## ignore rules would hide) always win. Ignored dirs are only entered
  ## when they contain tracked files; skipDirs still prunes. Raises IOError
  ## when `root` is not inside a git repo.
  let t = trackedSet(root)
  let w = newWalker(root, ignoreFiles, skipDirs, keepHidden, forceInclude, onError)
  for e in walkCore(w, t):
    if e.kind in {pcFile, pcLinkToFile}:
      yield e.path
