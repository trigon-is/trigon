# Network Auditing: Completeness vs. Depth — Concepts & Reasoning

> Status: conceptual reference (2026-08-12). This document exists for
> **understanding and reasoning**, not as an implementation spec. For the concrete
> feature requirements see `docs/audit/inception/requirements/requirements.md`; for
> the security gaps this relates to see `docs/threat-model.md` (esp. G3, G6, G8).
>
> The question it answers: *when we watch what an agent sends to the network, what
> can we actually guarantee — and what can a hostile agent defeat?*

---

## 1. Two independent axes

"Auditing the network" is not one property. It is two, and they are orthogonal —
you can choose each independently:

| Axis | Question it answers | Spectrum |
|------|--------------------|----------|
| **Completeness** | *Do we see *all* the traffic, or only some?* | cooperative (partial) → enforced (total) |
| **Depth** | *How much of each connection do we see?* | destination-only → full decryption |

Conflating these is the most common source of confused reasoning about audit
tooling. "We use a proxy" answers neither question by itself. A proxy can be
bypassable or unbypassable (completeness), and it can read only the destination or
the entire payload (depth). They are set separately.

```
            DEPTH  →  destination-only            full decrypt (MITM)
 COMPLETENESS ↓     ┌───────────────────────────┬───────────────────────────┐
 cooperative        │ weak: partial view, where  │ invasive but evadable      │
 (bypassable)       │ only                        │ (e.g. VibePod)             │
                    ├───────────────────────────┼───────────────────────────┤
 enforced           │ STRONG DEFAULT: total,     │ total capture, reads       │
 (unbypassable)     │ "where" proven              │ honest content             │
                    └───────────────────────────┴───────────────────────────┘
```

---

## 2. The vocabulary

**SNI (Server Name Indication).** When a TLS client opens an HTTPS connection, the
first message (the ClientHello) contains the destination hostname *in plaintext* —
it has to, because one IP can host many sites and the server must know which
certificate to present. Consequence: **anyone on the path can read the destination
host without decrypting anything.** "Destination-only" monitoring uses this: it
logs *where* a connection went (and how many bytes flowed) but not the URL path,
headers, or body. (A newer extension, Encrypted ClientHello, can hide SNI, but it
is rare and irrelevant when you control the container.)

**Forward proxy / "proxy-aware traffic."** A forward proxy is a middleman a program
*chooses* to talk to, usually via the `HTTP_PROXY` / `HTTPS_PROXY` environment
variables. A well-behaved client reads those and routes through it. "Proxy-aware
traffic" is traffic from software that *cooperates* this way. Software that ignores
the proxy env, opens a raw socket, or uses a non-HTTP protocol never touches the
proxy — invisible to it.

**Enforced gateway.** Instead of *asking* the agent to use a proxy, you remove
every other route: the agent sits on an internal network with no path to the
internet except through a sidecar that is the sole gateway. Now *all* IP traffic
must physically transit the sidecar, whether or not the agent cooperates. This is a
property of **routing**, not of client configuration.

**TLS interception (MITM).** To read *inside* an HTTPS connection, the middleman
terminates the TLS itself, presenting a certificate signed by a CA the client
trusts (achieved by injecting that CA into the container's trust store), then opens
its own TLS to the real server. Full visibility — URLs, headers, bodies — but the
middleman is now *reading* the traffic, and it only works if the client accepts the
forged certificate.

---

## 3. The core asymmetry: hard vs. soft guarantees

This is the central insight. The two axes are not merely independent — they have
**fundamentally different robustness against an adversary.**

- **Completeness is a *hard* guarantee.** It is imposed by routing, which lives
  outside the agent's control. An agent cannot change its own route out of an
  internal network without a capability (`NET_ADMIN`) it does not have. So *every
  packet is seen*, unconditionally.

- **Depth-by-decryption is a *soft* guarantee.** It works only if the agent's TLS
  client *accepts* the injected CA. That acceptance is under the agent's control.

Stated as a rule of thumb:

> **You can always guarantee *where* traffic went. You can never fully guarantee
> you can *read* it — not against an adversary who controls the endpoint software.**

---

## 4. The hostile-agent lens

Trigon's threat model (`docs/threat-model.md`) assumes the agent may be steered
against the user's interest by untrusted input (prompt injection, a poisoned
dependency, a malicious repo). So the right question is not "does this help us watch
an honest agent?" but "**what can a hostile agent defeat?**"

