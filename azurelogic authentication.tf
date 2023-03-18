terraform{
    required_providers {
      azurerm = {
          source = "hashicorp/azurerm"
          version = ">= 2.26"
      }
    }
}

provider "azurerm" {
    features {}  
}

locals{
    resource_group_name = "terraform-logAlerts"
    location = "southeastasia"
    logicAppName = "LogExport-Query1"
    frequency = "Minute"
    interval = 5
    logQuery = "AzureDiagnostics"
    workspaceSubscriptionId = ""
    workspaceName = "LogAlertsPOC"
    workspaceResourceGroup = "logalerts"
    timespan = "PT5M"    
    identityName = "LogReaderIdentity"
    dataIngestUrl = ""    
}


# Set up the resource group
resource "azurerm_resource_group" "logicapp"{
    name = local.resource_group_name
    location = local.location
}

# Create a Managed Identity
resource "azurerm_user_assigned_identity" "logicapp_identity"{
    resource_group_name = azurerm_resource_group.logicapp.name
    location = azurerm_resource_group.logicapp.location
    name = local.identityName
}

# Assign Monitoring Reader role to the Identity
resource "azurerm_role_assignment" "logicapp_identity"{
    scope = "/subscriptions/${local.workspaceSubscriptionId}/resourcegroups/${local.workspaceResourceGroup}/providers/microsoft.operationalinsights/workspaces/${local.workspaceName}"
    role_definition_name = "Monitoring Reader"
    principal_id = azurerm_user_assigned_identity.logicapp_identity.principal_id

    depends_on = [ azurerm_user_assigned_identity.logicapp_identity ]
}

# Create the Logic App Workflow and assign Identity at point of creation - identity assignation can only be done via ARM template

resource "azurerm_resource_group_template_deployment" "logicapp"{
    name = "deploy-logicApp"
    resource_group_name = local.resource_group_name
    deployment_mode = "Incremental"
    /*template_content = templatefile("azuredeploy.json",{
        "workflow_name" = local.logicAppName
        "location" = local.location
        "identity" = azurerm_user_assigned_identity.logicapp_identity.id
        "frequency" = local.frequency
        "interval" = local.interval
    })*/
    template_content = file("azuredeploy.json")
    parameters_content = jsonencode({
        workflow_name = {value=local.logicAppName}
        location =      {value=local.location}
        identity =      {value=azurerm_user_assigned_identity.logicapp_identity.id}
        frequency =     {value=local.frequency}
        interval =      {value=local.interval}
    })
  
    depends_on = [ azurerm_user_assigned_identity.logicapp_identity ]
}

resource "azurerm_logic_app_action_custom" "logicapp_executequery"{
    name = "ExecuteLogAnalyticsQuery"
    logic_app_id = jsondecode(azurerm_resource_group_template_deployment.logicapp.output_content).workflowId.value
    body = <<BODY
        {
              "inputs": {
                    "authentication": {
                        "identity": "${azurerm_user_assigned_identity.logicapp_identity.id}",
                        "type": "ManagedServiceIdentity"
                    },
                    "body": {
                        "query": "${local.logQuery}",
                        "timespan": "${local.timespan}"
                    },
                    "headers": {
                        "Content-Type": "application/json"
                    },
                    "method": "POST",
                    "uri": "https://management.azure.com/subscriptions/${local.workspaceSubscriptionId}/resourceGroups/${local.workspaceResourceGroup}/providers/Microsoft.OperationalInsights/workspaces/${local.workspaceName}/api/query?api-version=2017-01-01-preview"
                },
                "runAfter": {},
                "type": "Http"
        }
    BODY

    depends_on = [azurerm_resource_group_template_deployment.logicapp ]
}

resource "azurerm_logic_app_action_custom" "logicapp_parsequeryresults"{
    name = "ParseQueryResults"
    logic_app_id = jsondecode(azurerm_resource_group_template_deployment.logicapp.output_content).workflowId.value
    body = <<BODY
        {
                "inputs": {
                    "content": "@body('ExecuteLogAnalyticsQuery')",
                    "schema": {
                        "properties": {
                            "Tables": {
                                "items": {
                                    "properties": {
                                        "Columns": {
                                            "items": {
                                                "properties": {
                                                    "ColumnName": {
                                                        "type": "string"
                                                    },
                                                    "ColumnType": {
                                                        "type": "string"
                                                    },
                                                    "DataType": {
                                                        "type": "string"
                                                    }
                                                },
                                                "required": [
                                                    "ColumnName",
                                                    "DataType",
                                                    "ColumnType"
                                                ],
                                                "type": "object"
                                            },
                                            "type": "array"
                                        },
                                        "Rows": {
                                            "items": {
                                                "type": "array"
                                            },
                                            "type": "array"
                                        },
                                        "TableName": {
                                            "type": "string"
                                        }
                                    },
                                    "required": [
                                        "TableName",
                                        "Columns",
                                        "Rows"
                                    ],
                                    "type": "object"
                                },
                                "type": "array"
                            }
                        },
                        "type": "object"
                    }
                },
                "runAfter": {
                    "ExecuteLogAnalyticsQuery": [
                        "Succeeded"
                    ]
                },
                "type": "ParseJson"
            }
    BODY

    depends_on = [azurerm_logic_app_action_custom.logicapp_executequery ]
}

resource "azurerm_logic_app_action_custom" "logicapp_composepayload"{
    name = "ComposeFunctionPayload"
    logic_app_id = jsondecode(azurerm_resource_group_template_deployment.logicapp.output_content).workflowId.value
    body=<<BODY
            {
                "inputs": {
                    "SearchQuery": "${local.logQuery}",
                    "SearchResult": {
                        "tables": "@body('ParseQueryResults')?['Tables']"
                    },
                    "SubscriptionId": "${local.workspaceSubscriptionId}"
                },
                "runAfter": {
                    "ParseQueryResults": [
                        "Succeeded"
                    ]
                },
                "type": "Compose"
            }
    BODY

    depends_on = [azurerm_logic_app_action_custom.logicapp_parsequeryresults ]
}

resource "azurerm_logic_app_action_custom" "logicapp_postToFunction"{
    name = "PostToFunction"
    logic_app_id = jsondecode(azurerm_resource_group_template_deployment.logicapp.output_content).workflowId.value
    body=<<BODY
            {
                "inputs": {
                    "body": "@outputs('ComposeFunctionPayload')",
                    "method": "POST",
                    "uri": "${local.dataIngestUrl}"
                },
                "runAfter": {
                    "ComposeFunctionPayload": [
                        "Succeeded"
                    ]
                },
                "type": "Http"
            }
    BODY

    depends_on = [azurerm_logic_app_action_custom.logicapp_composepayload ]
}
