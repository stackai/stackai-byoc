# ✅ Step 1: Wait for Flux to bootstrap and deploy nginx ingress controller
resource "null_resource" "wait_for_nginx_ingress" {
  depends_on = [
    null_resource.bootstrap_flux,
    null_resource.wait_for_flux
  ]
  
  provisioner "local-exec" {
    command = <<EOT
      echo "🔄 Waiting for Flux to deploy nginx ingress controller..."
      
      # First ensure Flux controllers are ready
      echo "Checking Flux controllers..."
      kubectl wait --for=condition=ready --timeout=300s pod -l app=source-controller -n flux-system || true
      kubectl wait --for=condition=ready --timeout=300s pod -l app=kustomize-controller -n flux-system || true
      
      # Wait for nginx-ingress namespace to be created by Flux
      echo "Waiting for nginx-ingress namespace..."
      for i in {1..60}; do
        if kubectl get namespace nginx-ingress &>/dev/null; then
          echo "✅ nginx-ingress namespace found"
          break
        fi
        echo "Attempt $i/60: Waiting for nginx-ingress namespace..."
        sleep 5
      done
      
      # Wait for nginx ingress controller service to exist
      echo "Waiting for nginx ingress controller service..."
      for i in {1..60}; do
        if kubectl get svc -n nginx-ingress nginx-ingress-controller &>/dev/null; then
          echo "✅ nginx ingress controller service is available"
          break
        else
          echo "Attempt $i/60: Waiting for nginx ingress controller service..."
          sleep 10
        fi
      done
      
      # Wait for deployment to be ready
      echo "Waiting for nginx ingress controller deployment..."
      kubectl wait --for=condition=available --timeout=600s deployment/nginx-ingress-controller -n nginx-ingress || true
      
      # Wait for LoadBalancer to get external IP
      echo "Waiting for LoadBalancer external IP..."
      for i in {1..120}; do
        IP=$(kubectl get service nginx-ingress-controller -n nginx-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ ! -z "$IP" ] && [ "$IP" != "null" ]; then
          echo "✅ LoadBalancer IP found: $IP"
          exit 0
        fi
        echo "Attempt $i/120: Waiting for LoadBalancer IP..."
        sleep 10
      done
      
      echo "❌ Timeout waiting for LoadBalancer IP"
      exit 1
    EOT
  }
}

# ✅ Step 2: Data source depends on the wait resource
data "kubernetes_service" "nginx_ingress" {
  depends_on = [null_resource.wait_for_nginx_ingress]
  
  metadata {
    name      = "nginx-ingress-controller"
    namespace = "nginx-ingress"
  }
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