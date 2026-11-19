## nimignore - a gitignore-respecting directory walker.
##
## Steals the filtering semantics of Rust's `ignore` crate (ripgrep's
## walker) behind a deliberately simpler, Nim-ish interface. Purpose-built
## for copy-based agent workspaces: fork() walks the source tree with these
## rules and copies what survives.
##
##   import nimignore
##
##   # 90% case: one line. Yields paths relative to root.
##   for path in walkIgnore("src"):
##     echo path
##
##   # Need dirs/links too:
##   for e in walkEntries("."):
##     case e.kind
##     of pcFile: copy(e.path)
##     of pcDir:  discard
##     of pcLinkToFile, pcLinkToDir: copyLink(e.path)
##
##   # Point query, no walking - "would fork() take this?"
##   if ignored(".", "build/output.o"): discard
##
## Divergences from the ignore crate, deliberate: `requireGit = false`
## (gitignore semantics are VCS-neutral), explicit `CVS`/`_darcs` skips
## (the ripgrep gap), and no git dependency in the core - tracked-file
## override lives in nimignore/git.

import std/os
import nimignore/private/walker

export Entry, OnError, PathComponent

iterator walkEntries*(root: string;
                      ignoreFiles: seq[string] = @[".gitignore", ".ignore"];
                      skipDirs: seq[string] = @["CVS", "_darcs"];
                      keepHidden = false;
                      forceInclude: seq[string] = @[];
                      onError: OnError = nil): Entry =
  ## Walk `root` depth-first, yielding every surviving entry (files, kept
  ## dirs, and symlinks; dir symlinks are never followed). Paths are
  ## relative to `root` with '/' separators.
  ##
  ## `ignoreFiles` is the per-directory stack, ascending precedence
  ## (later entries override earlier ones); `.git/info/exclude` (when a
  ## repo is present) and the global gitignore are always added below it.
  ## `skipDirs` prunes whole subtrees by base name before any rule runs.
  ## `forceInclude` patterns (gitignore syntax, relative to root) are
  ## evaluated before ignore rules and the hidden rule - explicit user
  ## intent beats everything except skipDirs.
  let w = newWalker(root, ignoreFiles, skipDirs, keepHidden, forceInclude, onError)
  for e in walkCore(w, nil):
    yield e

iterator walkIgnore*(root: string;
                     ignoreFiles: seq[string] = @[".gitignore", ".ignore"];
                     skipDirs: seq[string] = @["CVS", "_darcs"];
                     keepHidden = false;
                     forceInclude: seq[string] = @[];
                     onError: OnError = nil): string =
  ## The 90% case: yields paths relative to root, files and file-symlinks
  ## only (no dirs, no dir-links). Use walkEntries for the full picture.
  for e in walkEntries(root, ignoreFiles, skipDirs, keepHidden, forceInclude, onError):
    if e.kind in {pcFile, pcLinkToFile}:
      yield e.path

proc ignored*(root: string; path: string;
              ignoreFiles: seq[string] = @[".gitignore", ".ignore"];
              skipDirs: seq[string] = @["CVS", "_darcs"];
              keepHidden = false;
              forceInclude: seq[string] = @[]): bool =
  ## Point query, no walking: "would fork() take `path`?" Mirrors the walk,
  ## including ancestor-dir pruning: a path below an excluded dir is
  ## ignored. `path` is relative to `root`; a trailing '/' marks a dir that
  ## need not exist.
  let w = newWalker(root, ignoreFiles, skipDirs, keepHidden, forceInclude, nil)
  result = ignoredCore(w, path)
