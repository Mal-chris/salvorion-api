defmodule Salvorion.Repo.Migrations.AddPeopleUsualAreaIdIndex do
  use Ecto.Migration

  def change do
    # Prompt 7: Scope.person_area_pairs_query/0's "usual area" arm filters
    # people on usual_area_id IS NOT NULL, run by every dashboard/roll-call
    # query. EXPLAIN ANALYZE against the dev roster (1,373 people) showed a
    # full sequential scan for this arm with no index; a partial index on
    # the non-null case matches what the query asks for and stays cheap
    # regardless of table size (NFR-PERF-01/02).
    create index(:people, [:usual_area_id], where: "usual_area_id IS NOT NULL")
  end
end
