output "names" {
  description = "Map of names per resource (CAF abbreviations + deterministic hash suffix)"
  value       = local.names
}

output "base" {
  description = "Common name prefix in the form <workload>-<environment>-<region>"
  value       = local.base
}

output "suffix" {
  description = "5-character hash appended to globally unique names"
  value       = local.suffix
}
