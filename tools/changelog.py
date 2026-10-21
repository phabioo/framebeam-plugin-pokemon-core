#!/usr/bin/env python3
"""Changelog tooling: PR check and release-note collection (stdlib only, run with `python3 -I`).

  changelog.py check   [--body-file F | env PR_BODY] [--author LOGIN]
  changelog.py collect --repo OWNER/NAME --base REF --head SHA [--product hub|player]
                       --format markdown|index|json [--title TEXT] [--compare-url] [--level N]

Every PR body carries a `## Changelog` section: either `none` or bullets under `### Added|Changed|Fixed|Removed|Security`.
A bullet may start with `Hub:` or `Player:` when only one product is affected (optional; repositories with a single
product just omit it). `collect` walks `git log --first-parent base..head` in a full clone, maps commits to PRs and builds
the notes from those sections. The file is generic: copy it unchanged into other repositories.
"""
import argparse, json, os, re, subprocess, sys

GROUPS = ["Added", "Changed", "Fixed", "Removed", "Security"]
EXTRA_GROUPS = ["Dependencies", "Other"]   # only produced by the fallbacks, never valid in a PR section
INDEX_MAX_BYTES = 4000
PRODUCTS = {"hub": "Hub", "player": "Player"}
PREFIX_RE = re.compile(r"^(hub|player)\s*:\s*", re.I)


def strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def parse_section(body):
    """Returns (status, entries, errors); status is 'missing', 'none' or 'entries'; entries are (group, text) pairs."""
    body = strip_comments((body or "").replace("\r\n", "\n"))
    lines = body.split("\n")
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^##\s+changelog\s*$", line.strip(), re.I) and not line.startswith(" "):
            start = i + 1
            break
    if start is None:
        return "missing", [], ["no `## Changelog` section"]
    content = []
    for line in lines[start:]:
        if re.match(r"^##(?!#)\s", line):
            break
        content.append(line)
    if "\n".join(content).strip().lower() == "none":
        return "none", [], []
    entries, errors, group, last = [], [], None, None
    for line in content:
        s = line.strip()
        if not s:
            continue
        h = re.match(r"^###\s+(.*?)\s*$", s)
        if h:
            name = next((g for g in GROUPS if g.lower() == h.group(1).lower()), None)
            if name is None:
                errors.append("unknown heading `### %s` (allowed: %s)" % (h.group(1), ", ".join("### " + g for g in GROUPS)))
            group, last = name, None
            continue
        if s.startswith("#"):
            errors.append("unexpected heading `%s` inside the Changelog section" % s)
            continue
        b = re.match(r"^-(?:\s+(.*))?$", s) if not line[0].isspace() else None
        if b is not None:
            text = (b.group(1) or "").strip()
            if not text:
                errors.append("empty bullet (`-` without text)")
                last = None
            elif group is None:
                errors.append("bullet before any `###` heading: `- %s`" % text)
                last = None
            else:
                entries.append([group, text])
                last = entries[-1]
            continue
        if line[0].isspace() and last is not None:   # continuation of the previous bullet
            last[1] += " " + s
            continue
        errors.append("text that is not a `- ` bullet: `%s`" % s)
    if not errors and not entries:
        errors.append("the section has no bullet (write `none` for changes without user-visible effect)")
    return ("entries" if not errors else "invalid"), [tuple(e) for e in entries], errors


