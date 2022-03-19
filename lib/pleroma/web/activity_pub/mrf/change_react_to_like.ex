# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.ChangeReactstoLikes do
  require Logger

  @moduledoc "Changes specified EmojiReacts into a Like"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @impl true
  @spec filter(any) :: {:ok, any}
  def filter(%{"type" => "EmojiReact"} = object) do
    react = object["content"]

    # TODO: make this pull from config
    if react in ["👍", "👎", "❤️", "😆", "😮", "😢", "😩", "😭", "🔥", "⭐"] do
      Logger.info("MRF.ChangeReactstoLikes: Changing #{inspect(react)} to a Like")

      object =
        object
        |> Map.put("type", "Like")

      {:ok, object}
    else
      {:ok, object}
    end
  end

  @impl true
  def filter(object), do: {:ok, object}

  @impl true
  def describe, do: {:ok, %{}}
end
