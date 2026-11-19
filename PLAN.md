# nimignore — gitignore-respecting directory walker for Nim

Goal: a small Nim library that steals the filtering semantics of Rust's
`ignore` crate (ripgrep's walker) behind a deliberately simpler, Nim-ish
interface. Purpose-built for copy-based agent workspaces (see
`~/p/3code/.agents/plan-copy-workspaces.md`): fork() walks the source
tree with these rules and copies what survives.

## Context

The `ignore` crate is the reference implementation of "what does the
ecosystem consider ignorable": gitignore matching (nested files,
negations, anchoring), `.git/info/exclude`, global gitignore
(`core.excludesFile`), `.ignore` + custom ignore files, and the hidden
rule (dot-prefixed + Windows hidden attribute). It has no VCS-dir list —
dot-prefixed VCS dirs (.git/.hg/.svn/.jj/.sl/.bzr) fall out of the
hidden rule, and it misses `CVS/` and `_darcs/` (not dot-prefixed), the
same gap ripgrep has. It also never reads the git index, so
force-added tracked files are invisible to it.

We adopt all of it, with three deliberate divergences locked in
conversation:

- **`requireGit = false` by default** (ripgrep defaults true). Gitignore
  semantics are VCS-neutral now (jj and Sapling read .gitignore
  natively); the file is meaningful without `.git`.
- **Explicit `CVS/` and `_darcs/` skips** — patching the gap.
- **Tracked-files override lives outside the core.** Core has zero git
  dependency. A separate proc shells `git ls-files` for callers that
  have a ledger repo; tracked files always copy regardless of ignore
  rules (gitignore only governs untracked files in real git).

## Interface (the Nim-ish part)

Rust-isms removed: no builder pattern (named default params instead),
no `Result` plumbing (exceptions instead), no trait objects (closures
or nil), iterators instead of collector types, `seq[string]` instead of
`Vec<String>` gymnastics.

```nim
import nimignore

# 90% case: one line. Yields paths relative to root, files only.
for path in walkIgnore("src"):
  echo path

# Need dirs/deletions too (reconcile wants the full picture):
for e in walkEntries("."):
  case e.kind
  of pcFile: copy(e.path)
  of pcDir:  discard            # dirs are yielded only when kept
  of pcLinkToFile, pcLinkToDir: copyLink(e.path)

# All knobs are named params with defaults — no builder:
for path in walkIgnore(".",
    ignoreFiles  = [".gitignore", ".ignore"],  # + .git/info/exclude + global
    skipDirs     = ["CVS", "_darcs"],          # the ripgrep gap, patched
    keepHidden   = false,                      # the hidden rule
    forceInclude = [".env", ".env.local"],     # beats ignore rules
    onError      = nil):                       # nil => raise IOError
  echo path

# Point query, no walking — "would fork() take this?"
if ignored(".", "build/output.o"): discard

# Git glue, separate module, only for ledger-repo callers:
import nimignore/git
for path in walkTrackedFirst("."):   # tracked files always win over ignore
  echo path
```

Semantics contract (stolen from `ignore`, unchanged):

- gitignore matching: per-directory stacking, `!` negation, `/`-anchoring,
  dir-only patterns (`foo/`), last match wins.
- Ignore file stack per directory: `.gitignore` (always, since
  requireGit=false), `.ignore`, plus `ignoreFiles` extras; precedence
  deepest-first, custom files after standard.
- Hidden rule: base name starts with `.` or (Windows) has the hidden
  attribute; `keepHidden = true` disables, ignore-file negations can
  still whitelist.
- `forceInclude` is evaluated before ignore rules and hidden rule;
  explicit user intent beats everything except `skipDirs`.
- `skipDirs` prunes whole subtrees before any ignore evaluation.

## Tasks

- [x] glob/gitignore matcher: port semantics (nested stacking, negation,
      anchoring, dir-only); property-test against `git check-ignore`
- [x] walker: iterative DFS, per-dir rule stack, skipDirs pruning,
      hidden rule, forceInclude
- [x] `walkIgnore` / `walkEntries` / `ignored` public API as above
- [x] Windows: hidden-attribute check, long-path handling, case folding
      (via std `isHidden`, `\\?\` long-path prefix, compile-time case
      folding; Windows branches cross-compile-checked, not run on Windows)
- [x] `nimignore/git`: `git ls-files` glue + `walkTrackedFirst`
- [x] bench: 100k-file tree walk; target: I/O-bound, not matcher-bound

## Current state

Implemented. Layout: `src/nimignore.nim` (public API),
`src/nimignore/private/glob.nim` (pattern parse/match, indexed candidate
buckets), `src/nimignore/private/walker.nim` (rule stack, DFS, hidden,
skipDirs, forceInclude, onError), `src/nimignore/git.nim` (`ls-files`
glue). Tests: `tests/test_glob.nim` (matcher units), `tests/test_walker.nim`,
`tests/test_oracle.nim` (fixed corpus + fuzz vs `git check-ignore`
--no-index, all agreeing incl. ancestor-exclusion propagation),
`tests/test_git.nim`. `nimble test` runs all; `nimble bench` walks a
100k-file tree (walkIgnore ≈ raw walkDirRec, stable under a 450-pattern
stress file; deletes `benchtree/` freely, it regenerates).

Divergences locked in beyond the plan text: parent dirs between the repo
root and the walk root contribute ignore rules (ignore-crate
`parents = true`); `.git` may be a worktree file (`gitdir:`); global
gitignore is found by parsing `~/.gitconfig` / XDG git config for
`core.excludesFile`, else `$XDG_CONFIG_HOME/git/ignore` — no git
dependency in the core; `walkIgnore` yields files and file-symlinks
(dir symlinks are `walkEntries`-only, never followed).
