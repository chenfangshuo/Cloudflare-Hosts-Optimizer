# pt-cf-optimize

Pick the fastest Cloudflare edge IPs and safely write them into the Windows hosts file,
so Cloudflare-proxied sites such as PT forums load faster.

> No proxy, no login, no egress IP change. Strict hosts validation, incremental updates,
> one-click rollback.

Windows 10/11 · PowerShell 7+ · built-in `curl.exe` · CFST optional

[中文说明](README.md) · [Releases](https://github.com/chenfangshuo/pt-cf-optimize/releases)

> Detailed docs under `docs/` are currently in Chinese; commands and option names are
> language-neutral.

**Why this exists.** On my line most PT sites took over ten seconds to open. Picking IPs with
[CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) (CFST) and editing hosts by
hand did help — but the lowest-ping IP sometimes came back as Error 1034 (the site refuses that
IP and the page simply won't load), and CFST's default speed-test URL is no longer maintained.
So this chains it into one run: latency scan → throughput test → per-domain verification →
hosts write → one-click rollback. **One PT site here went from >10s to about 3s; a single-site
run measured TTFB 1.75s → 0.69s.**

## Quick start

**1) Prepare domains**

Copy `domains.example.txt` to `domains.txt`; one domain per line. Prefer sites you have
confirmed are proxied by Cloudflare — a wrong entry won't corrupt anything, per-domain
validation simply skips it, but the run is wasted:

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

`server: cloudflare` is a hint, not proof. Non-CF sites are skipped during per-domain
validation.

List web hostnames only. **Do not list tracker-only hostnames** such as
`tracker.example.com`: an announce is a few dozen bytes every 30 minutes, so there is nothing to
gain, while a stale mapping or an Error 1034 would break announcements and turn torrents red.

**2) Optional: add CFST (better coverage)**

Download [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest/releases) and put
`cfst.exe` and `ip.txt` into a `cfst\` folder next to the script:

```text
pt-cf-optimize\
  cfst\
    cfst.exe
    ip.txt
```

Without it the built-in scanner is used automatically.

**3) Dry run** (no admin, no hosts changes)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -DryRun
```

**4) Apply** (elevated PowerShell)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1
```

**5) Roll back**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -Rollback
```

A full run takes about **8–15 minutes**. The `probing candidate colos (256)` phase takes
several minutes by itself; it prints progress every 32 candidates, so it is not stuck.

For automation, `-Plan -PlanPath .\plan.json` emits a JSON plan without touching hosts; see
[docs/scheduling.md](docs/scheduling.md) for three scheduling options, including auto-apply
with its risks.

## What a run looks like

Real numbers from my line: TTFB 1.75s → 0.69s on a single-site run. The output below is a
multi-domain example; domains and some numbers are placeholders, and a real run also prints
the scan and throughput tables.

```text
==== Cloudflare IP optimization -> hosts ====
hosts: C:\Windows\System32\drivers\etc\hosts
domains: 12

proxy: WinINET system proxy is enabled -> 127.0.0.1:7890
  Note: all curl calls use --noproxy * and CFST clears proxy env vars; probes always go direct.

probing candidate colos (256, may take a few minutes; progress every 32)...
  probed 32/256 (38s)
  probed 64/256 (79s)
...
per-domain validation (baseline = current hosts/DNS path)...
  pt.example.com      switch 104.17.143.151 -> 162.159.160.5  [confirmed]
  forum.example.org   keep   104.17.131.149  [below-threshold]

hosts written (backup: C:\ProgramData\pt-cf-optimize\backup\hosts-...bak)
```

## How it picks IPs

1. CFST (or the built-in scanner) filters candidates by latency/loss.
2. Stratified sampling across edge colos, so candidates are not all HKG.
3. Independent throughput test plus a 3 × 2MB final; only final results count.
4. Each domain is checked with HEAD against its current hosts/DNS baseline; the baseline and
   the chosen candidate are re-checked before switching.
5. Switch only when the candidate is ≥15% and ≥30ms faster, or the baseline is broken or a
   worse class (WAF/restricted).

Design notes, 1034 fallback and the IPv4-only decision are in
[docs/how-it-works.md](docs/how-it-works.md) (Chinese).

## Domains, import and merge

`domains.txt` is one domain per line; `#` starts a comment. It is gitignored, so your site
list stays local. You can also import from:

| Source | Command |
| --- | --- |
| PT-Depiler backup (recommended) | `.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip'` |
| Windows proxy bypass | `.\Import-Domains.ps1 -Source ProxyBypass` |
| Text file | `.\Import-Domains.ps1 -Source Text -Path .\sites.txt` |
| Clipboard | `.\Import-Domains.ps1 -Source Clipboard` |

The importer never accesses the network. PT-Depiler import only opens `metadata.json` and
never reads `cookies.json`, `userInfo.json` or `downloadHistory.json`. See
[docs/importing.md](docs/importing.md) for options.

### Review and merge (important)

Imports go to `domains.imported.txt`; **`domains.txt` is never overwritten**. Review the
file first: keep only Cloudflare-proxied sites, and remember that a proxy bypass list may
contain non-PT domains. Merge with:

