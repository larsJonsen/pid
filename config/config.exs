import Config

config :pid, :mqtt,
  host: ~c"localhost",
  port: 1883,
  group: "drejø",
  co2_device: "scd_2",
  pwm_device: "pwm_1"

config :pid, :store, data_dir: "priv/pid_state"

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

import_config "#{config_env()}.exs"
