---
date: 2026-11-20
resolved:
severity: degraded
kind: security
hosts: [tomo, fleet]
---

# Unencrypted static SSH keys on tomo bypassed the SSH CA login gate

## What was found

While setting up a separate SSH identity for the AI agent (`claude-ai`, see `Networking/ssh-ca/README.md` → "AI agent
identity"), a test that expected the AI's cert to be **refused** by `ssh-ca` succeeded. `~/.ssh/config` sends
`IdentityFile ~/.ssh/infrastructure` for that host, and the key had no passphrase, so the login never needed a cert.

The fleet was supposed to be cert-only since 2026-10-10 (old admin keys removed from `authorized_keys`), so anything
running as `purgos` on tomo (an AI agent, or malware) had to wait for Purgos's MFA login. In practice, 18 private
keys in `~/.ssh` had no passphrase, and an `authorized_keys` audit (read with the AI cert, fingerprints compared to
tomo's `*.pub`) showed several hosts still accepting them, some as root, including high-value infrastructure hosts.
*The per-host list is left out of this public copy until the keys are removed from those hosts.*

An attempt to test each key against each host directly was blocked by Claude Code's auto-mode permission check as
credential spraying, so the audit read `authorized_keys` instead.

## Done 2026-11-20 (fix option 1)

- Purgos gave all 18 keys in `~/.ssh` a passphrase (`ssh-keygen -p`, prompted via ksshaskpass, mode set back to
  `400`). Verified: no key in `~/.ssh` loads with an empty passphrase. Re-test: `ssh ssh-ca` with only the AI cert
  now gets `Permission denied (publickey)`.
- Gotcha: `cloud-auth` (and others) were mode `400`, so `ssh-keygen -p` failed with "Saving key failed: Permission
  denied" until `chmod u+w`.
- Side effect: SSH with these keys, and git pushes to Forgejo (`id_ed25519`), now prompt for the passphrase unless
  Purgos loads them into his own agent (`ssh-add`). The AI's shells use the separate AI agent and can't push to Forgejo.

## Still open

- **Option 2:** remove these keys from the hosts' `authorized_keys` and enroll the remaining hosts fully into the
  CA. First check what still uses each key (a forced-command backup key and some service accounts). Break-glass
  covers lockout.
- **Option 3:** run Claude Code as a separate Unix user. The AI still runs as `purgos`, so a key Purgos loads into
  his own agent is reachable by pointing `SSH_AUTH_SOCK` at that socket. That's a rule the agent follows, not a wall.

## Lesson

A cert gate only works if it's the only door. "Old keys removed from `authorized_keys`" was verified for the fleet
rollout list, but the CA host itself and hosts enrolled later weren't on that list, and nobody checked the client side
(unencrypted keys on the desktop that the gate is meant to protect). Audit both ends.
