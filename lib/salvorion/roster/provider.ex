defmodule Salvorion.Roster.Provider do
  @moduledoc """
  Behaviour every roster source implements, so the rest of the
  system never knows where roster data came from. See Technical
  Foundation (03), section 2.2.

  Implementations planned:
    - Salvorion.Roster.Providers.FileImport      (Release 1)
    - Salvorion.Roster.Providers.Synthetic        (Release 1, dev/test)
    - Salvorion.Roster.Providers.ScheduledExport  (Release 2)
    - Salvorion.Roster.Providers.DirectDatabase   (Release 2, pilot+)
  """

  @type raw_record :: %{
          type: String.t(),
          id_number: String.t() | nil,
          first_name: String.t(),
          last_name: String.t(),
          email: String.t() | nil,
          phone: String.t() | nil,
          department_code: String.t() | nil,
          programme_code: String.t() | nil
        }

  @callback fetch_records(opts :: keyword()) ::
              {:ok, [raw_record()]} | {:error, term()}
end