### What a hostile agent CANNOT defeat: completeness
Under an enforced gateway, the agent has no alternative route. It can misbehave all
it likes; the *fact of the connection*, its *destination*, and its *byte volume* are
recorded regardless. Nothing the agent does at the application layer changes the
routing.

### What a hostile agent CAN defeat: decryption
Even while fully enforced (all its packets still transit the gateway), a hostile
agent can make the *contents* opaque three ways:

1. **Reject the CA / pin certificates.** It controls its own TLS client, so it can
   refuse the forged certificate. The MITM handshake simply fails.
2. **Application-layer encryption.** Encrypt the payload *before* sending it over
   TLS. Even a perfect MITM then yields ciphertext inside ciphertext.
3. **Opaque protocols.** Raw TCP, QUIC/HTTP-3 over UDP, or DNS tunnelling. An
   HTTP-oriented MITM cannot parse them; the gateway still logs destination and
   volume, but not "requests."

In every case, **completeness survives and decryption does not.** Decryption is
therefore best understood as a convenience for *honest* flows (your own provider
traffic, debugging), never as a control against a hostile agent.

### Corollary: don't oversell decryption
It follows that a "decrypt everything" mode must **not** be described as
"unbypassable" or as an anti-exfiltration control. Only completeness earns those
words. This is precisely why *destination-only* is the right **default**: it is the
part of the picture that is genuinely robust, and it avoids reading content
(a privacy virtue) for no loss of the guarantee that actually matters.

---

## 5. What actually contains a hostile agent

If decryption can't stop exfiltration, what can? Containment is a *completeness*
story, not a *depth* story:

- **Completeness alone** gives you *detection and proof*: you know every
  destination the agent reached and how much left. Invaluable after the fact, and a
  deterrent — but it observes, it does not prevent.
- **Completeness + deny-all egress (`--air-gap`)** gives *prevention by isolation*:
  the external leg is severed, so there is nowhere for data to go. The audit log of
  such a run is an empty file — a positive proof of zero egress.
- **Completeness + an allow-list (the future G6 control)** gives *prevention by
  policy*: the gateway permits only known-good destinations (the provider API, the
  git host) and blocks the rest. This is the natural next step once the enforced
  gateway exists — blocking is just logging plus a decision.

Note the pattern: the enforced gateway is the *substrate*. Observation, isolation,
and allow-listing are all things you layer on the same chokepoint. Decryption is an
optional lens on top, orthogonal to all of them.

---

## 6. The unavoidable design tension: what to do when decryption fails

Because decryption is cooperative, a legitimate client that pins certificates (a
real possibility for an agent's own provider calls) will *refuse* the MITM. That
forces a choice, and there is no free option:

- **Fail closed** — drop the connection. Safe (nothing leaks) and still complete,
  but it may **break the agent's real work**.
- **Pass-through (SNI-only)** — don't intercept that flow; tunnel it opaquely and
  log destination only. Keeps the agent working and *keeps completeness*, but
  **silently degrades depth** for that flow.

The important property: **both options preserve completeness.** The decision is
purely about the depth/functionality trade for flows that resist interception —
never about whether traffic is seen at all.

---

## 7. Reading a comparison correctly: VibePod

A concrete example of why the two axes must be evaluated separately. VibePod (a
comparable open-source tool) was verified to be:

- **Depth: full MITM decryption**, always (its agent images trust the proxy CA).
- **Completeness: cooperative** — a forward proxy the container is pointed at, with
  no network-layer enforcement and a switch to disable it. Therefore *bypassable*.

So VibePod is *more invasive on depth* yet *weaker on completeness*. That is the
correct posture for its purpose — helping a **trusted developer** inspect their
agent's traffic. It is the wrong posture for a **compliance artifact** meant to hold
up against a possibly-hostile agent, which wants the inverse: **enforced
completeness with shallow-by-default depth.** The tool that reads the most is not
the tool that proves the most.

---

## 8. Mental model (the one-paragraph version)

Auditing splits into *completeness* (do we see all traffic?) and *depth* (how much
of each connection?). Completeness is won by **routing** and is a **hard** guarantee
— unbypassable even by a hostile agent, because it lives outside the agent's
control. Depth-by-decryption is won by **TLS trust** and is a **soft** guarantee —
a hostile agent defeats it (cert pinning, app-layer encryption, opaque protocols)
while remaining fully routed and therefore fully *counted*. So: prove **where**
with an enforced gateway (and contain with air-gap or an allow-list); treat reading
**what** as a best-effort convenience for honest flows, and never call it
unbypassable.
