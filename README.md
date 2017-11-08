# Multi-Region Consul on Azure

This objective of this project is to provide an example of a multi-region Consul cluster deployment in Azure using Terraform.  This is a high-level overview of the environment that is created:

* Creates a Resource Group to contain all resources created by this guide
* Creates a virtual network, one public subnet, and three private subnets (default values) in the West US and East US Azure regions (configurable)
* Creates a publically-accessible jumphost for SSH access in each public subnet
* Creates one Consul cluster in each region (3 server nodes in each) using an install script for on-the-fly Consul installation and configuration
* Uses Consul's cloud auto-join to connect the Consul nodes in each region to each other (LAN gossip pool) as well as connecting each region to each other (WAN gossip pool)
    * You can read more about Consul's Gossip protocol [here](https://www.consul.io/docs/internals/gossip.html).
    * You can read more about Consul's Basic Federation approach [here](https://www.consul.io/docs/guides/datacenters.html).

## Deployment Prerequisites

1. In order to perform the steps in this guide, you will need to have an Azure subscription for which you can create Service Principals as well as network and compute resources. You can create a free Azure account [here](https://azure.microsoft.com/en-us/free/).

2. Certain steps will require entering commands through the Azure CLI. You can find out more about installing it [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli).

3. Create Azure API Credentials - set up the main Service Principal that will be used by Terraform:
    * https://www.terraform.io/docs/providers/azurerm/index.html
    * The above steps will create a Service Principal with the [Contributor](https://docs.microsoft.com/en-us/azure/active-directory/role-based-access-built-in-roles#contributor) role in your Azure subscription

4. `export` environment variables for the main Terraform Service Principal. For example, create a `env.sh` file with the following values (obtained from step `1` above):

    ```
    export ARM_SUBSCRIPTION_ID="xxxxxxxx-yyyy-zzzz-xxxx-yyyyyyyyyyyy"
    export ARM_CLIENT_ID="xxxxxxxx-yyyy-zzzz-xxxx-yyyyyyyyyyyy"
    export ARM_CLIENT_SECRET="xxxxxxxx-yyyy-zzzz-xxxx-yyyyyyyyyyyy"
    export ARM_TENANT_ID="xxxxxxxx-yyyy-zzzz-xxxx-yyyyyyyyyyyy"
    ```

    You can then source these environment variables as such:
    
    ```
    $ source env.sh
    ```

5. Create a read-only Azure Service Principal (using the Azure CLI) that will be used to perform the Consul auto-join (make note of these values as you will use them later in this guide):

    ```
    $ az ad sp create-for-rbac --role="Reader" --scopes="/subscriptions/[YOUR_SUBSCRIPTION_ID]"
    ```

## Deploy the Consul Cluster

1. `git clone` the [`hashicorp-guides/azure-consul-multi-region`](https://github.com/hashicorp-guides/azure-consul-multi-region) repository

2. `cd` into the `azure-consul-multi-region/terraform` directory

3. At this point, you will need to customize the `terraform.tfvars` with your specific values. There's a `terraform.tfvars.example` file provided. Update the appropriate values:

    * `auto_join_subscription_id`, `auto_join_client_id`, `auto_join_client_secret`, `auto_join_tenant_id` will use the values obtained from creating the read-only auto-join Service Principal created in step #5 of the Deployment Prerequisites earlier.

4. Run `terraform init` to initialize the working directory and download appropriate providers

5. Run `terraform plan` to verify deployment steps and validate all modules

6. Finally, run `terraform apply` to deploy the Consul cluster

## Verify Deployment

* SSH into a jumphost, then SSH into Consul servers:
```
jumphost_ssh_connection_strings = [
    ssh-add private_key.pem && ssh -A -i private_key.pem azure-user@13.64.0.0
]
consul_private_ips = [
    ssh azure-user@172.31.48.4,
    ssh azure-user@172.31.64.4,
    ssh azure-user@172.31.80.4
]
```

* Since we are installing and configuring Consul at runtime, you will need to wait several minutes for everything to complete. You can view the progress of the installation with `tail -f /var/log/user-data.log`.

* Once you see the message "Completed Configuration of Consul Node. Run 'consul members' to view cluster information." you can perform the following:

* Run `consul members` to view the status of the local cluster:

```
$ consul members

Node             Address         Status  Type    Build  Protocol  DC   Segment
consul-eastus-0  10.1.48.4:8301  alive   server  1.0.0  2         dc1  <all>
consul-eastus-1  10.1.64.4:8301  alive   server  1.0.0  2         dc1  <all>
consul-eastus-2  10.1.80.4:8301  alive   server  1.0.0  2         dc1  <all>
```

* To view the status of your WAN-connected clusters, run `consul members -wan`:

```
$consul members -wan

Node                 Address         Status  Type    Build  Protocol  DC   Segment
consul-eastus-0.dc1  10.1.48.4:8302  alive   server  1.0.0  2         dc1  <all>
consul-eastus-1.dc1  10.1.64.4:8302  alive   server  1.0.0  2         dc1  <all>
consul-eastus-2.dc1  10.1.80.4:8302  alive   server  1.0.0  2         dc1  <all>
consul-westus-0.dc1  10.0.48.4:8302  alive   server  1.0.0  2         dc1  <all>
consul-westus-1.dc1  10.0.64.4:8302  alive   server  1.0.0  2         dc1  <all>
consul-westus-2.dc1  10.0.80.4:8302  alive   server  1.0.0  2         dc1  <all>
```
