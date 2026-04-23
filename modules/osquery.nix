{
  config,
  lib,
  pkgs,
  ...
}: {
  age.secrets.fleet-enroll-secret = {
    file = ../secrets/fleet-enroll-secret.age;
    mode = "0400";
  };

  services.osquery = {
    enable = true;
    settings = {
      options = {
        config_plugin = "tls";
        logger_plugin = "tls";
        enroll_tls_endpoint = "/api/osquery/enroll";
        config_tls_endpoint = "/api/osquery/config";
        config_refresh = "10";
        disable_distributed = "false";
        distributed_plugin = "tls";
        distributed_interval = "10";
        distributed_tls_max_attempts = "3";
        distributed_tls_read_endpoint = "/api/osquery/distributed/read";
        distributed_tls_write_endpoint = "/api/osquery/distributed/write";
        logger_tls_endpoint = "/api/osquery/log";
        logger_tls_period = "10";
      };
    };
    flags = {
      tls_hostname = "fleet.homelab.local";
      host_identifier = "hostname";
      enroll_secret_path = config.age.secrets.fleet-enroll-secret.path;
      tls_server_certs = "/etc/ssl/certs/ca-certificates.crt";
    };
  };
}
