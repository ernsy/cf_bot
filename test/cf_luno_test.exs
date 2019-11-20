defmodule CfBotTest do
  use ExUnit.Case
  doctest CfBot

  test "greets the world" do
    assert CfBot.hello() == :world
  end
end
