#!/usr/bin/env python3
"""kev-watch.py -- daily CISA KEV check against the homelab inventory. Runs on local-misc (cron).

Fetches the CISA Known Exploited Vulnerabilities catalog, finds entries not seen before whose
"<vendorProject>: <product>" matches a regex in /usr/local/etc/kev-inventory.txt, and for each:
  - files an issue on purgos/Homelab in the home Forgejo (token: /root/.forgejo-claude-token)
  - then emails one digest from no-reply@example.org to admin@example.org (app password: /root/.noreply-smtp-pass),
    because the token is Purgos's own account and Forgejo doesn't notify you of your own issues.
A CVE is marked seen only after its issue was filed, so a failed run retries next day.
First run: everything added more than 30 days ago is seeded as seen (no backlog flood).
Writes kev_watch_* metrics for node_exporter; KevWatchStale alerts if it stops running.

  kev-watch.py            # normal run
  kev-watch.py --dry-run  # print what would be filed, touch nothing
"""
import datetime, json, os, re, smtplib, sys, tempfile, urllib.request
from email.message import EmailMessage

FEED = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
INVENTORY = "/usr/local/etc/kev-inventory.txt"
STATE = "/var/lib/kev-watch/seen.json"
PROM = "/var/lib/prometheus/node-exporter/kev-watch.prom"
FORGEJO = "http://localhost:3000/api/v1/repos/purgos/Homelab/issues"
TOKEN_FILE = "/root/.forgejo-claude-token"
SMTP_PASS_FILE = "/root/.noreply-smtp-pass"
MAIL = "no-reply@example.org"   # sender + Gmail login (2026-11-14)
MAIL_TO = "admin@example.org"
SEED_DAYS = 30

dry = "--dry-run" in sys.argv


def load_patterns():
    pats = []
    for line in open(INVENTORY):
        line = line.strip()
        if line and not line.startswith("#"):
            pats.append(re.compile(line, re.I))
    return pats


def file_issue(token, v, pattern):
    body = (
        f"**CISA added this to the Known Exploited Vulnerabilities catalog on {v['dateAdded']}** "
        f"(it is being exploited in the wild).\n\n"
        f"- **CVE:** [{v['cveID']}](https://nvd.nist.gov/vuln/detail/{v['cveID']})\n"
        f"- **Product:** {v['vendorProject']}: {v['product']}\n"
        f"- **Name:** {v['vulnerabilityName']}\n"
        f"- **Ransomware use:** {v.get('knownRansomwareCampaignUse', 'Unknown')}\n"
        f"- **CISA due date (federal agencies):** {v.get('dueDate', '?')}\n\n"
        f"{v['shortDescription']}\n\n"
        f"**Required action:** {v['requiredAction']}\n\n"
        f"**Notes:** {v.get('notes', '')}\n\n"
        f"---\nMatched inventory pattern `{pattern}` (`Scripts/kev-inventory.txt`). Check whether the affected "
        f"version actually runs anywhere (home fleet *and* cloud), patch or close as not-affected.\n"
        f"Filed automatically by `Scripts/kev-watch.py` on local-misc."
    )
    req = urllib.request.Request(
        FORGEJO, method="POST",
        data=json.dumps({"title": f"KEV: {v['cveID']} - {v['vendorProject']} {v['product']}", "body": body}).encode(),
        headers={"Authorization": f"token {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["html_url"]


def write_prom(ok, matched, catalog):
    lines = [
        "# HELP kev_watch_last_success_timestamp_seconds Last successful kev-watch run",
        "# TYPE kev_watch_last_success_timestamp_seconds gauge",
        f"kev_watch_last_success_timestamp_seconds {int(datetime.datetime.now().timestamp()) if ok else 0}",
        "# HELP kev_watch_new_matches New KEV entries matching the inventory in the last run",
        "# TYPE kev_watch_new_matches gauge",
        f"kev_watch_new_matches {matched}",
        "# HELP kev_watch_catalog_size Entries in the KEV catalog at the last run",
        "# TYPE kev_watch_catalog_size gauge",
        f"kev_watch_catalog_size {catalog}",
    ]
    if dry:
        return
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PROM))
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, PROM)


def main():
    with urllib.request.urlopen(FEED, timeout=60) as r:
        vulns = json.load(r)["vulnerabilities"]
    pats = load_patterns()

    if os.path.exists(STATE):
        seen = set(json.load(open(STATE)))
    else:
        cutoff = (datetime.date.today() - datetime.timedelta(days=SEED_DAYS)).isoformat()
        seen = {v["cveID"] for v in vulns if v["dateAdded"] < cutoff}
        print(f"first run: seeded {len(seen)} entries older than {cutoff} as seen")

    new = [v for v in vulns if v["cveID"] not in seen]
    hits = []
    for v in new:
        key = f"{v['vendorProject']}: {v['product']}"
        p = next((p.pattern for p in pats if p.search(key)), None)
        if p:
            hits.append((v, p))
        else:
            seen.add(v["cveID"])  # not ours; never look at it again

    token = open(TOKEN_FILE).read().strip() if not dry else ""
    filed = []
    for v, p in hits:
        if dry:
            print(f"WOULD FILE {v['cveID']} {v['vendorProject']}: {v['product']} (pattern {p})")
            continue
        url = file_issue(token, v, p)
        seen.add(v["cveID"])
        filed.append((v, url))
        print(f"filed {v['cveID']} -> {url}")

    if not dry:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE + ".tmp", "w") as f:
            json.dump(sorted(seen), f)
        os.replace(STATE + ".tmp", STATE)

    if filed:
        msg = EmailMessage()
        msg["From"] = MAIL
        msg["To"] = MAIL_TO
        msg["Subject"] = f"[kev-watch] {len(filed)} actively exploited CVE(s) may affect the homelab"
        msg.set_content(
            "CISA added these to the Known Exploited Vulnerabilities catalog and they match the homelab inventory.\n"
            "A Forgejo issue was filed for each:\n\n"
            + "\n\n".join(f"{v['cveID']}  {v['vendorProject']}: {v['product']}\n  {v['vulnerabilityName']}\n  {url}"
                          for v, url in filed)
        )
        with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as s:
            s.starttls()
            s.login(MAIL, open(SMTP_PASS_FILE).read().strip())
            s.send_message(msg)
        print(f"emailed digest of {len(filed)}")

    write_prom(True, len(hits), len(vulns))
    print(f"catalog {len(vulns)}, new {len(new)}, matched {len(hits)}")


if __name__ == "__main__":
    main()
