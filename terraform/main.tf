terraform {
  required_version = ">= 0.10.1"
}

provider "azurerm" {}

resource "azurerm_resource_group" "main" {
  name     = "consul-global"
  location = "westus"
}

module "ssh_key" {
  source = "modules/ssh-keypair-data"

  private_key_filename = "${var.private_key_filename}"
}

module "network_westus" {
  source                = "modules/network-azure"
  resource_group_name   = "${azurerm_resource_group.main.name}"
  location              = "westus"
  network_name          = "consul-westus"
  network_cidr          = "10.0.0.0/16"
  network_cidrs_public  = ["10.0.0.0/20"]
  network_cidrs_private = ["10.0.48.0/20", "10.0.64.0/20", "10.0.80.0/20"]
  os                    = "${var.os}"
  public_key_data       = "${module.ssh_key.public_key_data}"
}

module "network_eastus" {
  source                = "modules/network-azure"
  resource_group_name   = "${azurerm_resource_group.main.name}"
  location              = "eastus"
  network_name          = "consul-eastus"
  network_cidr          = "10.1.0.0/16"
  network_cidrs_public  = ["10.1.0.0/20"]
  network_cidrs_private = ["10.1.48.0/20", "10.1.64.0/20", "10.1.80.0/20"]
  os                    = "${var.os}"
  public_key_data       = "${module.ssh_key.public_key_data}"
}

module "consul_azure_westus" {
  source                    = "modules/consul-azure"
  resource_group_name       = "${azurerm_resource_group.main.name}"
  consul_datacenter         = "consul-westus"
  consul_join_wan           = ["consul-eastus"]
  location                  = "westus"
  cluster_size              = "${var.cluster_size}"
  private_subnet_ids        = ["${module.network_westus.subnet_private_ids}"]
  consul_version            = "${var.consul_version}"
  vm_size                   = "${var.consul_vm_size}"
  os                        = "${var.os}"
  public_key_data           = "${module.ssh_key.public_key_data}"
  auto_join_subscription_id = "${var.auto_join_subscription_id}"
  auto_join_tenant_id       = "${var.auto_join_tenant_id}"
  auto_join_client_id       = "${var.auto_join_client_id}"
  auto_join_client_secret   = "${var.auto_join_client_secret}"
}

module "consul_azure_eastus" {
  source              = "modules/consul-azure"
  resource_group_name = "${azurerm_resource_group.main.name}"
  consul_datacenter   = "consul-eastus"

  //consul_join_wan           = ["consul-westus"]
  location                  = "eastus"
  cluster_size              = "${var.cluster_size}"
  private_subnet_ids        = ["${module.network_eastus.subnet_private_ids}"]
  consul_version            = "${var.consul_version}"
  vm_size                   = "${var.consul_vm_size}"
  os                        = "${var.os}"
  public_key_data           = "${module.ssh_key.public_key_data}"
  auto_join_subscription_id = "${var.auto_join_subscription_id}"
  auto_join_tenant_id       = "${var.auto_join_tenant_id}"
  auto_join_client_id       = "${var.auto_join_client_id}"
  auto_join_client_secret   = "${var.auto_join_client_secret}"
}

/*
There are currently no Terraform resources to create VPN gateways and associated
VNet-to-VNet connections between Azure regions.

There is currently a PR to address this:
    https://github.com/terraform-providers/terraform-provider-azurerm/pull/133

This will provide native Terraform resources to create these components and
properly track them in the state file.
*/
resource "azurerm_template_deployment" "vpngw_westus" {
  name                = "vpngw-westus"
  resource_group_name = "${azurerm_resource_group.main.name}"
  deployment_mode     = "Incremental"
  template_body       = "${file("${path.root}/templates/arm_template_vpngw.json")}"
  depends_on          = ["module.network_westus"]

  parameters {
    resourceGroupName          = "${azurerm_resource_group.main.name}"
    location                   = "westus"
    name                       = "vpngw-westus"
    existingVirtualNetworkName = "${module.network_westus.virtual_network_name}"
    newPublicIpAddressName     = "vpngw-pub-ip-westus"
    sku                        = "Basic"
    gatewayType                = "Vpn"
    vpnType                    = "RouteBased"
    newSubnetName              = "GatewaySubnet"
    subnetAddressPrefix        = "10.0.96.0/20"
  }
}

resource "azurerm_template_deployment" "vpngw_eastus" {
  name                = "vpngw-eastus"
  resource_group_name = "${azurerm_resource_group.main.name}"
  deployment_mode     = "Incremental"
  template_body       = "${file("${path.root}/templates/arm_template_vpngw.json")}"
  depends_on          = ["module.network_eastus"]

  parameters {
    resourceGroupName          = "${azurerm_resource_group.main.name}"
    location                   = "eastus"
    name                       = "vpngw-eastus"
    existingVirtualNetworkName = "${module.network_eastus.virtual_network_name}"
    newPublicIpAddressName     = "vpngw-pub-ip-eastus"
    sku                        = "Basic"
    gatewayType                = "Vpn"
    vpnType                    = "RouteBased"
    newSubnetName              = "GatewaySubnet"
    subnetAddressPrefix        = "10.1.96.0/20"
  }
}

// We create the reverse connection in the same template
resource "azurerm_template_deployment" "vnet_conn_westus_to_eastus" {
  name                = "vnet-conn-westus-to-eastus"
  resource_group_name = "${azurerm_resource_group.main.name}"
  deployment_mode     = "Incremental"
  template_body       = "${file("${path.root}/templates/arm_template_vnet_to_vnet.json")}"

  depends_on = [
    "azurerm_template_deployment.vpngw_westus",
    "azurerm_template_deployment.vpngw_eastus",
  ]

  parameters {
    resourceGroupName          = "${azurerm_resource_group.main.name}"
    location                   = "westus"
    connectionName             = "vpngw-westus-to-vpngw-eastus"
    connectionType             = "Vnet2Vnet"
    virtualNetworkGatewayName1 = "vpngw-westus"
    virtualNetworkGatewayName2 = "vpngw-eastus"
    sharedKey                  = "testpsk"
    connectionReverseName      = "vpngw-eastus-to-vpngw-westus"
    connectionReverseLocation  = "eastus"
  }
}
