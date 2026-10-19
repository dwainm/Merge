defmodule GitasticWeb.RedirectController do
  @moduledoc """
  Any other page (there is no sign-in, so a habit-typed `/login` among them)
  goes to the list of merge requests.
  """

  use GitasticWeb, :controller

  def home(conn, _params), do: redirect(conn, to: ~p"/")
end
