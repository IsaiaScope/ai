#!/usr/bin/env python3
import json, pathlib, subprocess, sys, tempfile

P = pathlib.Path(__file__).parent / "build_query.py"

GUIDES = [
    {"title": "Attention Is All You Need",
     "summary": "Introduce l'architettura transformer.",
     "keywords": ["transformer", "attention", "self-attention"],
     "topics": ["deep learning"]},
    {"title": "Repo: nanoGPT",
     "summary": "Implementazione minimale di un GPT.",
     "keywords": ["GPT", "training"],
     "topics": ["deep learning", "codice"]},
]

def run(prose, guides=GUIDES):
    d = pathlib.Path(tempfile.mkdtemp())
    (d / "prose.txt").write_text(prose, encoding="utf-8")
    (d / "g.json").write_text(json.dumps(guides), encoding="utf-8")
    r = subprocess.run([sys.executable, str(P), str(d / "prose.txt"), str(d / "g.json")],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout

def test_keywords_from_guides_reach_the_query():
    q = run("spiega i transformer")
    assert "self-attention" in q
    assert "nanoGPT" in q or "GPT" in q

def test_user_prose_reaches_the_query():
    q = run("concentrati sulla parte storica")
    assert "parte storica" in q

def test_query_is_italian_and_asks_for_depth():
    q = run("x")
    assert "italiano" in q.lower()
    assert "approfondisci" in q.lower() or "ricerca" in q.lower()

def test_duplicate_keywords_appear_once():
    q = run("x", guides=[{"title": "a", "summary": "", "keywords": ["gpt", "GPT"], "topics": []}])
    assert q.lower().count("gpt") >= 1
    assert "gpt, GPT" not in q

def test_empty_prose_still_produces_a_query():
    q = run("")
    assert len(q.strip()) > 40
    assert "transformer" in q

def test_no_guides_falls_back_to_prose_alone():
    q = run("come funziona un LLM", guides=[])
    assert "come funziona un LLM" in q
    assert len(q.strip()) > 40


def test_summaries_reach_the_query():
    # The Source Guide summary is the richest field the API returns; `topics`
    # is documented but absent in practice, so the summary carries that weight.
    q = run("x")
    assert "architettura transformer" in q, q

def test_a_guide_without_topics_still_works():
    q = run("x", guides=[{"title": "a", "summary": "Roba utile.", "keywords": ["k"]}])
    assert "Roba utile" in q
    assert len(q.strip()) > 40

def test_long_summaries_are_trimmed():
    q = run("x", guides=[{"title": "a", "summary": "parola " * 400, "keywords": []}])
    assert len(q) < 4000, len(q)

def test_no_guides_scopes_instead_of_widening():
    # "what the material does not cover" subtracts only when there IS material.
    # With none it means everything: a prose-only run drifted into Italian AI
    # law and energy consumption. No sources -> scope the topic, don't widen it.
    q = run("AI vs Machine Learning vs Deep Learning vs LLM", guides=[])
    assert "NON copre" not in q, q
    assert "Resta strettamente" in q, q

def test_guides_keep_the_subtracting_clause():
    q = run("x", guides=[{"title": "a", "summary": "Roba utile.", "keywords": ["k"]}])
    assert "NON copre" in q, q
    assert "Resta strettamente" not in q, q

def test_both_branches_keep_the_depth_axes():
    # The axes are useful either way; only the framing around them changes.
    for guides in ([], [{"title": "a", "summary": "s", "keywords": []}]):
        q = run("x", guides=guides)
        for axis in ("contesto storico", "obiezioni e critiche",
                     "dati aggiornati", "malintesi"):
            assert axis in q, (axis, guides, q)

if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print("  ok   %s" % name)
            except AssertionError as e:
                print("  FAIL %s: %s" % (name, e)); failed += 1
    print("PASS: build_query" if not failed else "FAILED: %d" % failed)
    sys.exit(1 if failed else 0)
