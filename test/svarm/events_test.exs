defmodule Svarm.EventsTest do
  use ExUnit.Case, async: false

  alias Svarm.Events

  test "broadcast delivers to subscriber" do
    Events.subscribe()

    assert :ok =
             Phoenix.PubSub.broadcast(Svarm.PubSub, Events.topic(), {:ping, :test})

    assert_receive {:ping, :test}, 500
  end
end
