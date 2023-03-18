/*#logic app azure ##/*

provider "azurerm" {
  features {}
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/template_deployment

variable "name" {
  default = "test"
}

variable "env" {
  default = "test"
}

variable "short_name" {
  default = "tst"
}

variable "location" {
  default = "westeurope"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}-logic-app"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "monitoring_law" {
  name                = "law-${var.name}-core-services"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  # sku                 = var.law_sku
  retention_in_days = 30
}

resource "azurerm_logic_app_workflow" "this" {
  name                = "la-${var.name}-core-services"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_logic_app_trigger_http_request" "http_req" {
  name         = "http-trigger"
  logic_app_id = azurerm_logic_app_workflow.this.id
  schema       = <<SCHEMA
  {}
  SCHEMA
}

resource "azurerm_template_deployment" "logic_app_endpoint" {
  name                = "${var.name}-${var.env}-logic_app_endpoint"
  resource_group_name = azurerm_resource_group.this.name
  deployment_mode     = "Incremental"

  template_body = <<DEPLOY
  {
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "variables": {
      "logicApp": {
        "name": "${azurerm_logic_app_workflow.this.name}",
        "trigger": "http-trigger"
      },
      "resourceId": "[resourceId('Microsoft.Logic/workflows/triggers', variables('logicApp').name, variables('logicApp').trigger)]",
      "apiVersion": "[providers('Microsoft.Logic', 'workflows').apiVersions[0]]"
    },
    "resources": [],
    "outputs": {
      "endpointUrl": {
        "type": "string",
        "value": "[listCallbackUrl(variables('resourceId'), variables('apiVersion')).value]"
      }
    }
  }
  DEPLOY
}

resource "azurerm_monitor_action_group" "this" {
  name                = "${var.name}-${var.env}-ag"
  short_name          = var.short_name
  resource_group_name = azurerm_resource_group.this.name

  /*
  logic_app_receiver {
    name                    = "logic-app-receiver"
    resource_id             = azurerm_logic_app_workflow.this.id
    callback_url            = azurerm_template_deployment.logic_app_endpoint.outputs["endpointUrl"]
    use_common_alert_schema = true
  }
  */

  webhook_receiver {
    name        = "logic-app-receiver"
    service_uri = azurerm_template_deployment.logic_app_endpoint.outputs["endpointUrl"]
  }
}

output "endpoint_url" {
  value = azurerm_template_deployment.logic_app_endpoint.outputs["endpointUrl"]
}
