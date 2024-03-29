# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.StaticFE.StaticFEControllerTest do
  use Pleroma.Web.ConnCase, async: false

  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  setup_all do: clear_config([:static_fe, :enabled], true)

  setup %{conn: conn} do
    conn = put_req_header(conn, "accept", "text/html")
    user = insert(:user)

    %{conn: conn, user: user}
  end

  describe "user profile html" do
    test "just the profile as HTML", %{conn: conn, user: user} do
      conn = get(conn, "/users/#{user.nickname}")

      assert html_response(conn, 200) =~ user.nickname
    end

    test "404 when user not found", %{conn: conn} do
      conn = get(conn, "/users/limpopo")

      assert html_response(conn, 404) =~ "not found"
    end

    test "profile does not include private messages", %{conn: conn, user: user} do
      CommonAPI.post(user, %{status: "public"})
      CommonAPI.post(user, %{status: "private", visibility: "private"})

      conn = get(conn, "/users/#{user.nickname}")

      html = html_response(conn, 200)

      assert html =~ "\npublic\n"
      refute html =~ "\nprivate\n"
    end

    test "main page does not include replies", %{conn: conn, user: user} do
      {:ok, op} = CommonAPI.post(user, %{status: "beep"})
      CommonAPI.post(user, %{status: "boop", in_reply_to_id: op})

      conn = get(conn, "/users/#{user.nickname}")

      html = html_response(conn, 200)

      assert html =~ "\nbeep\n"
      refute html =~ "\nboop\n"
    end

    test "media page only includes posts with attachments", %{conn: conn, user: user} do
      file = %Plug.Upload{
        content_type: "image/jpeg",
        path: Path.absname("test/fixtures/image.jpg"),
        filename: "an_image.jpg"
      }

      {:ok, %{id: media_id}} = ActivityPub.upload(file, actor: user.ap_id)

      CommonAPI.post(user, %{status: "virgin text post"})
      CommonAPI.post(user, %{status: "chad post with attachment", media_ids: [media_id]})

      conn = get(conn, "/users/#{user.nickname}/media")

      html = html_response(conn, 200)

      assert html =~ "\nchad post with attachment\n"
      refute html =~ "\nvirgin text post\n"
    end

    test "show follower list", %{conn: conn, user: user} do
      follower = insert(:user)
      CommonAPI.follow(follower, user)

      conn = get(conn, "/users/#{user.nickname}/followers")

      html = html_response(conn, 200)

      assert html =~ "user-card"
    end

    test "don't show followers if hidden", %{conn: conn, user: user} do
      follower = insert(:user)
      CommonAPI.follow(follower, user)

      {:ok, user} =
        user
        |> User.update_changeset(%{hide_followers: true})
        |> User.update_and_set_cache()

      conn = get(conn, "/users/#{user.nickname}/followers")

      html = html_response(conn, 200)

      refute html =~ "user-card"
    end

    test "pagination", %{conn: conn, user: user} do
      Enum.map(1..30, fn i -> CommonAPI.post(user, %{status: "test#{i}"}) end)

      conn = get(conn, "/users/#{user.nickname}")

      html = html_response(conn, 200)

      assert html =~ "\ntest30\n"
      assert html =~ "\ntest11\n"
      refute html =~ "\ntest10\n"
      refute html =~ "\ntest1\n"
    end

    test "pagination, page 2", %{conn: conn, user: user} do
      activities = Enum.map(1..30, fn i -> CommonAPI.post(user, %{status: "test#{i}"}) end)
      {:ok, a11} = Enum.at(activities, 11)

      conn = get(conn, "/users/#{user.nickname}?max_id=#{a11.id}")

      html = html_response(conn, 200)

      assert html =~ "\ntest1\n"
      assert html =~ "\ntest10\n"
      refute html =~ "\ntest20\n"
      refute html =~ "\ntest29\n"
    end

    test "does not require authentication on non-federating instances", %{
      conn: conn,
      user: user
    } do
      clear_config([:instance, :federating], false)

      conn = get(conn, "/users/#{user.nickname}")

      assert html_response(conn, 200) =~ user.nickname
    end

    test "returns 404 for local user with `restrict_unauthenticated/profiles/local` setting", %{
      conn: conn
    } do
      clear_config([:restrict_unauthenticated, :profiles, :local], true)

      local_user = insert(:user, local: true)

      conn
      |> get("/users/#{local_user.nickname}")
      |> html_response(404)
    end
  end

  describe "notice html" do
    test "single notice page", %{conn: conn, user: user} do
      {:ok, activity} = CommonAPI.post(user, %{status: "testing a thing!"})

      conn = get(conn, "/notice/#{activity.id}")

      html = html_response(conn, 200)
      assert html =~ "<div class=\"panel conversation\">"
      assert html =~ user.nickname
      assert html =~ "testing a thing!"
    end

    test "redirects to json if requested", %{conn: conn, user: user} do
      {:ok, activity} = CommonAPI.post(user, %{status: "testing a thing!"})

      conn =
        conn
        |> put_req_header(
          "accept",
          "Accept: application/activity+json, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\", text/html"
        )
        |> get("/notice/#{activity.id}")

      assert redirected_to(conn, 302) =~ activity.data["object"]
    end

    test "filters HTML tags", %{conn: conn} do
      user = insert(:user)
      {:ok, activity} = CommonAPI.post(user, %{status: "<script>alert('xss')</script>"})

      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/notice/#{activity.id}")

      html = html_response(conn, 200)
      assert html =~ ~s[&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;]
    end

    test "shows the whole thread", %{conn: conn, user: user} do
      {:ok, activity} = CommonAPI.post(user, %{status: "space: the final frontier"})

      CommonAPI.post(user, %{
        status: "these are the voyages or something",
        in_reply_to_status_id: activity.id
      })

      conn = get(conn, "/notice/#{activity.id}")

      html = html_response(conn, 200)
      assert html =~ "the final frontier"
      assert html =~ "voyages"
    end

    test "redirect by AP object ID", %{conn: conn, user: user} do
      {:ok, %Activity{data: %{"object" => object_url}}} =
        CommonAPI.post(user, %{status: "beam me up"})

      conn = get(conn, URI.parse(object_url).path)

      assert html_response(conn, 302) =~ "redirected"
    end

    test "redirect by activity ID", %{conn: conn, user: user} do
      {:ok, %Activity{data: %{"id" => id}}} =
        CommonAPI.post(user, %{status: "I'm a doctor, not a devops!"})

      conn = get(conn, URI.parse(id).path)

      assert html_response(conn, 302) =~ "redirected"
    end

    test "404 when notice not found", %{conn: conn} do
      conn = get(conn, "/notice/88c9c317")

      assert html_response(conn, 404) =~ "not found"
    end

    test "404 for private status", %{conn: conn, user: user} do
      {:ok, activity} = CommonAPI.post(user, %{status: "don't show me!", visibility: "private"})

      conn = get(conn, "/notice/#{activity.id}")

      assert html_response(conn, 404) =~ "not found"
    end

    test "302 for remote cached status", %{conn: conn, user: user} do
      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "actor" => user.ap_id,
        "object" => %{
          "to" => user.follower_address,
          "cc" => "https://www.w3.org/ns/activitystreams#Public",
          "id" => Utils.generate_object_id(),
          "content" => "blah blah blah",
          "type" => "Note",
          "attributedTo" => user.ap_id
        }
      }

      assert {:ok, activity} = Transmogrifier.handle_incoming(message)

      conn = get(conn, "/notice/#{activity.id}")

      assert html_response(conn, 302) =~ "redirected"
    end

    test "does not require authentication on non-federating instances", %{
      conn: conn,
      user: user
    } do
      clear_config([:instance, :federating], false)

      {:ok, activity} = CommonAPI.post(user, %{status: "testing a thing!"})

      conn = get(conn, "/notice/#{activity.id}")

      assert html_response(conn, 200) =~ "testing a thing!"
    end

    test "returns 404 for local public activity with `restrict_unauthenticated/activities/local` setting",
         %{conn: conn, user: user} do
      clear_config([:restrict_unauthenticated, :activities, :local], true)

      {:ok, activity} = CommonAPI.post(user, %{status: "testing a thing!"})

      conn
      |> get("/notice/#{activity.id}")
      |> html_response(404)
    end
  end
end
