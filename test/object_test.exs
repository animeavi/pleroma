defmodule Pleroma.ObjectTest do
  use Pleroma.DataCase
  import Pleroma.Factory
  alias Pleroma.{Repo, Object}

  test "returns an object by it's AP id" do
    object = insert(:note)
    found_object = Object.get_by_ap_id(object.data["id"])

    assert object == found_object
  end

  describe "generic changeset" do
    test "it ensures uniqueness of the id" do
      object = insert(:note)
      cs = Object.change(%Object{}, %{data: %{id: object.data["id"]}})
      assert cs.valid?

      {:error, _result} = Repo.insert(cs)
    end
  end

  describe "deletion function" do
    test "deletes an object" do
      object = insert(:note)
      found_object = Object.get_by_ap_id(object.data["id"])

      assert object == found_object

      Object.delete(found_object)

      found_object = Object.get_by_ap_id(object.data["id"])

      refute object == found_object
    end

    test "ensures cache is cleared for the object" do
      object = insert(:note)
      cached_object = Object.get_cached_by_ap_id(object.data["id"])

      assert object == cached_object

      Object.delete(cached_object)

      {:ok, nil} = Cachex.get(:user_cache, "object:#{object.data["id"]}")

      cached_object = Object.get_cached_by_ap_id(object.data["id"])

      refute object == cached_object
    end
  end
end
