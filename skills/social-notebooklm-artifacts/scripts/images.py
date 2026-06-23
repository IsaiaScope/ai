#!/usr/bin/env python3
"""Generate the 2x2 infographic matrix for a NotebookLM notebook.

Produces exactly 4 PNGs in OUT_DIR:
  simple_landscape.png   detailed_landscape.png
  simple_portrait.png    detailed_portrait.png

Concepts are NOT hardcoded — they are passed in (derived upstream from the
notebook's own sources). Paced + budget-capped for the free-tier quota.

Invocation (all via argv/env, no interactive input):
  NBLM_NOTEBOOK=<id> images.py <out_dir> <concepts_file>

<concepts_file> is 4 lines, one per quadrant, in this order:
  simple_landscape, detailed_landscape, simple_portrait, detailed_portrait
each line: "TITOLO :: dettaglio breve"

Requires the notebooklm-py library (run with the venv python, e.g.
~/.venvs/nblm/bin/python). The notebooklm CLI does NOT expose infographic
generation, so the library is mandatory for this step.
"""
import asyncio
import os
import pathlib
import sys

try:
    from notebooklm import NotebookLMClient
    from notebooklm.rpc import (
        InfographicOrientation,
        InfographicDetail,
        InfographicStyle,
    )
except Exception as e:  # pragma: no cover - import guard
    sys.stderr.write(
        "images.py: notebooklm library not importable in this interpreter.\n"
        f"  {type(e).__name__}: {e}\n"
        "  Install into a venv and point NBLM_PYTHON at it:\n"
        "    uv venv --python 3.13 ~/.venvs/nblm\n"
        '    uv pip install --python ~/.venvs/nblm "notebooklm-py[browser]"\n'
    )
    sys.exit(2)

NB = os.environ.get("NBLM_NOTEBOOK", "").strip()

# Pacing / quota knobs (the free tier is ~8 generations/rolling-24h).
DAILY_BUDGET  = int(os.environ.get("NBLM_BUDGET", "4"))
SPACING       = int(os.environ.get("NBLM_SPACING", "60"))
BACKOFF_START = int(os.environ.get("NBLM_BACKOFF_START", "90"))
BACKOFF_MAX   = int(os.environ.get("NBLM_BACKOFF_MAX", "600"))
MAX_RETRIES   = int(os.environ.get("NBLM_MAX_RETRIES", "4"))
BAD_STATUS    = {"removed", "failed", "not_found"}
STYLE         = InfographicStyle.PROFESSIONAL  # one style across all 4 = consistent look


def instr_simple(title, detail):
    return (
        f"Lingua: italiano. Crea un'infografica MOLTO SEMPLICE su UN SOLO concetto: '{title}'. "
        f"{detail} Massimo 3 elementi visivi. Testo ENORME, 5-8 parole per blocco. "
        f"Tanto spazio vuoto, ampi margini. NIENTE liste/passaggi/diagrammi complessi. "
        f"Solo un titolo gigante, una frase chiave, al massimo 2 icone."
    )


def instr_detailed(title, detail):
    return (
        f"Lingua: italiano. Crea un'infografica COMPLETA e ACCURATA su: '{title}'. "
        f"{detail} Includi piu dettagli, dati e una struttura chiara e organizzata. "
        f"Testo ben leggibile, gerarchia visiva chiara, ampi margini. "
        f"Stile professionale e coerente."
    )


# 2x2 quadrant spec: (name, kind, orientation, detail_level)
QUADRANTS = [
    ("simple_landscape",   "simple",   InfographicOrientation.LANDSCAPE, InfographicDetail.CONCISE),
    ("detailed_landscape", "detailed", InfographicOrientation.LANDSCAPE, InfographicDetail.DETAILED),
    ("simple_portrait",    "simple",   InfographicOrientation.PORTRAIT,  InfographicDetail.CONCISE),
    ("detailed_portrait",  "detailed", InfographicOrientation.PORTRAIT,  InfographicDetail.DETAILED),
]


def is_refusal(st):
    return (not getattr(st, "task_id", "")) or getattr(st, "status", "") == "failed"


def load_concepts(path):
    """Read 4 'TITOLO :: dettaglio' lines, pad/truncate to exactly 4."""
    raw = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    items = []
    for line in raw:
        line = line.strip()
        if not line:
            continue
        if "::" in line:
            title, detail = line.split("::", 1)
        else:
            title, detail = line, ""
        items.append((title.strip(), detail.strip()))
    if not items:
        sys.stderr.write("images.py: no concepts parsed from concepts file.\n")
        sys.exit(3)
    # pad to 4 by reusing the last concept; truncate to 4
    while len(items) < 4:
        items.append(items[-1])
    return items[:4]


async def gen_paced(client, out_dir, name, kind, orient, level, title, detail):
    a = client.artifacts
    instructions = instr_simple(title, detail) if kind == "simple" else instr_detailed(title, detail)
    backoff = BACKOFF_START
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            st = await a.generate_infographic(
                NB, language="it", instructions=instructions,
                orientation=orient, detail_level=level, style=STYLE,
            )
            if is_refusal(st):
                raise RuntimeError(getattr(st, "error", "") or "synchronous rate-limit refusal")
            final = await a.wait_for_completion(NB, st.task_id, timeout=600)
            if getattr(final, "status", "") in BAD_STATUS:
                raise RuntimeError(f"ended status={final.status} (quota/delisted)")
            p = await a.download_infographic(NB, str(out_dir / f"{name}.png"), st.task_id)
            print(f"[{name}] DONE -> {p}", flush=True)
            return True
        except Exception as e:
            print(f"[{name}] attempt {attempt}/{MAX_RETRIES} {type(e).__name__}: {e} -> backoff {backoff}s", flush=True)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX)
    print(f"[{name}] GAVE UP (likely daily quota — retry tomorrow)", flush=True)
    return False


async def main():
    if not NB:
        sys.stderr.write("images.py: NBLM_NOTEBOOK env var (notebook id) required.\n")
        sys.exit(1)
    if len(sys.argv) < 3:
        sys.stderr.write("images.py: usage: NBLM_NOTEBOOK=<id> images.py <out_dir> <concepts_file>\n")
        sys.exit(1)

    out_dir = pathlib.Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    concepts = load_concepts(sys.argv[2])

    done, failed = [], []
    spent = 0
    async with NotebookLMClient.from_storage() as client:
        for i, (name, kind, orient, level) in enumerate(QUADRANTS):
            if spent >= DAILY_BUDGET:
                failed.extend(q[0] for q in QUADRANTS[i:])
                print(f"BUDGET REACHED ({DAILY_BUDGET}). Skipped: {[q[0] for q in QUADRANTS[i:]]}", flush=True)
                break
            title, detail = concepts[i]
            ok = await gen_paced(client, out_dir, name, kind, orient, level, title, detail)
            spent += 1
            (done if ok else failed).append(name)
            if not ok:
                print("Refused — likely daily quota exhausted. Stopping; retry tomorrow.", flush=True)
                failed.extend(q[0] for q in QUADRANTS[i + 1:])
                break
            if i < len(QUADRANTS) - 1 and spent < DAILY_BUDGET:
                print(f"...spacing {SPACING}s... ({spent}/{DAILY_BUDGET} used)", flush=True)
                await asyncio.sleep(SPACING)

    # machine-readable tail for the shell wrapper
    print(f"IMAGES_DONE={','.join(done)}", flush=True)
    print(f"IMAGES_FAILED={','.join(dict.fromkeys(failed))}", flush=True)
    sys.exit(0 if done and not failed else (0 if done else 4))


asyncio.run(main())
