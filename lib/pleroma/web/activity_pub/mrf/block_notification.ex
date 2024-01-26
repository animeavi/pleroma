# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.BlockNotification do
  @moduledoc "Notify local users upon remote block."
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.Config
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  defp is_block_or_unblock(%{"type" => "Block", "object" => object}),
    do: {true, Pleroma.Config.get([:mrf_block_notification, :blocked_text]), object}

  defp is_block_or_unblock(%{
         "type" => "Undo",
         "object" => %{"type" => "Block", "object" => object}
       }),
       do: {true, Pleroma.Config.get([:mrf_block_notification, :unblocked_text]), object}

  defp is_block_or_unblock(_), do: {false, nil, nil}

  defp is_remote_or_displaying_local?(%User{local: false}), do: true

  defp is_remote_or_displaying_local?(_), do: false

  defp user_old_enough?(actor) do
    days_old = Pleroma.Config.get([:mrf_block_notification, :account_days_old])

    if days_old < 1 do
      true
    else
      old_enough = Timex.shift(NaiveDateTime.utc_now(), days: -days_old)
      Timex.to_unix(actor.inserted_at) < Timex.to_unix(old_enough)
    end
  end

  defp format_message(blocked_user, blocking_user, action) do
    notification = Pleroma.Config.get([:mrf_block_notification, :notification_format])

    String.replace(
      notification,
      [
        "[blocked_user]",
        "[blocking_user]",
        "[blocking_user_without_mention]",
        "[action]"
      ],
      fn
        "[blocked_user]" -> "@#{blocked_user}"
        "[blocking_user]" -> "@#{blocking_user}"
        "[blocking_user_without_mention]" -> blocking_user
        "[action]" -> action
      end
    )
  end

  @impl true
  def filter(message) do
    with {true, action, object} <- is_block_or_unblock(message),
         %User{} = actor <- User.get_cached_by_ap_id(message["actor"]),
         true <- actor.is_active,
         %User{} = recipient <- User.get_cached_by_ap_id(object),
         true <- recipient.local,
         true <- is_remote_or_displaying_local?(actor) do
      # Make a cron job to delete the log file every hour or whatever
      # Not my problem
      log_file = Pleroma.Config.get([:mrf_block_notification, :log_file])
      bot_user = Pleroma.Config.get([:mrf_block_notification, :account_username])

      log_contents =
        if File.exists?(log_file) do
          File.read!(log_file)
        else
          ""
        end

      logged_blocks = String.split(log_contents, "\n")

      actor_name =
        (fn actor_uri -> Path.basename(actor_uri.path) <> "@" <> actor_uri.authority end).(
          URI.parse(message["actor"])
        )

      log_entry = actor_name <> ":" <> action

      if not Enum.member?(logged_blocks, log_entry) and user_old_enough?(actor) do
        File.write!(log_file, log_entry <> "\n", [:append])

        _reply =
          CommonAPI.post(User.get_by_nickname(bot_user), %{
            status: format_message(recipient.nickname, actor_name, action),
            visibility: Pleroma.Config.get([:mrf_block_notification, :notification_visibility])
          })
      end
    end

    {:ok, message}
  end

  @impl true
  def describe do
    mrf_block_notification =
      Config.get(:mrf_block_notification)
      |> Enum.into(%{})

    {:ok, %{mrf_block_notification: mrf_block_notification}}
  end

  @impl true
  def config_description do
    %{
      key: :mrf_block_notification,
      related_policy: "Pleroma.Web.ActivityPub.MRF.BlockNotification",
      label: "MRF Block Notification",
      description: @moduledoc,
      children: [
        %{
          key: :account_username,
          type: :string,
          description: "The username of the account that will send the block notifications.",
          suggestions: ["BlockNotifier"]
        },
        %{
          key: :notification_visibility,
          type: :string,
          description: "Visibility of the block notification (direct, unlisted, public).",
          suggestions: ["direct", "unlisted", "public"]
        },
        %{
          key: :log_file,
          type: :string,
          description: """
          Location of the log file to prevent notification spam, the pleroma user has to be able to write to it.

          I recommend deleting this file every hour or so using something like cron.
          """,
          suggestions: ["/opt/pleroma/logs/blocks.log"]
        },
        %{
          key: :notification_format,
          type: :string,
          description: """
            The text of notification.

            Modifiers: **[blocked_user]** (@joe@fbi.gov), **[blocking_user]** (@bill@cia.gov), **[blocking_user_without_mention]** (bill@cia.gov), **[action]** (blocked | unblocked).
          """,
          suggestions: [
            "[blocked_user] you have been [action] by [blocking_user_without_mention]"
          ]
        },
        %{
          key: :blocked_text,
          type: :string,
          description: "Text to use for **[action]** when action is blocking.",
          suggestions: ["blocked"]
        },
        %{
          key: :unblocked_text,
          type: :string,
          description: "Text to use for **[action]** when action is unblocking.",
          suggestions: ["unblocked"]
        },
        %{
          key: :account_days_old,
          type: :integer,
          description:
            "How old (in days) the account should be to generate a notification. Set to a value lower than 1 to disable the check.",
          suggestions: [1, 2, 7]
        }
      ]
    }
  end
end
