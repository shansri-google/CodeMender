# ------------------------------------------------------------------------------
# Private VPC for the runners. No default network, no auto subnets.
# ------------------------------------------------------------------------------
resource "google_compute_network" "runner" {
  name                    = "codemender-runner-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required]
}

resource "google_compute_subnetwork" "runner" {
  name                     = "codemender-runner-subnet"
  region                   = var.region
  network                  = google_compute_network.runner.self_link
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ------------------------------------------------------------------------------
# Private Service Connect endpoint for Google APIs (Vertex AI, Secret Manager,
# IAM, Logging ...). Traffic to *.googleapis.com never leaves Google's network.
# ------------------------------------------------------------------------------
resource "google_compute_global_address" "psc_apis" {
  name         = "codemender-psc-apis"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  address      = var.psc_endpoint_ip
  network      = google_compute_network.runner.self_link
}

resource "google_compute_global_forwarding_rule" "psc_apis" {
  # PSC-for-Google-APIs names must be 1-20 chars, lowercase letters + digits only.
  name                  = "cmpscapis"
  target                = "all-apis"
  network               = google_compute_network.runner.self_link
  ip_address            = google_compute_global_address.psc_apis.id
  load_balancing_scheme = ""
}

# Private DNS so googleapis.com resolves to the PSC endpoint inside the VPC.
resource "google_dns_managed_zone" "googleapis" {
  name        = "codemender-googleapis"
  dns_name    = "googleapis.com."
  description = "Route Google API traffic to the PSC endpoint"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.runner.self_link
    }
  }
}

resource "google_dns_record_set" "googleapis_a" {
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.psc_apis.address]
}

resource "google_dns_record_set" "googleapis_wildcard" {
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["googleapis.com."]
}

# ------------------------------------------------------------------------------
# Cloud NAT: the only path to the public internet (GitHub). VMs have no
# external IP, so nothing can initiate a connection inbound.
# ------------------------------------------------------------------------------
resource "google_compute_router" "runner" {
  name    = "codemender-runner-router"
  region  = var.region
  network = google_compute_network.runner.self_link
}

resource "google_compute_router_nat" "runner" {
  name                               = "codemender-runner-nat"
  router                             = google_compute_router.runner.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.runner.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ------------------------------------------------------------------------------
# Firewall. Posture: deny all egress, then punch exactly two holes
# (PSC on 443, internet on 80/443). Ingress is implied-deny; only IAP SSH.
# ------------------------------------------------------------------------------
locals {
  runner_tag = "codemender-runner"
}

resource "google_compute_firewall" "deny_all_egress" {
  name      = "codemender-runner-deny-all-egress"
  network   = google_compute_network.runner.name
  direction = "EGRESS"
  priority  = 65000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.runner_tag]
}

resource "google_compute_firewall" "allow_egress_psc" {
  name      = "codemender-runner-allow-egress-psc"
  network   = google_compute_network.runner.name
  direction = "EGRESS"
  priority  = 100

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["${var.psc_endpoint_ip}/32"]
  target_tags        = [local.runner_tag]
}

# tcp/80 is needed only for apt on first boot (Ubuntu mirrors are http).
# Bake a custom image with the runner preinstalled to drop port 80 entirely.
resource "google_compute_firewall" "allow_egress_internet" {
  name      = "codemender-runner-allow-egress-internet"
  network   = google_compute_network.runner.name
  direction = "EGRESS"
  priority  = 200

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  destination_ranges = var.egress_allow_cidrs
  target_tags        = [local.runner_tag]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  count     = var.enable_iap_ssh ? 1 : 0
  name      = "codemender-runner-allow-iap-ssh"
  network   = google_compute_network.runner.name
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google's fixed IAP TCP-forwarding range.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.runner_tag]
}
