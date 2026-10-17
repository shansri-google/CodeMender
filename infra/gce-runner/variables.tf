variable "project_id" {
  description = "GCP project that hosts the runner VMs and Vertex AI (CodeMender)."
  type        = string
}

variable "region" {
  description = "Region for the VPC subnet, Cloud Router and NAT."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the zonal Managed Instance Group."
  type        = string
  default     = "us-central1-a"
}

variable "github_repo" {
  description = "GitHub repository (owner/name) the runners register against."
  type        = string
  default     = "shansri-google/CodeMender"
}

variable "github_pat_secret_id" {
  description = <<-EOT
    Secret Manager secret ID that holds a GitHub token able to mint runner
    registration tokens for `github_repo` (classic PAT with `repo` scope, or a
    fine-grained PAT with Repository -> Administration: Read & write).
    Terraform creates the empty secret; you add the version out-of-band so the
    token never lands in state or tfvars.
  EOT
  type        = string
  default     = "github-runner-pat"
}

variable "runner_labels" {
  description = "Custom labels advertised by the runner (self-hosted/linux/x64 are added automatically)."
  type        = list(string)
  default     = ["gcp", "codemender"]
}

variable "runner_count" {
  description = "Number of warm ephemeral runner VMs the MIG keeps alive. Each VM runs exactly one job, then recreates itself."
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "Machine type for runner VMs."
  type        = string
  default     = "e2-standard-4"
}

variable "boot_disk_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 50
}

variable "subnet_cidr" {
  description = "Primary CIDR for the private runner subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "psc_endpoint_ip" {
  description = "Internal IP for the Private Service Connect endpoint to Google APIs. Must NOT overlap any subnet."
  type        = string
  default     = "10.255.0.5"
}

variable "egress_allow_cidrs" {
  description = <<-EOT
    Destination CIDRs the runner may reach on tcp/80+443 via Cloud NAT (in
    addition to the PSC endpoint for Google APIs). The runner MUST reach
    github.com, api.github.com, *.actions.githubusercontent.com and
    objects.githubusercontent.com. GitHub publishes >7k CIDRs for Actions and
    none for the Azure-hosted runner endpoints, so an IP allowlist is not
    practical; default is 0.0.0.0/0 with the port restriction as the control.
    For hostname-based allowlisting put Secure Web Proxy in front and narrow
    this to the proxy IP (see README).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_iap_ssh" {
  description = "Allow SSH (tcp/22) from the Identity-Aware Proxy range only. No other ingress is ever opened."
  type        = bool
  default     = true
}
