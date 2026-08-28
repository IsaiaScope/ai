#!/usr/bin/env python3
"""Check the Ramp at the Hook.

A Scaletta's Hook may name a Termine only if it glosses it within GLOSS_WINDOW
words. Everything after the Hook is prompt-guided and not checked: the Ramp is
deliberately conditional, and a rigid checker would fight it.

    lint_scaletta.py <scaletta.md> --draft <draft.md>

Compare a humanized Scaletta against the draft it came from. The terms are
whatever the draft's own Hook glossed, so no term list is needed and nothing is
asked of NotebookLM: the generator is told to gloss, the humanizing pass is a
second model rewriting that text, and this catches it dropping a gloss.
"""
import pathlib, re, sys, unicodedata

GLOSS_WINDOW = 12
GLOSS_MARKERS = ("cioe", "ovvero", "vale a dire", "in pratica", "in altre parole")
STOPWORDS = {"un", "uno", "una", "il", "lo", "la", "i", "gli", "le", "l",
             "di", "da", "in", "con", "su", "per", "e", "del", "della"}


def fold(s):
    """Lowercase and strip accents, so 'cioè' and 'cioe'' both match."""
    s = unicodedata.normalize("NFD", s.lower())
    return "".join(c for c in s if unicodedata.category(c) != "Mn")


def hook(scaletta_path):
    """The HOOK's text, in either of the two layouts the prompts produce.

    long   a bare ``**HOOK**`` line, the text on the lines below it, ending at
           the next bold-only section heading.
    short  a bullet carrying its text inline: ``* **HOOK**: ...``.

    Matching only the bare form meant every short Scaletta failed the lint with
    "no **HOOK** section" -- never a dropped gloss, just a HOOK the parser
    could not see.
    """
    lines = pathlib.Path(scaletta_path).read_text(encoding="utf-8").splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r'^(?:[-*+]\s+)?\*\*HOOK\*\*\s*:?\s*(.*)$', ln.strip(), re.I)
        if not m:
            continue
        inline = m.group(1).strip()
        if inline:
            return inline
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if re.match(r'^\*\*[^*]+\*\*\s*$', lines[j].strip()):
                end = j
                break
        return " ".join(lines[i + 1:end])
    return None


def unglossed(hook_text, terms):
    folded = fold(hook_text)
    bad = []
    for term in terms:
        ft = fold(term)
        # Word boundaries, not substring: 'AGI' must not match inside 'magia'.
        m = re.search(r'(?<![0-9a-z])%s(?![0-9a-z])' % re.escape(ft), folded)
        if not m:
            continue
        after = folded[m.end():]
        window = " ".join(after.split()[:GLOSS_WINDOW])
        immediate = after.lstrip()[:1] in ("(", ":", "—", "-")
        if immediate or any(mk in window for mk in GLOSS_MARKERS):
            continue
        bad.append(term)
    return bad


def glossed_terms(hook_text):
    """The terms a Hook itself glossed: whatever sits before a gloss marker.

    'un transformer, cioe\' un modello ...' yields 'transformer'. Only the last
    few words before the marker are considered -- the gloss attaches to the
    term it follows, not to the whole sentence.
    """
    folded = fold(hook_text)
    out = []
    for marker in GLOSS_MARKERS:
        for m in re.finditer(r"(?<![0-9a-z])%s(?![0-9a-z])" % re.escape(marker), folded):
            before = folded[:m.start()].rstrip(" ,:;(\u2014-")
            words = before.split()
            if not words:
                continue
            # Skip Italian articles/prepositions so 'un transformer' -> 'transformer'.
            tail = [w for w in words[-2:] if w not in STOPWORDS]
            if tail and tail[-1] not in out:
                out.append(tail[-1])
    return out


def main(argv):
    if len(argv) != 4 or argv[2] != "--draft":
        sys.stderr.write("usage: lint_scaletta.py <scaletta.md> --draft <draft.md>\n")
        return 2
    scaletta, draft = argv[1], argv[3]
    for p in (scaletta, draft):
        if not pathlib.Path(p).is_file():
            sys.stderr.write("lint_scaletta: no such file: %s\n" % p)
            return 2

    h = hook(scaletta)
    if h is None:
        sys.stderr.write("FAIL: no **HOOK** section in %s\n" % scaletta)
        return 1

    dh = hook(draft)
    terms = glossed_terms(dh) if dh else []
    if not terms:
        print("lint_scaletta: no Termini in %s -- nothing to check" % draft)
        return 0

    bad = unglossed(h, terms)
    for t in bad:
        sys.stderr.write(
            "FAIL: '%s' appears in the HOOK without a gloss within %d words.\n"
            "      Anchor it first: an everyday example, then the term.\n" % (t, GLOSS_WINDOW))
    if bad:
        return 1
    print("lint_scaletta: HOOK clean (%d Termini checked)" % len(terms))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
