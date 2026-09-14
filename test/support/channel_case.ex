defmodule SalvorionWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by tests that require
  setting up a connection to a `Phoenix.Socket`/`Phoenix.Channel`.

  A channel test spawns the joined channel as its own process, distinct
  from the test process, so — unlike `SalvorionWeb.ConnCase`, whose
  requests run in-process — the sandbox must be shared (`async: false`
  at the use site) for that process to see the same data the test set up.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import SalvorionWeb.ChannelCase

      @endpoint SalvorionWeb.Endpoint
    end
  end

  setup tags do
    Salvorion.DataCase.setup_sandbox(tags)
    :ok
  end
end
