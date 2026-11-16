You are post-processing one recorded call. Its files are included below, each under a
"===== name =====" line:

- meeting.json — call metadata: name, started_at/ended_at (ISO time), sources, client,
  model (speech-to-text model), save_audio, server_backup.
- transcript.txt — the readable transcript, one finished sentence/segment per line:
  "[mm:ss] Speaker: text" ([h:mm:ss] after an hour). Times are from the start of the call.
- prep.md — material I brought to the call: attendees, agenda, past notes, documents.
  "## Before the call" was written before it started; "## Added during the call" has entries
  under "### mm:ss" headings — context that appeared at that time (someone joined, a doc was
  shared). Use prep as REFERENCE: correct spellings of names and terms, background facts, who
  was present when. Prep was not said in the call.
- notes.md — my own notes taken during the call, "- [mm:ss] note" (the time is when I started
  typing, usually just after the point was made). There are two kinds:
  - Follow-up notes: a note that asks for work, i.e. contains "research", "confirm",
    "check", "verify", "look up", "find out", "investigate", "dig into" or a similar
    request. You have no tools in this run, so you cannot do that work. Use the transcript
    around its time to understand what it refers to and expand it from what was said, like
    any other note.
  - All other notes are my highlights and open questions: expand or verify each against
    the transcript.

Any of prep.md and notes.md may be missing; work with what is there.

Speakers: "Me" = my microphone (only me). {me_line}"Them" = the other side of the call,
possibly several people mixed together (not separated). "Room" = a single microphone in an
in-person meeting, capturing everyone in the room including me.

The transcript is automatic speech recognition (English) and has errors: misheard names and
jargon (fix them using prep.md), numbers written as words ("forty two thousand dollars"),
sentences occasionally split mid-way at pauses, and imperfect punctuation. Ground everything
in the transcript content: only state what the transcript supports, and if it is unclear,
say so. Use [mm:ss] times to locate things, but never show them anywhere in summary.md.
Do not invent decisions, owners or dates.

Outcome: summary.md, with these sections:

1. Summary — start with this line, exactly as given: "{date_line}". Then the list of
   attendees taken from prep.md and notes.md (say "not listed" if neither names anyone);
   list me once, {me_attendee}. Then a short overview of the call.
2. Decisions — a plain list.
3. Action items — each with an owner (or "owner unclear"). A follow-up note is not an action
   item by itself; it stays under "My notes, expanded".
4. My notes, expanded — every line of notes.md, in order, expanded using what was said
   around its time, and marked as confirmed, corrected or not found in the transcript.
   Directly under each follow-up note, add the line
   "Follow-up: not researched (local model, no tools)".

Additional rules:
- Figures: in the Summary, keep every amount, count, target and date that was said, with units ($M, GPUs, months). Don't drop them for brevity.
- Decisions: only what was explicitly agreed: someone accepted it, or the person deciding said so. A stated preference, a suggestion, or a question nobody answered is not a decision; if you mention it, write it as "preferred, not confirmed".
- Self-corrections: when a speaker corrects themselves ("I'll call X ... no, you do it"), use the corrected version.
- Owners: name an owner only when that person explicitly took the task on ("I will ...") or was explicitly given it; otherwise write "owner unclear". "Them" is several people mixed together: name the speaker only when a name is said or the context makes it unambiguous (e.g. the person being presented to, just addressed by name, answers "I will ..."); if in doubt, don't.
- Action items: one entry per distinct task; merge overlapping ones, never repeat. Include what I (Me) said I would do.
- Speech-recognition garble (runs of number words, broken words) is not a name, ID or budget line; never turn it into one.
- Names: fix obvious typos in notes.md, but if notes.md and the transcript disagree on a name, keep the notes.md spelling and mention the other. The transcript may address me by name; use it.
- Never show [mm:ss] times anywhere in summary.md, including the headings of "My notes, expanded".

---
In this run you have no tools and cannot read or write files yourself. Reply with the complete
contents of summary.md only, in Markdown, and nothing else.
