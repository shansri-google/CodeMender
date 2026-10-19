# ------------------------------------------------------------------------------
# Identity. The VM's attached service account IS the GCP identity for the
# pipeline: `cm` picks it up via ADC from the metadata server, so the workflow
# no longer needs the GitHub-OIDC -> WIF exchange.
# ------------------------------------------------------------------------------
resource "google_service_account" "runner" {
  account_id   = "codemender-runner-sa"
  display_name = "CodeMender self-hosted GitHub Actions runner"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "runner_roles" {
  for_each = toset([
    "roles/aiplatform.user",   # CodeMender agent on Vertex AI
    "roles/logging.logWriter", # Ops Agent / startup-script logs
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.runner.email}"
}

# Ephemeral runners delete themselves after one job so the MIG replaces them
# with a clean VM. Scope that power to instances with our own name prefix.
resource "google_project_iam_member" "runner_self_delete" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.runner.email}"

  condition {
    title       = "only-codemender-runner-instances"
    description = "Restrict delete to VMs created by the runner MIG"
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/zones/${var.zone}/instances/codemender-runner-\")"
  }
}

# ------------------------------------------------------------------------------
# GitHub token lives in Secret Manager. Terraform only creates the container;
# add the version with:
#   printf '%s' "$GH_PAT" | gcloud secrets versions add github-runner-pat --data-file=-
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "github_pat" {
  secret_id = var.github_pat_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "runner_reads_pat" {
  secret_id = google_secret_manager_secret.github_pat.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

# ------------------------------------------------------------------------------
# Instance template + zonal MIG. The MIG keeps `runner_count` warm VMs; each
# registers with --ephemeral, runs exactly one job, then deletes itself, and
# the MIG recreates it. Net effect: GitHub-hosted-style isolation, on GCE.
# ------------------------------------------------------------------------------
resource "google_compute_instance_template" "runner" {
  name_prefix  = "codemender-runner-"
  machine_type = var.machine_type
  tags         = [local.runner_tag]

  disk {
    source_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    auto_delete  = true
    boot         = true
    disk_size_gb = var.boot_disk_gb
    disk_type    = "pd-balanced"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runner.self_link
    # Deliberately no access_config block => no external IP.
  }

  service_account {
    email  = google_service_account.runner.email
    scopes = ["cloud-platform"] # IAM roles, not scopes, bound the real permissions
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script = templatefile("${path.module}/scripts/runner-startup.sh", {
      github_repo          = var.github_repo
      project_id           = var.project_id
      github_pat_secret_id = var.github_pat_secret_id
      runner_labels        = join(",", var.runner_labels)
    })
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_project_iam_member.runner_roles,
    google_secret_manager_secret_iam_member.runner_reads_pat,
  ]
}

resource "google_compute_instance_group_manager" "runner" {
  name               = "codemender-runner-mig"
  zone               = var.zone
  base_instance_name = "codemender-runner"
  target_size        = var.runner_count

  version {
    instance_template = google_compute_instance_template.runner.id
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }
}
