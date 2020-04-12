$resourceGroup = Read-Host "Enter Resource Group Name"
$resourceGroupLocation = Read-Host "Enter Resouce Group Location"
$aksName = Read-Host "Enter AKS Cluster Name"
$aksDNSName = Read-Host "Enter AKS DNS Prefix"


if ((az group exists --name $resourceGroup) -eq $false) {
    az group create --name $resourceGroup --location $resourceGroupLocation
}
else {
    write-host "A resource group with the name $resourceGroup already exists"
    exit 1
}

Write-Output "Provisioning AKS Cluster - THIS WILL TAKE A WHILE..."

try {
    az aks create --resource-group $resourceGroup --name $aksName --node-count 2 --generate-ssh-keys 
}
catch {
    #Sometimes this fails due to https://github.com/Azure/azure-cli/issues/9585 so try again
    az aks create --resource-group $resourceGroup --name $aksName --node-count 2 --generate-ssh-keys 

}

az aks get-credentials --resource-group $resourceGroup --name $aksName --overwrite-existing
kubectl create namespace ingress-basic

$aksRG = az aks show --resource-group $resourceGroup --name $aksName --query nodeResourceGroup -o tsv
$publicIP = az network public-ip create --resource-group $aksRG --name AKSPublicIP --sku Standard --allocation-method static --query publicIp.ipAddress -o tsv

Write-Output "Downloading Helm to C:\Helm"

New-Item -Path 'C:\Helm' -ItemType Directory -Force
Invoke-WebRequest -Uri "https://get.helm.sh/helm-v3.1.2-windows-amd64.zip" -OutFile "C:\Helm\Helm.zip" 
Expand-Archive -LiteralPath 'C:\Helm\Helm.zip' -DestinationPath C:\Helm -Force

Set-Location C:\Helm\windows-amd64
.\helm repo add stable https://kubernetes-charts.storage.googleapis.com/
.\helm repo update
.\helm install nginx-ingress stable/nginx-ingress --namespace ingress-basic --set controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux --set controller.service.loadBalancerIP="$publicIP"

$dnsData = az network public-ip update --ids (az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$publicIP')].[id]" --output tsv) --dns-name $aksDNSName
$fqdn = ($dnsData | ConvertFrom-Json).dnsSettings.fqdn

kubectl create deployment helloworld --image tomaustin/helloworldnetcore --namespace ingress-basic
kubectl expose deployment helloworld --name helloworld --namespace ingress-basic --port 80

$tmpIngress = New-TemporaryFile

$ingress = 'apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: ingress
  namespace: ingress-basic
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  rules:
  - host: dnsAddress
    http:
      paths:
      - path: /
        backend:
          serviceName: helloworld
          servicePort: 80

'

$ingress = $ingress -replace "dnsAddress", $fqdn | Out-File $tmpIngress.FullName

kubectl apply -f $tmpIngress.FullName --namespace ingress-basic

Remove-Item -Path $tmpIngress.FullName

Write-Output "Test your AKS instance by navigating to the following url"
Write-Output $fqdn
