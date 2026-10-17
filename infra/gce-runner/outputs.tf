output "runner_service_account" {
  description = "Service account attached to runner VMs (used by cm via ADC)."
  value       = google_service_account.runner.email
}

output "psc_endpoint_ip" {
  description = "Private Service Connect IP that *.googleapis.com resolves to inside the VPC."
  value       = google_compute_global_address.psc_apis.address
}

output "mig_name" {
  description = "Managed Instance Group running the ephemeral runners."
  value       = google_compute_instance_group_manager.runner.name
}

output "runs_on_labels" {
  description = "Use this in the workflow's runs-on."
  value       = concat(["self-hosted", "linux"], var.runner_labels)
}

output "next_steps" {
  value = <<-EOT
    1. Add the GitHub token (never via tfvars):
         printf '%s' "$GH_PAT" | gcloud secrets versions add ${var.github_pat_secret_id} --data-file=- --project ${var.project_id}
    2. (Re)create the runners so they pick the token up:
         gcloud compute instance-groups managed rolling-action replace ${google_compute_instance_group_manager.runner.name} --zone ${var.zone} --project ${var.project_id}
    3. Confirm a runner is Idle under https://github.com/${var.github_repo}/settings/actions/runners
    4. Trigger .github/workflows/codemender-cicd-gcp.yml
    5. Debug a VM (no public IP, IAP tunnel only):
         gcloud compute ssh codemender-runner-XXXX --zone ${var.zone} --tunnel-through-iap -- sudo tail -f /var/log/codemender-runner.log
  EOT
}
