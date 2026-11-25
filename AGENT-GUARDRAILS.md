# Supervising AI agents on live infrastructure

Since mid-2026, AI coding agents (Claude Code and opencode) have done much of the scripting, configuration and
documentation in this homelab. They have shell access, including SSH to production hosts. This page describes the
rules they work under, why those rules exist, and where the rules are weaker than they should be.

## The rules

**0. No human login, no access.** *(enforced)*
Every host trusts certificates from my SSH certificate authority. The AI agent has **its own identity**: a separate
SSO user (`claude-ai`) with its own password and TOTP, and a CA login method that issues it **8-hour** certificates
for a single principal, `ssh-ai`. Only I can complete that login. The certificate goes into a dedicated ssh-agent that
only the agent's shells use, so it never holds my admin certificate (24 hours, separate login). When its certificate
expires, every SSH command it runs fails with `Permission denied (publickey)` until I log it in again, and
`ssh-cert-login-ai --off` cuts it off immediately. Host logs record `ID claude-ai@...`, so its actions are separate
from mine. The CA host doesn't accept the agent's principal, so it can't reach the machine that issues its
certificates. A break-glass key sits offline in the password manager.
*Why:* a gate that depends on the agent following instructions isn't a gate. This one holds even if an agent
ignores every other rule on this page.

**1. The repo is the source of truth, but live state outranks it.**
Agents read the docs before guessing at ports, paths or hostnames. Before touching live infrastructure, they
re-check over SSH instead of trusting the docs.
*Why:* in August 2026 I found the docs had drifted badly from reality, and I rebuilt every host doc from live SSH
checks. Docs that look authoritative but are wrong are worse than having no docs.

**2. Secrets never leave the box.**
Agents are told which files hold live credentials. They don't echo those files into chat, don't paste their values
into external tools or URLs, and must tell me if a change would newly expose a secret. Credential files used by
scripts are referenced only by path (for example `/root/.forgejo-claude-token`, chmod 600), never inlined.
*Why:* an agent's chat context goes to an external API. Whatever enters it has already left the machine.
*Since 2026-11-21, partly enforced:* live credentials in the ops repo are sops/age-encrypted, and configs hold
placeholders. A pre-commit hook refuses unencrypted files under `secrets/` and runs gitleaks on every staged diff.
Claude Code deny rules block the agent from reading `secrets/` or the age key and from running `sops`/`age`
decryption, so it works by key name only and can't read back what it encrypted. This is a speed bump, not a wall:
anything running as my Unix user can still read the age key (see Known gaps). Write-up:
`architecture/2026-11-21-secrets-out-of-plaintext-sops.md`.

**3. Policy changes are staged, not applied.**
For changes to network access policy (the Headscale tailnet ACL), the agent writes and validates the new policy,
then hands me the exact commands to apply it. I run them.
*Why:* a bad ACL can lock everyone out, or quietly let everyone in. Decisions that change the blast radius need a
human to sign off.

**4. Destructive or judgment-heavy steps aren't automated.**
The VM hardening script (`scripts/harden-vm.sh`) automates the mechanical phases on purpose, and deliberately
leaves out investigation and old-account removal. See `scripts/harden-vm.md`.
*Why:* `incidents/forgejo-data-loss-userdel-hardening.md`. A routine `userdel -r` deleted a service's entire data
directory, because nobody checked what that home directory was holding.

**5. Mechanical safety nets for mistakes that happen quietly.**
- A pre-commit hook (`scripts/check-gitignore-paths.sh`) flags `.gitignore` rules whose directory no longer exists.
  This came from a folder restructure that broke the ignore rules, after which secret files started being tracked.
- New Docker services must pin their container IP *before* a firewall rule is added. Unpinned containers lose
  traffic after their first restart, and nothing reports an error.
- Every scheduled job writes a metric, and the job going stale is itself an alert. Several incidents here were jobs
  that had quietly never run.

**6. Write it down as you go.**
Agents write up incidents (symptoms, root cause, resolution) as part of fixing them, without being asked. When a
planned change gets built, they also write a post about how it was done. They add dated follow-ups ("check back
after a quiet week") to a shared calendar, so loose ends don't depend on anyone's memory.

**7. I own the result.**
I set the architecture, security goals and priorities. Agents do the work, and I review, test and take
responsibility for what ships.

## Known gaps

A safety case that has no weaknesses in it isn't being honest. These are mine:

- **The gate had a side door, and testing found it.** While setting up the agent's identity, a test that expected
  the CA host to *refuse* the agent succeeded instead. Old SSH keys on my desktop had no passphrase, and some hosts
  still accepted them. The agent runs as my Linux user, so it could read those files and skip the login gate
  entirely. *Mitigated the same day:* every key got a passphrase, and a re-test with only the agent's certificate is
  refused. Still open: removing those keys from the hosts and finishing their move to certificates. Until then, a key
  I load into my own ssh-agent is reachable by the AI (next item). Write-up:
  `incidents/2026-11-20-static-ssh-keys-bypass-cert-gate.md`.
- **The agent runs as my Unix user.** Its separate ssh-agent is a default, not a wall: it could point at mine if it
  chose to. The same goes for the sops deny rules (rule 2): my age key is a file my user can read. *Planned fix:* move
  the agents to their own VM, which holds none of my keys, files or sessions. Fleet access there comes only from a
  forwarded socket to the AI-only ssh-agent, so it exists only while I'm attached.
- **Separate identity, same privileges.** On the fleet, the agent logs in as root under its own ID. That's
  accountability, not least privilege. Rules 3 and 4 are still instructions, not enforcement. Progress elsewhere: the
  dashboard's Proxmox API token, which had full root rights, was replaced with a privilege-separated read-only
  (`PVEAuditor`) token. New agent access is granted without sudo (one desktop accepts the agent's principal as a plain
  user shell).
- **Outbound access isn't restricted.** Inbound is default-deny, but nothing limits what the agent's machine can reach
  on the internet. In the OpenAI–Hugging Face incident (2026), agents turned one service's outbound requests into
  internet access. Egress filtering for the agent VM is on the list.
- **No sandbox for exploratory work.** Agents debug directly against production hosts.

Next steps: remove the old static keys from the hosts and finish moving every host to certificates; build the agent
VM (above); a read-only account for the agent's diagnostic work, with root needing a separate login from me; and
egress rules for the agent VM.
