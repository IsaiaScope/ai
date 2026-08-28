#!/usr/bin/env python3
"""Plain-assert tests for lint_scaletta. Run: python3 test_lint_scaletta.py"""
import pathlib, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).parent
LINT = HERE / "lint_scaletta.py"
sys.path.insert(0, str(HERE))
import lint_scaletta as L  # noqa: E402

TERMS = ["inferenza statistica", "transformer"]

def run(scaletta, terms=TERMS):
    """The predicate, called directly.

    An explicit term list is not a CLI mode -- the only shipped mode is
    --draft, which derives its terms from the draft's own Hook and so can
    never carry a multi-word term. These call hook()/unglossed() in-process
    so the predicate stays covered for term lists the CLI cannot express.
    """
    d = pathlib.Path(tempfile.mkdtemp())
    (d / "s.md").write_text(scaletta, encoding="utf-8")
    h = L.hook(d / "s.md")
    if h is None:
        return 1, "FAIL: no **HOOK** section"
    bad = L.unglossed(h, terms)
    return (1 if bad else 0), " ".join(bad)

def test_unglossed_term_in_hook_fails():
    rc, out = run("# T\n\n**HOOK**\n\n* Funziona tramite l'inferenza statistica.\n\n**Poi**\n\n* Altro.\n")
    assert rc == 1, out
    assert "inferenza statistica" in out

def test_glossed_term_in_hook_passes():
    rc, out = run("# T\n\n**HOOK**\n\n* Usa l'inferenza statistica, cioe' trova regolarita' nei dati.\n\n**Poi**\n\n* Altro.\n")
    assert rc == 0, out

def test_gloss_must_be_near_the_term():
    far = " ".join(["parola"] * 20)
    rc, out = run("# T\n\n**HOOK**\n\n* L'inferenza statistica %s cioe' spiega.\n\n**Poi**\n\n* x.\n" % far)
    assert rc == 1, out

def test_term_after_the_hook_is_ignored():
    rc, out = run("# T\n\n**HOOK**\n\n* Un filtro antispam.\n\n**Dopo**\n\n* Il transformer nudo.\n")
    assert rc == 0, out

def test_parenthesis_counts_as_a_gloss():
    rc, out = run("# T\n\n**HOOK**\n\n* Il transformer (una struttura software) e' veloce.\n\n**Poi**\n\n* x.\n")
    assert rc == 0, out

def test_missing_hook_section_fails():
    rc, out = run("# T\n\n**Intro**\n\n* Nessun hook qui.\n")
    assert rc == 1, out
    assert "HOOK" in out

def test_realistic_nested_hook_with_unglossed_term_fails():
    """Real Scalette nest bullets under a bold first bullet. Check that shape.

    Deliberately synthetic. The 2026-06-05 Scaletta is NOT a fixture here: its
    HOOK glosses 'inferenza statistica' with 'ovvero' and correctly passes. Its
    defect is that it opens on an abstraction, which this predicate does not
    measure and does not claim to.
    """
    hook = ("# T\n\n**HOOK**\n\n"
            "* **L'AI non e' magia: e' matematica applicata a dati**\n"
            "    * Funziona tramite l'inferenza statistica su volumi enormi di dati.\n"
            "    * Non serve una coscienza per prevedere il traffico.\n\n"
            "**Cos'e' davvero**\n\n* Altro.\n")
    rc, out = run(hook)
    assert rc == 1, out
    assert "inferenza statistica" in out

def test_same_hook_passes_once_glossed():
    hook = ("# T\n\n**HOOK**\n\n"
            "* **L'AI non e' magia: e' matematica applicata a dati**\n"
            "    * Funziona tramite l'inferenza statistica, ovvero trova regolarita' nei dati.\n\n"
            "**Cos'e' davvero**\n\n* Altro.\n")
    rc, out = run(hook)
    assert rc == 0, out

def test_acronym_inside_a_word_is_not_a_match():
    """'AGI' must not match inside 'magia'. Found against the real 06-05 file."""
    rc, out = run("# T\n\n**HOOK**\n\n* L'AI non e' magia, e' pattern.\n\n**Poi**\n\n* x.\n",
                  ["AGI", "narrow AI"])
    assert rc == 0, out

