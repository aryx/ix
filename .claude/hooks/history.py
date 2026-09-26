#!/usr/bin/env python3
# Claude Code hooks keeping docs/yoann_notes/prompt-history.md: each of
# Yoann's prompts verbatim, followed by a short summary of Claude's answer
# (written by Haiku, since the full answers are long and not deterministic).
#
#   history.py prompt              UserPromptSubmit hook (its work in a
#                                  detached child): write the session's
#                                  previous exchange (see below), then
#                                  keep the new prompt as the session's
#                                  open one
#   history.py answer              Stop hook: attach the answer to the
#                                  session's open prompt
#   history.py end                 SessionEnd hook: write the session's
#                                  last exchange, with no next prompt
#   history.py stage-if-commit     PreToolUse (Bash) hook: `git add` this
#                                  file when the command is a `git commit`,
#                                  so the history rides along with it
#   history.py rebuild TRANSCRIPT  regenerate the whole file from a session
#                                  transcript (.jsonl)
#   history.py rebuild-from 'YYYY-MM-DD HH:MM' TRANSCRIPT...
#                                  keep the entries before that time,
#                                  regenerate the rest from the sessions'
#                                  transcripts, interleaved by time
#
# An exchange is written whole, its prompt then the summary of its
# answer, and lazily: when the *same session's* next prompt comes (or the
# session ends), not right after the answer. That next prompt is what
# Yoann actually reacted to, so it is passed to the summarizer as extra
# context to judge what in the answer mattered, without being summarized
# itself.
#
# Each session has its own open exchange (SESSIONS/<session id>.json).
# old: one pending answer for the repository, and the prompt written at
# once; with two sessions at the same time, an answer of one was
# summarized under the other's next prompt, and a Stop overwrote the
# other's pending answer (2026-09-25 and 26: four sessions interleaved).
# Now an entry is never split, and entries of concurrent sessions come in
# the order they were written, their headings keeping the prompts' times.
#
# A session started in this repository but working on another project
# is listed in IGNORED (one session id per line, # for comments), and
# not recorded.
#
# The hooks get their JSON payload on stdin.
import concurrent.futures, datetime, fcntl, json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
PATH = os.path.join(ROOT, "docs", "yoann_notes", "prompt-history.md")
SESSIONS = os.path.join(ROOT, ".claude", "hooks", ".sessions")
IGNORED = os.path.join(ROOT, ".claude", "hooks", "ignored-sessions")
DEBUG_LOG = os.path.join(ROOT, ".claude", "hooks", ".debug.log")
LOCK = os.path.join(ROOT, ".claude", "hooks", ".history.lock")

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
repository are recorded (but those listed in
`.claude/hooks/ignored-sessions`, started here for another project). An
entry is written when its session's next prompt comes, so entries of
sessions run at the same time may be a little out of order. The first
entries, from a session started in ocaml-elm-playground before this
repository existed, were rebuilt from that session's transcript, and so
were those from 2026-09-25 09:19 to 2026-09-26 08:06, which concurrent
sessions had mixed up. Times are UTC.
"""

SEPARATOR = "\n" + "-" * 72 + "\n"

SUMMARY_PROMPT = """Below is one exchange from a conversation between \
Yoann (the user) and Claude (an AI coding assistant) about "ix", a planned \
series of small but real OCaml programs (ARM emulator, kernel, compiler, \
...): "mini" twins faithful to the Plan 9 originals (mini-mk, mini-rc, ...) \
and "tiny" free one-file variants (tiny-build, tiny-shell, ...).

Summarize CLAUDE'S ANSWER in AT MOST 5 short lines (roughly 12-18 words \
each, so five plain sentences, one per line, no line wrapping into a \
paragraph). No heading, no bullet list, no markdown emphasis. Say what \
Claude recommended, found, decided, or did (files written, commits \
made), keeping concrete names. Write in the past tense with Claude as \
the subject ("Claude recommended ..."). Do not restate Yoann's prompt.

