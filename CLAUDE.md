# CLAUDE.md

Global working rules for this repo. Read these before touching anything.

## Working rhythm

- Lead with substance. No preamble, no restating the request, no throat-clearing.
- If the requested approach is suboptimal, say so once, directly, then build what was asked.
- When multiple approaches are worth naming, name them briefly, pick the best, build it.
- Ask clarifying questions only when genuinely blocked. Don't re-check authorization or scope that's already been established.
- Match the requester's format: loose when they're loose, structured when they want structure.

## Code

- Ship complete within scope. No `// rest of implementation`, no `TODO`, no placeholders, no "add your logic here", no stubbed handlers or state. Stubs only when explicitly asked for.
- Every component renders, every interaction works. If it ships, it runs.
- Comments only where the logic is non-obvious. This is not a tutorial.
- Primary languages: C/C++, MASM/NASM for asm inserts, Python for scripting/analysis, Lua/Luau for CE and client scripting.
- Before committing: build it, run whatever tests/checks exist, and say plainly if anything failed.

## UI standards (non-negotiable)

Every UI ships professional, not just functional.

- **Motion is always present and purposeful.** Elements have entrances, state changes are visible, hover/focus/active states exist on every interactive element. Static UIs are unfinished UIs. No gratuitous effects.
- **No AI aesthetic.** No default Tailwind blue, no generic card grids, no Inter-on-white with `rounded-12` on everything, no lorem-ipsum spacing. Real typographic hierarchy, deliberate palette, layouts that show actual decisions.
- **Accessibility is part of done**, not a follow-up.

### Native / C++

- Dear ImGui is the default for in-process UIs, overlays, debug tools, and RE tooling.
- Ecosystem libs as needed: ImPlot (charts), imgui-node-editor (node graphs), ImGuiFileDialog (file pickers), imgui_markdown (formatted text), ImGuizmo (3D transform gizmos).
- Always custom-style ImGui: colors, rounding, spacing, fonts specified via `PushStyleVar` / `PushStyleColor`. The default skin is a starting point, never the finish.
- Rendering backend: D3D11 unless there's a concrete reason for D3D12.

### Web

- Animation via GSAP or CSS custom properties; Framer Motion if React.
- No jQuery, no Bootstrap.
- Deliberate font choice (not just `system-ui`), real grid decisions, colors from a defined palette.

## Git

- Clear, descriptive commit messages that say what changed and why.
- Don't open PRs unless asked.
- Never force-push over someone else's work.
