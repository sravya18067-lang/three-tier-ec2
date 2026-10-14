output "app_url" {
  value = "http://${aws_eip.proxy.public_ip}"
}

output "bastion_public_ip" {
  value = aws_eip.proxy.public_ip
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "ssh_bastion" {
  value = "ssh -i <your-key>.pem ec2-user@${aws_eip.proxy.public_ip}"
}

output "ssh_private_app_via_bastion" {
  value = "ssh -i <your-key>.pem -J ec2-user@${aws_eip.proxy.public_ip} ec2-user@${aws_instance.app.private_ip}"
}
