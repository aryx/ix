#!/usr/bin/env python3
# Claude Code hooks keeping docs/yoann_notes/prompt-history.md: each of
# Yoann's prompts verbatim, followed by a short summary of Claude's answer
# (written by Haiku, since the full answers are long and not deterministic).
#
#   history.py prompt              UserPromptSubmit hook: flush the pending
#                                  summary (see below), then append the
#                                  new prompt
#   history.py answer              Stop hook: stash the answer as pending,
#                                  instead of summarizing it right away
#   history.py stage-if-commit     PreToolUse (Bash) hook: `git add` this
#                                  file when the command is a `git commit`,
#                                  so pending history rides along with it
#   history.py rebuild TRANSCRIPT  regenerate the whole file from a session
#                                  transcript (.jsonl)
#
# The summary of an answer is written lazily, on the *next* prompt rather
# than right after the answer (Stop hook just stashes prompt+answer in
# PENDING). That next prompt is what Yoann actually reacted to, so it is
# passed to the summarizer as extra context to judge what in the answer
# mattered, without being summarized itself. This means the last exchange
# of a session stays pending until something (even in a later session)
# triggers a new prompt in this repo.
#
# The hooks get their JSON payload on stdin.
import concurrent.futures, datetime, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
PATH = os.path.join(ROOT, "docs", "yoann_notes", "prompt-history.md")
PENDING = os.path.join(ROOT, ".claude", "hooks", ".pending-answer.json")

# set in the environment of the summarizing `claude -p`, so that its own
# hooks, if any, don't log or summarize it
GUARD = "IX_HISTORY_SUMMARIZING"

HEADER = """# Prompt history

Every prompt Yoann wrote to Claude to build this repository, in order,
verbatim (typos included), each followed by a short summary of Claude's
answer. The summaries are written by a small model (Haiku) from the
answer's text, once Yoann's next prompt is known so it can weigh what
mattered to him: they are paraphrases, not records, and the commits show
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
Yoann's next message is included below, after the answer: use it only to \
judge which parts of Claude's answer actually mattered to Yoann (what he \
followed up on, corrected, or built on), and weight the summary toward \
that; do not describe or summarize the next message itself. If Claude's \
answer is just an error message and contains no actual response (e.g. \
"API Error", "safeguards flagged this message"), reply with exactly: \
(no answer: the request errored out)

=== YOANN'S PROMPT ===
{prompt}

=== CLAUDE'S ANSWER ===
{answer}

=== YOANN'S NEXT PROMPT (context only, do not summarize this) ===
{next_prompt}
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

def save_pending(prompt, answer):
    with open(PENDING, "w") as f:
        json.dump({"prompt": prompt, "answer": answer}, f)

def load_pending():
    if not os.path.exists(PENDING):
        return None
    with open(PENDING) as f:
        return json.load(f)

def clear_pending():
    if os.path.exists(PENDING):
        os.remove(PENDING)

def flush_pending(next_prompt):
    pending = load_pending()
    if not pending:
        return
    s = summarize(pending["prompt"], pending["answer"], next_prompt)
    if s:
        append(render_summary(s))
    clear_pending()

def summarize(prompt, answer, next_prompt=None):
    if not answer.strip():
        return None
    env = dict(os.environ, **{GUARD: "1"})
    next_text = clean_prompt(next_prompt) if next_prompt and next_prompt.strip() \
        else "(none - this is the last message so far)"
    r = subprocess.run(
        ["claude", "-p", "--model", "haiku", "--tools", "",
         "--no-session-persistence"],
        input=SUMMARY_PROMPT.format(prompt=clean_prompt(prompt),
                                    answer=answer[-40000:],
                                    next_prompt=next_text),
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
            flush_pending(prompt)
            append(render_prompt(prompt,
                                 datetime.datetime.now(datetime.timezone.utc)))
    elif mode == "answer":
        turns = exchanges(json.load(sys.stdin)["transcript_path"])
        if turns:
            save_pending(turns[-1]["prompt"], turns[-1]["answer"])
    elif mode == "stage-if-commit":
        data = json.load(sys.stdin)
        command = data.get("tool_input", {}).get("command", "")
        if re.search(r"\bgit\s+commit\b", command):
            subprocess.run(
                ["git", "-C", ROOT, "add", "--",
                 os.path.relpath(PATH, ROOT)],
                capture_output=True)
    elif mode == "rebuild":
        turns = exchanges(sys.argv[2])
        next_prompts = [turns[i + 1]["prompt"] if i + 1 < len(turns) else None
                        for i in range(len(turns))]
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            sums = list(pool.map(
                lambda a: summarize(a[0]["prompt"], a[0]["answer"], a[1]),
                zip(turns, next_prompts)))
        with open(PATH, "w") as f:
            f.write(HEADER)
            for t, s in zip(turns, sums):
                f.write(render_prompt(t["prompt"], t["time"]))
                if s:
                    f.write(render_summary(s))

main()
