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


# 1. Define the multi-select parameter
data "coder_parameter" "selected_apps" {
  name         = "selected_apps"
  display_name = "Workspace Applications"
  description  = "Select which applications you want to include in this workspace."
  type         = "list(string)"
  
  form_type = "multi-select"
  # Set your default selections here (must be JSON encoded)
  default      = jsonencode(["vscode-web", "filebrowser","codex"]) 
  mutable      = true # Allows users to add/remove apps later by editing the workspace
  
  option {
    name  = "VS Code Web"
    value = "vscode-web"
    icon  = "/icon/code.svg"
  }
  option {
    name  = "Code Server"
    value = "code-server"
    icon  = "/icon/code.svg"
  }
  option {
    name  = "File Browser"
    value = "filebrowser"
    icon  = "/icon/folder.svg"
  }
  option {
    name  = "Codex"
    value = "codex"
    icon  = "/icon/robot.svg" 
  }
  
  option {
    name  = "Antigravity"
    value = "antigravity"
    icon  = "/icon/antigravity.svg" 
  }
}

# 2. Extract the list into a local variable for easy reading
locals {
  apps_list = jsondecode(data.coder_parameter.selected_apps.value)
}


#application: vscode
module "vscode-web" {
  count          = contains(local.apps_list, "vscode-web") ? data.coder_workspace.me.start_count : 0
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
  count          = contains(local.apps_list, "code-server") ? data.coder_workspace.me.start_count : 0
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

#application: antigravity
module "antigravity" {
  count          = contains(local.apps_list, "antigravity") ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/antigravity/coder"
  version  = "1.0.1"
  agent_id = coder_agent.main.id
  folder   = "/home/coder/repos"
  open_recent = "true"
}


#application: filebrowser
module "filebrowser" {
  count      = contains(local.apps_list, "filebrowser") ? data.coder_workspace.me.start_count : 0
  source     = "registry.coder.com/coder/filebrowser/coder"
  version    = "1.1.4"
  agent_id   = coder_agent.main.id
  agent_name = "main"
  folder   = "/home/coder/repos"
  subdomain  = false
}


module "codex" {
  count          = contains(local.apps_list, "codex") ? data.coder_workspace.me.start_count : 0
  source         = "registry.coder.com/coder-labs/codex/coder"
  version        = "4.3.1"
  agent_id       = coder_agent.main.id
  workdir        = "/home/coder/repos"
  openai_api_key = data.coder_parameter.openai_api_key.value
  continue = true
  enable_state_persistence = true
  codex_system_prompt = ""
  
base_config_toml = replace(<<-EOT


################################################################################
# Approval & Sandbox
################################################################################
# 默认是on-request,  - untrusted: only known-safe read-only commands auto-run; others prompt
# - on-failure: auto-run in sandbox; prompt only on failure for escalation
# - on-request: model decides when to ask (default)
# - never: never prompt (risky)
project_doc_fallback_filenames = ["CLAUDE.md"] # agents.md找不到，则找claude.md
approval_policy = "never"  # 默认
sandbox_mode = "danger-full-access" # 开大点好，文件系统/网络沙箱策略: read-only | workspace-write | danger-full-access (无沙箱，极其危险)

################################################################################
# Core Model Selection
################################################################################
model_provider = "packycode" #请自己设置
model = "gpt-5.4" # Codex使用的主要模型。默认: "gpt-5.2-codex"

review_model = "gpt-5.4"

########## 模型压缩 ⭐️⭐️⭐️ ⭐️⭐️⭐️重要#######
# 借鉴https://www.reddit.com/r/codex/comments/1per8fj/something_is_wrong_with_auto_compaction/  还有https://steipete.me/posts/2025/shipping-at-inference-speed
### ⭐️⭐️⭐️gpt 5.4使用下面两个:
model_context_window = 1000000 # 模型上下文窗口大小，默认1000000（1M）; gpt-5.4
model_auto_compact_token_limit = 350000 # for gpt-5.4⭐️虽然是1M ，但是有效注意力不够，可以自己网上查，不建议开的太高

tool_output_token_limit = 40000 # 工具输出最大token; default: 10000 for gpt-5.2-codex

################################################################################
# Reasoning & Verbosity (Responses API capable models)
################################################################################
model_reasoning_effort = "high" # 推理努力程度: minimal | low | medium | high | xhigh (默认: medium; gpt-5.2-codex和gpt-5.2上默认xhigh)
model_reasoning_summary = "detailed" # 模型输出思维链的summary风格，可以是auto | concise | detailed | none (default: auto)
# Text verbosity for GPT-5 family (Responses API): low | medium | high (default: medium)
model_verbosity = "high" # 如有需要可以开大哦！！！low则 Shorten responses
model_supports_reasoning_summaries = true # Force reasoning
#service_tier = "fast" # 开启后会变快哦，用量2倍

################################################################################
# Model Providers (extend/override built-ins)
################################################################################

[model_providers.packycode]
name = "OpenAI" # ⭐️⭐️⭐️ 如果你的中转支持， 这里就用大写的OpenAI，可以启用远程压缩效果更好哦， 不支持的话就换个别的字符串就行
base_url = "https://sub2api-hub.tsunhei.com"
wire_api = "responses" 
supports_websockets = true
requires_openai_auth = true

################################################################################
# Centralized Feature Flags (preferred)
################################################################################
[features]
shell_tool = true # 启用 shell 工具。默认: true
apply_patch_freeform = true # 通过自由格式编辑路径包含apply_patch（影响默认工具集）。默认: false
shell_snapshot = true # 启用shell快照功能。默认: false
undo = true # 启用undo功能。默认: true
unified_exec = true # 使用统一 PTY 执行工具
# exec_policy = true # Enforce rules checks for shell/unified_exec
multi_agent = true
steer = true
prevent_idle_sleep = true
# voice_transcription = true  
child_agents_md = true

memories = true # 开启记忆 ⭐️⭐️⭐️
sqlite = true # 其实可以不设置吧，开了也行
#fast_mode = true # 必开 -- 当然会让gpt-5.4用量2倍

responses_websockets_v2 = true

[memories] # ⭐️⭐️⭐️，强烈建议用新模型来总结memories
consolidation_model = "gpt-5.4"
extract_model = "gpt-5.4"
# generate_memories = true # 默认true
# use_memories = true # 默认true，表示把 memory_summary.md 注入 developer instructions
max_raw_memories_for_consolidation = 512
max_unused_days = 30 # 默认 30
max_rollout_age_days = 45 # 默认 30
# max_rollouts_per_startup = 16 # 默认 16
# min_rollout_idle_hours = 6 # 默认 6

[agents]
max_threads = 12
max_depth = 2



################################################################################
# Shell Environment Policy for spawned processes (table)
################################################################################
[shell_environment_policy] # Shell环境配置
# 环境变量继承策略inherit: all (default) | core | none 
inherit = "all" # 可以全给他看
# 是否忽略默认的 KEY/SECRET/TOKEN Skip default excludes for names containing KEY/SECRET/TOKEN (case-insensitive). Default: true
ignore_default_excludes = true # 意思是可以给他看
# Case-insensitive glob patterns to remove (e.g., "AWS_*", "AZURE_*"). Default: []
# exclude = []
# Explicit key/value overrides (always win). Default: {}
# set = {}
# Whitelist; if non-empty, keep only matching vars. Default: []
# include_only = []
# Experimental: run via user shell profile. Default: false
# experimental_use_profile = false

################################################################################
# Sandbox settings (tables)
################################################################################
[sandbox_workspace_write]
# Additional writable roots beyond the workspace (cwd). Default: [] 例如在/root/paddlejob/RLHF 启动，但需要让他访问 /root/paddlejob 下的其他文件夹，可以在这里加上 /root/paddlejob
# writable_roots = [] 
network_access = true # # Allow outbound network access inside the sandbox. Default: false

################################################################################
# Notifications
################################################################################
# External notifier program (argv array). When unset: disabled.
# Example: notify = ["notify-send", "Codex"]


[tui]
# Send desktop notifications when approvals are required or a turn completes. # Defaults to false.
notifications = true

# 使用包装脚本以集中配置通知偏好（声音/图标/分组等）
# notify = [ ] # linux机器不开 wrapper.sh

################################################################################
# Project Controls
################################################################################
# Max bytes from AGENTS.md to embed into first-turn instructions. Default: 32768
# project_doc_max_bytes = 32768


status_line = ["model-name", "project-root", "context-usage","fast-mode"]


[notice]
hide_rate_limit_model_nudge = true


EOT
  , "\r", "") # This tells Terraform to replace all carriage returns with nothing
}


module "git-config" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/git-config/coder"
  version  = "1.0.33" # Use the latest version
  
  agent_id = coder_agent.main.id 
  
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