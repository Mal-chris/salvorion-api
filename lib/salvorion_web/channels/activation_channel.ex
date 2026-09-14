defmodule SalvorionWeb.ActivationChannel do
  @moduledoc """
  Topic `"activation:<id>"` (Prompt 12, Task 2). The real-time nudge
  Document 07 section 2 describes: PowerSync remains the source of truth
  a client reads for the actual row, so every push here is deliberately
  lightweight — a reason to go fetch the fresh data, not the data itself.

  Every one of the four roles may join (Document 10 section 1's "View
  live dashboard" row has at least some form of Yes for all four), but
  what a joined socket actually *receives* differs:

    * `admin`, `osh_officer`, `report_viewer` — every push for this
      activation, unfiltered.
    * `warden` — `activation_changed` unfiltered (activation status is
      not scoped to anyone), but `person_status_updated` only when the
      event's `zone_ids` intersects the warden's own scope, computed
      ONCE at join from `Scope.warden_scope/2` pinned to the
      activation's `started_at` (matching `Accountability.list_roll_call/2`'s
      own pinning for the HTTP roll-call read — consistency with what
      the client will actually fetch matters more here than matching
      PowerSync's necessarily-current sync-rule scoping). A warden with
      no effective assignment still joins, with an empty scope, so they
      at least see `activation_changed`.

  ## No explicit `Accountability.subscribe/1` call here

  It would be redundant, and worse, harmful: `use Phoenix.Channel`
  already subscribes this process to this exact topic string,
  `"activation:<id>"`, on the endpoint's own `pubsub_server`
  (`Salvorion.PubSub`, `config/config.exs`) — the same server and the
  same topic `Accountability.subscribe/1` would use. A second, explicit
  subscription to that same topic doesn't get deduplicated by
  `Phoenix.PubSub`; it registers a second subscriber entry for this same
  pid, and `Accountability`'s plain `Phoenix.PubSub.broadcast/3` calls
  (not `Phoenix.Channel.broadcast/3`, which only fastlanes
  `%Phoenix.Socket.Broadcast{}` structs) then get delivered to
  `handle_info/2` once per entry — i.e. twice. Caught by a test that
  actually asserted absence (`refute_push`) after the expected pushes,
  not just presence: every scoped-in socket was receiving
  `person_status_updated` and `activation_changed` twice. The raw
  `{:person_status_updated, payload}` / `{:activation_changed, payload}`
  tuples `Accountability`/`Activations` broadcast are plain terms, not
  `%Phoenix.Socket.Broadcast{}` structs, so Phoenix's own auto-subscribe
  delivers them to `handle_info/2` exactly like any other subscriber —
  nothing here needs to ask for that a second time.
  """

  use SalvorionWeb, :channel

  alias Salvorion.Accounts
  alias Salvorion.Accounts.User
  alias Salvorion.Accountability.Scope
  alias Salvorion.Activations

  @unscoped_roles ~w(admin osh_officer report_viewer)

  # Task 3: how long a joined channel can go on pushing to a device that
  # was revoked, a user who was deactivated, or accepting a token that
  # has since expired, before this self-check catches up. Not a
  # documented FR/NFR number — a starting
  # trade-off: shorter tightens the exposure window at the cost of one
  # more `devices` query per open channel every interval; 5 minutes costs
  # nothing measurable at this system's scale (a warden's shift, not a
  # consumer app with a huge number of concurrent sockets) while still
  # bounding "how late can a cut-off device learn it's cut off" to a
  # fraction of the access token's own 15-minute life. See
  # docs/DECISIONS.md for the full rationale and how this compares with
  # PowerSync's own, much wider, revocation gap (Prompt 10).
  @revocation_check_interval :timer.minutes(5)

  @impl true
  def join("activation:" <> activation_id, _params, socket) do
    case Activations.get_activation(activation_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      activation ->
        schedule_revocation_check()
        {:ok, assign_scope(socket, activation)}
    end
  end

  defp assign_scope(%{assigns: %{current_role: "warden"}} = socket, activation) do
    scope = Scope.warden_scope(%User{id: socket.assigns.current_user_id}, activation)
    assign(socket, :zone_ids, scope.zone_ids)
  end

  defp assign_scope(socket, _activation), do: socket

  @impl true
  def handle_info({:person_status_updated, payload}, socket) do
    if push_status_update?(socket, payload) do
      push(socket, "person_status_updated", Map.delete(payload, :zone_ids))
    end

    {:noreply, socket}
  end

  def handle_info({:activation_changed, payload}, socket) do
    push(socket, "activation_changed", payload)
    {:noreply, socket}
  end

  # Task 3's self-check, sent to this channel process by its own timer
  # (or directly by a test — see docs/DECISIONS.md). Re-verifies the
  # device against `devices.revoked_at` and the user against
  # `users.active` fresh each time (either can change at any moment —
  # Document 25, Task 7 added the user check, symmetric with device
  # revocation), and expiry against the `exp` claim already decoded at
  # connect time (Task 1) — never a full `Guardian.decode_and_verify/2`
  # re-run, since the signature was checked once already and cannot
  # change out from under an open connection.
  def handle_info(:check_revocation, socket) do
    if session_invalid?(socket) do
      push(socket, "session_revoked", %{})
      {:stop, :normal, socket}
    else
      schedule_revocation_check()
      {:noreply, socket}
    end
  end

  defp push_status_update?(%{assigns: %{current_role: "warden", zone_ids: zone_ids}}, payload) do
    Enum.any?(payload.zone_ids, &(&1 in zone_ids))
  end

  defp push_status_update?(%{assigns: %{current_role: role}}, _payload),
    do: role in @unscoped_roles

  defp session_invalid?(socket) do
    device_revoked?(socket.assigns[:current_device_id]) or
      token_expired?(socket.assigns[:token_claims]) or
      Accounts.user_deactivated?(socket.assigns.current_user_id)
  end

  defp device_revoked?(nil), do: false
  defp device_revoked?(device_id), do: Accounts.device_revoked?(device_id)

  defp token_expired?(%{"exp" => exp}) when is_integer(exp),
    do: exp <= System.system_time(:second)

  defp token_expired?(_claims), do: false

  defp schedule_revocation_check do
    Process.send_after(self(), :check_revocation, @revocation_check_interval)
  end
end
