#!/usr/bin/env python3
"""Compose the deep-research query from the user's prose and the Source Guides.

The user's own phrasing is usually thin — a few words, sometimes only a link.
The sources they passed already know what they are about: NotebookLM generates
a summary, keywords and topic tags per source. Combining the two gives web
research something specific to chase without the user having to write a brief.

usage: build_query.py <prose-file> <guides-json>
"""
import json, pathlib, sys

SUMMARY_CHARS = 400


def dedupe(items):
    out, seen = [], set()
    for it in items:
        k = it.strip().lower()
        if k and k not in seen:
            seen.add(k)
            out.append(it.strip())
    return out


def build(prose, guides):
    keywords = dedupe([k for g in guides for k in g.get("keywords", [])])
    # `topics` is documented by the CLI but absent from the JSON in practice.
    # Kept because it costs nothing and returns for free if the API adds it.
    topics = dedupe([t for g in guides for t in g.get("topics", [])])
    titles = dedupe([g.get("title", "") for g in guides])
    # The summary is the richest thing a Source Guide returns, and with topics
    # missing it is what tells the web search what the material is actually
    # about. Trimmed: a dozen long summaries would bury the rest of the query.
    briefs = []
    for g in guides:
        summary = " ".join((g.get("summary") or "").split())
        if not summary:
            continue
        if len(summary) > SUMMARY_CHARS:
            summary = summary[:SUMMARY_CHARS].rsplit(" ", 1)[0] + "..."
        title = (g.get("title") or "").strip()
        briefs.append(("%s: %s" % (title, summary)) if title else summary)

    parts = [
        "Fai una ricerca approfondita in italiano per preparare un video "
        "divulgativo. Trova fonti autorevoli, dati concreti e numeri "
        "verificabili, ed esempi quotidiani che rendano il tema comprensibile "
        "a chi non e' tecnico."
    ]
    if prose.strip():
        parts.append("Richiesta di chi fara' il video: " + prose.strip())
    if briefs:
        parts.append("Materiale gia' raccolto:\n- " + "\n- ".join(briefs))
    elif titles:
        parts.append("Materiale gia' raccolto: " + "; ".join(titles) + ".")
    if keywords:
        parts.append("Approfondisci in particolare questi concetti: "
                     + ", ".join(keywords) + ".")
    if topics:
        parts.append("Ambito: " + ", ".join(topics) + ".")
    # The same axes are worth chasing either way; only the framing may differ.
    depth = ("contesto storico, obiezioni e critiche, dati aggiornati, e i "
             "malintesi piu' diffusi sull'argomento")
    if briefs or titles:
        # With sources present this SUBTRACTS: go past what is already covered.
        parts.append("Cerca anche cio' che il materiale gia' raccolto NON "
                     "copre: " + depth + ".")
    else:
        # With no sources it would ADD instead: "what the material does not
        # cover" is everything, so the search spreads across adjacent topics
        # rather than deepening the requested one. A prose-only run for
        # "AI vs ML vs DL vs LLM" came back with 85 sources, 16 of them about
        # Italian AI law and energy consumption. Same axes, scoped instead.
        parts.append("Approfondisci l'argomento richiesto lungo questi assi: "
                     + depth + ". Resta strettamente su quell'argomento: "
                     "non allargarti a temi adiacenti che non sono stati "
                     "chiesti.")
    return "\n\n".join(parts)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write("usage: build_query.py <prose-file> <guides-json>\n")
        sys.exit(2)
    prose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    guides = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    sys.stdout.write(build(prose, guides))