Yoann's next message is included below, after the answer: use it to find \
the one part of Claude's answer he actually reacted to (what he picked, \
followed up on, corrected, or built on). Skew the summary hard toward \
that part: spend MOST of the lines (3-4 of the 5) on it, with real detail \
and concrete names, and compress everything else Claude's answer covered \
into AT MOST one single line, or drop it entirely if it's minor. Do not \
spread the lines evenly across everything Claude said. Do not describe \
or summarize the next message itself, only use it to pick the focus. If \
nothing in the next message points to a specific part of the answer, \
summarize normally instead of forcing a skew. If Claude's answer is just \
an error message and contains no actual response (e.g. "API Error", \
"safeguards flagged this message"), reply with exactly: \
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

def session_path(sid):
    return os.path.join(SESSIONS, re.sub(r"[^\w-]", "_", sid) + ".json")

def load_session(sid):
    try:
        with open(session_path(sid)) as f:
            return json.load(f)
    except FileNotFoundError:
        return None

def save_session(sid, open_exchange):
    os.makedirs(SESSIONS, exist_ok=True)
    with open(session_path(sid), "w") as f:
        json.dump(open_exchange, f)

def take_session(sid):
    # move it away at once: an answer attached while the summary is
    # being written goes to the next exchange instead of being lost
    path = session_path(sid)
    taken = path + ".%d" % os.getpid()
    try:
        os.rename(path, taken)
    except FileNotFoundError:
        return None
    with open(taken) as f:
        open_exchange = json.load(f)
    os.remove(taken)
    return open_exchange

def ignored(sid):
    if not os.path.exists(IGNORED):
        return False
    with open(IGNORED) as f:
        return sid in (l.split("#")[0].strip() for l in f)

def is_notification(prompt):
    # background-task notifications, subagents' reports (<agent-message>)
    # and system reminders arrive as prompts, but Yoann didn't write them;
    # as in exchanges(), a prompt starting with a tag is not his
    return prompt.lstrip().startswith("<")

def debug_log(msg):
    with open(DEBUG_LOG, "a") as f:
        f.write("[%s] %s\n" % (
            datetime.datetime.now(datetime.timezone.utc).isoformat(), msg))

def render_exchange(prompt, when, summary):
    text = render_prompt(prompt, when)
    return text + render_summary(summary) if summary else text

def write_exchange(open_exchange, next_prompt):
    """The session's open exchange as an entry: its prompt, then its
    answer's summary if it had an answer."""
    if not open_exchange:
        return
    when = datetime.datetime.fromisoformat(open_exchange["time"])
    answer = open_exchange.get("answer")
    s = None
    if answer:
        # Never lose the exchange: if summarization fails, fall back to
        # a truncated raw answer.
        s = summarize(open_exchange["prompt"], answer, next_prompt) or \
            "(summary generation failed - raw answer follows)\n\n" + answer[:1000]
    append(render_exchange(open_exchange["prompt"], when, s))

