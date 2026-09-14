// Client-side schema for the verification tool. Declares every table any
// stream in docker/powersync/sync-config.yaml can populate. This is NOT
// part of the Flutter client's eventual schema (Stage C, item 17) - it
// exists only so this Node.js script's local SQLite mirror has somewhere
// to put replicated rows to inspect them.
import { column, Schema, Table } from '@powersync/node';

const text = column.text;

// The installed @powersync/node's Schema constructor takes the tables
// record directly (`new Schema({ tableName: table, ... })`), NOT wrapped
// in a `{ tables: {...} }` options object - the latter is what
// docs.powersync.com's own examples show, but it silently mis-parses
// against this package version: `tables` itself gets treated as a single
// "table" whose (nonexistent) `.copyWithName` is then called, throwing
// `table.copyWithName is not a function`. Confirmed against
// node_modules/@powersync/node/node_modules/@powersync/common's actual
// Schema.d.ts (`constructor(tables: ResolvedTable[] | Record<string, Table>)`).
export const AppSchema = new Schema({
    faculties: new Table({ name: text, code: text }),
    departments: new Table({ name: text, code: text, faculty_id: text }),
    programmes: new Table({ name: text, code: text, faculty_id: text }),
    assembly_points: new Table({ name: text, description: text, latitude: text, longitude: text }),
    zones: new Table({ number: text, assembly_point_id: text }),
    areas: new Table({ name: text, building: text, floor: text, zone_id: text }),
    department_areas: new Table({ department_id: text, area_id: text }),
    settings: new Table({ value: text, inserted_at: text, updated_at: text }),
    people: new Table({ type: text, id_number: text, first_name: text, last_name: text, email: text, phone: text, primary_department_id: text, programme_id: text, usual_area_id: text, source: text, visitor_host: text, visitor_expires_at: text }),
    // Populated by the `sync_safe_users` stream, which selects FROM `users`
    // (see docs/DECISIONS.md) - deliberately declared here with EXACTLY the
    // safe column list and nothing else, so that even attempting to select
    // password_hash from this local table is a schema error, not just an
    // empty result (Prompt 10 verification item 6).
    users: new Table({ email: text, role: text, active: text, inserted_at: text, updated_at: text }),
    activations: new Table({ activation_type: text, status: text, scope: text, started_by_id: text, closed_by_id: text, started_at: text, closed_at: text }),
    activation_zones: new Table({ activation_id: text, zone_id: text }),
    warden_assignments: new Table({ user_id: text, zone_id: text, area_id: text, starts_at: text, ends_at: text }),
    accountability_events: new Table({ client_uuid: text, activation_id: text, person_id: text, kind: text, status: text, recorded_by_id: text, device_id: text, assembly_point_id: text, area_id: text, note: text, client_timestamp: text, server_timestamp: text }),
    person_statuses: new Table({ activation_id: text, person_id: text, status: text, source_event_id: text, contradicting_event_id: text, contradiction_resolved_at: text }),
    expected_presences: new Table({ activation_id: text, person_id: text, rule_applied: text })
});