def clean_line(text):
    """One line without control characters (the Hub and signer reject them in notes): they become spaces, runs collapse."""
    return re.sub(r"\s+", " ", re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", text)).strip()


def is_bot(login, utype=None):
    return (login or "").endswith("[bot]") or utype == "Bot"


def cmd_check(args):
    body = open(args.body_file, encoding="utf-8").read() if args.body_file else os.environ.get("PR_BODY", "")
    author = args.author if args.author is not None else os.environ.get("PR_AUTHOR", "")
    if is_bot(author):
        print("Changelog check skipped for bot author %s" % author)
        return 0
    status, entries, errors = parse_section(body)
    if status in ("none", "entries"):
        print("Changelog section ok (%s)" % ("none" if status == "none" else "%d entries" % len(entries)))
        return 0
    how = ("Add a `## Changelog` section to the PR description: `none` for CI, docs, test or refactoring-only changes, "
           "otherwise one `- ` line per user-visible change under `### Added`, `### Changed`, `### Fixed`, `### Removed` "
           "or `### Security` (optional prefix `Hub:` or `Player:`).")
    for e in errors:
        print("::error title=Changelog section::%s" % e)
    print("::error title=Changelog section::%s" % how)
    return 1


# --- collect -------------------------------------------------------------------------------------------------------

def run_git_log(base, head):
    out = subprocess.run(["git", "log", "--first-parent", "--reverse", "--format=%H%x09%s", "%s..%s" % (base, head)],
                         check=True, capture_output=True, text=True).stdout
    return [tuple(l.split("\t", 1)) for l in out.splitlines() if "\t" in l]


def run_gh_api(path):
    return json.loads(subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout)


def pr_number(subject):
    m = re.match(r"^Merge pull request #(\d+)\b", subject) or re.search(r"\(#(\d+)\)\s*$", subject)
    return int(m.group(1)) if m else None


def apply_product(text, product):
    """Returns the text for the product or None when the line belongs to the other product."""
    m = PREFIX_RE.match(text)
    if not m:
        return text
    if product is None:
        return text
    if m.group(1).lower() != product:
        return None
    return text[m.end():].strip() or None


def collect(repo, base, head, product=None, git_log=run_git_log, gh_api=run_gh_api):
    """Returns {group: [(text, [(number, url), ...])]} in fixed group order, oldest change first, duplicates merged."""
    items = []   # (group, text, ref or None)
    for sha, subject in git_log(base, head):
        num = pr_number(subject)
        if num is None:
            try:
                pulls = gh_api("repos/%s/commits/%s/pulls" % (repo, sha))
                num = pulls[0]["number"] if pulls else None
            except Exception:
                num = None
        if num is None:
            items.append(("Other", subject, None))
            continue
        pr = gh_api("repos/%s/pulls/%d" % (repo, num))
        ref = (num, pr.get("html_url") or "https://github.com/%s/pull/%d" % (repo, num))
        user = pr.get("user") or {}
        status, entries, _ = parse_section(pr.get("body") or "")
        if status == "none":
            continue
        if status == "entries":
            items.extend((g, t, ref) for g, t in entries)
        else:
            group = "Dependencies" if is_bot(user.get("login"), user.get("type")) else "Changed"
            items.append((group, (pr.get("title") or "PR #%d" % num).strip(), ref))
    result = {g: [] for g in GROUPS + EXTRA_GROUPS}
    seen = {}
    for group, text, ref in items:
        text = apply_product(clean_line(text), product)
        if not text:
            continue
        key = (group, text)
        if key in seen:
            if ref and ref not in seen[key][1]:
                seen[key][1].append(ref)
            continue
        seen[key] = (text, [ref] if ref else [])
        result[group].append(seen[key])
    return {g: v for g, v in result.items() if v}


def render_markdown(groups, title=None, compare=None, level=3):
    out = []
    if title:
        out += [title, ""]
    if not groups:
        out += ["No user-visible changes.", ""]
    for g, entries in groups.items():
        out.append("%s %s" % ("#" * level, g))
        out.append("")
        for text, refs in entries:
            suffix = " (%s)" % ", ".join("[#%d](%s)" % r for r in refs) if refs else ""
            out.append("- %s%s" % (text, suffix))
        out.append("")
    if compare:
        out += ["Full changelog: %s" % compare, ""]
    return "\n".join(out).rstrip("\n") + "\n"


def render_index(groups, limit=INDEX_MAX_BYTES):
    lines = []   # (text, is_entry)
    for g, entries in groups.items():
        lines.append((g + ":", False))
        lines += [("- " + clean_line(t), True) for t, _ in entries]
    total = sum(1 for _, e in lines if e)
    if not total:
        return ""
    full = "\n".join(t for t, _ in lines)
    if len(full.encode("utf-8")) <= limit:
        return full + "\n"
    keep = len(lines)
    while keep > 0:
        part = lines[:keep]
        while part and not part[-1][1]:   # never end on a group header
            part = part[:-1]
        left = total - sum(1 for _, e in part if e)
        text = "\n".join([t for t, _ in part] + ["... and %d more (see the release notes)" % left])
        if len(text.encode("utf-8")) <= limit:
            return text + "\n"
        keep = len(part) - 1
    return "... and %d more (see the release notes)\n" % total


def cmd_collect(args, git_log=run_git_log, gh_api=run_gh_api):
    try:
        groups = collect(args.repo, args.base, args.head, args.product, git_log, gh_api)
    except Exception as e:   # git or API failure: the caller decides whether that blocks anything
        print("::error::collecting the changelog failed: %s" % e, file=sys.stderr)
        return 1
    if args.format == "json":
        data = {g: [{"text": t, "prs": [{"number": n, "url": u} for n, u in refs]} for t, refs in v] for g, v in groups.items()}
        sys.stdout.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    elif args.format == "index":
        sys.stdout.write(render_index(groups))
    else:
        compare = "https://github.com/%s/compare/%s...%s" % (args.repo, args.base, args.head) if args.compare_url else None
        sys.stdout.write(render_markdown(groups, args.title, compare, args.level))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--body-file")
    c.add_argument("--author")
    k = sub.add_parser("collect")
    k.add_argument("--repo", required=True)
    k.add_argument("--base", required=True)
    k.add_argument("--head", required=True)
    k.add_argument("--product", choices=sorted(PRODUCTS))
    k.add_argument("--format", choices=["markdown", "index", "json"], default="markdown")
    k.add_argument("--title")
    k.add_argument("--compare-url", action="store_true")
    k.add_argument("--level", type=int, default=3, help="heading level of the groups in markdown output")
    args = p.parse_args(argv)
    return cmd_check(args) if args.cmd == "check" else cmd_collect(args)


if __name__ == "__main__":
    sys.exit(main())
