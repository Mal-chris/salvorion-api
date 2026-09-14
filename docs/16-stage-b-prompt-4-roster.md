# Prompt 4: Roster Context, Providers, and Synthetic Data

**Document:** 16 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 7
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 12 September 2026

---

## Scope note

This prompt builds `Salvorion.Roster` and two concrete implementations of the `RosterProvider` behaviour that already exists (`lib/salvorion/roster/provider.ex`): a synthetic generator for development and testing, and a file-import path for the CSV/Excel route OSH will actually use once real data is available (Document 02, section 5). No HTTP routes yet, same reasoning as Prompt 3 — verification via a `mix run` script.

Have Claude Code read `docs/03-technical-foundation.md` section 2.2 (the `RosterProvider` design) and `docs/06-erd-and-data-dictionary.md` (the `Person` and `RosterImport` entities) before starting.

---

## The prompt

```
This is the fourth step in building Salvorion. Prompts 1–3 (complete)
built the scaffold, Accounts/Audit with RS256 auth, and Organisation/
Locations seeded with real OSH data. This prompt builds the Roster
context: the Person records themselves, and two ways to populate them.

Read docs/03-technical-foundation.md section 2.2 and
docs/06-erd-and-data-dictionary.md before starting. Follow the audit
pattern already established (lib/salvorion/audit/multi.ex) for every
create/update.

TASK 1: The Roster context — core Person operations
Create lib/salvorion/roster.ex (schemas already exist in
lib/salvorion/roster/) exposing:
- create_person/2, update_person/3 — via Person.changeset/2
- get_person_by_id_number/1 — the primary lookup for ID card scans
  later (FR-SIGN-01); returns nil, not an exception, since a missed
  lookup during scanning is an expected case, not an error
- search_people_by_name/1 — case-insensitive partial match on
  first_name/last_name, for the manual name-search flow (FR-SIGN-03)
- list_people/1 — filterable by :type (staff/student/visitor) and
  :department_id (checks both primary_department_id and the
  person_departments join table)
- upsert_person_by_id_number/2 — creates if no person with that
  id_number exists, updates if one does; this is what both providers
  in Tasks 2 and 3 will call. Staff and students are upserted this way;
  visitors (Task in a later prompt, not this one) are always created
  fresh since they have no id_number to match on.
- register_person_department/3 and remove_person_department/3 — manage
  the secondary person_departments join, mirroring how Locations
  handles department_areas

TASK 2: RosterImport tracking
Add to lib/salvorion/roster.ex (or a submodule if it gets long):
- start_roster_import/1 (provider name) — creates a RosterImport row
  with started_at now, status implied by completed_at being nil
- complete_roster_import/3 (import, total_records, error_count,
  errors) — sets completed_at, the counts, and the errors map
- list_roster_imports/0 — most recent first, for the future admin
  history screen (Document 11, section 2.6)

TASK 3: SyntheticRosterProvider
Create lib/salvorion/roster/providers/synthetic.ex implementing the
Roster.Provider behaviour (@callback fetch_records/1). Given an opts
keyword list with :staff_count and :student_count (defaults: 150 staff,
1200 students — enough to make the dashboard's participation-rate math
meaningful without approaching load-test scale, which is a separate,
later concern), generate raw_record maps as the behaviour specifies:
- Distribute generated people across the REAL departments and
  programmes already seeded by Prompt 3 — query them, don't hardcode a
  list. Staff get a primary_department_id from the real 21 departments.
  Students need a programme, but Prompt 3 seeded zero programmes (real
  programme data doesn't exist yet — see Document 05, Appendix A,
  "student grouping"). Create a small set of clearly-synthetic
  programmes for this purpose only (e.g. "Synthetic Programme — Faculty
  TBD", tied to no real faculty), so students have something to attach
  to without inventing fake real-sounding NCU programme names. Comment
  this clearly so nobody mistakes these for real programmes later.
- Generate id_number values that are obviously synthetic and cannot
  collide with a real future import — prefix them (e.g. "SYN-000001")
  rather than generating something that looks like a real NCU ID, since
  the actual ID format is still an open question (Document 05, Appendix
  A, "ID barcode format").
- Names: generate plausible-looking but clearly fictional first/last
  names. Do not use any real NCU student or staff name under any
  circumstance, even as a joke or placeholder — generate from a name
  list you construct, not from any real roster you might have training
  knowledge of.
- Every synthetic person's `source` field (Person schema) must be set
  to "synthetic" — this is what lets a future real import coexist
  without confusion, and what will let a "clear all synthetic data"
  admin action (not built in this prompt) find and remove exactly
  these rows later.
- Wire this through start_roster_import/complete_roster_import from
  Task 2, provider name "synthetic".

TASK 4: FileImportProvider
Create lib/salvorion/roster/providers/file_import.ex implementing the
same behaviour, taking a file path (CSV) in opts. Expected columns:
type, id_number, first_name, last_name, email, phone, department_code,
programme_code (any of the last four may be blank). For each row:
- Validate type is staff/student/visitor-adjacent-but-visitors-are-out-
  of-scope-here (reject "visitor" rows in this provider — visitors are
  never bulk-imported, they're registered live; treat a "visitor" row
  as a row error, not a crash)
- Resolve department_code/programme_code against the real Organisation
  records by their :code field (already present on Department and
  Programme) — a code that doesn't match is a row-level error, not a
  fatal one; the import continues and reports it
- Missing required fields (type, id_number for non-visitors, first_name,
  last_name) are also row-level errors, collected and reported, not
  raised
- Return {:ok, %{total: n, errors: [%{row: n, reason: "..."}]}} — the
  shape complete_roster_import/3 from Task 2 expects
- Set every created/updated person's `source` field to "roster"
- Do not actually call this against a real file in this prompt (no real
  roster exists yet) — write a small fixture CSV under test/fixtures/
  with a handful of rows including at least one deliberately broken row
  (bad department_code, missing id_number) to prove the error path
  works, and use that fixture in the ExUnit tests and in this prompt's
  own verification.

VERIFICATION
After completing all tasks, tell me explicitly:
1. mix compile output, zero new warnings; mix precommit passes.
2. Run the synthetic provider via mix run with the default counts.
   Report: total people created, broken down by type (staff/student),
   and confirm every one has source: "synthetic".
3. Query and show the distribution of staff across the 21 real
   departments — it does not need to be perfectly even, but confirm no
   department has zero staff and no person references a department
   that doesn't exist (a broken foreign key would already prevent
   insert, but confirm the distribution logic actually iterates the
   real list rather than a hardcoded subset).
4. Run the synthetic provider a second time with different counts (e.g.
   staff_count: 10, student_count: 10) and confirm it does NOT wipe or
   duplicate the first run — synthetic data accumulates unless someone
   explicitly clears it. State plainly whether this second run's
   id_numbers could ever collide with the first run's, and why or why
   not.
5. Run the FileImportProvider against the test fixture CSV. Show the
   returned {:ok, %{total, errors}} shape, and confirm the deliberately
   broken rows appear in `errors` with a clear reason, while the valid
   rows were actually created (query and show at least one).
6. Show one RosterImport row for each provider run above, with correct
   started_at/completed_at/total_records/error_count.
7. Confirm get_person_by_id_number/1 returns nil (not an exception) for
   an id_number that doesn't exist.
8. A list of every file created or modified.

Stop after verification. Do not build routes/controllers, and do not
start the Activations or Accountability contexts yet.
```

---

## What to check yourself

1. **Item 4 is the one that matters most here.** Read the collision-safety explanation carefully. If synthetic IDs are generated as a random suffix rather than a running counter checked against existing rows, two separate runs could theoretically produce the same `id_number`, which would violate the unique index on `people.id_number` and crash the import rather than silently corrupting data (that part is safe), but it's worth understanding whether the scheme is "impossible to collide" or "extremely unlikely," and which one Claude Code actually built.
2. **Check that the synthetic programmes are obviously fake in the database itself**, not just in a code comment. Query `programmes` yourself and confirm the name genuinely reads as a placeholder, not something that could be mistaken for a real NCU programme by someone browsing the admin screen next year.
3. **Confirm no real name leaked in.** This is a real, if small, risk whenever a model is asked to "generate plausible names" — skim a sample of the generated `people` rows yourself.
4. **Try the FileImportProvider against a second, hand-written fixture of your own** with a case not covered by Claude Code's own test fixture (an empty file, a file with only a header row, a row with an unknown `type` value) — this is cheap insurance against the exact kind of edge case a generated fixture might not think to include.
