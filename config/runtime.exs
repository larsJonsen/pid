import Config

config :pid, :mqtt,
  host: System.get_env("MQTT_HOST", "localhost") |> String.to_charlist(),
  port: System.get_env("MQTT_PORT", "1883") |> String.to_integer(),
  group: System.get_env("MQTT_GROUP", "drejø"),
  co2_device: System.get_env("MQTT_CO2_DEVICE", "scd_2"),
  pwm_device: System.get_env("MQTT_PWM_DEVICE", "pwm_1"),
  username: System.get_env("MQTT_USERNAME"),
  password: System.get_env("MQTT_PASSWORD")

config :pid, :store, data_dir: System.get_env("PID_STATE_DIR", "priv/pid_state")
