# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.BlockNotification do
  @moduledoc "Notify local users upon remote block."
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  defp is_block_or_unblock(%{"type" => "Block", "object" => object}),
    do: {true, "blocked", object}

  defp is_block_or_unblock(%{
         "type" => "Undo",
         "object" => %{"type" => "Block", "object" => object}
       }),
       do: {true, "unblocked", object}

  defp is_block_or_unblock(_), do: {false, nil, nil}

  defp is_remote_or_displaying_local?(%User{local: false}), do: true

  defp is_remote_or_displaying_local?(_), do: true

  @impl true
  def filter(message) do

    with {true, action, object} <- is_block_or_unblock(message),
         %User{} = actor <- User.get_cached_by_ap_id(message["actor"]),
         %User{} = recipient <- User.get_cached_by_ap_id(object),
         true <- recipient.local,
         true <- is_remote_or_displaying_local?(actor),
         false <- User.blocks_user?(recipient, actor) do

      # Create /opt/pleroma/logs/ with write perms for user pleroma
      # Make a cron job to delete the log file every hour or whatever
      # Not my problem
      log_file = "/opt/pleroma/logs/blocks.log"
      bot_user = "cockblock"

      log_contents = if File.exists?(log_file) do
        File.read!(log_file)
      else
        ""
      end

      logged_blocks = String.split(log_contents, "\n")

      actor_name = (fn actor_uri -> Path.basename(actor_uri.path) <> "@" <> actor_uri.authority end).(URI.parse(message["actor"]))
      log_entry = actor_name <> ":" <> action

      unless Enum.member?(logged_blocks, log_entry) do
        File.write!(log_file, log_entry <> "\n", [:append])
        _reply =
          CommonAPI.post(User.get_by_nickname(bot_user), %{
            status: "@" <> recipient.nickname <> " you have been " <> action <> " by @" <> actor_name <> " (" <> actor_name <> ")",
            visibility: "unlisted"
          })
      end
    end

    {:ok, message}
  end

  @impl true
  def describe, do: {:ok, %{}}
end
