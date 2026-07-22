# Cost and Quota Model

_Audit date 2026-07-20. Unit prices are from current provider docs (linked) but
change often and vary by region — **treat every dollar figure as order-of-magnitude
and verify before relying on it.** Usage volumes come from `CAPACITY_MODEL.md` and
inherit its assumptions._

## Unit prices used

| Resource | Price | Source |
|---|---|---|
| Firestore reads | $0.06 / 100k | [Firestore pricing](https://cloud.google.com/firestore/pricing) |
| Firestore writes | $0.18 / 100k | same |
| Firestore deletes | $0.02 / 100k | same |
| Firestore storage | ~$0.18 / GiB-mo | same |
| Phone Auth SMS | $0.01 (US/CA/IN), $0.06 (other) | [Phone verification pricing](https://firebase.google.com/docs/phone-number-verification/pricing) |
| Cloud Functions v2 invocations | ~$0.40 / million (2M/mo free) | [Cloud Run pricing](https://cloud.google.com/run/pricing) — approx |
| Cloud Functions compute | ~$0.000024/GiB-s, ~$0.000024/vCPU-s | approx, verify |
| LiveKit connection minutes | $0.0004–$0.0005 / participant-min | [LiveKit pricing](https://livekit.com/pricing) |
| LiveKit bandwidth | $0.10–$0.12 / GB egress | same |
| Storage (Firebase) egress | ~$0.12 / GB | [Storage pricing](https://firebase.google.com/pricing) — approx |

## Daily Firestore ops (from capacity model, average rates × 86,400s)

Using **average** (not peak) rates so monthly cost isn't overstated. Peaks drive
_reliability_, averages drive _cost_.

### Reads/day

| Source | Normal 10k | Viral 50k | Extreme 100k |
|---|---|---|---|
| Discover feed (~27/load) | ~186M | ~933M | ~1.87B |
| Matchmaking (~35/join) | ~126M | ~630M | ~1.26B |
| Chat trigger + listeners | ~26M | ~130M | ~259M |
| Realtime listener re-reads (est.) | ~50M | ~250M | ~500M |
| **Total reads/day** | **~388M** | **~1.94B** | **~3.9B** |
| **Reads $/day** @ $0.06/100k | **~$233** | **~$1,165** | **~$2,330** |

### Writes/day

| Source | Normal 10k | Viral 50k | Extreme 100k |
|---|---|---|---|
| Presence heartbeat | ~7.2M | ~36M | ~72M |
| Matchmaking (queue+session+profile, ~4/join) | ~14M | ~72M | ~144M |
| Chat (msg + trigger, ~2/msg) | ~17M | ~86M | ~173M |
| Decisions/history/notifications | ~10M | ~50M | ~100M |
| **Total writes/day** | **~48M** | **~244M** | **~489M** |
| **Writes $/day** @ $0.18/100k | **~$86** | **~$439** | **~$880** |

### Firestore subtotal

| | Normal | Viral | Extreme |
|---|---|---|---|
| **$/day** | ~$320 | ~$1,600 | ~$3,200 |
| **$/month** | **~$9,600** | **~$48,000** | **~$96,000** |
| **$/1k DAU/month** | ~$96 | ~$96 | ~$96 |

> Firestore alone is roughly **$0.10 per DAU per month** in this design. That is
> high for a consumer app and is driven by the read-heavy Discover + matchmaking
> paths. Denormalization is good; the volume is the issue.

## LiveKit (video) — the biggest variable

- **Assumption:** 100k DAU × 4 calls/day × 3 min × 2 participants =
  **2.4M participant-minutes/day**.
- Connection minutes: `2.4M × $0.00045 ≈ $1,080/day ≈ $32k/month`.
- Bandwidth: video at ~1.5 Mbps ≈ ~11 MB/participant-min. `2.4M min × 11MB ≈
  26.4 TB/day` egress. At $0.11/GB → **~$2,900/day ≈ $87k/month**. **Bandwidth,
  not connection minutes, dominates.**
- **Confidence: Low** — entirely gated by the unknown "% of users who call" and
  the video bitrate. Could be 3× higher or lower. This is the single largest and
  least-known cost.

## SMS (Phone Auth)

- 100k sign-ups on a viral day. If 60% non-US: `60k × $0.06 + 40k × $0.01 =
  $3,600 + $400 = ~$4,000/day` during peak growth.
- **Billing-attack exposure (see security review):** with App Check off, an
  attacker triggering verifications to premium/expensive destinations (SMS
  pumping / toll fraud) can run this line item up with no per-app-integrity gate.

## Cloud Functions

- Invocations at Viral avg ~1,000/s → ~86M/day → ~2.6B/month. At ~$0.40/M ≈
  **~$1,000/month** invocations, plus compute (GB-s/vCPU-s) — likely a few
  thousand $/month more, inflated by matchmaking transaction latency.
- **Confidence: Low-Medium** — compute cost depends on request duration, which
  the matchmaking contention makes unpredictable.

## Rough monthly totals (order of magnitude, verify)

| Scenario | Firestore | LiveKit | Functions | SMS (steady) | **Total/mo** |
|---|---|---|---|---|---|
| Normal 10k | ~$9.6k | ~$17k | ~$1–2k | ~$1–5k | **~$30–35k** |
| Viral 50k | ~$48k | ~$87k | ~$3–5k | ~$5–30k | **~$150–170k** |
| Extreme 100k | ~$96k | ~$175k | ~$6–10k | (spiky) | **~$280–320k** |

## Quotas / limits to watch

| Limit | Type | Risk |
|---|---|---|
| Firestore ~500 writes/s per sequential index | Soft (hotspot) | **Presence writes breach this at Viral** — reliability, not just cost |
| Firestore 10 GiB/s aggregate, 1M connections | Soft | fine at these volumes |
| Phone Auth SMS/day per project | Soft quota | request increase before launch; **toll-fraud cap** |
| Cloud Functions max instances | **Unset** | no cost ceiling; runaway/abuse scales the bill |
| Cloud Run per-region CPU quota | Soft | may throttle a spike; request increase |
| LiveKit plan allowance | Tiered | Scale tier ($500/mo) + overage; set a bandwidth alert |
| Secret Manager access | Soft | fine |

## Billing-attack surface (features an attacker can turn into your bill)

1. **Matchmaking loop** — no rate limit, no App Check: scripted
   `joinMatchmakingQueue` drives Firestore reads/writes + function compute.
   **P0.**
2. **publicProfiles scrape** — paginate the whole base via `orderBy` queries;
   read cost + PII exfiltration. **P0/P1.**
3. **SMS pumping** — trigger verifications; SMS cost + toll fraud. **P1.**
4. **getCallMediaToken** — mint tokens in a loop (function compute) even without
   media; LiveKit cost only accrues on actual join, but token minting is free
   compute for the attacker to burn. **P2.**
5. **Boost/decision spam** — function invocations. **P2.**

## Must-do cost controls before launch

- Set a **Cloud Billing budget + alerts** (e.g. 50/80/100% of a monthly cap).
- Set **`maxInstances`** on every function (a real ceiling, e.g. 20–100 each).
- **Enforce App Check** on callables and (where supported) publicProfiles reads.
- Add **per-user rate limiting** to `joinMatchmakingQueue`, `getCallMediaToken`,
  `activateBoost`, `submitCallDecision`.
- Set a **LiveKit bandwidth alert** and a monthly cap.
- Request SMS and Cloud Run quota increases **with** a toll-fraud region allowlist.

Without these, the honest statement is: **a single motivated attacker can run an
unbounded bill in a day.**
