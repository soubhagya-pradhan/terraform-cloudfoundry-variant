locals {
  empty_remote_write  = yamlencode(jsondecode("{ \"remote_write\": null}"))
  remote_write_config = var.mtls_private_key != "" ? local.remote_write_tls_config : (var.remote_write_config == "" ? local.empty_remote_write : var.remote_write_config)
  mtls_env_variable   = var.mtls_private_key == "" ? {} : { "MTLS_PRIVATE_KEY" : "${var.mtls_private_key}", "MTLS_CERT" : "${var.mtls_cert}" }
  command             = var.mtls_private_key == "" ? "echo $PROMETHEUS_CONFIG_BASE64|base64 -d > /sidecars/etc/prometheus.default.yml && supervisord --nodaemon --configuration /etc/supervisord.conf" : "echo $PROMETHEUS_CONFIG_BASE64|base64 -d > /sidecars/etc/prometheus.default.yml && echo $MTLS_CERT|base64 -d > /sidecars/etc/cert.crt && echo $MTLS_PRIVATE_KEY|base64 -d > /sidecars/etc/private.key && supervisord --nodaemon --configuration /etc/supervisord.conf"
  prometheus_routes   = var.prometheus_public_endpoints ? [cloudfoundry_route.prometheus.id, cloudfoundry_route.prometheus_internal.id] : [cloudfoundry_route.prometheus_internal.id]
  postfix             = var.name_postfix != "" ? var.name_postfix : random_id.id.hex
  prometheus_config = templatefile("${path.module}/templates/prometheus.yml", {
    alertmanagers       = var.alertmanagers_endpoints
    remote_write_config = local.remote_write_config
    external_labels     = var.external_labels
    scrape_interval     = var.prometheus_scrape_interval
    evaluation_interval = var.prometheus_evaluation_interval
  })
  remote_write_tls_config = templatefile("${path.module}/templates/remote_write_tls.yaml",
  { remote_write_url = var.remote_write_url })
}

resource "random_id" "id" {
  byte_length = 4
}

resource "random_password" "password" {
  length = 16
}

resource "cloudfoundry_app" "prometheus" {
  name         = "tf-prometheus-${local.postfix}"
  space        = var.cf_space_id
  memory       = var.prometheus_memory
  disk_quota   = var.prometheus_disk_quota
  docker_image = var.variant_image
  docker_credentials = {
    username = var.docker_username
    password = var.docker_password
  }
  command = local.command
  environment = merge({
    PROMETHEUS_CONFIG_BASE64   = base64encode(local.prometheus_config)
    USERNAME                   = var.cf_functional_account.username
    PASSWORD                   = var.cf_functional_account.password
    API_ENDPOINT               = var.cf_functional_account.api_endpoint
    VARIANT_API_ENDPOINT       = var.cf_functional_account.api_endpoint
    VARIANT_USERNAME           = var.cf_functional_account.username
    VARIANT_PASSWORD           = var.cf_functional_account.password
    VARIANT_INTERNAL_DOMAIN_ID = data.cloudfoundry_domain.apps_internal_domain.id
    VARIANT_PROMETHEUS_CONFIG  = "/sidecars/etc/prometheus.yml"
    VARIANT_TENANTS            = join(",", var.tenants)
    VARIANT_SPACES             = join(",", var.spaces)
    VARIANT_RELOAD             = "true"
  }, local.mtls_env_variable, var.environment)

  dynamic "routes" {
    for_each = local.prometheus_routes
    content {
      route = routes.value
    }
  }
}

resource "cloudfoundry_route" "prometheus" {
  domain   = data.cloudfoundry_domain.app_domain.id
  space    = var.cf_space_id
  hostname = "prometheus-${local.postfix}"
}

resource "cloudfoundry_route" "prometheus_internal" {
  domain   = data.cloudfoundry_domain.apps_internal_domain.id
  space    = var.cf_space_id
  hostname = "prometheus-${local.postfix}"
}

resource "cloudfoundry_network_policy" "prometheus" {
  count = length(var.network_policies) > 0 ? 1 : 0

  dynamic "policy" {
    for_each = [for p in var.network_policies : {
      destination_app = p.destination_app
      port            = p.port
      protocol        = p.protocol
    }]
    content {
      source_app      = cloudfoundry_app.prometheus.id
      destination_app = policy.value.destination_app
      protocol        = policy.value.protocol == "" ? "tcp" : policy.value.protocol
      port            = policy.value.port
    }
  }
}
