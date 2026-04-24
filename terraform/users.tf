resource "authentik_user" "chris" {
  username = "chris"
  name     = "Chris Matcham"
  email    = "chris.matcham@tempo.io"
  password = var.admin_password
}

resource "authentik_group" "grafana_admins" {
  name  = "Grafana Admins"
  users = toset([authentik_user.chris.id])
}
