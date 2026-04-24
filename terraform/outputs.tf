output "demo_user_username" {
  description = "Authentik username for the demo account"
  value       = authentik_user.demo_user.username
  sensitive   = true
}

output "demo_user_password" {
  description = "Authentik password for the demo account"
  value       = var.admin_password
  sensitive   = true
}
