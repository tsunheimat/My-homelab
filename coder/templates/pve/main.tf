terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {
}

#k8s settings
variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
  default     = false
}

#k8s settings
variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces). If the Coder host is itself running as a Pod on the same Kubernetes cluster as you are deploying workspaces to, set this to the same namespace."
  default = "coder"
}

#k8s settings
data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
  option {
    name  = "16 Cores"
    value = "16"
  }
}

#k8s settings
data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory in GB"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB"
    value = "8"
  }

}

#k8s settings
data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "The size of the home disk in GB"
  default      = "20"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 99999
  }
}

#nfs server ip
data "coder_parameter" "nfs_server" {
  name         = "nfs_server"
  type         = "string"
  display_name = "NFS Server IP"
  description  = "The NFS server IP address to use for the workspace"
  default = "10.0.100.240"
}

#nfs share path
data "coder_parameter" "nfs_mount_path" {
  name         = "nfs_mount_path"
  type         = "string"
  display_name = "NFS Mount Path"
  description  = "The path in your workspace container to mount the NFS share to"
  default      = "/srv/sharing/cd6/files/vibe-coding-share"
  validation {
    regex = "^/[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$"
    error = "NFS mount path must be a valid path in your workspace container"
  }
}

#codex setting

data "coder_parameter" "codex_base_url" {
  name         = "codex_base_url"
  display_name = "Codex Base URL"
  description  = "The custom base URL for the Codex OpenAI provider."
  default      = "https://sub2api-hub.tsunhei.com"
  type         = "string"
  mutable      = true 
}

data "coder_parameter" "openai_api_key" {
  name         = "openai_api_key"
  display_name = "OpenAI API Key"
  description  = "OpenAI API Key for Codex"
  type         = "string"
  mutable      = true
}


#k8s settings
provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

#application: vscode
module "vscode-web" {
  #count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/vscode-web/coder"
  version        = "1.5.0"
  agent_id       = coder_agent.main.id
  subdomain      = false
  accept_license = true
  display_name  = "vscode-web"
  extensions = ["openai.chatgpt","kilocode.kilo-code","eamodio.gitlens"]
  folder = "/home/coder/repos"
  use_cached = true
  
}

#application: code-server
module "code-server" {
  #count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/code-server/coder"
  version        = "1.4.2"
  agent_id       = coder_agent.main.id
  subdomain      = false
  additional_args = "--disable-workspace-trust"
  open_in = "tab"
  folder = "/home/coder/repos"
  extensions = ["kilocode.kilo-code","eamodio.gitlens"]
  use_cached = true
  use_cached_extensions = true
}

#application: filebrowser
module "filebrowser" {
  #count      = data.coder_workspace.me.start_count
  source     = "registry.coder.com/coder/filebrowser/coder"
  version    = "1.1.4"
  agent_id   = coder_agent.main.id
  agent_name = "main"
  folder   = "/home/coder/repos"
  subdomain  = false
}



module "codex" {
  source         = "registry.coder.com/coder-labs/codex/coder"
  version        = "4.3.1"
  agent_id       = coder_agent.main.id
  workdir        = "/home/coder/repos"
  openai_api_key = data.coder_parameter.openai_api_key.value
  continue = true

  enable_state_persistence = false
  
base_config_toml = replace(<<-EOT
model_provider = "OpenAI"
model = "gpt-5.4"
review_model = "gpt-5.4"
model_reasoning_effort = "high"
disable_response_storage = true
network_access = "enabled"
windows_wsl_setup_acknowledged = true
model_context_window = 1000000
model_auto_compact_token_limit = 900000
approvals_reviewer = "user"

sandbox_mode = "danger-full-access"
approval_policy = "never"
preferred_auth_method = "apikey"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "${data.coder_parameter.codex_base_url.value}"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true

[features]
responses_websockets_v2 = true

[projects."/home/coder/repos"]
trust_level = "trusted"

[projects."/home/coder"]
trust_level = "trusted"

[notice]
hide_full_access_warning = true
EOT
  , "\r", "") # This tells Terraform to replace all carriage returns with nothing
}


module "git-config" {
  #count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/git-config/coder"
  version  = "1.0.33" # Use the latest version
  
  agent_id = coder_agent.main.id 
  
  # Disabling these hides the UI prompts and forces automatic configuration
  allow_username_change = false
  allow_email_change    = false
}


#main resource
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }
}


#k8s storage
resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.name}-${substr(data.coder_workspace.me.id, 0, 6)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace-home"
      "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.name}-${substr(data.coder_workspace.me.id, 0, 6)}"
      "app.kubernetes.io/part-of"  = "coder"
      //Coder-specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

#k8s deploy
resource "kubernetes_deployment" "main" {
  #count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home
  ]
  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.name}-${substr(data.coder_workspace.me.id, 0, 6)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.name}-${substr(data.coder_workspace.me.id, 0, 6)}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.name}-${substr(data.coder_workspace.me.id, 0, 6)}"
        "app.kubernetes.io/part-of"  = "coder"
        "com.coder.resource"         = "true"
        "com.coder.workspace.id"     = data.coder_workspace.me.id
        "com.coder.workspace.name"   = data.coder_workspace.me.name

      }
    }
    strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.name}-${substr(data.coder_workspace.me.id, 0, 6)}"
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name

        }
      }
      spec {
        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }
        container {
          name              = "dev"
          image             = "codercom/example-node:ubuntu"
          image_pull_policy = "Always"
          command = ["sh", "-c",<<EOF
            # Restore default bash profile/dotfiles (without overwriting existing ones)
            cp -rn /etc/skel/. /home/coder/ || true
            
            # Create user and setup home directory
            mkdir -p /home/coder/coder-${data.coder_workspace.me.name} && \
            ${coder_agent.main.init_script}
            EOF
          ]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          resources {
            requests = {
              "cpu"    = "250m"
              "memory" = "512Mi"
            }
            limits = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }

          # nfs mounting for repo only
          volume_mount {
            name       = "nfs-repos"
            mount_path = "/home/coder/repos" # This is where your code lives
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
            read_only  = false
          }
        }

        volume {
          name = "nfs-repos"
          nfs {
            server = data.coder_parameter.nfs_server.value          # Your NFS server IP
            path   = data.coder_parameter.nfs_mount_path.value     # Your NFS path
            
            # Optional: Add /${data.coder_workspace.me.owner} to the path 
            # if you want individual isolated repo folders per user on the NFS.
          }
        }
      

        affinity {
          // This affinity attempts to spread out all workspace pods evenly across
          // nodes.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}