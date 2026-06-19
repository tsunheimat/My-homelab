---
display_name: Kubernetes (Deployment)
description: Provision Kubernetes Deployments as Coder workspaces
icon: ../../../../.icons/kubernetes.svg
verified: true
tags: [kubernetes, container]
---

# Remote Development on Kubernetes Deployments

Provision Kubernetes Deployments as [Coder workspaces](https://coder.com/docs/workspaces) with this example template.

<!-- TODO: Add screenshot -->

## Prerequisites

### Infrastructure

**Cluster**: This template requires an existing Kubernetes cluster.

**Container Image**: This template uses the [codercom/example-node:ubuntu](https://github.com/coder/enterprise-images) image with some development tools pre-installed. To add additional tools, you can edit the `image` field in the `main.tf` file or build your own custom image.

### Authentication

This template authenticates using a `~/.kube/config` if present on the Coder host, or via built-in authentication if the Coder provisioner is running on Kubernetes with an authorized ServiceAccount.

You can control this behavior with the `use_kubeconfig` parameter when creating a workspace:
*   Set it to `false` (default) if the Coder host is running as a Pod on the same Kubernetes cluster you are deploying workspaces to.
*   Set it to `true` if the Coder host is running outside the Kubernetes cluster for workspaces. A valid `~/.kube/config` must be present on the Coder host.

## Architecture

This template provisions the following resources for each workspace:

- A **Kubernetes Deployment**: This manages an ephemeral pod where your development environment runs.
- A **Kubernetes Persistent Volume Claim**: This provides persistent storage for your `/home/coder` directory.

This means that when a workspace is stopped or restarted, any files or tools outside of the `/home/coder` directory will not be saved. To have tools pre-installed in your workspace, you should modify the container image. Alternatively, individual developers can [personalize](https://coder.com/docs/dotfiles) their workspaces using dotfiles to install tools and configure their environment on startup.

> **Note**
> This template is designed to be a starting point! You can edit the Terraform code in `main.tf` to extend the template to support your specific use case.
