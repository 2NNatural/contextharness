# Operator guide

For the person who describes what they want and expects a working result. No engineering
background assumed.

## The one-minute version

1. Install once (below).
2. Open Claude Code in any project folder and say what you want in plain English.
3. Read the short report at the end. It always has four parts:
   - **Done** — what now exists.
   - **Checked** — what was actually run, and what was seen.
   - **Not checked / open** — anything that was not proven, skipped, or still failing.
   - **Needs you** — only real decisions.

You never choose models, launch reviewers, name skills, or tell it to keep going.

## Install

```sh
git clone https://github.com/2NNatural/contextharness harness
cd harness
./install.sh --recommended
```

Restart Claude Code. To confirm everything is live:

```sh
~/.claude/scripts/harness doctor
```

Every line should say `ok`. A line saying `WARN` tells you what to do.

Needs `git` and `jq` on the machine (most developer machines have both; `doctor` tells you
if not).

## What the words in a report mean

| Word | Meaning |
|---|---|
| implemented | The code was written. Nothing more. |
| tested | Automated checks pass. |
| verified | The behaviour was actually observed working. |
| deployed | It is live for real users. |
| UNVERIFIED | It was not possible to prove it works. Treat it as untested. |

If you see **UNVERIFIED**, that is the harness being honest, not broken. Ask "what would it
take to verify this?".

## What it will do without asking

Read code, make changes, run tests, try a different approach when the first fails, pick
how careful to be based on what is at stake (a small script change gets a quick check;
anything involving money, logins, data deletion or live systems gets a plan, invariant
tests and an independent review).

## What it will always ask you first

- Deploying, publishing or releasing anything
- Pushing directly to the main branch, or rewriting history
- Changing cloud infrastructure
- Deleting data or running destructive database commands
- Reading files that hold passwords or keys
- Turning the harness's checks off, or changing what counts as "verified" (re-trusting or
  un-trusting a verify recipe, editing its own session state)
- Spending money
- A choice that changes *what* gets built (asked once, with a recommendation)

When you see a prompt that starts with "harness ops-guard:", it is one of these. Say yes
only if you asked for that action.

## Things you can say

| You say | What happens |
|---|---|
| "Build / fix / change …" | It plans in proportion to the risk, builds, proves it works, reports. |
| "Does it actually work?" / "make sure this works" | It runs the real thing and shows what it saw. |
| "Audit this" / "is this safe?" / "check this before we go live" | The full audit standard: how the pieces connect, what happens when things fail, what has never actually run. |
| "Get a second opinion" | An independent reviewer that did not write the code (and a different AI vendor, if you have Codex switched on). |
| "That was wrong — make sure it never happens again" | It finds the cause and adds a real safeguard (a test, a rule in the code), not just a note. |
| "Where were we?" | It reads the saved task state for this project. |
| "Undo what you did this session" | It uses the checkpoint taken when the session started. |
| "Refresh the routing policy" | It re-checks which AI models are the best value and shows you the proposed change first. |

## If something goes wrong

| Situation | What to do |
|---|---|
| It seems stuck repeating something | It is told to change approach after three identical failures. If it still loops, say "stop, tell me what is blocking you". |
| The session was interrupted or the conversation got compacted | Just continue. Task state is restored automatically. |
| A safety prompt keeps appearing for something you do want | Approve it. If it is truly routine for you, ask "why is this being flagged?" |
| You want all the automatic checks off for a moment | `~/.claude/scripts/harness off` (and `harness on` to restore). When Claude runs it for you, you will be asked to approve it. |
| "The project verify recipe was modified or removed after it was trusted" | Someone changed `.claude/harness/verify.sh` (or deleted it). Until you decide, nothing counts as verified. Read the change (`git diff .claude/harness/verify.sh`); if it is right, run `~/.claude/scripts/harness trust-verify` in the project yourself. |
| You removed the project's verify recipe on purpose | Run `~/.claude/scripts/harness untrust-verify` in the project (or `harness untrust-verify <dir>`). It deletes only that project's line from `~/.claude/harness/trust` and says what it removed. When Claude runs it for you, you will be asked to approve it. |
| An update made things worse | `./install.sh --rollback` in the harness folder puts back the previous version. |
| You want it gone | `./install.sh --uninstall`. Your own settings and notes are kept. |

## Optional: a second AI vendor for reviews (Codex)

If you have OpenAI's Codex CLI installed and logged in, switch on cross-vendor review:

```sh
touch ~/.claude/codex-routing.on
```

It is then used only for read-only second opinions on risky changes, never to write code.
Switch off with:

```sh
rm ~/.claude/codex-routing.on
```

## Updating

```sh
cd harness
git pull
./install.sh --recommended
```

## What it cannot promise

It makes unproven work visible and hard to pass off as finished; it does not make software
bug-free. The safeguards are tripwires against accidents, not locks. See
[LIMITATIONS.md](LIMITATIONS.md).
