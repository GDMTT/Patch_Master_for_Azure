// main.bicep
// Deploys 1 to N Windows and/or Linux VMs based on a configuration file

param location string = resourceGroup().location
param vmConfig object = loadTextContent('vmconfig.json')

var config = json(vmConfig)

// Loop for Windows VMs
targetScope = 'resourceGroup'

resource windowsVms 'Microsoft.Compute/virtualMachines@2023-03-01' = [for (win, i) in config.windows: {
  name: win.name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: win.vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: win.image.offer
        sku: win.image.sku
        version: win.image.version
      }
    }
    osProfile: {
      computerName: win.name
      adminUsername: win.adminUsername
      adminPassword: win.adminPassword
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: resourceId('Microsoft.Network/networkInterfaces', '${win.name}-nic')
        }
      ]
    }
  }
}]

// Loop for Linux VMs
resource linuxVms 'Microsoft.Compute/virtualMachines@2023-03-01' = [for (lin, i) in config.linux: {
  name: lin.name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: lin.vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'Canonical'
        offer: lin.image.offer
        sku: lin.image.sku
        version: lin.image.version
      }
    }
    osProfile: {
      computerName: lin.name
      adminUsername: lin.adminUsername
      adminPassword: lin.adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: resourceId('Microsoft.Network/networkInterfaces', '${lin.name}-nic')
        }
      ]
    }
  }
}]

// Create NICs for all VMs
resource nics 'Microsoft.Network/networkInterfaces@2023-05-01' = [for vm in union(config.windows, config.linux): {
  name: '${vm.name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', 'vnet', 'default')
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}]

// Create a VNet and subnet if not exists
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}
