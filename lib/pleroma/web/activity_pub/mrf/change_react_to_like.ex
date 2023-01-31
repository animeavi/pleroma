# Pleroma: A lightweight social networking server
# Copyright © 2017-2023 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.ChangeReactstoLikes do
  require Logger

  @moduledoc "Changes specified EmojiReacts into a Like"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

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
    known_soapbox_hosts = [
      "poa.st",
      "gleasonator.com",
      "spinster.xyz",
      "leafposter.club",
      "chudbuds.lol",
      "nicecrew.digital"
    ]

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
  
  defp is_remote(host) do
    my_host = Pleroma.Config.get([Pleroma.Web.Endpoint, :url, :host])
    my_host != host
  end

  @impl true
  @spec filter(any) :: {:ok, any}
  def filter(%{"type" => "EmojiReact"} = object) do
    if is_soapbox(object) do
      react = object["content"]

      # TODO: make this pull from config
      if react in ["👍", "👎", "❤️", "😆", "😮", "😢", "😩", "😭", "🔥", "🤔", "😡"] do
        object =
          object
          |> Map.put("type", "Like")

        {:ok, object}
      else
        {:ok, object}
      end
    else
      {:ok, object}
    end
  end

  @impl true
  def filter(object), do: {:ok, object}

  @impl true
  def describe, do: {:ok, %{}}
end
