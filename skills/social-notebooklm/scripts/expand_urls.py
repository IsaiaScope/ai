#!/usr/bin/env python3
"""Classify URLs for `notebooklm source add --type`, and expand what is thin.

A bare GitHub repo URL renders as a project page: NotebookLM gets navigation
chrome and little prose. The raw README is where the actual explanation lives,
so a bare repo URL becomes two sources. A deep link already points at content
and is left alone.

stdin: JSON list of URLs. stdout: JSON list of {"url", "type"}.
"""
import json, re, sys

YOUTUBE = re.compile(r'^https?://((www\.|m\.)?youtube\.com/|youtu\.be/)', re.I)
GH_REPO = re.compile(r'^https?://github\.com/([^/\s]+)/([^/\s#?]+)/?$', re.I)


def expand(urls):
    out, seen = [], set()
    for u in urls:
        if u in seen:
            continue
        seen.add(u)
        if YOUTUBE.match(u):
            out.append({"url": u, "type": "youtube"})
            continue
        out.append({"url": u, "type": "url"})
        m = GH_REPO.match(u)
        if m:
            owner, repo = m.group(1), m.group(2)
            raw = "https://raw.githubusercontent.com/%s/%s/HEAD/README.md" % (owner, repo)
            if raw not in seen:
                seen.add(raw)
                out.append({"url": raw, "type": "url"})
    return out


if __name__ == "__main__":
    json.dump(expand(json.load(sys.stdin)), sys.stdout, ensure_ascii=False)
    print()
