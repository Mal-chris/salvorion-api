defmodule Salvorion.AuditTest do
  use Salvorion.DataCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Audit

  test "record/1 appends a row and list_audit_logs/1 filters it" do
    actor = user_fixture()
    entity_id = Ecto.UUID.generate()

    assert {:ok, log} =
             Audit.record(%{
               actor_user_id: actor.id,
               action: "thing.changed",
               entity_type: "thing",
               entity_id: entity_id,
               before: %{"a" => 1},
               after: %{"a" => 2}
             })

    assert log.id

    assert [^log] = Audit.list_audit_logs(entity_type: "thing")
    assert [^log] = Audit.list_audit_logs(actor_user_id: actor.id, entity_type: "thing")
    assert [] = Audit.list_audit_logs(entity_type: "thing", actor_user_id: Ecto.UUID.generate())

    from = DateTime.add(log.inserted_at, -1, :second)
    to = DateTime.add(log.inserted_at, 1, :second)
    assert [^log] = Audit.list_audit_logs(entity_type: "thing", from: from, to: to)
    assert [] = Audit.list_audit_logs(entity_type: "thing", from: to)
  end

  test "record/1 allows a nil actor for system actions" do
    assert {:ok, log} = Audit.record(%{action: "visitor.purged", entity_type: "person"})
    assert log.actor_user_id == nil
  end

  test "record/1 rejects rows without an action or entity type" do
    assert {:error, changeset} = Audit.record(%{})
    assert %{action: ["can't be blank"], entity_type: ["can't be blank"]} = errors_on(changeset)
  end

  test "the context exposes no update or delete functions" do
    exported = Audit.__info__(:functions) |> Keyword.keys() |> Enum.map(&Atom.to_string/1)
    refute Enum.any?(exported, &String.contains?(&1, ["update", "delete", "change"]))
  end
end
