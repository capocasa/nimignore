## nimignore/git: tracked files beat ignore rules, including force-added
## ones under ignored dirs.

import std/[os, sequtils, sets, osproc, unittest]
import nimignore/git

let base = getTempDir() / "nimignore-git-" & $getCurrentProcessId()
createDir base / "home"
putEnv("HOME", base / "home")
putEnv("XDG_CONFIG_HOME", base / "home" / ".config")
putEnv("GIT_CONFIG_NOSYSTEM", "1")
putEnv("GIT_CONFIG_GLOBAL", base / "home" / "gitconfig")
putEnv("GIT_CONFIG_SYSTEM", "/dev/null")

proc git(args: string; wd: string) =
  let r = execCmdEx("git " & args, workingDir = wd, options = {poStdErrToStdOut})
  doAssert r.exitCode == 0, "git " & args & " failed: " & r.output

suite "walkTrackedFirst":

  test "tracked files always win":
    let repo = base / "repo"
    createDir repo
    git("init -q .", repo)
    writeFile repo / ".gitignore", "ignored.txt\nbuild/\n"
    for f in ["tracked.txt", "plain.txt", "forced.txt", "ignored.txt"]:
      writeFile repo / f, "x"
    createDir repo / "build"
    writeFile repo / "build" / "t.o", "x"
    writeFile repo / "build" / "good.o", "x"
    git("add tracked.txt plain.txt", repo)
    git("add -f forced.txt build/good.o", repo)
    let got = toSeq(walkTrackedFirst(repo)).toHashSet
    check got == ["tracked.txt", "plain.txt", "forced.txt", "build/good.o"].toHashSet
    let tracked = toSeq(trackedSet(repo).files).toHashSet
    check "build/good.o" in tracked
    check "forced.txt" in tracked

  test "non-repo raises IOError":
    let norepo = base / "norepo"
    createDir norepo
    expect IOError:
      for p in walkTrackedFirst(norepo):
        discard p
