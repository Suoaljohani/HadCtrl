# HadCtrl implementation contract

Read docs/HadCtrl_Complete_Spec_AR.md in full. Preserve its requirement IDs, API contracts, acceptance criteria, role boundaries, and domain definitions.

## Product

- Native iPhone app using SwiftUI, Arabic-first RTL, initially iOS 17+ subject to verified dependency compatibility.
- Supabase is the source of shared truth; local cache and drafts do not count as submission or approval.
- Director dashboard, department cards, goals, indicators, tasks, recurring reports, achievements, evidence, search, notifications, exports, and audit history are required.
- Five stable navigation tabs: Home, Departments, Performance, Execution, Reports. Execution contains tasks and achievements. Creation is an action, not a navigation tab.

## Correctness

- Missing data is not zero. Distinguish receipt, review, return, and approval. Preserve first submission timestamps and immutable approved revisions.
- Never average incompatible units or unweighted period ratios. Show coverage with any aggregate performance score.
- Enforce organization and department authorization on the server. Never trust client-selected roles or user-editable metadata.
- All sensitive state transitions require authoritative actor identity, valid membership, expected version, idempotency, and atomic audit events.
- No service_role, Apple private signing material, APNs private key, or database password in the app, repository, artifacts, or logs.

## Engineering

- Inspect existing code and tooling before editing. Keep a buildable project and shared HadCtrl scheme.
- Use the verified official supabase-swift SDK and lock dependencies. Do not invent APIs.
- Keep networking and business rules out of SwiftUI body. Use narrow state, MainActor where appropriate, cancellation, request identity, and dependency injection.
- Do not replace real backend failures with demo records. Mock data belongs to explicit test/preview environments.
- Use reviewed skills only for their scope; record exact source revisions and preserve upstream notices.
- Follow native accessibility, Dynamic Type, reduced motion/transparency, and RTL behaviors.

## Verification and delivery

- Maintain REQUIREMENTS_TRACEABILITY.md, DECISIONS.md, API_CONTRACTS.md, TEST_REPORT.md, BUILD_REPORT.md, and RUNBOOK.md.
- Implement and verify the staged gates G1–G8 from the specification.
- Do not skip tests, weaken RLS, or use continue-on-error to hide a required failure.
- Never claim a simulator build is a device IPA. A signed IPA requires a real-device archive and valid Apple signing assets.
- Missing external setup must be recorded precisely while independent work continues. Do not fabricate credentials, a repository, a backend connection, or a successful build.
- Never run destructive reset/drop operations against a live Supabase project.
- Templates in templates/ are illustrative contracts. Integrate them only after implementing their assumptions and verifying the pinned toolchain.
