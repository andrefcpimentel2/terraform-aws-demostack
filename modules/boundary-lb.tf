
# resource "aws_lb" "boundary-controller" {
#    name = "${var.namespace}-boundary-cont"
#   load_balancer_type = "network"
#   internal           = false
# subnets         = aws_subnet.demostack.*.id

#  tags = {
#     Name           = "${var.namespace}-boundary-cont"
#     owner          = var.owner
#     created-by     = var.created-by
#     sleep-at-night = var.sleep-at-night
#     TTL            = var.TTL
#   }
# }

# resource "aws_lb_target_group" "boundary-controller" {
#   name     = "${var.namespace}-boundary-cont"
#   port     = 9200
#   protocol = "TCP"
#   vpc_id   = aws_vpc.demostack.id

#   stickiness  {
#     enabled = false
#      type    = "lb_cookie"
#   }
#   tags = {
#     Name           = "${var.namespace}-boundary-cont"
#     owner          = var.owner
#     created-by     = var.created-by
#     sleep-at-night = var.sleep-at-night
#     TTL            = var.TTL
#   }
# }

# resource "aws_lb_target_group_attachment" "boundary-controller" {
#   count            = var.servers
#   target_group_arn = aws_lb_target_group.boundary-controller.arn
#   target_id        = aws_instance.servers[count.index].id
#   port             = 9200
# }

# resource "aws_lb_listener" "boundary-controller" {
#   load_balancer_arn = aws_lb.boundary-controller.arn
#   port              = "9200"
#   protocol          = "TCP"

#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.boundary-controller.arn
#   }
# }
