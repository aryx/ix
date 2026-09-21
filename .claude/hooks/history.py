#!/usr/bin/env python3
# Claude Code hooks keeping docs/yoann_notes/prompt-history.md: each of
# Yoann's prompts verbatim, followed by a short summary of Claude's answer
# (written by Haiku, since the full answers are long and not deterministic).
#
#   history.py prompt              UserPromptSubmit hook: append the prompt
#   history.py answer              Stop hook: append a summary of the answer
#   history.py rebuild TRANSCRIPT  regenerate the whole file from a session
#                                  transcript (.jsonl)
#
# The hooks get their JSON payload on stdin.
import concurrent.futures, datetime, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
PATH = os.path.join(ROOT, "docs", "yoann_notes", "prompt-history.md")

# set in the environment of the summarizing `claude -p`, so that its own
# hooks, if any, don't log or summarize it
GUARD = "IX_HISTORY_SUMMARIZING"

HEADER = """# Prompt history

Every prompt Yoann wrote to Claude to build this repository, in order,
verbatim (typos included), each followed by a short summary of Claude's
answer. The summaries are written by a small model (Haiku) from the
answer's text: they are paraphrases, not records, and the commits show
what was actually done. Together with `git log`, this file tells how ix
came to be.

Entries are appended by Claude Code hooks (`.claude/hooks/history.py`,
set in `.claude/settings.json`), so only sessions started in this
repository are recorded. The first entries, from a session started in
ocaml-elm-playground before this repository existed, were rebuilt from
that session's transcript. Times are UTC.
"""

SEPARATOR = "\n" + "-" * 72 + "\n"

SUMMARY_PROMPT = """Below is one exchange from a conversation between \
Yoann (the user) and Claude (an AI coding assistant) about "ix", a planned \
series of tiny but real OCaml programs (ARM emulator, kernel, compiler, \
...) that are tiny twins of Yoann's xix project.

Summarize CLAUDE'S ANSWER in AT MOST 5 short lines (roughly 12-18 words \
each, so five plain sentences, one per line, no line wrapping into a \
paragraph). No heading, no bullet list, no markdown emphasis. Say what \
Claude recommended, found, decided, or did (files written, commits \
made), keeping concrete names. Write in the past tense with Claude as \
the subject ("Claude recommended ..."). Do not restate Yoann's prompt. \
If Claude's answer is just an error message and contains no actual \
response (e.g. "API Error", "safeguards flagged this message"), reply \
with exactly: (no answer: the request errored out)

=== YOANN'S PROMPT ===
{prompt}

=== CLAUDE'S ANSWER ===
{answer}
"""

def clean_prompt(text):
    # pasted text arrives wrapped in <pasted_content ...> tags: keep the text
    return re.sub(r"</?pasted_content[^>]*>\n?", "", text).strip()

def render_prompt(prompt, when):
    quoted = "\n".join("> " + l if l else ">"
                       for l in clean_prompt(prompt).splitlines())
    return "%s\n## %s\n\n**Yoann:**\n\n%s\n" % (
        SEPARATOR, when.strftime("%Y-%m-%d %H:%M"), quoted)

def render_summary(summary):
    # Haiku sometimes blank-line-separates its sentences instead of
    # single-newline: normalize to one sentence per line either way.
    lines = [l.strip() for l in summary.strip().splitlines() if l.strip()]
    return "\n**Claude (summary):**\n\n%s\n" % "\n".join(lines)

def append(text):
    new = not os.path.exists(PATH)
    with open(PATH, "a") as f:
        if new:
            f.write(HEADER)
        f.write(text)

def summarize(prompt, answer):
    if not answer.strip():
        return None
    env = dict(os.environ, **{GUARD: "1"})
    r = subprocess.run(
        ["claude", "-p", "--model", "haiku", "--tools", "",
         "--no-session-persistence"],
        input=SUMMARY_PROMPT.format(prompt=clean_prompt(prompt),
                                    answer=answer[-40000:]),
        capture_output=True, text=True, cwd="/tmp", env=env, timeout=300)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() \
        else None

# A transcript is a .jsonl of entries; a user prompt is a "user" entry
# whose content is text (tool results are lists without text), and
# Claude's answer is the text blocks of the "assistant" entries after it.
def exchanges(transcript):
    turns = []
    for line in open(transcript):
        d = json.loads(line)
        if d.get("isMeta"):
            continue
        if d.get("type") == "user":
            c = d.get("message", {}).get("content")
            if isinstance(c, list):
                texts = [b.get("text", "") for b in c if b.get("type") == "text"]
                c = "\n".join(texts) if texts else None
            if isinstance(c, str) and c.strip() and not c.startswith("<"):
                turns.append({"prompt": c, "time": d["timestamp"],
                              "answer": []})
        elif d.get("type") == "assistant" and turns:
            for b in d.get("message", {}).get("content", []):
                if b.get("type") == "text" and b["text"].strip():
                    turns[-1]["answer"].append(b["text"])
    for t in turns:
        t["answer"] = "\n\n".join(t["answer"])
        t["time"] = datetime.datetime.fromisoformat(
            t["time"].replace("Z", "+00:00"))
    return turns

def main():
    mode = sys.argv[1]
    if os.environ.get(GUARD):
        return
    if mode == "prompt":
        prompt = json.load(sys.stdin).get("prompt", "")
        if prompt.strip():
            append(render_prompt(prompt,
                                 datetime.datetime.now(datetime.timezone.utc)))
    elif mode == "answer":
        turns = exchanges(json.load(sys.stdin)["transcript_path"])
        if turns:
            s = summarize(turns[-1]["prompt"], turns[-1]["answer"])
            if s:
                append(render_summary(s))
    elif mode == "rebuild":
        turns = exchanges(sys.argv[2])
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            sums = list(pool.map(lambda t: summarize(t["prompt"], t["answer"]),
                                 turns))
        with open(PATH, "w") as f:
            f.write(HEADER)
            for t, s in zip(turns, sums):
                f.write(render_prompt(t["prompt"], t["time"]))
                if s:
                    f.write(render_summary(s))

main()
