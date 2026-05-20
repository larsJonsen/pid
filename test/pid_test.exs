defmodule PidTest do
  use ExUnit.Case
  doctest Pid

  test "greets the world" do
    assert Pid.hello() == :world
  end
end
