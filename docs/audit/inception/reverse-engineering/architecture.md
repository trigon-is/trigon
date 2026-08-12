# Reverse Engineering — Networking / Egress Subsystem

> Scope note: Trigon is a single-repo CLI harness (no REST APIs, data stores, or
> CDK stacks), so several standard RE artifacts (api-documentation, data-models,
> business-overview) are **N/A** and intentionally omitted. This artifact is
> scoped to the subsystem the `--audit` feature must integrate with: how
> `trigon-up.sh` assembles the container's network and where outbound traffic
> flows today.

## System overview

`trigon-up.sh` is the launcher. It parses flags, resolves a provider, and
**assembles a `docker compose` invocation from a base file plus zero or more
runtime-generated compose fragments** (temp `.yml` files created with
`mktemp_yml`, appended to a `COMPOSE_FILES` array, and removed by a `cleanup`
trap on `EXIT INT TERM`). Every network-shaping feature is one of these
fragments. The audit sidecar will be another such fragment.

## Network topologies in play today

```
Default (bridge):
  [agent container] --default compose bridge--> NAT --> internet (unrestricted)

Tier-2 provider (litellm-proxy):
  [agent] --default--> [litellm sidecar] --> provider API / host Ollama
                                   (extra_hosts: host.docker.internal:host-gateway)

--playwright (HOST networking):
  [agent] === host network namespace ===  (localhost services, LAN, 169.254.169.254)
     ^ no network namespace of its own — cannot be firewalled from an unprivileged launcher

--playwright-headless:
  [agent + in-container Chromium] --default bridge--> internet   (stays namespaced)

--air-gap (internal network):
  networks: air_gap {driver: bridge, internal: true}
  [agent] --air_gap only--> (no route to internet)
  [litellm] --air_gap + default--> host Ollama only    (litellm-proxy case)
```

## Key integration facts for `--audit`

1. **Fragment pattern is the extension point.** A `--audit` proxy sidecar +
   network rewiring is a generated fragment appended to `COMPOSE_FILES`, cleaned
   up by the existing trap. No new mechanism needed. (`trigon-up.sh:331`,
   `:351` cleanup, `:361` trap, `:667` air-gap fragment as the closest model.)
2. **To observe/enforce egress, the agent's traffic must pass through the
   proxy.** That means the agent gets an `HTTP(S)_PROXY` env pointing at the
   sidecar, or a network topology where the sidecar is the only route out
   (agent on an `internal` net, sidecar dual-homed — mirrors the air-gap
   litellm arrangement at `:670-686`).
3. **Host networking is a hard blind spot.** `--playwright` puts the agent in
   the host netns (`:540-547`), so a compose-level proxy sidecar cannot see or
   constrain its traffic. The G3 guard already established the precedent that an
   unprivileged launcher *cannot firewall a host-netns container* — the audit
   design must state this limitation and likely refuse `--audit` + `--playwright`
   (or downgrade to headless).
4. **Tier-2 already inserts a sidecar.** The litellm sidecar (`:419-446`) shows
   the exact shape: a service on the compose network with `extra_hosts` for host
   reachability. The audit proxy is architecturally the same kind of object; the
   two must compose (agent → audit proxy → litellm → provider, or the proxy
   observes the litellm hop).
5. **`--air-gap` is the degenerate audit case.** With `internal: true` there is
   no route out; `--air-gap --audit` should produce a log that *proves* zero
   egress. This is the strongest privacy claim and the cheapest to validate.

## Existing egress controls (what audit builds on)

| Control | Location | Nature |
|---------|----------|--------|
| `--air-gap` internal network | `trigon-up.sh:650-703` | binary kill switch (no egress) |
| G3 metadata reachability guard | `trigon-up.sh:719+` | refuse-to-launch probe, not an egress rule |
| Provider/flag incompatibility guards | `:388-391`, `:652-661` | prevent nonsensical net combos |

There is **no** allow-list, no traffic logging, and no per-destination policy
today. That gap is exactly M7 (`--audit`) + G6 (egress allow-list).
