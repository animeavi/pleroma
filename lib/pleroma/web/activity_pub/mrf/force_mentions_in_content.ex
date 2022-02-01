# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.ForceMentionsInContent do
  require Pleroma.Constants

  alias Pleroma.Formatter
  alias Pleroma.Object
  alias Pleroma.User

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  defp do_extract({:a, attrs, _}, acc) do
    if Enum.find(attrs, fn {name, value} ->
         name == "class" && value in ["mention", "u-url mention", "mention u-url"]
       end) do
      href = Enum.find(attrs, fn {name, _} -> name == "href" end) |> elem(1)
      acc ++ [href]
    else
      acc
    end
  end

  defp do_extract({_, _, children}, acc) do
    do_extract(children, acc)
  end

  defp do_extract(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, fn node, acc -> do_extract(node, acc) end)
  end

  defp do_extract(_, acc), do: acc

  defp extract_mention_uris_from_content(content) do
    {:ok, tree} = :fast_html.decode(content, format: [:html_atoms])
    do_extract(tree, [])
  end

  defp get_replied_to_user(%{"inReplyTo" => in_reply_to}) do
    case Object.normalize(in_reply_to, fetch: false) do
      %Object{data: %{"actor" => actor}} -> User.get_cached_by_ap_id(actor)
      _ -> nil
    end
  end

  defp get_replied_to_user(_object), do: nil

  # Ensure the replied-to user is sorted to the left
  defp sort_replied_user([%User{id: user_id} | _] = users, %User{id: user_id}), do: users

  defp sort_replied_user(users, %User{id: user_id} = user) do
    if Enum.find(users, fn u -> u.id == user_id end) do
      users = Enum.reject(users, fn u -> u.id == user_id end)
      [user | users]
    else
      users
    end
  end

  defp sort_replied_user(users, _), do: users

  # Drop constants and the actor's own AP ID
  defp clean_recipients(recipients, object) do
    Enum.reject(recipients, fn ap_id ->
      ap_id in [
        object["object"]["actor"],
        Pleroma.Constants.as_public(),
        Pleroma.Web.ActivityPub.Utils.as_local_public()
      ]
    end)
  end

  defp is_remote(host) do
    my_host = Pleroma.Config.get([Pleroma.Web.Endpoint, :url, :host])
    my_host != host
  end

  defp has_soapbox_header(host) do
    api_url = "https://" <> host <> "/api/v1/instance"
    api_resp = HTTPoison.get!(api_url)

    if api_resp.status_code == 200 do
      with {:ok, resp_body} <- Jason.decode(api_resp.body) do
        if resp_body["soapbox"] do
          true
        else
          false
        end
      end
    else
      false
    end
  end

  defp is_soapbox(object) do
    known_soapbox_hosts = ["gleasonator.com", "spinster.xyz", "leafposter.club"]
    # Getting double mentions when they reply to misskey or mastodon(?)
    skip_hosts = [""]
    actor = object["object"]["actor"]
    host = URI.parse(actor).host

    cond do
      is_remote(host) && Enum.member?(skip_hosts, host) -> false
      is_remote(host) && Enum.member?(known_soapbox_hosts, host) -> true
      is_remote(host) && has_soapbox_header(host) -> true
      true -> false
    end
  end

  @impl true
  def filter(
        %{
          "type" => "Create",
          "object" => %{"type" => "Note", "to" => to, "inReplyTo" => in_reply_to}
        } = object
      )
      when is_list(to) and is_binary(in_reply_to) do
    if is_soapbox(object) do
      # image-only posts from pleroma apparently reach this MRF without the content field
      content = object["object"]["content"] || ""

      # Get the replied-to user for sorting
      replied_to_user = get_replied_to_user(object["object"])

      mention_users =
        to
        |> clean_recipients(object)
        |> Enum.map(&User.get_cached_by_ap_id/1)
        |> Enum.reject(&is_nil/1)
        |> sort_replied_user(replied_to_user)

      explicitly_mentioned_uris = extract_mention_uris_from_content(content)

      added_mentions =
        Enum.reduce(mention_users, "", fn %User{ap_id: uri} = user, acc ->
          unless uri in explicitly_mentioned_uris do
            acc <> Formatter.mention_from_user(user, %{mentions_format: :compact}) <> " "
          else
            acc
          end
        end)

      recipients_inline =
        if added_mentions != "",
          do: "<span class=\"recipients-inline\">#{added_mentions}</span>",
          else: ""

      content =
        cond do
          # For Markdown posts, insert the mentions inside the first <p> tag
          recipients_inline != "" && String.starts_with?(content, "<p>") ->
            "<p>" <> recipients_inline <> String.trim_leading(content, "<p>")

          recipients_inline != "" ->
            recipients_inline <> content

          true ->
            content
        end

      {:ok, put_in(object["object"]["content"], content)}
    else
      {:ok, object}
    end
  end

  @impl true
  def filter(object), do: {:ok, object}

  @impl true
  def describe, do: {:ok, %{}}
end
