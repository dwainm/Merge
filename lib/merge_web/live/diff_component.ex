defmodule MergeWeb.DiffComponent do
  @moduledoc """
  A merge request's diff: its groups and files, with the `comment` and
  `comment_form` slots passed through to each file.

  It is a LiveComponent so that the browser skips it when it hasn't changed. A
  big diff runs to a hundred thousand elements, and LiveView's client
  otherwise rebuilds and compares the whole page on every update: opening a
  dialog or each draft of a comment froze the page for seconds (more on a
  phone), and keys typed meanwhile were lost. Events in it still go to the
  page, which handles "pick" and "line_comment".
  """

  use MergeWeb, :live_component

  import MergeWeb.MergeRequestComponents

  alias Merge.Groups

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.diff_group :for={group <- @groups} group={group} headed={length(@groups) > 1}>
        <.diff_file
          :for={file <- group.files}
          file={file}
          index={file.index}
          stacked={length(@groups) > 1}
          quiet={Groups.quiet?(file)}
          line_comments={@line_comments}
          picked={@picked}
          commentable={@commentable}
        >
          <:comment :let={comment}>{render_slot(@comment, comment)}</:comment>
          <:comment_form>{render_slot(@comment_form)}</:comment_form>
        </.diff_file>
      </.diff_group>
    </div>
    """
  end
end
