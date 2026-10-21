defmodule PictureRail.ViewEventsTest do
  use ExUnit.Case, async: true

  alias PictureRail.View

  test "a value event with a fixed argument reaches its controller as one payload" do
    id = {"home_assistant", "url"}

    # as Emerge routes a text field's change: the element's message, then the text
    assert View.wrap_payload({:solve_event, :set, id}, "http://ha", :change) ==
             {:solve_event, :set, {id, "http://ha"}}

    # an event without an argument takes the value as its payload
    assert View.wrap_payload({:solve_event, :page}, 2, :change) == {:solve_event, :page, 2}

    # anything else is left to Emerge
    assert View.wrap_payload({:slider, "light.hall", :brightness}, 40, :change) ==
             {:slider, "light.hall", :brightness, 40}
  end
end
