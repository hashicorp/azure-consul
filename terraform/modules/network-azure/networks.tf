# Copyright IBM Corp. 2017, 2023
# SPDX-License-Identifier: MPL-2.0

resource "azurerm_virtual_network" "main" {
  resource_group_name = "${var.resource_group_name}"
  location            = "${var.location}"
  name                = "${var.network_name}"
  address_space       = ["${var.network_cidr}"]
}
