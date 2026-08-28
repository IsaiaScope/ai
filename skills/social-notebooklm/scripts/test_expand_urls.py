#!/usr/bin/env python3
import json, pathlib, subprocess, sys

P = pathlib.Path(__file__).parent / "expand_urls.py"

def run(urls):
    r = subprocess.run([sys.executable, str(P)], input=json.dumps(urls),
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)

def test_youtube_watch_is_typed_youtube():
    out = run(["https://www.youtube.com/watch?v=abc"])
    assert out == [{"url": "https://www.youtube.com/watch?v=abc", "type": "youtube"}]

def test_youtu_be_short_link_is_typed_youtube():
    out = run(["https://youtu.be/abc"])
    assert out[0]["type"] == "youtube"

def test_plain_url_is_typed_url():
    out = run(["https://example.com/article"])
    assert out == [{"url": "https://example.com/article", "type": "url"}]

def test_bare_github_repo_also_adds_raw_readme():
    out = run(["https://github.com/foo/bar"])
    assert len(out) == 2, out
    assert out[0]["url"] == "https://github.com/foo/bar"
    assert out[1]["url"] == "https://raw.githubusercontent.com/foo/bar/HEAD/README.md"
    assert all(o["type"] == "url" for o in out)

def test_github_deep_link_is_not_expanded():
    out = run(["https://github.com/foo/bar/blob/main/x.py"])
    assert len(out) == 1, out

def test_github_trailing_slash_still_expands():
    out = run(["https://github.com/foo/bar/"])
    assert len(out) == 2, out

def test_order_is_preserved_and_duplicates_dropped():
    out = run(["https://a.example/1", "https://a.example/1", "https://b.example/2"])
    assert [o["url"] for o in out] == ["https://a.example/1", "https://b.example/2"]

if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print("  ok   %s" % name)
            except AssertionError as e:
                print("  FAIL %s: %s" % (name, e)); failed += 1
    print("PASS: expand_urls" if not failed else "FAILED: %d" % failed)
    sys.exit(1 if failed else 0)
