resource "authentik_user" "demo_user" {
  username = "demo-user"
  name     = "Demo User"
  email    = "demo@example.com"
  password = var.admin_password
}

resource "authentik_group" "grafana_admins" {
  name  = "Grafana Admins"
  users = toset([authentik_user.demo_user.id])
}

resource "authentik_group" "argocd_admins" {
  name  = "argocd-admins"
  users = toset([authentik_user.demo_user.id])
}
