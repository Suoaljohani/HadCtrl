# HadCtrl design direction (2026-11)

Research inputs: Apple WWDC25 sessions on Liquid Glass and scroll edge effects
(sessions 219/256/310/323 and the Design/UI-Frameworks Group Lab summaries), the
2025 Apple Design Award categories (Interaction, Visuals and Graphics), and 2026
trend reviews (Tubik, Muzli, Pixelmatters, UX Pilot). Vendor trend posts were used
only for direction, checked against Apple's guidance; nothing here relies on an
unverified API.

## The five directions we adopt (ranked by fit with HadCtrl's content)

| # | Direction | Why it fits a hospital performance app | Where it lives |
|---|-----------|----------------------------------------|----------------|
| 1 | **Content-first depth: opaque content, glass controls** (Liquid Glass on iOS 26, material fallback on 17–18) | Numbers must stay legible; glass belongs to the control layer only (Apple: glass inside scrolling content "feels heavy"). Scroll edge effects keep the floating bar readable over cards. | Tab bar and toolbars (system), period chip, dashboard edit bar, signature sheet controls |
| 2 | **Scroll-driven storytelling** | A director reads the dashboard top-down as a story: what needs me → how are we doing → where. Motion tied to scroll position (hero compresses, cards settle in as they enter, sticky context) guides that reading without autoplay. | Dashboard hero parallax + compression, `scrollTransition` on every card and list row, sticky period context |
| 3 | **Personal, role-aware workspace** | Directors, heads and coordinators need different first screens. A user-arranged dashboard (order, visibility, density) and role-specific settings make the app feel built for each person. | Customizable dashboard modules, role sections in Settings, start tab, default filters |
| 4 | **Purposeful, controllable motion** | Motion explains state (a number changed, a record opened, a decision was recorded) — and users can say "stop": in-app reduced motion and haptics switches on top of the system settings. | Zoom transitions, numeric text transitions, symbol effects on decisions, signature confirmation, haptics only for outcomes |
| 5 | **Calm, honest data visualization** | Rings, bars and small multiples with numerator/denominator, coverage beside every score, no fake zeros; monospaced digits that animate in place instead of flickering. | Score ring, coverage tracks, reading tiles, department pulse, indicator detail |

## Rules that keep it coherent

- One accent (`hcPrimary`) for interaction; status colours always paired with text.
- Radii: cards 20–28, chips capsule; elevation is a hairline plus a soft low shadow (none in dark).
- Every animation has a static end state and is off under Reduce Motion, the in-app
  "reduce motion" switch, and UI tests.
- Scroll effects transform only opacity/scale/offset (cheap, GPU-composited); no layout
  changes during scroll.
- Custom layouts respect safe areas; glass never sits inside scrolling content.
- Arabic-first: mixed-direction lines are built so they read right-to-left; numbers use the
  user's digit preference.
