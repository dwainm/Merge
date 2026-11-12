defmodule MergeWeb.FileComponent do
  @moduledoc """
  One file of a merge request's diff, as a piece of its own.

  A big diff runs to tens of thousands of elements. Sent whole with the page,
  nothing could be painted until all of it was in and built: seconds on a
  phone. As pieces, the page paints first with each file's name and counts
  (`loaded` false), the files follow a few at a time, one that starts folded
  only when it is opened, and a picked line or a new comment sends its own
  file again and no other. Events in it still go to the page, which handles
  "pick", "line_comment" and "open_file".
  """

  use MergeWeb, :live_component

  import MergeWeb.MergeRequestComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.diff_file
        file={@file}
        index={@index}
        stacked={@stacked}
        loaded={@loaded}
        line_comments={@line_comments}
        picked={@picked}
        form={@form}
        commentable={@commentable}
      />
    </div>
    """
  end
end
