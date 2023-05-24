# Pleroma: A lightweight social networking server
# Copyright © 2017-2023 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.NoIncomingDeletes do
  alias Pleroma.User

  require Logger

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  defp is_remote?(%User{local: false}), do: true

  defp is_remote?(_), do: false

  def is_delete_or_undelete(%{
        "type" => "Delete",
        "object" => _
      }),
      do: true

  def is_delete_or_undelete(%{
        "type" => "Undo",
        "object" => %{"type" => "Delete", "object" => _}
      }),
      do: true

  def is_delete_or_undelete(_), do: false

  @impl true
  def filter(message) do
    with true <- is_delete_or_undelete(message) do
      with %User{} = actor <- User.get_cached_by_ap_id(message["actor"]),
           true <- is_remote?(actor) do
        # Logger.warn("DELETE rejected: #{inspect(message)}")

        {:reject, message}
      else
        _ ->
          # Logger.warn("DELETE from this instance, not rejecting:  #{inspect(message)}")

          {:ok, message}
      end
    else
      _ ->
        {:ok, message}
    end
  end

  @impl true
  def describe, do: {:ok, %{}}
end
