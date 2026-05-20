defmodule Pid.MixProject do
  use Mix.Project

  def project do
    [
      app: :pid,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      usage_rules: usage_rules()
    ]
  end

  def application do
    [
      mod: {Pid.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:usage_rules, "~> 1.0", only: [:dev, :test]},
      {:pid_controller, "~> 0.1.3"},
      {:cubdb, "~> 2.0"},
      {:jason, "~> 1.2"},
      {:emqtt, github: "emqx/emqtt", tag: "1.14.6", system_env: [{"BUILD_WITHOUT_QUIC", "1"}]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false},
      {:credence, "~> 0.4.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "usage_rules.sync",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:usage_rules],
      skills: [
        build: [
          cubdb: [
            description:
              "Use this skill when reading or writing persistent state via CubDB. Consult when working with Pid.Store or any CubDB.start_link/get/put calls.",
            usage_rules: [:cubdb]
          ],
          "pid-controller": [
            description:
              "Use this skill when working with the PidController struct — new/2, set_setpoint/2, output/2. Consult before changing the PI calculation.",
            usage_rules: [:pid_controller]
          ]
        ]
      ]
    ]
  end
end
