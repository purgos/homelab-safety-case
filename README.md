# homelab-safety-case

A curated, sanitized slice of the operations repo for my self-hosted community platform: about 20 VMs on one
Proxmox host plus a few AWS hosts, serving a small group of friends and family.

I spent 2004–2012 as a submarine nuclear electronics technician in the U.S. Navy, maintaining reactor
instrumentation and control systems. That job taught me a few habits I still use here:

- **Written procedures over memory.** If it isn't written down, it isn't how the system works.
- **Verify, then act.** Check the live state of the system, not what the documentation says it should be.
- **Write up every incident without blame.** Record the symptoms, root cause, fix and lesson, so the same failure
  doesn't happen twice.

In nuclear engineering, a *safety case* is the documented argument that a system is acceptably safe. This repo is
the evidence for mine, including the parts where it went wrong.

## What's here

| Folder | What it shows |
|---|---|
| [`AGENT-GUARDRAILS.md`](AGENT-GUARDRAILS.md) | How I supervise AI coding agents that have shell access to real infrastructure, including the gaps I know about. |
| [`architecture/`](architecture/) | Design write-ups: zero inbound port forwards, a default-deny tailnet ACL, an SSH certificate authority with 24-hour certs, CrowdSec, tailnet-only HTTPS, backups with restore drills, and getting live secrets out of the repo with sops. |
| [`incidents/`](incidents/) | 19 selected incident and security write-ups out of 155+ in the private repo. |
| [`scripts/`](scripts/) | Tooling: a daily CISA KEV watcher, a VM hardening script with its runbook, a cloud restore drill, and a pre-commit check that caught `.gitignore` rules silently going stale. |

## Good places to start

- [`incidents/forgejo-data-loss-userdel-hardening.md`](incidents/forgejo-data-loss-userdel-hardening.md): a
  hardening step deleted all repo data. It's the reason the hardening runbook now has a human-judgment phase that
  isn't automated.
- [`incidents/2026-09-25-npm-access-list-satisfy-any-bypasses-forward-auth.md`](incidents/2026-09-25-npm-access-list-satisfy-any-bypasses-forward-auth.md):
  one reverse-proxy setting quietly turned single sign-on into "anyone on an allowed IP gets in".
- [`incidents/nextcloud-immich-backup-no-versioning.md`](incidents/nextcloud-immich-backup-no-versioning.md):
  ransomware-encrypted files would have overwritten the last good off-site copy.
- [`scripts/kev-watch.py`](scripts/kev-watch.py): checks CISA's Known Exploited Vulnerabilities catalog daily
  against my inventory and files a ticket for every match.

## What was removed

This is a fresh repo, not a rewritten copy of the private one, so none of the private history is here. Domains are
replaced with `example.org` / `example.net` / `example.com`, public IPs with `203.0.113.0/24`, and LAN ranges are
renumbered. Secrets, the names of community members, and security findings that weren't confirmed fixed at
publication time have been left out. Links to documents that aren't published have been turned into plain text.

AI coding agents helped write much of the scripting and many of the write-ups, under the guardrails described in
`AGENT-GUARDRAILS.md`. I set the architecture and priorities, and I review, test and own the results.