```powershell
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -Merge
```

`-Merge` backs up `domains.txt`, appends new domains and deduplicates; it is idempotent.
Do not merge an entire backup or bypass list without reviewing it.

## Runtime

| Phase | Typical | Notes |
| --- | --- | --- |
| CFST latency/loss scan | 1–3 min | `-NoCfst` built-in scan is faster but has less coverage |
| Probe 256 candidate colos | 2–6 min | 6s timeout, 16 parallel; progress every 32 |
| ↳ with a cache younger than 14 days | about 1 min | Stops early once last run's colos are covered; falls back to a full probe when stale or the colos changed |
| Throughput quick test + final | 1–3 min | about 70MB of downloads |
| Per-domain validation and re-check | 1–3 min | ~6–10 HEADs per domain, 400ms apart |

To shorten a run:

```powershell
.\pt-cf-optimize.ps1 -ThroughputCandidates 16 -MaxDomainProbes 4
.\pt-cf-optimize.ps1 -NoCfst -MaxCandidates 128
```

## Safety

- No login, no cookies, no announce URLs, no passkeys. Only a small number of HEAD requests
  per domain (typically 6–10, at most 11; one IP is probed at most twice during the
  pre-switch confirmation). The budget grows with the candidate count and `-MaxDomainProbes`,
  so raising it is not recommended.
- **Egress IP is unchanged** as long as these domains are in your proxy bypass list. The
  script checks the WinINET bypass list and TUN adapters, but cannot detect every
  PAC/WPAD/WinHTTP/WFP setup.
- Clash/proxy can stay on: every curl call uses `--noproxy '*'` and CFST clears proxy
  environment variables. Probes and speed tests always go direct.
- Do not use VPNs, online IP-picking services or public reverse proxies to access PT sites.
- hosts only changes name resolution for these domains' web pages; announces do not get
  faster, and tracker hostnames should not be listed (see the FAQ, Chinese); **P2P and IPv6
  peer connections are unaffected**.

See [docs/faq.md](docs/faq.md) for more.

## CFST vs built-in scanner

| | CFST (`cfst\cfst.exe`) | Built-in (`-NoCfst` / not found) |
| --- | --- | --- |
| Candidate source | 25 CIDRs from `ip.txt` | random sample of `-MaxCandidates` (default 192) |
| Latency measurement | TCPing | HTTPS `cdn-cgi/trace` (includes TLS) |
| Coverage | wider | limited sample |
| Dependency | third-party GPL-3.0 binary | PowerShell + system `curl.exe` |

**Why not just write CFST's ranking into hosts.** CFST ranks IPs for your line; it does not tell
you whether an IP works for a given site — the same IP can serve site A and return 1034 on site
B. Its download test also depends on `-url`, and the default URL is no longer maintained
([issue #168](https://github.com/XIU2/CloudflareSpeedTest/issues/168)); the current version scores
non-200 responses as failures. This tool borrows CFST's latency/loss screening only, measures
throughput itself, and verifies every domain.

Both share the same colo sampling, throughput final and per-domain selection. CFST is used
for latency/loss only; its download test is not used.

## Common options

| Option | Default | Description |
| --- | --- | --- |
| `-DryRun` | | Scan and verify only; do not modify hosts |
| `-Plan` / `-PlanPath` | `.\plan.json` | Emit a JSON plan without modifying hosts |
| `-Rollback` | | Restore hosts from the latest backup |
| `-RollbackFrom` | latest | With `-Rollback`, restore a specific `hosts-*.bak` |
| `-Prune` | | Remove managed entries no longer in the domain list |
| `-NoCfst` | | Force the built-in scanner |
| `-TopN` | 1 | Maximum IPs written per domain |
| `-MinImprovementPct` | 15 | Minimum percentage improvement to switch |
| `-MinImprovementMs` | 30 | Minimum absolute improvement (ms) to switch |
| `-MaxDomainProbes` | 6 | Hard cap on candidate probes per domain |
| `-NoColoCache` | | Ignore the colo cache and probe every candidate |
| `-CfstPath` | auto | Path to `cfst.exe` (file or folder) |

Full parameter list: [docs/parameters.md](docs/parameters.md).

## hosts safety

- Only zero or exactly one BEGIN/END block is accepted; malformed markers abort the run.
- Only ASCII/UTF-8 hosts files are supported. Multi-alias lines, IPv6 mappings and other
  tools' managed blocks abort with a line number.
- Failed domains keep their previous mapping; only explicit 1034/1003 drops it. Entries not
  in the current list are kept unless `-Prune` is used.
- Writes use a mutex, a pre-commit hash check, a backup manifest, atomic replace and
  read-back verification. `-Rollback` restores the latest backup; `-RollbackFrom` goes back
  to an earlier one.

Full rules: [docs/hosts-safety.md](docs/hosts-safety.md).

## Development

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

All tests are offline; CI runs the parse check, PSScriptAnalyzer and Pester on Windows.
See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). The repository does not include CloudflareSpeedTest code or binaries.
