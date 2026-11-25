# 2026-11-21: Getting live secrets out of the ops repo (sops + age)

**Why.** The private ops repo held live plaintext credentials: dashboard widget tokens, media-stack API keys, database
passwords, even an SMTP app password in a script docstring. That made it impossible to share, and it meant every
AI agent session that read those files sent the values to an external API (rule 2 in `AGENT-GUARDRAILS.md`). A
gitignored secrets file was considered and dropped: no history, no backup, and every clone would need it copied by
hand.

**Design decisions.**
- **sops + age, values-only encryption.** The files stay in git and diffs still show *which* key changed. The one
  thing kept out of git is the age private key (with a copy in the password manager, because losing it loses
  everything).
- **Least-privilege decryption.** The only host that deploys config from git (the dashboard) got its own age key, and
  only its own secrets file lists that key as a recipient.
- **Placeholders that point somewhere.** Reference snapshots carry `SOPS[secrets/<file>.yaml:<key>]`, so the docs
  still say where each value lives.
- **The agent works blind.** Claude Code deny rules block reading `secrets/` or the age key and running any
  `sops`/`age` decryption. The agent moves values by name and through pipes, never onto its screen.
- **Guard the door going forward.** A pre-commit hook refuses unencrypted files under `secrets/` and runs gitleaks
  on the staged diff, so new plaintext is caught at commit time.

**Build.**
0. Tooling and guardrails first, with no live impact: sops, age, `.sops.yaml`, the hook and the deny rules. The hook
   was tested in a scratch clone against four cases (plaintext blocked, encrypted allowed, fake keys blocked, a
   harmless edit to an old file allowed).
1. The dashboard, the only git-deployed consumer, came first, and order mattered: its host resets to `origin/main`
   every 10 minutes. The decrypt-and-recreate sync went out while the YAML was still literal, and the placeholders
   went out only after that was live. 20 credentials moved. A probe of 17 widget calls gave identical status codes
   before and after.
2. Reference snapshots: 33 values from 14 files moved into five encrypted files. Each move was checked with a
   round-trip test (substituting the values back gives the original file byte for byte) before encrypting.
3. Prose, scripts and retired configs: most "secrets in notes" turned out to be file paths. Each one was settled by
   checking the *shape* of the value (letters → `a`, digits → `9`) without showing it. Retired configs were redacted
   after confirming, as booleans only, that none of their values matched a live one.
4. Rotation, because the old values are still in git history. All eight media-stack API keys and the download
   client's keys were rotated in one maintenance window. Database passwords, internal tokens and app passwords were
   rotated as well, and retired login roles were dropped. **Consumers were found by value, not by docs:** a helper
   on each host searched configs and volumes for the old keys and reported file names only. That turned up
   consumers the docs didn't list. Every API was checked to answer the new key and reject the old one.

**Side finding.** The dashboard's Proxmox widget used a root API token **without privilege separation** (full root
on the hypervisor), and its secret was in git. It was replaced with a privilege-separated `PVEAuditor` token (seven
read-only privileges), and the old token and its ACL entry were deleted. The access log showed the old token used
only by the dashboard host.

**What went wrong (agent-handling lessons).**
- **A secret got printed into the agent session, twice.** A "mask tokens of 10+ characters" filter let an
  8-character value through. Later, printing a diff showed a *removed* line that held a password, because the mask
  regex matched across quote boundaries. Both values were rotated first. New rules: mask *every* value, not just
  long ones, and never print diff lines that used to hold a value: print counts.
- **A test that passed for the wrong reason.** The new hook script lacked the exec bit, so git silently skipped it
  and every test "passed" by committing. Lesson: a guard needs a test that's supposed to fail, and you have to watch
  it fail.
- **A name-based filter missed a key** (`comicvine_api`). gitleaks over the changed files caught it.
- **The deny rule worked on its author.** The agent's own `sops decrypt` spot-check was blocked: it can't read back
  what it encrypted, as designed. Verification used hashes and live API responses instead.
- **Limits.** The deny rules are a speed bump, not a wall. Anything running as my Unix user can read the age key,
  which is why the agent is moving to its own VM (`AGENT-GUARDRAILS.md` → Known gaps).
