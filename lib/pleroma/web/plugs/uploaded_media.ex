# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.UploadedMedia do
  @moduledoc """
  """

  import Plug.Conn
  import Pleroma.Web.Gettext
  require Logger

  alias Pleroma.Web.MediaProxy

  @behaviour Plug
  # no slashes
  @path "media"

  @default_cache_control_header "public, max-age=1209600"

  def init(_opts) do
    static_plug_opts =
      [
        headers: %{"cache-control" => @default_cache_control_header},
        cache_control_for_etags: @default_cache_control_header
      ]
      |> Keyword.put(:from, "__unconfigured_media_plug")
      |> Keyword.put(:at, "/__unconfigured_media_plug")
      |> Plug.Static.init()

    %{static_plug_opts: static_plug_opts}
  end

  def call(%{request_path: <<"/", @path, "/", file::binary>>} = conn, opts) do
    conn =
      case fetch_query_params(conn) do
        %{query_params: %{"name" => name}} = conn ->
          name = escape_header_value(name)

          put_resp_header(conn, "content-disposition", ~s[inline; filename="#{name}"])

        conn ->
          conn
      end
      |> merge_resp_headers([{"content-security-policy", "sandbox"}])

    config = Pleroma.Config.get(Pleroma.Upload)

    %{scheme: media_scheme, host: media_host, port: media_port} =
      Pleroma.Upload.base_url() |> URI.parse()

    with {:valid_host, true} <- {:valid_host, match?(^media_host, conn.host)},
         uploader <- Keyword.fetch!(config, :uploader),
         {:ok, get_method} <- uploader.get_file(file),
         false <- media_is_banned(conn, get_method) do
      get_media(conn, get_method, opts)
    else
      {:valid_host, false} ->
        redirect_url =
          %URI{
            scheme: media_scheme,
            host: media_host,
            port: media_port,
            path: conn.request_path,
            query: conn.query_string
          }
          |> URI.to_string()
          |> String.trim_trailing("?")

        conn
        |> Phoenix.Controller.redirect(external: redirect_url)
        |> halt()

      _ ->
        conn
        |> send_resp(:internal_server_error, dgettext("errors", "Failed"))
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp media_is_banned(%{request_path: path} = _conn, {:static_dir, _}) do
    MediaProxy.in_banned_urls(Pleroma.Upload.base_url() <> path)
  end

  defp media_is_banned(_, {:url, url}), do: MediaProxy.in_banned_urls(url)

  defp media_is_banned(_, _), do: false

  defp get_media(conn, {:static_dir, directory}, opts) do
    static_opts =
      Map.get(opts, :static_plug_opts)
      |> Map.put(:at, [@path])
      |> Map.put(:from, directory)

    conn = Plug.Static.call(conn, static_opts)

    if conn.halted do
      conn
    else
      conn
      |> send_resp(:not_found, dgettext("errors", "Not found"))
      |> halt()
    end
  end

  defp get_media(conn, {:url, url}, _) do
    conn
    |> Phoenix.Controller.redirect(external: url)
    |> halt()
  end

  defp get_media(conn, unknown, _) do
    Logger.error("#{__MODULE__}: Unknown get startegy: #{inspect(unknown)}")

    conn
    |> send_resp(:internal_server_error, dgettext("errors", "Internal Error"))
    |> halt()
  end

  defp escape_header_value(value) do
    value
    |> String.replace("\"", "\\\"")
    |> String.replace("\\r", "")
    |> String.replace("\\n", "")
  end
end
