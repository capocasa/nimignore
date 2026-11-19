## Unit tests for the gitignore pattern matcher.

import std/[strutils, unittest]
import nimignore/private/glob

proc m(pat: string; path: string; isDir = false): bool =
  let p = parsePattern(pat)
  let comps = path.split('/')
  matchPath(p, comps, 0, comps.len, isDir)

proc flags(pat: string): tuple[neg, dirOnly, anchored: bool] =
  let p = parsePattern(pat)
  (p.neg, p.dirOnly, p.anchored)

suite "parsing":

  test "flags":
    check flags("foo") == (false, false, false)
    check flags("!foo") == (true, false, false)
    check flags("foo/") == (false, true, false)     # trailing / does not anchor
    check flags("/foo") == (false, false, true)
    check flags("a/b") == (false, false, true)
    check flags("/a/b/") == (false, true, true)

  test "comments and blanks are inert":
    for l in ["", "  ", "# comment", "#"]:
      check parsePattern(l).comps.len == 0

  test "leading whitespace is significant (no comment)":
    check m("\t# x", "\t# x")

  test "escapes":
    check m(r"\#hash", "#hash")
    check m(r"\!bang", "!bang")
    check m(r"foo\ ", "foo ")
    check not m("foo", "foo ")
    check m(r"a\*b", "a*b")
    check not m(r"a\*b", "ab")

  test "trailing spaces stripped unless escaped":
    check m("foo   ", "foo")
    check m("foo\r", "foo")
    check m("foo\\ ", "foo ")
    check not m("foo\\ ", "foo")

suite "basics":

  test "literal and star":
    check m("foo", "foo")
    check not m("foo", "bar")
    check m("*.log", "a.log")
    check m("*.log", "x.dir/b.log")
    check not m("*.log", "log")
    check m("*.txt", "d/a.txt")   # non-anchored: matches at any depth
    check m("a*c", "abc")
    check m("a*c", "ac")
    check m("a*c", "abbbc")

  test "star does not cross /":
    check m("d/*.txt", "d/a.txt")
    check not m("d/*.txt", "d/e/a.txt")

  test "question mark":
    check m("foo?ar", "foobar")
    check not m("foo?ar", "foo/ar")
    check not m("foo?ar", "foar")

  test "character classes":
    check m("*.[oa]", "x.o")
    check m("*.[oa]", "x.a")
    check not m("*.[oa]", "x.b")
    check m("[abc].txt", "b.txt")
    check not m("[abc].txt", "d.txt")
    check m("[!0-9].md", "a.md")
    check not m("[!0-9].md", "5.md")
    check m("[a-]x", "-x")
    check m("[a-]x", "ax")
    check m("a[2]b", "a2b")
    check m("[", "[")           # unterminated class: '[' is a literal
    check not m("[", "x")
    check m("[ab", "[ab")       # '[a' literal, then 'b'
    check not m("[ab", "b")

suite "anchoring":

  test "non-anchored matches basename at any depth":
    check m("b.txt", "b.txt")
    check m("b.txt", "x/b.txt")
    check m("b.txt", "x/y/b.txt")

  test "anchored matches from the ignore-file dir only":
    check m("/build", "build")
    check not m("/build", "x/build")
    check m("doc/*.tmp", "doc/x.tmp")
    check not m("doc/*.tmp", "doc/sub/x.tmp")
    check not m("doc/*.tmp", "x/doc/y.tmp")
    check m("very/deep/nested/**/x", "very/deep/nested/m/x")
    check not m("very/deep/nested/**/x", "other/x")

suite "dir-only":

  test "trailing slash":
    check m("build/", "build", isDir = true)
    check not m("build/", "build")
    check m("build/", "x/build", isDir = true)
    check not m("build/", "x/build")
    check m("/a/b/", "a/b", isDir = true)
    check not m("/a/b/", "a/b")

suite "doublestar":

  test "leading **/ matches at any depth":
    check m("**/deep", "deep")
    check m("**/deep", "a/deep")
    check m("**/deep", "a/b/deep")
    check not m("**/deep", "deep/x")
    check m("**/*.o", "a/b/x.o")
    check m("**/*.o", "x.o")

  test "trailing /** matches everything inside":
    check not m("deep/**", "deep")
    check m("deep/**", "deep/x")
    check m("deep/**", "deep/x/y")
    check not m("deep/**", "x/deep")

  test "interior /**/ matches zero or more dirs":
    check m("a/**/b", "a/b")
    check m("a/**/b", "a/x/b")
    check m("a/**/b", "a/x/y/b")
    check not m("a/**/b", "x/a/b")
    check m("a/**/b/**", "a/b/c/d")

  test "bare ** matches everything":
    check m("/**", "x")
    check m("/**", "a/b")
    check m("**", "whatever")

  test "other consecutive asterisks are regular stars":
    check m("a**b", "ab")
    check m("a**b", "axxb")
    check not m("a**b", "a/b")
    check m("**/", "any", isDir = true)
    check not m("**/", "any")

suite "negation flag":

  test "neg flag parsed, matching unchanged":
    let p = parsePattern("!keep.log")
    check p.neg
    check matchPath(p, @["keep.log"], 0, 1, false)

  test "dir-only + doublestar":
    check m("**/build/", "a/build", isDir = true)
    check not m("**/build/", "a/build")
