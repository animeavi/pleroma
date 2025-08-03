# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Mix.Tasks.Pleroma.Uploads do
  use Mix.Task
  import Mix.Pleroma
  import Ecto.Query
  alias Pleroma.Upload
  alias Pleroma.Uploaders.Local
  require Logger

  @log_every 50

  @shortdoc "Migrates uploads from local to remote storage"
  @moduledoc File.read!("docs/docs/administration/CLI_tasks/uploads.md")

  def run(["migrate_local", target_uploader | args]) do
    delete? = Enum.member?(args, "--delete")
    start_pleroma()
    local_path = Pleroma.Config.get!([Local, :uploads])
    uploader = Module.concat(Pleroma.Uploaders, target_uploader)

    unless Code.ensure_loaded?(uploader) do
      raise("The uploader #{inspect(uploader)} is not an existing/loaded module.")
    end

    target_enabled? = Pleroma.Config.get([Upload, :uploader]) == uploader

    unless target_enabled? do
      Pleroma.Config.put([Upload, :uploader], uploader)
    end

    shell_info("Migrating files from local #{local_path} to #{to_string(uploader)}")

    if delete? do
      shell_info(
        "Attention: uploaded files will be deleted, hope you have backups! (--delete ; cancel with ^C)"
      )

      :timer.sleep(:timer.seconds(5))
    end

    uploads =
      File.ls!(local_path)
      |> Enum.map(fn id ->
        root_path = Path.join(local_path, id)

        cond do
          File.dir?(root_path) ->
            files = for file <- File.ls!(root_path), do: {id, file, Path.join([root_path, file])}

            case List.first(files) do
              {id, file, path} ->
                {%Pleroma.Upload{id: id, name: file, path: id <> "/" <> file, tempfile: path},
                 root_path}

              _ ->
                nil
            end

          File.exists?(root_path) ->
            file = Path.basename(id)
            hash = Path.rootname(id)
            {%Pleroma.Upload{id: hash, name: file, path: file, tempfile: root_path}, root_path}

          true ->
            nil
        end
      end)
      |> Enum.filter(& &1)

    total_count = length(uploads)
    shell_info("Found #{total_count} uploads")

    uploads
    |> Task.async_stream(
      fn {upload, root_path} ->
        case Upload.store(upload, uploader: uploader, filters: [], size_limit: nil) do
          {:ok, _} ->
            if delete?, do: File.rm_rf!(root_path)
            Logger.debug("uploaded: #{inspect(upload.path)} #{inspect(upload)}")
            :ok

          error ->
            shell_error("failed to upload #{inspect(upload.path)}: #{inspect(error)}")
        end
      end,
      timeout: 150_000
    )
    |> Stream.chunk_every(@log_every)
    # credo:disable-for-next-line Credo.Check.Warning.UnusedEnumOperation
    |> Enum.reduce(0, fn done, count ->
      count = count + length(done)
      shell_info("Uploaded #{count}/#{total_count} files")
      count
    end)

    shell_info("Done!")
  end

  @doc """
  Rewrite media domains to somewhere new
  """
  def run(["rewrite_media_domain", from_domain, to_domain | args]) do
    dry_run = Enum.member?(args, "--dry-run")
    start_pleroma()
    IO.puts("Rewriting media domain from #{from_domain} to #{to_domain}")
    IO.puts("Dry run: #{dry_run}")
    # actually selecting based on the attachment URL is stupidly difficult due to it being
    # stored as a JSONB array in the `data` field... the easier way to do this is just to iterate though
    # local posts
    from(o in Pleroma.Object)
    |> where([o], fragment("?->'url'->0->>'href' LIKE ?", o.data, ^"#{from_domain}%"))
    |> Pleroma.Repo.chunk_stream(100, :batches, timeout: :infinity)
    |> Stream.each(fn chunk ->
      # now we just rewrite it and save it back, ezpz
      chunk
      |> Enum.each(fn object ->
        IO.inspect(object)
        new_data =
          object
          |> Map.get(:data)
          |> Map.update!("url", fn urls ->
            Enum.map(urls, fn url ->
              Map.update!(url, "href", fn href ->
                new_uri = String.replace(href, from_domain, to_domain)
                check = URI.parse(new_uri)
                case check do
                  %URI{scheme: nil, host: nil} ->
                    raise("Invalid URL after rewriting: #{href}")

                  _ ->
                    new_uri
                end
              end)
            end)
          end)

        if dry_run do
          IO.puts("Dry run: would update object #{object.id} to new media domain (#{inspect(new_data["url"])})")
        else
          Pleroma.Repo.update!(Ecto.Changeset.change(object, data: new_data))
          IO.puts("Updated object #{object.id} to new media domain")
        end
      end)
    end)
    |> Stream.run()
  end
end
