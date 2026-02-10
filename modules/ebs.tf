

# resource "aws_ebs_volume" "mysql" {
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   size              = 40
#   tags = local.common_tags
# }

# resource "aws_ebs_volume" "mongodb" {
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   size              = 40
#   tags = local.common_tags
# }

# resource "aws_ebs_volume" "prometheus" {
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   size              = 40
#   tags = local.common_tags
# }

# resource "aws_ebs_volume" "ollama" {
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   size              = 80
#   tags = {
#     Name = "ollama"
#   }
# }

# resource "aws_ebs_volume" "shared" {
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   size              = 40
#   tags = local.common_tags
# }
