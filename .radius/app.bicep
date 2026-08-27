extension radius

param environment string

@secure()
param registryPassword string

@secure()
param registryUsername string

resource gatewayByoDemoApp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'gateway-byo-demo'
  properties: {
    environment: environment
  }
}

resource registryCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'radius-ghcr-registry-creds'
  properties: {
    environment: environment
    application: gatewayByoDemoApp.id
    codeReference: '.radius/app.bicep'
    data: {
      password: {
        value: registryPassword
      }
      username: {
        value: registryUsername
      }
    }
  }
}

resource webImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'web-image'
  properties: {
    environment: environment
    application: gatewayByoDemoApp.id
    codeReference: 'Dockerfile'
    build: {
      source: 'git::https://github.com/willdavsmith/radius-gateway-byo-demo.git?ref=82da6372ae69d20e0a3aa14d2dcd69dd80e225aa'
    }
  }
  dependsOn: [
    registryCreds
  ]
}

resource webContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: gatewayByoDemoApp.id
    codeReference: 'index.html'
    containers: {
      web: {
        image: webImage.properties.imageReference
        ports: {
          web: {
            containerPort: 80
          }
        }
      }
    }
  }
}

resource webRoute 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: gatewayByoDemoApp.id
    codeReference: '.radius/app.bicep'
    kind: 'HTTP'
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: webContainer.id
          containerName: 'web'
          containerPort: 80
        }
      }
    ]
  }
}
