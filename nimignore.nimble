# Package

version       = "0.1.0"
author        = "carlo"
description   = "gitignore-respecting directory walker (ripgrep-style semantics, Nim-ish API)"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "run the test suite":
  for f in ["test_glob", "test_walker", "test_oracle", "test_git"]:
    exec "nim c -r -d:release --path:src tests/" & f & ".nim"

task bench, "build and run the walker benchmark":
  exec "nim c -d:release --path:src bench/bench.nim"
  exec "bench/bench"
