import Config

if config_env() == :test do
  config :ash, :validate_domain_resource_inclusion?, false
  config :ash, :validate_domain_config_inclusion?, false
  config :ash, default_string_length_count: :codepoints
  config :logger, level: :warning
end
