# Deploying Test Servers with Bicep

This guide explains how to deploy 1 to N Windows and/or Linux virtual machines (VMs) in Azure using the provided Bicep template and configuration file.

## Prerequisites

- Azure CLI or Azure PowerShell installed
- Sufficient permissions to deploy resources in your Azure subscription
- The following files in your workspace:
  - `Testing/Deploy Servers/main.bicep`
  - `Testing/Deploy Servers/vmconfig.json`

## Configuration: `vmconfig.json`

Edit `Testing/Deploy Servers/vmconfig.json` to specify the VMs you want to deploy. The file contains two arrays: `windows` and `linux`. Each entry defines a VM.

**Example:**
```json
{
  "windows": [
    {
      "name": "winvm1",
      "vmSize": "Standard_DS1_v2",
      "image": {
        "offer": "WindowsServer",
        "sku": "2019-Datacenter",
        "version": "latest"
      },
      "adminUsername": "azureuser",
      "adminPassword": "ReplaceWithSecurePassword1!"
    }
  ],
  "linux": [
    {
      "name": "linuxvm1",
      "vmSize": "Standard_DS1_v2",
      "image": {
        "offer": "0001-com-ubuntu-server-focal",
        "sku": "20_04-lts-gen2",
        "version": "latest"
      },
      "adminUsername": "azureuser",
      "adminPassword": "ReplaceWithSecurePassword2!"
    }
  ]
}
```
- Add or remove objects in the `windows` or `linux` arrays to control how many VMs of each type are deployed.
- **Important:** Use strong, secure passwords for all VMs.

## How to Deploy

1. **Open a terminal in the root of your workspace.**
2. **Set your Azure subscription and resource group:**
   ```powershell
   az login
   az account set --subscription <your-subscription-id>
   az group create --name <your-resource-group> --location <azure-region>
   ```
3. **Deploy the Bicep template:**
   ```powershell
   az deployment group create \
     --resource-group <your-resource-group> \
     --template-file "Testing/Deploy Servers/main.bicep" \
     --parameters vmConfig=@"Testing/Deploy Servers/vmconfig.json"
   ```
   - Replace `<your-resource-group>` and `<azure-region>` with your values.
   - The deployment will create a VNet, subnet, NICs, and all VMs as defined in your config file.

## Notes
- The Bicep template will create a virtual network (`vnet`) and subnet (`default`) if they do not exist.
- Each VM will have its own NIC and will be placed in the same subnet.
- You can deploy any mix of Windows and Linux VMs by editing `vmconfig.json`.
- To redeploy with a different set of VMs, update `vmconfig.json` and rerun the deployment command.

## Troubleshooting
- Ensure your passwords meet Azure's complexity requirements.
- If you encounter errors, check the Azure Portal for deployment status and error details.
- Make sure the `Testing/Deploy Servers` directory contains both `main.bicep` and `vmconfig.json`.

---

For advanced customization, edit the Bicep template as needed. For questions, contact your Azure administrator or refer to the [Azure Bicep documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/).