def detached(work):
    # Summarizing can take longer than Claude Code waits for a hook
    # (60 s), which used to kill it after the summary and before the
    # prompt: lost prompts, summaries under the wrong entry. So the work
    # goes to a detached child, serialized by a lock so that entries stay
    # whole, and the hook returns at once.
    if os.fork() == 0:
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        try:
            with open(LOCK, "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                work()
        except Exception as e:
            debug_log("detached: %r" % e)
        os._exit(0)

def summarize(prompt, answer, next_prompt=None):
    if not answer.strip():
        return None
    env = dict(os.environ, **{GUARD: "1"})
    next_text = clean_prompt(next_prompt) if next_prompt and next_prompt.strip() \
        else "(none - this is the last message so far)"
    try:
        r = subprocess.run(
            ["claude", "-p", "--model", "haiku", "--tools", "",
             "--no-session-persistence"],
            input=SUMMARY_PROMPT.format(prompt=clean_prompt(prompt),
                                        answer=answer[-40000:],
                                        next_prompt=next_text),
            capture_output=True, text=True, cwd="/tmp", env=env, timeout=120)
    except subprocess.TimeoutExpired:
        debug_log("summarize: timed out after 120s")
        return None
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    debug_log("summarize: returncode=%d stderr=%r stdout=%r" %
              (r.returncode, r.stderr[-2000:], r.stdout[-500:]))
    return None

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
        elif d.get("type") == "attachment":
            # a prompt Yoann sent while Claude was working ("absorbed mid
            # turn"): not a "user" entry, but a queued command, which the
            # prompt hook records like any prompt
            a = d.get("attachment", {})
            c = a.get("prompt")
            if (a.get("type") == "queued_command" and a.get("commandMode") == "prompt"
                    and a.get("origin", {}).get("kind") == "human"
                    and isinstance(c, str) and c.strip() and not c.startswith("<")):
                turns.append({"prompt": c, "time": d["timestamp"],
                              "answer": []})
        elif d.get("type") == "assistant" and turns:
            for b in d.get("message", {}).get("content", []):
                if b.get("type") == "text" and b["text"].strip():
                    turns[-1]["answer"].append(b["text"])
    for t in turns:
        # a long turn (hours of work between two prompts) is summarized
        # from its last message, the report Yoann read: given the whole
        # turn cut to 40000 characters, Haiku once answered the next
        # prompt instead of summarizing
        whole = "\n\n".join(t["answer"])
        t["answer"] = t["answer"][-1] if len(whole) > 40000 and t["answer"] else whole
        t["time"] = datetime.datetime.fromisoformat(
            t["time"].replace("Z", "+00:00"))
    return turns

def main():
    mode = sys.argv[1]
    if os.environ.get(GUARD):
        return
    if mode == "prompt":
        data = json.load(sys.stdin)
        prompt, sid = data.get("prompt", ""), data.get("session_id", "")
        if not prompt.strip() or is_notification(prompt) or ignored(sid):
            return
        now = datetime.datetime.now(datetime.timezone.utc)
        previous = take_session(sid)
        # a prompt sent while the answer is still being written has no
        # answer of its own: written alone, as its prompt
        save_session(sid, {"prompt": prompt, "time": now.isoformat()})
        detached(lambda: write_exchange(previous, prompt))
    elif mode == "answer":
        data = json.load(sys.stdin)
        sid, transcript_path = data.get("session_id", ""), data["transcript_path"]
        if ignored(sid):
            return
        turns = exchanges(transcript_path)
        # The transcript file can lag slightly behind the Stop event: retry
        # briefly rather than attach an empty answer and lose it.
        for _ in range(5):
            if turns and turns[-1]["answer"].strip():
                break
            time.sleep(0.3)
            turns = exchanges(transcript_path)
        open_exchange = load_session(sid)
        if not open_exchange:
            debug_log("answer: no open prompt for session %s" % sid)
        elif turns and turns[-1]["answer"].strip():
            open_exchange["answer"] = turns[-1]["answer"]
            save_session(sid, open_exchange)
        elif turns:
            debug_log("answer: empty answer after retries for prompt=%r" %
                      turns[-1]["prompt"][:200])
    elif mode == "end":
        sid = json.load(sys.stdin).get("session_id", "")
        if ignored(sid):
            return
        last = take_session(sid)
        detached(lambda: write_exchange(last, None))
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

    elif mode == "rebuild-from":
        rebuild_from(sys.argv[2], sys.argv[3:])

def entry_time(chunk):
    m = re.match(r"\s*## (\d{4}-\d\d-\d\d \d\d:\d\d)", chunk)
    return m.group(1) if m else None

def rebuild_from(start, transcripts):
    """Keep the entries before [start] as they are; regenerate the rest
    from the transcripts, each exchange summarized with its own
    session's next prompt, the entries in the prompts' order. A session
    with an open exchange (running now) keeps its last prompt open."""
    sessions = []
    for t in transcripts:
        sid = os.path.basename(t)[:-len(".jsonl")]
        if ignored(sid):
            continue
        turns = exchanges(t)
        if load_session(sid):
            turns = turns[:-1]
        for i, turn in enumerate(turns):
            nxt = turns[i + 1]["prompt"] if i + 1 < len(turns) else None
            if turn["time"].strftime("%Y-%m-%d %H:%M") >= start:
                sessions.append((turn, nxt))
    sessions.sort(key=lambda e: e[0]["time"])
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        sums = list(pool.map(
            lambda e: summarize(e[0]["prompt"], e[0]["answer"], e[1]), sessions))
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        chunks = open(PATH).read().split(SEPARATOR)
        kept = [c for c in chunks[1:] if (entry_time(c) or "") < start]
        with open(PATH, "w") as f:
            f.write(HEADER)
            for c in kept:
                f.write(SEPARATOR + c)
            for (turn, _), s in zip(sessions, sums):
                f.write(render_exchange(turn["prompt"], turn["time"], s))

if __name__ == "__main__":
    main()
