defmodule Pleroma.Web.OStatus.UserRepresenter do
  alias Pleroma.User
  def to_simple_form(user) do
    ap_id = to_charlist(user.ap_id)
    nickname = to_charlist(user.nickname)
    name = to_charlist(user.name)
    bio = to_charlist(user.bio)
    avatar_url = to_charlist(User.avatar_url(user))
    [
      { :id, [ap_id] },
      { :"activity:object", ['http://activitystrea.ms/schema/1.0/person'] },
      { :uri, [ap_id] },
      { :"poco:preferredUsername", [nickname] },
      { :"poco:displayName", [name] },
      { :"poco:note", [bio] },
      { :name, [nickname] },
      { :link, [rel: 'avatar', href: avatar_url], []}
    ]
  end
end
