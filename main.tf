terraform {
  required_providers {
    oci = {
      source = "hashicorp/oci"
    }
  }
}

locals {
  ad = data.oci_identity_availability_domain.ad.name

  tcp_protocol  = "6"
  all_protocols = "all"
  anywhere      = "0.0.0.0/0"
  bastion_subnet_prefix = cidrsubnet(var.vcn_cidr, var.subnet_cidr_offset, 0)
  private_subnet_prefix = cidrsubnet(var.vcn_cidr, var.subnet_cidr_offset, 1)
}

variable "vcn_cidr" {
  default = "10.0.0.0/16"
}

variable "subnet_cidr_offset" {
  default = 5
}

variable "compartment_id" {
  type        = string
  description = "Compartment id value from OCI"
}

variable "ssh_public_key" {
}

variable "instance_image" {
  type        = string
  description = "image to be provisioned"
  default     = "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaacdxb2cpmyxtqfinev5vywq6yu4p47mgty6wjfd7xmrgauop6ieya"
}

variable "instance_shape" {
  default = "VM.Standard.E2.1.Micro"
}

variable "user_data" {
  default = <<EOF
#!/bin/bash -x
echo '################### webserver userdata begins #####################'
touch ~opc/userdata.`date +%s`.start
# echo '########## yum update all ###############'
# yum update -y
echo '########## basic webserver ##############'
yum install -y httpd
systemctl enable  httpd.service
systemctl start  httpd.service
echo '<html><head></head><body><pre><code>' > /var/www/html/test.html
hostname >> /var/www/html/test.html
echo '' >> /var/www/html/test.html
cat /etc/os-release >> /var/www/html/test.html
echo '</code></pre></body></html>' >> /var/www/html/test.html
firewall-offline-cmd --add-service=http
systemctl enable  firewalld
systemctl restart  firewalld
touch ~opc/userdata.`date +%s`.finish
echo '################### webserver userdata ends #######################'
EOF

}

provider "oci" {
  region              = "eu-frankfurt-1"
  auth                = "SecurityToken"
  config_file_profile = "mihaia"
}

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.compartment_id
  ad_number      = 3
}

resource "oci_core_vcn" "internal" {
  dns_label      = "internal"
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_id
  display_name   = "Internal VCN"
}

resource "oci_core_nat_gateway" "nat_gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  display_name   = "nat_gateway"
}

resource "oci_core_internet_gateway" "internet_gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  enabled        = true
  display_name   = "Public internet gateway"
}

resource "oci_load_balancer" "lb" {
  shape          = "100Mbps"
  compartment_id = var.compartment_id

  subnet_ids = [
    oci_core_subnet.public.id
  ]

  display_name = "lb"
  reserved_ips {
    id = oci_core_public_ip.test_reserved_ip.id
  }
}

resource "oci_core_public_ip" "test_reserved_ip" {
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"

  lifecycle {
    ignore_changes = [private_ip_id]
  }
}

resource "oci_load_balancer_backend" "lb_be" {
  load_balancer_id = oci_load_balancer.lb.id
  backendset_name  = oci_load_balancer_backend_set.lb_bes.name
  ip_address       = oci_core_instance.stage.private_ip
  port             = 80
  backup           = false
  drain            = false
  offline          = false
  weight           = 1
}

resource "oci_load_balancer_backend_set" "lb_bes" {
  name             = "lb-bes"
  load_balancer_id = oci_load_balancer.lb.id
  policy           = "ROUND_ROBIN"

  health_checker {
    port                = "80"
    protocol            = "HTTP"
    response_body_regex = ".*"
    url_path            = "/test.html"
  }
}

resource "oci_load_balancer_backend" "lb_be_ssh" {
  load_balancer_id = oci_load_balancer.lb.id
  backendset_name  = oci_load_balancer_backend_set.lb_bes_ssh.name
  ip_address       = oci_core_instance.stage.private_ip
  port             = 22
  backup           = false
  drain            = false
  offline          = false
  weight           = 1
}

resource "oci_load_balancer_backend_set" "lb_bes_ssh" {
  name             = "lb-bes-ssh"
  load_balancer_id = oci_load_balancer.lb.id
  policy           = "ROUND_ROBIN"
  health_checker {
    port                = "22"
    protocol            = "TCP"
    response_body_regex = ".*"
    url_path            = "/"
  }
}

resource "oci_load_balancer_listener" "lb_listener1" {
  load_balancer_id         = oci_load_balancer.lb.id
  name                     = "http"
  default_backend_set_name = oci_load_balancer_backend_set.lb_bes.name
  port                     = 80
  protocol                 = "HTTP"

  connection_configuration {
    idle_timeout_in_seconds = "2"
  }
}

resource "oci_load_balancer_listener" "lb_listener_ssh" {
  load_balancer_id         = oci_load_balancer.lb.id
  name                     = "tcp"
  default_backend_set_name = oci_load_balancer_backend_set.lb_bes_ssh.name
  port                     = 22
  protocol                 = "TCP"

  connection_configuration {
    idle_timeout_in_seconds = "20"
  }
}

resource "oci_core_subnet" "private" {
  availability_domain        = local.ad
  cidr_block                 = local.private_subnet_prefix
  display_name               = "private"
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.internal.id
  route_table_id             = oci_core_route_table.private.id

  security_list_ids = [
    oci_core_security_list.private.id,
  ]
  
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  display_name   = "private"

  route_rules {
    destination       = local.anywhere
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway.id
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_id
  display_name   = "private"
  vcn_id         = oci_core_vcn.internal.id

  ingress_security_rules {
    source   = local.bastion_subnet_prefix
    protocol = 6

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.bastion_subnet_prefix

    tcp_options {
      min = 80
      max = 80
    }
  }

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
}

resource "oci_core_subnet" "public" {
  vcn_id                     = oci_core_vcn.internal.id
  cidr_block                 = local.bastion_subnet_prefix
  compartment_id             = var.compartment_id
  display_name               = "Public subnet"
  prohibit_public_ip_on_vnic = false
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.routetable_public.id
  security_list_ids          = [oci_core_security_list.securitylist_public.id]
}

resource "oci_core_route_table" "routetable_public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  display_name   = "routetable_public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.internet_gateway.id
  }
}

resource "oci_core_security_list" "securitylist_public" {
  display_name   = "public"
  compartment_id = oci_core_vcn.internal.compartment_id
  vcn_id         = oci_core_vcn.internal.id

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_instance" "stage" {
  availability_domain = local.ad
  compartment_id      = var.compartment_id
  display_name        = "stage"
  shape               = var.instance_shape

  source_details {
    source_id   = var.instance_image
    source_type = "image"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(var.user_data)
  }

  timeouts {
    create = "10m"
  }
}

output "lb_public_ip" {
  value = [oci_load_balancer.lb.ip_address_details]
}

output "example_ssh_command" {
  value = "ssh -i $PRIVATE_KEY_PATH opc@${oci_load_balancer.lb.ip_address_details[0].ip_address}"
}