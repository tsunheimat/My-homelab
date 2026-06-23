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

data "coder_parameter" "gitlab_host" {
  name         = "gitlab_host"
  display_name = "GitLab Host"
  description  = "The GitLab hostname used for Git HTTPS authentication."
  type         = "string"
  default      = "gitlab.tsunhei.com"
  mutable      = true
}

#k8s settings
provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_external_auth" "gitlab" {
  id = "gitlab"
}


# 1. Define the multi-select parameter
data "coder_parameter" "selected_apps" {
  name         = "selected_apps"
  display_name = "Workspace Applications"
  description  = "Select which applications you want to include in this workspace."
  type         = "list(string)"
  
  form_type = "multi-select"
  # Set your default selections here (must be JSON encoded)
  default      = jsonencode(["vscode", "vscode-web", "filebrowser"])
  mutable      = true # Allows users to add/remove apps later by editing the workspace
  
  option {
    name  = "VS Code Desktop"
    value = "vscode"
    icon  = local.vscode_desktop_icon
  }

  option {
    name  = "VS Code Web"
    value = "vscode-web"
    icon  = local.vscode_web_icon
  }

  option {
    name  = "Code Server"
    value = "code-server"
    icon  = local.code_server_icon
  }

  option {
    name  = "File Browser"
    value = "filebrowser"
    icon  = "/icon/folder.svg"
  }

}

# 2. Extract the list into a local variable for easy reading
locals {
  vscode_web_icon     = "https://cdn.jsdelivr.net/gh/tsunheimat/My-homelab@main/coder/icon/vscode-web-coder.svg"
  code_server_icon    = "https://cdn.jsdelivr.net/gh/tsunheimat/My-homelab@main/coder/icon/code-server-coder.svg"
  vscode_desktop_icon = "https://cdn.jsdelivr.net/gh/tsunheimat/My-homelab@main/coder/icon/vscode-desktop-coder.svg"

  apps_list = jsondecode(data.coder_parameter.selected_apps.value)
}


#application: VS Code Desktop
module "vscode-desktop" {
  count                  = contains(local.apps_list, "vscode") ? data.coder_workspace.me.start_count : 0
  source                 = "registry.coder.com/coder/vscode-desktop-core/coder"
  version                = "1.0.2"
  agent_id               = coder_agent.main.id
  coder_app_icon         = local.vscode_desktop_icon
  coder_app_slug         = "vscode"
  coder_app_display_name = "VS Code Desktop"
  coder_app_order        = 1
  folder                 = "/home/coder/repos"
  protocol               = "vscode"

}

#application: vscode-web
# Vendored module lives in coder/modules/vscode-web (single source of truth, shared across
# templates). Sourced over git so `coder templates push` works (local ../ paths outside the
# template dir are NOT uploaded in the push tarball). Pin ?ref to a tag for hard reproducibility.
module "vscode-web" {
  count          = contains(local.apps_list, "vscode-web") ? data.coder_workspace.me.start_count : 0
  source         = "git::https://github.com/tsunheimat/My-homelab.git//coder/modules/vscode-web?ref=main"
  agent_id       = coder_agent.main.id
  subdomain      = false
  accept_license = true
  display_name  = "vscode-web"
  icon          = local.vscode_web_icon
  extensions    = ["openai.chatgpt", "kilocode.kilo-code", "eamodio.gitlens"]
  folder        = "/home/coder/repos"
  use_cached    = true
}

#application: code-server
# Vendored module lives in coder/modules/code-server (see vscode-web note above).
module "code-server" {
  count           = contains(local.apps_list, "code-server") ? data.coder_workspace.me.start_count : 0
  source          = "git::https://github.com/tsunheimat/My-homelab.git//coder/modules/code-server?ref=main"
  agent_id        = coder_agent.main.id
  subdomain       = false
  additional_args = "--disable-workspace-trust"
  open_in         = "tab"
  display_name    = "code-server"
  icon            = local.code_server_icon
  folder          = "/home/coder/repos"
  extensions      = ["kilocode.kilo-code", "eamodio.gitlens"]
  use_cached      = true
  use_cached_extensions = true
}





#main resource
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  display_apps {
    vscode                = true
    vscode_insiders       = false
    web_terminal          = true
    ssh_helper            = true
    port_forwarding_helper = true
  }

  startup_script_behavior = "non-blocking"
  startup_script          = replace(<<-EOT
    set -e

    #rm -f "$HOME/.git-credentials"
    #rm -f "$(printf '%s\r' "$HOME/.git-credentials")"
    #git config --global credential.helper store
    #printf '%s\n' "https://oauth2:${data.coder_external_auth.gitlab.access_token}@${data.coder_parameter.gitlab_host.value}" > "$HOME/.git-credentials"
    #chmod 600 "$HOME/.git-credentials"
    git config --global user.name "${data.coder_workspace_owner.me.name}"
    git config --global user.email "${data.coder_workspace_owner.me.email}"
  EOT
  , "\r", "")

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
  count = data.coder_workspace.me.start_count
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
          command =  ["sh", "-c", coder_agent.main.init_script]

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
