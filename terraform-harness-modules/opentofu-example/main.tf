terraform {
  required_providers {
    harness = {
      source  = "harness/harness"
    }
  }
}

provider "harness" {
  endpoint         = "https://app.harness.io/gateway"
  account_id       = "ACCOUNT_ID"
  platform_api_key = "PLATFORM_API_KEY"
}

module "org_OpenTofu" {
  source = "git@github.com:harness-community/terraform-harness-structure.git//modules/organizations"
  name        = "OpenTofu"
  description = "Organization created via OpenTofu"
}

module "project_OpenTofu" {
    source = "git@github.com:harness-community/terraform-harness-structure.git//modules/projects"
    organization_id = module.org_OpenTofu.organization_details.id
    name = "OpenTofu"
    description = "Project created via OpenTofu"
    color = "#ffffff"

}

module "dev_k8s_delegate" {
  source = "harness-community/connectors/harness//modules/kubernetes/cluster"
  version = "0.1.1"
  organization_id    = module.org_OpenTofu.organization_details.id
  project_id         = module.project_OpenTofu.project_details.id
  name               = "dev_k8s_connector"
  delegate_selectors = ["opentofu-delegate"]
}

module "secret_OpenTofu_github" {
  source = "git@github.com:harness-community/terraform-harness-structure.git//modules/secrets/text"
  organization_id = module.org_OpenTofu.organization_details.id
  project_id      = module.project_OpenTofu.project_details.id
  name            = "github_secret"
  description     = "Github PAT"
  value           = "GITHUB_PAT"
}

module "github" {
  source = "harness-community/connectors/harness//modules/scms/github"
  version = "0.1.1"
  organization_id = module.org_OpenTofu.organization_details.id
  project_id      = module.project_OpenTofu.project_details.id
  name            = "github_connector"
  url             = "GITHUB_URL"
  github_credentials = {
    type            = "http"
    username        = "GITHUB_USERNAME"
    secret_location = "project"
    password        = module.secret_OpenTofu_github.secret_details.id
  }
}

module "dev" {
  source = "git@github.com:harness-community/terraform-harness-delivery.git//modules/environments"

  organization_id = module.org_OpenTofu.organization_details.id
  project_id      = module.project_OpenTofu.project_details.id
  name            = "dev"
  type            = "nonprod"
  yaml_render     = false
  yaml_data       = <<EOT
environment:
  name: dev
  identifier: dev
  projectIdentifier: ${module.project_OpenTofu.project_details.id}
  orgIdentifier: ${module.org_OpenTofu.organization_details.id}
  description: Harness Environment created via OpenTofu
  type: PreProduction
  EOT
}

module "harness_guestbook" {
  source = "git@github.com:harness-community/terraform-harness-delivery.git//modules/services"

  organization_id = module.org_OpenTofu.organization_details.id
  project_id      = module.project_OpenTofu.project_details.id
  description = "Harness Service created via OpenTofu"
  name            = "harness_guestbook"
  yaml_render     = false
  yaml_data       = <<EOT
service:
  name: harness_guestbook
  identifier: harness_guestbook
  tags: {}
  serviceDefinition:
    type: Kubernetes
    spec:
      manifests:
        - manifest:
            identifier:  guestbook
            type: K8sManifest
            spec:
              store:
                type: Github
                spec:
                  connectorRef: github_connector
                  gitFetchType: Branch
                  paths:
                    - guestbook/guestbook-ui-deployment.yaml
                    - guestbook/guestbook-ui-svc.yaml
                  repoName: harnesscd-pipeline
                  branch: master
              valuesPaths:
                - values.yaml
              skipResourceVersioning: false
              enableDeclarativeRollback: false
  EOT
}

module "dev_k8s" {
  source = "git@github.com:harness-community/terraform-harness-delivery.git//modules/infrastructures"
  organization_id = module.org_OpenTofu.organization_details.id
  project_id      = module.project_OpenTofu.project_details.id
  description = "Harness infrastructure definition created via OpenTofu"
  environment_id = "dev"
  name            = "k8s"
  type            = "KubernetesDirect"
  deployment_type = "Kubernetes"
  yaml_data       = <<EOT
spec:
  connectorRef: ${module.dev_k8s_delegate.connector_details.id}
  namespace: default
  releaseName: release-<+INFRA_KEY>
  EOT
}

module "pipelines" {
  source = "harness-community/content/harness//modules/pipelines"
  version = "0.1.1"
  organization_id = module.org_OpenTofu.organization_details.id
  project_id      = module.project_OpenTofu.project_details.id
  name            = "Deployment_Pipeline"
   tags = {
    created_by = "Terraform"
  }
  yaml_data       = <<EOT
  stages:
    - stage:
        name: deploy-guestbook
        identifier: deployguestbook
        description: "Harness pipeline created via OpenTofu"
        type: Deployment
        spec:
          deploymentType: Kubernetes
          service:
            serviceRef: harness_guestbook
          environment:
            environmentRef: dev
            deployToAll: false
            infrastructureDefinitions:
              - identifier: k8s
          execution:
            steps:
              - step:
                  name: Rollout Deployment
                  identifier: rolloutDeployment
                  type: K8sRollingDeploy
                  timeout: 10m
                  spec:
                    skipDryRun: false
                    pruningEnabled: false
            rollbackSteps:
              - step:
                  name: Rollback Rollout Deployment
                  identifier: rollbackRolloutDeployment
                  type: K8sRollingRollback
                  timeout: 10m
                  spec:
                    pruningEnabled: false
        tags: {}
        failureStrategies:
          - onFailure:
              errors:
                - AllErrors
              action:
                type: StageRollback
  EOT
}
