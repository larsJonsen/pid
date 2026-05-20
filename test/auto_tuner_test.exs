defmodule Pid.AutoTunerTest do
  use ExUnit.Case, async: true

  alias Pid.AutoTuner

  defp feed(tuner, count, error) do
    Enum.reduce(1..count, tuner, fn _, t ->
      {_, new_t, _} = AutoTuner.step(error, t)
      new_t
    end)
  end

  test "starts with relay_high on first step regardless of error sign" do
    tuner = AutoTuner.new(relay_high: 800, relay_low: 100, hysteresis: 20)
    {output, _, status} = AutoTuner.step(50, tuner)
    assert output == 800
    assert status == :running
  end

  test "switches to relay_low when error crosses below negative hysteresis" do
    tuner = AutoTuner.new(relay_high: 800, relay_low: 100, hysteresis: 20)
    {_, tuner, _} = AutoTuner.step(50, tuner)
    {output, _, _} = AutoTuner.step(-30, tuner)
    assert output == 100
  end

  test "holds output within hysteresis band" do
    tuner = AutoTuner.new(relay_high: 800, relay_low: 100, hysteresis: 20)
    {_, tuner, _} = AutoTuner.step(50, tuner)
    # -10 is within the band [-20, 20]
    {output, _, _} = AutoTuner.step(-10, tuner)
    assert output == 800
  end

  test "returns :timeout after max_steps without enough crossings" do
    tuner = AutoTuner.new()

    tuner =
      Enum.reduce(1..299, tuner, fn _, t ->
        {_, new_t, _} = AutoTuner.step(100, t)
        new_t
      end)

    {_, _, status} = AutoTuner.step(100, tuner)
    assert status == :timeout
  end

  test "records a crossing when relay output flips" do
    tuner = AutoTuner.new(relay_high: 800, relay_low: 100, hysteresis: 5)
    {_, tuner, _} = AutoTuner.step(50, tuner)
    assert tuner.crossings == []
    {_, tuner, _} = AutoTuner.step(-30, tuner)
    assert length(tuner.crossings) == 1
  end

  test "completes with valid Kp and Ki after min_full_cycles" do
    tuner = AutoTuner.new(relay_high: 800, relay_low: 100, hysteresis: 5, min_full_cycles: 3)

    # 7 half-cycles of 10 steps each → 6 crossings (not yet done)
    half_cycles = [{10, 50}, {10, -50}, {10, 50}, {10, -50}, {10, 50}, {10, -50}, {10, 50}]

    tuner =
      Enum.reduce(half_cycles, tuner, fn {n, err}, t ->
        feed(t, n, err)
      end)

    {_output, _tuner, status} = AutoTuner.step(-50, tuner)

    assert {:done, kp, ki} = status
    assert kp > 0
    assert ki > 0

    # Verify against known inputs: Tu=20 steps, a=50 ppm, d=350
    # Ku = 4*350 / (π*50) ≈ 8.913, Kp = 0.45*Ku ≈ 4.011, Ki = Kp*1.2/20 ≈ 0.241
    expected_ku = 4.0 * 350 / (:math.pi() * 50)
    assert_in_delta kp, 0.45 * expected_ku, 0.001
    assert_in_delta ki, 0.45 * expected_ku * 1.2 / 20, 0.001
  end

  test "does not complete before min_full_cycles" do
    tuner = AutoTuner.new(relay_high: 800, relay_low: 100, hysteresis: 5, min_full_cycles: 3)

    # Only 5 half-cycles → 4 crossings, not enough for 3 full cycles
    half_cycles = [{10, 50}, {10, -50}, {10, 50}, {10, -50}, {10, 50}]

    tuner =
      Enum.reduce(half_cycles, tuner, fn {n, err}, t ->
        feed(t, n, err)
      end)

    {_, _, status} = AutoTuner.step(-50, tuner)
    assert status == :running
  end
end
