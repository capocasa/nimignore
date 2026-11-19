# nimignore

A gitignore-respecting directory walker for Nim. Same filtering
semantics as ripgrep's `ignore` crate, Nim-ish API.

```nim
import nimignore

# The 90% case: every file gitignore would let through.
for path in walkIgnore("."):
  echo path
```

No `.git` required, gitignore rules work standalone (that's the
divergence from ripgrep, which needs a repo). Hidden files are skipped
like ripgrep skips them, `CVS/` and `_darcs/` too, and `.gitignore` plus
`.ignore` files stack per directory with normal negation and anchoring.

## Copy with symlinks intact

`walkIgnore` yields files only. For the full picture (dirs, symlinks),
use `walkEntries`:

```nim
import std/os
import nimignore

for e in walkEntries("."):
  case e.kind
  of pcFile:       copyFile(e.path, dest / e.path)
  of pcDir:        createDir(dest / e.path)
  of pcLinkToFile: copyFile(e.path, dest / e.path)  # copies link target
  of pcLinkToDir:  createSymlink(e.path.expandSymlink, dest / e.path)
```

## "Would my rules take this file?"

Point query, no walking:

```nim
if ignored(".", "build/cache/tmp.o"):
  echo "skip it"
```

## Tracked files win

In a real git repo, ignore rules only govern untracked files, and
force-added files are invisible to any rule set. To match that, layer
`nimignore/git` on top:

```nim
import nimignore
import nimignore/git

# Tracked files always yield, even if .gitignore says otherwise.
for path in walkTrackedFirst("."):
  copy(path)
```

## Tweaks

All knobs are named parameters, all default to ripgrep behavior
(minus `requireGit`):

```nim
for path in walkIgnore(".", ignoreFiles = @[".gitignore", ".dockerignore"],
                       skipDirs = @["node_modules"],
                       keepHidden = true,
                       forceInclude = @["!.env.example"],
                       onError = proc(p: string, e: ref CatchableError) =
                         stderr.writeLine "skip ", p, ": ", e.msg):
  echo path
```

`forceInclude` patterns beat everything except `skipDirs`, so the above
drags `.env.example` out from behind the hidden rule. One gotcha:
`keepHidden = true` also unhides `.git`. Add `".git"` to `skipDirs`
unless you enjoy copying 30,000 hook samples.

MIT. Version 0.1.0, expect the usual alpha caveats.
