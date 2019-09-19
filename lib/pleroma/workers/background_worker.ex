# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.BackgroundWorker do
  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.MRF.MediaProxyWarmingPolicy
  alias Pleroma.Web.OAuth.Token.CleanWorker

  use Pleroma.Workers.WorkerHelper, queue: "background"

  @impl Oban.Worker
  def perform(%{"op" => "fetch_initial_posts", "user_id" => user_id}, _job) do
    user = User.get_cached_by_id(user_id)
    User.perform(:fetch_initial_posts, user)
  end

  def perform(%{"op" => "deactivate_user", "user_id" => user_id, "status" => status}, _job) do
    user = User.get_cached_by_id(user_id)
    User.perform(:deactivate_async, user, status)
  end

  def perform(%{"op" => "delete_user", "user_id" => user_id}, _job) do
    user = User.get_cached_by_id(user_id)
    User.perform(:delete, user)
  end

  def perform(
        %{
          "op" => "blocks_import",
          "blocker_id" => blocker_id,
          "blocked_identifiers" => blocked_identifiers
        },
        _job
      ) do
    blocker = User.get_cached_by_id(blocker_id)
    User.perform(:blocks_import, blocker, blocked_identifiers)
  end

  def perform(
        %{
          "op" => "follow_import",
          "follower_id" => follower_id,
          "followed_identifiers" => followed_identifiers
        },
        _job
      ) do
    follower = User.get_cached_by_id(follower_id)
    User.perform(:follow_import, follower, followed_identifiers)
  end

  def perform(%{"op" => "clean_expired_tokens"}, _job) do
    CleanWorker.perform(:clean)
  end

  def perform(%{"op" => "media_proxy_preload", "message" => message}, _job) do
    MediaProxyWarmingPolicy.perform(:preload, message)
  end

  def perform(%{"op" => "media_proxy_prefetch", "url" => url}, _job) do
    MediaProxyWarmingPolicy.perform(:prefetch, url)
  end

  def perform(%{"op" => "fetch_data_for_activity", "activity_id" => activity_id}, _job) do
    activity = Activity.get_by_id(activity_id)
    Pleroma.Web.RichMedia.Helpers.perform(:fetch, activity)
  end
end
