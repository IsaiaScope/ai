#!/usr/bin/env python3
"""Split a free-form invocation into URLs and steering prose.

The input is whatever the user typed: any number of URLs of any kind, mixed
with text that explains what they want. URLs become NotebookLM sources; the
prose steers the research query built from those sources' guides.

stdin: raw string. stdout: {"urls": [...], "prose": "..."}
"""
import json, re, sys

# Trailing punctuation is prose, not URL: "vedi https://x.com/p, poi" must not
# swallow the comma. Closing brackets and quotes are excluded for the same
# reason.
URL_RE = re.compile(r'https?://[^\s<>"\'\)\]]+')
TRAILING = ".,;:!?"


def parse(raw):
    urls, seen = [], set()
    for m in URL_RE.finditer(raw):
        u = m.group(0).rstrip(TRAILING)
        if u not in seen:
            seen.add(u)
            urls.append(u)
    prose = URL_RE.sub(" ", raw)
    prose = re.sub(r"\s+", " ", prose).strip()
    return {"urls": urls, "prose": prose}


if __name__ == "__main__":
    json.dump(parse(sys.stdin.read()), sys.stdout, ensure_ascii=False)
    print()
