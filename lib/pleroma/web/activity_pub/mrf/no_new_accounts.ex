# Pleroma: A lightweight social networking server
# Copyright © 2017-2023 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.NoNewAccounts do
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy
  # require Logger

  alias Pleroma.Config
  alias Pleroma.User

  defp is_remote?(host) do
    my_host = Config.get([Pleroma.Web.Endpoint, :url, :host])
    my_host != host
  end

  @impl true
  def filter(
        %{
          "type" => type,
          "actor" => actor
        } = object
      )
      when type in ["Create", "Update"] do
    actor_info = URI.parse(actor)
    user = User.get_cached_by_ap_id(actor)
    old_enough = Timex.shift(NaiveDateTime.utc_now(), days: -2)

    if(
      is_remote?(actor_info.host) &&
        Timex.to_unix(user.inserted_at) >= Timex.to_unix(old_enough)
    ) do
      # Logger.warn("[NoNewAccounts] Rejecting post from fresh account: #{user.nickname}!")
      {:reject, "[NoNewAccounts] Rejecting post from fresh account!"}
    else
      {:ok, object}
    end
  end

  @impl true
  def filter(object), do: {:ok, object}

  @impl true
  def describe, do: {:ok, %{}}
end
