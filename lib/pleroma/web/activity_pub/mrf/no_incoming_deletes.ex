# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.NoIncomingDeletes do
  @moduledoc "Reject remote deletes."

  require Logger

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy
  @impl true
  def filter(%{"type" => "Delete", "actor" => actor} = object) do
    actor_info = URI.parse(actor)
    instance_domain = Pleroma.Config.get([Pleroma.Web.Endpoint, :url, :host])
    if (actor_info.host == instance_domain) do
      #Logger.warn("DELETE from this instance, not rejecting: #{inspect(object)}")
      {:ok, object}
    else
      #Logger.warn("DELETE rejected: #{inspect(object)}")
      {:reject, object}
    end
  end

  @impl true
  def filter(object), do: {:ok, object}

  @impl true
  def describe, do: {:ok, %{}}
end