def test_multiword_term_still_matches():
    rc, out = run("# T\n\n**HOOK**\n\n* Usa l'inferenza statistica per tutto.\n\n**Poi**\n\n* x.\n",
                  ["inferenza statistica"])
    assert rc == 1, out


def test_two_file_mode_compares_draft_against_humanized():
    # The real job: the draft glossed a term, the humanized version dropped it.
    d = pathlib.Path(tempfile.mkdtemp())
    draft = "# T\n\n**HOOK**\n\n* Un transformer, cioe' un modello che pesa le parole.\n\n**Poi**\n\n* x.\n"
    final = "# T\n\n**HOOK**\n\n* Un transformer che pesa le parole.\n\n**Poi**\n\n* x.\n"
    (d / "draft.md").write_text(draft, encoding="utf-8")
    (d / "final.md").write_text(final, encoding="utf-8")
    r = subprocess.run([sys.executable, str(LINT), str(d / "final.md"), "--draft", str(d / "draft.md")],
                       capture_output=True, text=True)
    assert r.returncode == 1, (r.returncode, r.stdout, r.stderr)
    assert "transformer" in (r.stdout + r.stderr)

def test_two_file_mode_passes_when_the_gloss_survives():
    d = pathlib.Path(tempfile.mkdtemp())
    draft = "# T\n\n**HOOK**\n\n* Un transformer, cioe' un modello che pesa le parole.\n\n**Poi**\n\n* x.\n"
    final = "# T\n\n**HOOK**\n\n* Un transformer, ovvero un modello che sceglie cosa contare.\n\n**Poi**\n\n* x.\n"
    (d / "draft.md").write_text(draft, encoding="utf-8")
    (d / "final.md").write_text(final, encoding="utf-8")
    r = subprocess.run([sys.executable, str(LINT), str(d / "final.md"), "--draft", str(d / "draft.md")],
                       capture_output=True, text=True)
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)

def test_short_layout_inline_hook_is_found():
    # scaletta-short writes the HOOK as a bullet carrying its text inline.
    # A parser matching only a bare '**HOOK**' line reported "no **HOOK**
    # section" for every short Scaletta ever generated.
    d = pathlib.Path(tempfile.mkdtemp())
    draft = ("# T\n\n* **HOOK**: Un transformer, cioe' un modello che pesa le parole.\n"
             "* **Poi**\n    * (a) x.\n")
    final = ("# T\n\n* **HOOK**: Un transformer che pesa le parole.\n"
             "* **Poi**\n    * (a) x.\n")
    (d / "draft.md").write_text(draft, encoding="utf-8")
    (d / "final.md").write_text(final, encoding="utf-8")
    r = subprocess.run([sys.executable, str(LINT), str(d / "final.md"), "--draft", str(d / "draft.md")],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    assert "no **HOOK** section" not in out, out
    # Found the HOOK, and caught the dropped gloss inside it.
    assert r.returncode == 1, (r.returncode, out)
    assert "transformer" in out, out

def test_short_layout_inline_hook_passes_when_gloss_survives():
    d = pathlib.Path(tempfile.mkdtemp())
    draft = "# T\n\n* **HOOK**: Un transformer, cioe' un modello che pesa le parole.\n* **Poi**\n    * (a) x.\n"
    final = "# T\n\n* **HOOK**: Un transformer, ovvero un modello che sceglie cosa contare.\n* **Poi**\n    * (a) x.\n"
    (d / "draft.md").write_text(draft, encoding="utf-8")
    (d / "final.md").write_text(final, encoding="utf-8")
    r = subprocess.run([sys.executable, str(LINT), str(d / "final.md"), "--draft", str(d / "draft.md")],
                       capture_output=True, text=True)
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)

if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("  ok   %s" % name)
            except AssertionError as e:
                print("  FAIL %s: %s" % (name, e))
                failed += 1
    print("PASS: lint_scaletta" if not failed else "FAILED: %d" % failed)
    sys.exit(1 if failed else 0)
