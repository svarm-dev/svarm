# Product

## Platform

web

## Users

Primary: **Alex** — senior/staff developer or platform engineer who runs the orchestrator day to day. Opens `/board` to see what's running, what's stuck, what finished, and what it cost. Needs the loop to feel reliable and the numbers to be trustworthy under real ambient light at a desk.

Secondary: **Jordan** — engineering team lead who configures agents and routing for a small team, then uses the same board to trust that AI work is visible, governed, and attributable. Influences spend and tool adoption; needs clarity without operator-level detail noise.

Both are already using coding agents (pi, Claude Code, etc.). Their job on any given screen is operational: status, identity, cost, and control — not exploration or marketing.

## Product Purpose

Svärm is the self-hosted control plane for a blended engineering team: humans and coding agents working from the same tickets. It connects trackers, agents, and LLM providers you already use; dispatches agent work into isolated workspaces; enforces approvals and budgets at the provisioning layer; and attaches an auditable cost receipt to every ticket.

Near-term success is a polished board and governance experience: activity and costs feel authoritative, agents have clear names on the work, and the system feels alive and under control. Richer team features (profiles, performance history, team composition) come later.

## Positioning

Your AI teammates, governed.

## Brand Personality

**Calm · Trustworthy · Precise.**

The interface should feel like an ops console you can leave open all day: quiet confidence, no alarm theatre, numbers and status that read as fact. Voice is plain and specific — tickets, agents, costs, approvals — never hype about “AI magic.”

## Anti-references

- SaaS-purple product dashboards and generic “AI platform” chrome
- Chat-first agent UIs that bury work status in conversation threads
- Hero-metric marketing layouts (big vanity number + supporting stats + gradient accent) inside the product
- Playful or gamified “AI coworker” aesthetics that undermine governance trust

Prefer the density and scannability of calm tools like Linear or Vercel’s product surfaces: information first, decoration last.

## Design Principles

1. **Governance first** — Costs, approvals, and run state must feel rock-solid; if anything is approximate, say so plainly.
2. **Clarity over cleverness** — Prefer boring, scannable UI. Real vs estimated, agent vs human, live vs idle should be obvious in under three seconds.
3. **Named participants** — Agents appear as consistent identities on the board, not as raw assignee keys or anonymous process IDs.
4. **Overview, then detail** — At-a-glance board is primary; logs and breakdowns are one deliberate step deeper, not clutter on every card.
5. **Alive and under control** — Live updates should reassure, not startle. Motion and status changes signal real work, never decoration.

## Accessibility & Inclusion

Target **WCAG 2.2 AA**: body text contrast ≥4.5:1, keyboard-reachable controls, visible focus, meaningful labels, and `prefers-reduced-motion` alternatives for any non-essential animation. Cost and status information must not rely on color alone.
