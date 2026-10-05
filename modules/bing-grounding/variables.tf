variable "name" {
  description = "Descriptive Bing Grounding resource name."
  type        = string
}

variable "resource_group_id" {
  description = "Resource group scope for the Bing Grounding resource."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Bing Grounding resource."
  type        = map(string)
  default     = {}
}
