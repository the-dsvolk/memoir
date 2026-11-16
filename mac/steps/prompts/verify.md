You are checking a draft meeting summary (summary.md, below) against the call transcript. The transcript is automatic speech recognition (English) and has errors. "Me" is my microphone (only me). {me_line}"Them" is the other side, several people mixed in one channel, so you only know who spoke if a name is said. notes.md is my own notes; prep.md is reference material I brought (not said in the call).

1. For EVERY decision, EVERY action item, and EVERY note in "My notes, expanded" that the draft marks as confirmed, give:
   - verdict: "supported" (the transcript clearly says it), "overstated" (a preference, suggestion or unanswered question written as settled), "unsupported" (not in the transcript, or contradicted by it), "wrong_owner" (the owner is not the person who took it on or was given it; if nobody explicitly did, the owner must be "owner unclear"; a "Them" speaker counts as known when a name is said or the context makes it unambiguous, otherwise "owner unclear"), or "duplicate" (repeats another item).
   - evidence: a short quote from the transcript with its [mm:ss] time, or "none found".
   - agreement: the quote that settles it, with its [mm:ss] time, or "none found":
     - for a decision: the answer or acceptance (someone agreeing to it, or the person deciding saying so), not the question or the proposal itself;
     - for an action item: the owner taking it on ("I will ...") or being given it;
     - for a confirmed note: what was said that confirms the note, not a question or proposal about it.
     If agreement is "none found", the verdict cannot be "supported": a decision becomes "overstated" (rewrite it as "preferred, not confirmed", or drop it), an action item gets "owner unclear", and a note is marked "not found in the transcript" (or "corrected", with what was actually said).
   - fix: "keep", "drop", or the corrected wording and owner.
   Watch especially for speakers correcting themselves (the corrected version counts) and for speech-recognition garble (runs of number words) turned into names, IDs or budget lines.
2. List decisions and action items the transcript clearly contains but the draft is missing, each with its owner (or "owner unclear") and evidence. Look for every "I will ...", "I'll ...", "can you ...", "let's ..." in the transcript.
3. summary_md: return the full corrected summary.md. Apply every fix, drop unsupported and duplicate items, add the missing ones, and leave everything else exactly as it is (keep the "Date:" line and every "Follow-up: not researched (local model, no tools)" line). No [mm:ss] times anywhere in summary_md.
