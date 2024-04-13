# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Object.Fetcher do
  alias Pleroma.HTTP
  alias Pleroma.Instances
  alias Pleroma.Maps
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.Signature
  alias Pleroma.Web.ActivityPub.InternalFetchActor
  alias Pleroma.Web.ActivityPub.MRF
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.Federator

  require Logger
  require Pleroma.Constants

  @moduledoc """
  This module deals with correctly fetching Acitivity Pub objects in a safe way.

  The core function is `fetch_and_contain_remote_object_from_id/1` which performs
  the actual fetch and common safety and authenticity checks. Other `fetch_*`
  function use the former and perform some additional tasks
  """

  @mix_env Mix.env()

  @spec reinject_object(struct(), map()) :: {:ok, Object.t()} | {:error, any()}
  defp reinject_object(%Object{data: %{}} = object, new_data) do
    Logger.debug("Reinjecting object #{new_data["id"]}")

    with {:ok, new_data, _} <- ObjectValidator.validate(new_data, %{}),
         {:ok, new_data} <- MRF.filter(new_data),
         {:ok, new_object, _} <-
           Object.Updater.do_update_and_invalidate_cache(
             object,
             new_data,
             _touch_changeset? = true
           ) do
      {:ok, new_object}
    else
      e ->
        Logger.error("Error while processing object: #{inspect(e)}")
        {:error, e}
    end
  end

  defp reinject_object(_, new_data) do
    with {:ok, object, _} <- Pipeline.common_pipeline(new_data, local: false) do
      {:ok, object}
    else
      e -> e
    end
  end

  @doc "Assumes object already is in our database and refetches from remote to update (e.g. for polls)"
  def refetch_object(%Object{data: %{"id" => id}} = object) do
    with {:local, false} <- {:local, Object.local?(object)},
         {:ok, new_data} <- fetch_and_contain_remote_object_from_id(id),
         {:id, true} <- {:id, new_data["id"] == id},
         {:ok, object} <- reinject_object(object, new_data) do
      {:ok, object}
    else
      {:local, true} -> {:ok, object}
      {:id, false} -> {:error, :id_mismatch}
      e -> {:error, e}
    end
  end

  @doc """
    Fetches a new object and puts it through the processing pipeline for inbound objects

    Note: will also insert a fake Create activity, since atm we internally
    need everything to be traced back to a Create activity.
  """
  def fetch_object_from_id(id, options \\ []) do
    with %URI{} = uri <- URI.parse(id),
         # let's check the URI is even vaguely valid first
         {:valid_uri_scheme, true} <- {:valid_uri_scheme, uri.scheme == "http" or uri.scheme == "https"},
         # If we have instance restrictions, apply them here to prevent fetching from unwanted instances
         {:ok, nil} <- Pleroma.Web.ActivityPub.MRF.SimplePolicy.check_reject(uri),
         {:ok, _} <- Pleroma.Web.ActivityPub.MRF.SimplePolicy.check_accept(uri),
         {_, nil} <- {:fetch_object, Object.get_cached_by_ap_id(id)},
         {_, true} <- {:allowed_depth, Federator.allowed_thread_distance?(options[:depth])},
         {_, {:ok, data}} <- {:fetch, fetch_and_contain_remote_object_from_id(id)},
         {_, nil} <- {:normalize, Object.normalize(data, fetch: false)},
         params <- prepare_activity_params(data),
         {_, {:ok, activity}} <-
           {:transmogrifier, Transmogrifier.handle_incoming(params, options)},
         {_, _data, %Object{} = object} <-
           {:object, data, Object.normalize(activity, fetch: false)} do
      {:ok, object}
    else
      {:allowed_depth, false} = e ->
        log_fetch_error(id, e)
        {:error, :allowed_depth}

      {:valid_uri_scheme, _} = e ->
        log_fetch_error(id, e)
        {:error, :invalid_uri_scheme}

      {:containment, reason} = e ->
        log_fetch_error(id, e)
        {:error, reason}

      {:transmogrifier, {:error, {:reject, reason}}} = e ->
        log_fetch_error(id, e)
        {:reject, reason}

      {:transmogrifier, {:reject, reason}} = e ->
        log_fetch_error(id, e)
        {:reject, reason}

      {:transmogrifier, reason} = e ->
        log_fetch_error(id, e)
        {:error, reason}

      {:object, data, nil} ->
        reinject_object(%Object{}, data)

      {:normalize, object = %Object{}} ->
        {:ok, object}

      {:fetch_object, %Object{} = object} ->
        {:ok, object}

      {:fetch, {:error, reason}} = e ->
        log_fetch_error(id, e)
        {:error, reason}

      {:reject, reason} ->
        {:reject, reason}

      e ->
        log_fetch_error(id, e)
        {:error, e}
    end
  end

  defp log_fetch_error(id, error) do
    Logger.metadata(object: id)
    Logger.error("Object rejected while fetching #{id} #{inspect(error)}")
  end

  defp prepare_activity_params(data) do
    %{
      "type" => "Create",
      # Should we seriously keep this attributedTo thing?
      "actor" => data["actor"] || data["attributedTo"],
      "object" => data
    }
    |> Maps.put_if_present("to", data["to"])
    |> Maps.put_if_present("cc", data["cc"])
    |> Maps.put_if_present("bto", data["bto"])
    |> Maps.put_if_present("bcc", data["bcc"])
  end

  defp make_signature(id, date) do
    uri = URI.parse(id)

    signature =
      InternalFetchActor.get_actor()
      |> Signature.sign(%{
        "(request-target)": "get #{uri.path}",
        host: uri.host,
        date: date
      })

    {"signature", signature}
  end

  defp sign_fetch(headers, id, date) do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      [make_signature(id, date) | headers]
    else
      headers
    end
  end

  defp maybe_date_fetch(headers, date) do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      [{"date", date} | headers]
    else
      headers
    end
  end

  @doc "Fetches arbitrary remote object and performs basic safety and authenticity checks"
  def fetch_and_contain_remote_object_from_id(id)

  def fetch_and_contain_remote_object_from_id(%{"id" => id}),
    do: fetch_and_contain_remote_object_from_id(id)

  def fetch_and_contain_remote_object_from_id(id) when is_binary(id) do
    Logger.debug("Fetching object #{id} via AP")

    with {:valid_uri_scheme, true} <- {:valid_uri_scheme, String.starts_with?(id, "http")},
         {_, :ok} <- {:local_fetch, Containment.contain_local_fetch(id)},
         {:ok, final_id, body} <- get_object(id),
         {:ok, data} <- safe_json_decode(body),
         {_, :ok} <- {:strict_id, Containment.contain_id_to_fetch(final_id, data)},
         {_, :ok} <- {:containment, Containment.contain_origin(final_id, data)} do
      unless Instances.reachable?(final_id) do
        Instances.set_reachable(final_id)
      end

      {:ok, data}
    else
      {:strict_id, _} = e->
        log_fetch_error(id, e)
        {:error, :id_mismatch}

      {:valid_uri_scheme, _} = e ->
        log_fetch_error(id, e)
        {:error, :invalid_uri_scheme}

      {:local_fetch, _} = e ->
        log_fetch_error(id, e)
        {:error, :local_resource}

      {:containment, reason} ->
        log_fetch_error(id, reason)
        {:error, reason}

      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  def fetch_and_contain_remote_object_from_id(_id),
    do: {:error, :invalid_id}

  # HOPEFULLY TEMPORARY
  # Basically none of our Tesla mocks in tests set the (supposed to
  # exist for Tesla proper) url parameter for their responses
  # causing almost every fetch in test to fail otherwise
  if @mix_env == :test do
    defp check_crossdomain_redirect(nil, _) do
      {:cross_domain_redirect, false}
    end
  end

  defp check_crossdomain_redirect(final_host, original_url) do
    {:cross_domain_redirect, final_host != URI.parse(original_url).host}
  end

  if @mix_env == :test do
    defp get_final_id(nil, initial_url), do: initial_url
    defp get_final_id("", initial_url), do: initial_url
  end

  defp get_final_id(final_url, _intial_url) do
    final_url
  end

  @doc "Do NOT use; only public for use in tests"
  def get_object(id) do
    date = Pleroma.Signature.signed_date()

    headers =
      [
        # The first is required by spec, the second provided as a fallback for buggy implementations
        {"accept", "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""},
        {"accept", "application/activity+json"}
      ]
      |> maybe_date_fetch(date)
      |> sign_fetch(id, date)

	    with {:ok, %{body: body, status: code, headers: headers, url: final_url}}
         when code in 200..299 <-
           HTTP.get(id, headers),
	         remote_host <-
           URI.parse(final_url).host,
         {:cross_domain_redirect, false} <-
           check_crossdomain_redirect(remote_host, id),
         {:has_content_type, {_, content_type}} <-
           {:has_content_type, List.keyfind(headers, "content-type", 0)},
         {:parse_content_type, {:ok, "application", subtype, type_params}} <-
           {:parse_content_type, Plug.Conn.Utils.media_type(content_type)} do
      final_id = get_final_id(final_url, id)

      case {subtype, type_params} do
        {"activity+json", _} ->
          {:ok, final_id, body}

        {"ld+json", %{"profile" => "https://www.w3.org/ns/activitystreams"}} ->
          {:ok, final_id, body}

        _ ->
          {:error, {:content_type, content_type}}
      end
    else
      {:ok, %{status: code}} when code in [401, 403] ->
        {:error, :forbidden}

      {:ok, %{status: code}} when code in [404, 410] ->
        {:error, :not_found}

      {:error, e} ->
        {:error, e}

      {:has_content_type, _} ->
        {:error, {:content_type, nil}}

      {:parse_content_type, e} ->
        {:error, {:content_type, e}}

      e ->
        {:error, e}
    end
  end

  defp safe_json_decode(nil), do: {:ok, nil}
  defp safe_json_decode(json), do: Jason.decode(json)
end
