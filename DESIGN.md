---
name: Svärm
description: Calm ops console for a governed blended engineering team — soft moss green, Linear density, Mercury polish.
colors:
  bg: "oklch(100% 0 0)"
  surface: "oklch(97.5% 0.006 152)"
  hairline: "oklch(90% 0.01 152)"
  ink: "oklch(22% 0.02 152)"
  primary: "oklch(48% 0.09 152)"
  primary-content: "oklch(99% 0.005 152)"
  secondary: "oklch(52% 0.016 152)"
  accent: "oklch(58% 0.07 210)"
  accent-content: "oklch(99% 0.005 210)"
  neutral: "oklch(36% 0.018 152)"
  success: "oklch(48% 0.09 152)"
  warning: "oklch(72% 0.12 75)"
  error: "oklch(52% 0.16 25)"
  dark-bg: "oklch(16% 0.012 152)"
  dark-surface: "oklch(20% 0.014 152)"
  dark-ink: "oklch(94% 0.01 152)"
  dark-primary: "oklch(72% 0.09 152)"
  dark-accent: "oklch(72% 0.07 210)"
typography:
  body:
    fontFamily: "\"Source Sans 3\", ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.5
  headline:
    fontFamily: "\"Source Sans 3\", ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.5rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.02em"
  title:
    fontFamily: "\"Source Sans 3\", ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.125rem"
    fontWeight: 600
    lineHeight: 1.35
  label:
    fontFamily: "\"Source Sans 3\", ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 500
    lineHeight: 1.3
  mono:
    fontFamily: "\"IBM Plex Mono\", ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "0.8125rem"
    fontWeight: 400
    lineHeight: 1.45
rounded:
  sm: "0.25rem"
  md: "0.5rem"
  pill: "999px"
spacing:
  sm: "8px"
  md: "16px"
  lg: "24px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.primary-content}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "8px 12px"
  card-task:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "10px"
  chip-cost:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "2px 6px"
---

# Design System: Svärm

## 1. Overview

**Creative North Star: "The Forest Ops Desk"**

A quiet engineering control room: Linear density and scan rhythm, Mercury material restraint, soft moss green as the single voice of action and trust. Surfaces stay pure white so brand lives in accent, type, and numbers — never cream paper.

Product register. Users leave `/board` open all day. Status, agent identity, and cost must read as fact. Personality: **Calm · Trustworthy · Precise.** Positioning: *Your AI teammates, governed.*

Rejected: SaaS-purple chrome, chat-first agent UIs, hero-metric marketing blocks in-product, playful AI-coworker gamification, green-on-cream, stock Phoenix themes.

**Key Characteristics:**
- Restrained: pure white + soft moss ≤10% of screen
- Dense kanban; overview first, detail on selection (`?task=`)
- Source Sans 3 + IBM Plex Mono for governed facts
- Flat tonal layering; hairline borders; no decorative shadows
- Motion only for real state (running pulse, selection)

## 2. Colors

Tokens live in `assets/css/app.css` daisyUI `light` / `dark` themes. OKLCH is canonical.

### Primary
- **Soft Moss** (`oklch(48% 0.09 152)` light / `oklch(72% 0.09 152)` dark): Primary buttons, selection rings, running pulse. Near-white text on fills in light mode (AA ≥4.5:1).

### Accent
- **Steel Teal** (`oklch(58% 0.07 210)`): Info and secondary cool chrome — not Linear purple.

### Neutral
- **Snow** (`oklch(100% 0 0)`): Page background.
- **Moss Mist** (`oklch(97.5% 0.006 152)`): Columns, panels (`base-200`).
- **Hairline** (`oklch(90% 0.01 152)`): Borders (`base-300`).
- **Ink** (`oklch(22% 0.02 152)`): Body text.

### Semantic
- Success shares forest family; warning amber (`oklch(72% 0.12 75)`); error restrained red (`oklch(52% 0.16 25)`). Never color-only for status — pair with text labels.

### Named Rules
**The One Forest Rule.** Primary green ≤10% of any screen.  
**The No Cream Rule.** Body bg is pure white or dark forest-ink — never sand/parchment.  
**The Cost Is Ink Rule.** Costs are mono ink (or muted + “est.”), not decorative gold.

## 3. Typography

**UI:** Source Sans 3 (Google Fonts)  
**Mono:** IBM Plex Mono — costs, ids, logs  

### Hierarchy
- **Headline** 1.5rem / 600 — page titles  
- **Title** ~1.125rem / 600 — panel titles  
- **Body** 0.9375rem / 400 — default UI  
- **Label** 0.75rem / 500 — meta, chips  
- **Mono** 0.8125rem — governed facts  

**The Product Scale Rule.** Fixed rem only; no marketing fluid display type on app routes.  
**The Mono Means Governed Rule.** Money, ids, model names, logs → mono.

## 4. Elevation

Flat by default. Depth via tonal steps (base-100 / 200 / 300), not shadow. daisyUI `--depth: 0`. Borders 1px hairline.

**The Flat-By-Default Rule.** No permanent card drop shadows.  
**The Hairline Rule.** Separation is 1px hairline or tonal step — never side-stripe accents.

## 5. Components

### Buttons
- Radius 0.25rem (`rounded.sm` / daisy field radius)
- Primary: soft moss + light content
- Ghost / outline for secondary chrome
- Approval actions: primary + ghost (on board and `/approvals`)

### Agent badge
- Monogram circle (primary soft fill) + display name — not emoji avatars

### Task cards
- Raised white on moss column well; selected primary border/ring; pending dashed warning; running primary soft wash
- Cost chip only when ledger has records (intentional)

### Orchestrator bar
- Idle: one quiet line (last poll · gates · session cost)
- Busy: compact metric row, hairline container — not daisy `stats` shadows

### Columns
- Human titles (Todo, Needs approval, …); empty cells “—”

### Navigation
- Top bar: swarm logo + Svärm wordmark; Dashboard / Board / Setup / Approvals ghost; theme toggle

### Home
- Minimal product home: positioning line + Open team board CTA — not Phoenix marketing

## 6. Do's and Don'ts

### Do:
- Keep moss rare — action and live state only  
- Costs in mono; label estimates  
- Named agents via monogram + display name  
- Prefer density and scannability  
- 150–250ms ease-out; honor `prefers-reduced-motion`  
- WCAG 2.2 AA; status not color-alone  

### Don't:
- SaaS-purple dashboards or generic AI platform chrome  
- Chat-first agent UIs burying work status  
- Hero-metric marketing layouts inside the product  
- Playful gamified “AI coworker” aesthetics  
- Forest green on cream/sand paper  
- Side-stripe borders, gradient text, glassmorphism defaults  
- Stock Phoenix orange/purple themes as brand  
