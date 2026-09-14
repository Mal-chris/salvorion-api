# Prompt 11: Reporting

**Document:** 23 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 14
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 13 September 2026

---

## Scope note

The `ReportRun`, `ReportRecipient` and `ReportDelivery` schemas already exist. This prompt builds the context, the render job, the delivery job, and — unlike Prompts 3 through 8 — its own routes in the same prompt, since Prompt 9 already consolidated routing for everything built before it and there is no later routes-only prompt planned. Gotenberg is real and already running; test against it for real. Amazon SES is not — no AWS credentials exist yet, and this prompt must not require them to be considered complete.

Have Claude Code read `docs/05-srs.md` (FR-REP-01 to FR-REP-06), `docs/08-sequence-state-deployment-diagrams.md` section 4, and `docs/10-security-design.md` section 1 (report recipient management: admin, osh_officer) before starting.

---

## The prompt

```
This is the eleventh step in building Salvorion. Prompts 1–10 (complete)
built every context, its routes, and PowerSync sync. This prompt builds
Reporting: what happens when an activation closes.

Read docs/05-srs.md (FR-REP-01 to FR-REP-06),
docs/08-sequence-state-deployment-diagrams.md section 4, and
docs/10-security-design.md section 1 before starting.

TASK 1: One more accountability query
Add Accountability.list_manual_events/1 (activation_id) — every event
with kind "manual" in the activation, joined to the person and the
recording user, ordered by server_timestamp. This is FR-REP-02's
"record of manual sign-ins" and did not exist before (Prompt 6's
list_events_for_person/2 is scoped to one person).

TASK 2: The Reporting context — recipients
Create lib/salvorion/reporting.ex (schemas exist) exposing:
- create_report_recipient/2, list_report_recipients/1 (opts:
  :active_only, default true), update_report_recipient/3,
  deactivate_report_recipient/2 (sets active: false — do not delete;
  same convention as everywhere else in this codebase)
All audited via Audit.Multi, same pattern as every prior context.

TASK 3: The report content and template
- compile_report_data/1 (activation) → a plain map: activation
  (type, scope, started_at, closed_at), summary
  (Accountability.activation_summary/1), by_department
  (participation_by_department/1), by_faculty
  (participation_by_faculty/1), unaccounted
  (unaccounted_list/2 with no filter), manual_events
  (Task 1). This function has no side effects and is unit-testable on
  its own against a closed activation.
- An HTML template (priv/report_templates/activation_report.html.eex or
  .heex — use whichever Phoenix's templating already supports without
  adding a new dependency) rendering that data: a header stating the
  activation type prominently (drill vs real must be visually
  unmistakable, per Document 11 section 4), start/close times, the
  headline summary, a participation-by-department table, a
  participation-by-faculty table, the unaccounted list, and the manual
  sign-in log. Plain, legible CSS inline or in a <style> block (Gotenberg
  renders standalone HTML — no external stylesheet requests). This is a
  first draft for OSH to react to (Document 05, Appendix A, item 12),
  not a final design — say so in a comment at the top of the template.

TASK 4: Rendering via Gotenberg
- render_report_pdf/1 (activation) — renders the template with
  compile_report_data/1's output, POSTs the resulting HTML to
  Gotenberg's /forms/chromium/convert/html endpoint (confirm the exact
  path and multipart form field name against Gotenberg 8's real
  documentation — do not guess), and returns {:ok, pdf_binary} or
  {:error, reason}. Test this against the actually-running Gotenberg
  container, not a mock — it exists and is healthy (confirmed in
  Prompt 1's verification).
- Store the PDF under a new, gitignored directory
  priv/generated_reports/ (not committed — these are generated
  artefacts, and production will need real object storage, noted in
  DECISIONS.md as a Release 1 limitation), named
  "{activation_id}-{report_run_id}.pdf". Add the directory to
  .gitignore with a .gitkeep so the empty folder still exists in git.

TASK 5: The render job and the delivery job
- Salvorion.Reporting.Workers.GenerateReportWorker (Oban, queue
  :reports): given an activation_id, creates a ReportRun (status
  pending), calls render_report_pdf/1, updates the run (status
  generated, pdf_path, generated_at) or (status failed) with the
  reason logged — Oban's own retry handles transient failures; on
  final exhaustion the run stays failed and is visible in history, not
  silently lost. On success, enqueues DeliverReportWorker once per
  currently-active ReportRecipient.
- Salvorion.Reporting.Workers.DeliverReportWorker (Oban, queue
  :reports): given a report_run_id and a report_recipient_id, creates
  or updates the corresponding ReportDelivery row (pending), sends the
  email (Task 6), sets delivery_status sent/failed and delivered_at.
- After every ReportDelivery for a run reaches a terminal state (sent
  or failed — Oban retries handle transient ones before that point),
  call Activations.mark_activation_reported/1. If there are zero active
  recipients, still mark it reported (Document 09 section 5's branch F)
  after logging/recording that no recipients were configured — do not
  leave an activation with no recipients stuck as "closed" forever.

TASK 6: Email delivery — real interface, dev-safe by default
- Add ex_aws and ex_aws_ses to mix.exs for the eventual SES adapter,
  but configure Swoosh with Swoosh.Adapters.Local in dev,
  Swoosh.Adapters.Test in test, and Swoosh.Adapters.AmazonSES in prod
  ONLY (guarded by config_env(), in config/runtime.exs, exactly the
  pattern already used for the Guardian key path). Do not attempt to
  send real email anywhere in this prompt's own verification — there
  are no AWS credentials, and there must not be a code path that tries
  to reach AWS during development. Record in DECISIONS.md: SES itself
  is unverified until real credentials exist; the interface is
  complete and swappable via config alone.
- The email: subject includes the activation type and date; body has a
  short summary and the PDF attached. Use Swoosh's attachment support.

TASK 7: Manual regenerate (FR-REP-05)
- regenerate_report/2 (activation, opts) — enqueues a fresh
  GenerateReportWorker run. This creates a NEW ReportRun row (history
  is retained per FR-REP-06 — never overwrite a previous run). Audited
  as "report.regenerate_requested".
- If the activation is already "reported", regenerating does not
  revert its status; it stays "reported" (a new run and new deliveries
  happen, but the activation's own state machine, per Document 08
  section 5, has no path backward from reported).

TASK 8: Routes
  POST   /api/report-recipients                    admin, osh_officer
  GET    /api/report-recipients                     admin, osh_officer
  PATCH  /api/report-recipients/:id                  admin, osh_officer
  GET    /api/activations/:id/reports                admin, osh_officer,
                                                      report_viewer
                                                      (list ReportRuns
                                                      for the activation,
                                                      newest first, with
                                                      each run's
                                                      deliveries)
  GET    /api/activations/:id/reports/:run_id/download
                                                      admin, osh_officer,
                                                      report_viewer
                                                      (streams the PDF;
                                                      404 if the run's
                                                      status is not
                                                      "generated" or
                                                      later — do not
                                                      serve a path for a
                                                      pending/failed run)
  POST   /api/activations/:id/reports/regenerate     admin, osh_officer
Extend the FallbackController for any new error atoms these introduce
(e.g. {:error, :report_not_ready} -> 404).

VERIFICATION
Reset the dev DB to baseline first if it is not already (1 user, 1373
people, zero activations). Create one report recipient with a
deliverable-looking but clearly non-real address
(e.g. "test-recipient@example.test"). After completing all tasks, tell
me explicitly:

 1. mix compile clean; mix precommit passes; test count.
 2. Start a campus activation, ingest a handful of events across at
    least two departments including at least one "manual" kind, close
    it. Show compile_report_data/1's output directly (the raw map),
    confirming every FR-REP-02 field is present and populated,
    including the manual event.
 3. Render the PDF for real against the running Gotenberg container.
    Confirm a real PDF file exists at the expected path in
    priv/generated_reports/, show its file size, and confirm (e.g. via
    `file` or `pdfinfo` on the file) it is a genuine, valid PDF, not an
    HTML error page saved with a .pdf extension.
 4. Run the full job chain (enqueue GenerateReportWorker, let it and
    the resulting DeliverReportWorker run — Oban testing mode per
    Prompt 8's convention, asserting each job's expected effect rather
    than waiting on a real queue). Confirm: ReportRun ends at status
    generated; exactly one ReportDelivery row for the one recipient,
    status sent; the activation's status is now "reported"; using
    Swoosh's test/local mailbox, show the captured email's subject,
    recipient, and that a PDF attachment is present (name and
    approximate size, not its full binary content).
 5. Zero-recipients case: deactivate the recipient, start and close a
    second activation, run the job chain, and confirm it still reaches
    "reported" with zero ReportDelivery rows, and that this is
    recorded somewhere sensible (say where) rather than silently
    indistinguishable from "recipients existed but all failed."
 6. Regenerate: call regenerate_report/2 on the first activation.
    Confirm a second ReportRun row exists (not a replacement of the
    first — show both), the first is untouched, and
    GET /api/activations/:id/reports lists both, newest first.
 7. Download route: fetch the generated PDF through
    GET .../reports/:run_id/download as report_viewer R1 and confirm
    the bytes match the file on disk. Attempt to download a run that
    is still "pending" (construct one, or race is fine to simulate by
    creating a ReportRun row directly with status pending) and confirm
    404 :report_not_ready, not a broken download.
 8. RBAC: a warden attempting any Task 8 route -> 403 for all of them
    (report recipients and report access are never warden actions).
 9. Confirm .gitignore excludes priv/generated_reports/*.pdf but the
    directory itself is tracked (the .gitkeep), and that mix.exs's new
    dependencies (ex_aws, ex_aws_ses) do not require any credential to
    be present for mix compile or mix test to succeed.
10. Every file created or modified, and the DECISIONS.md text added.

Stop after verification. Do not start the OpenAPI/Dart-client prompt's
work.
```

---

## What to check yourself

1. **Item 3 is the one to actually open.** A Gotenberg call that silently returns its own error page as a 200 with an HTML body would look successful in every automated check that only inspects the HTTP status. Open the resulting file yourself, or at minimum read the `file`/`pdfinfo` output in the report rather than trusting "a PDF was created."
2. **Item 5 is a real design point, not a formality.** Document 09 section 5 explicitly names the zero-recipients case as a visible failure mode OSH should notice, not a silent no-op. Confirm the report says exactly where that visibility lives (a log line is not enough on its own; it should be something a future admin screen could show).
3. **Confirm Task 6's guard is real, not just documented.** Try running `mix test` and `mix compile` yourself and confirm neither one makes any network attempt toward AWS. If `ex_aws`/`ex_aws_ses` being added to `mix.exs` introduces any compile-time requirement for credentials, that is a problem worth catching now, not in Stage D.
4. **Read the template once as a document, not as code.** It is going into the DECISIONS-adjacent list of things OSH will eventually see a draft of. Confirm the drill/real distinction is visually impossible to miss, per Document 11's own stated requirement, not just present in a small badge.
