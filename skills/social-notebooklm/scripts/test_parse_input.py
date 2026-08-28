#!/usr/bin/env python3
"""Plain-assert tests. Run: python3 test_parse_input.py"""
import json, pathlib, subprocess, sys

P = pathlib.Path(__file__).parent / "parse_input.py"

def run(s):
    r = subprocess.run([sys.executable, str(P)], input=s, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)

def test_prose_only():
    d = run("come funziona un LLM sotto il cofano")
    assert d["urls"] == []
    assert "sotto il cofano" in d["prose"]

def test_single_url():
    d = run("https://www.youtube.com/watch?v=abc123")
    assert d["urls"] == ["https://www.youtube.com/watch?v=abc123"]
    assert d["prose"].strip() == ""

def test_mixed_urls_and_prose():
    d = run("guarda https://youtu.be/aaa e anche https://github.com/foo/bar "
            "e spiega la parte sui transformer")
    assert d["urls"] == ["https://youtu.be/aaa", "https://github.com/foo/bar"]
    assert "transformer" in d["prose"]
    assert "http" not in d["prose"]

def test_duplicate_urls_collapse():
    d = run("https://a.example/x https://a.example/x altro")
    assert d["urls"] == ["https://a.example/x"]

def test_trailing_punctuation_is_not_part_of_the_url():
    d = run("vedi https://example.com/page, poi commenta")
    assert d["urls"] == ["https://example.com/page"], d["urls"]

def test_url_order_is_preserved():
    d = run("https://b.example/1 testo https://a.example/2")
    assert d["urls"] == ["https://b.example/1", "https://a.example/2"]

def test_whitespace_is_collapsed_in_prose():
    d = run("uno   due\n\ntre")
    assert d["prose"] == "uno due tre"

if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print("  ok   %s" % name)
            except AssertionError as e:
                print("  FAIL %s: %s" % (name, e)); failed += 1
    print("PASS: parse_input" if not failed else "FAILED: %d" % failed)
    sys.exit(1 if failed else 0)
