# Data source to get the nginx ingress controller service
data "kubernetes_service" "nginx_ingress" {
  metadata {
    name      = "nginx-ingress-controller"
    namespace = "nginx-ingress"
  }
  depends_on = [null_resource.wait_for_nginx_ingress]
}

# Null resource to wait for nginx ingress controller to be ready
resource "null_resource" "wait_for_nginx_ingress" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for nginx ingress controller to be ready..."
      kubectl wait --for=condition=available --timeout=600s deployment/nginx-ingress-controller -n nginx-ingress || true
      
      # Wait for the LoadBalancer service to get an external IP
      echo "Waiting for LoadBalancer IP..."
      for i in {1..60}; do
        IP=$(kubectl get service nginx-ingress-controller -n nginx-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ ! -z "$IP" ] && [ "$IP" != "null" ]; then
          echo "LoadBalancer IP found: $IP"
          break
        fi
        echo "Attempt $i/60: Waiting for LoadBalancer IP..."
        sleep 10
      done
    EOT
  }
  depends_on = [azurerm_kubernetes_cluster.aks]
}

# Local values for generating hostnames using nip.io (no DNS configuration needed)
locals {
  # Get the load balancer IP and create hostnames using nip.io
  # nip.io automatically resolves subdomains to the embedded IP address
  load_balancer_ip = data.kubernetes_service.nginx_ingress.status.0.load_balancer.0.ingress.0.ip
  
  # Generate hostnames using nip.io format: subdomain.IP.nip.io
  service_hostnames = {
    api = "api.${replace(local.load_balancer_ip, ".", "-")}.nip.io"
    app = "app.${replace(local.load_balancer_ip, ".", "-")}.nip.io"
    db  = "db.${replace(local.load_balancer_ip, ".", "-")}.nip.io"
  }
}

# No DNS records needed - nip.io handles everything automatically!
