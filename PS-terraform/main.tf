terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.45.0"
    }
  }
}

provider "openstack" {
  user_name = "17129_sigma-neptunium 1" #Имя пользователя Openstack
  tenant_name = "sigma-neptunium 1" #Имя проекта (тенант) Openstack
  password = "" # Пароль для аутентификации.
  auth_url    = "https://auth.pscloud.io/v3/"
  region      = "kz-ala-1"
}

variable "image_id" {
  default = "c8a3b89e-fd30-4d41-8c8e-57f8f5708af4"
}

resource "openstack_compute_keypair_v2" "ssh" {
  name       = "sigma"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC/eNDQn5YGET0OsN3OCDDEQXOO7NRdRLm5gmfJ0O7exF9S2lW/LQVuE+Nmq9GlW362Hq9TRyEZVRXD+dOVWQFNdEj+0P0Sdwl4vlkQ4B0aJNmKnb8pYcuSYoLRFNfocqP1KRAPeJAMhUHdZoC1ykrLG2+uoed6vwuJVneJL66O7SI1iEfrC6ju6NFCeLnFqqPkNu1V/LhIAgZbP0zPbv3AX9fDBANpChMVLSUqiA57FNwD0iuEHP8jhMaIeLSSw0XUqit1CBqn2kz20qnDxQt47oOuVmEXefDEhXfr72hmDyZmnKlix29muOdzQyV+FyzlhhECa5OOv4rRU3sUCxn5"
}

resource "openstack_compute_secgroup_v2" "sg_name" {
  name = "sg_name"
  description = "security group for HAproxy"
  rule {
    from_port   = 22
    to_port     = 22
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
  rule {
    from_port   = -1
    to_port     = -1
    ip_protocol = "icmp"
    cidr        = "0.0.0.0/0"
  }
  rule {
    from_port   = 443
    to_port     = 443
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
  rule {
    from_port   = 80
    to_port     = 80
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
}

resource "openstack_networking_network_v2" "private_network" {
  name             = "private-net"
  admin_state_up   = "true"
}

resource "openstack_networking_subnet_v2" "private_subnet" {
  name             = "subnet_name"
  network_id       = openstack_networking_network_v2.private_network.id
  cidr             = "192.168.100.0/24"
  dns_nameservers  = [
                      "195.210.46.195",
                      "195.210.46.132"
                      ]
  ip_version       = 4
  depends_on = [openstack_networking_network_v2.private_network]
}

resource "openstack_networking_router_v2" "router" {
  name             = "router_name"
  external_network_id = "83554642-6df5-4c7a-bf55-21bc74496109" #UUID of the floating ip network
  admin_state_up   = "true"
  depends_on = [openstack_networking_network_v2.private_network]
}

resource "openstack_networking_router_interface_v2" "router_interface" {
  router_id        = openstack_networking_router_v2.router.id
  subnet_id        = openstack_networking_subnet_v2.private_subnet.id
  depends_on       = [openstack_networking_router_v2.router]
}

# Control VM: 192.168.100.10
resource "openstack_networking_port_v2" "control_port" {
  name       = "control-port"
  network_id = openstack_networking_network_v2.private_network.id

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.private_subnet.id
    ip_address = "192.168.100.10"
  }
}

# HAProxy VM: 192.168.100.20
resource "openstack_networking_port_v2" "haproxy_port" {
  name       = "haproxy-port"
  network_id = openstack_networking_network_v2.private_network.id

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.private_subnet.id
    ip_address = "192.168.100.20"
  }
}

# Apache VMs: 192.168.100.30, .31, .32 (3 сервера)
resource "openstack_networking_port_v2" "apache_ports" {
  count      = 3
  name       = "apache-port-${count.index}"
  network_id = openstack_networking_network_v2.private_network.id

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.private_subnet.id
    ip_address = cidrhost(openstack_networking_subnet_v2.private_subnet.cidr, 30 + count.index)
  }
}
resource "openstack_blockstorage_volume_v3" "control_volume" {
  name       = "control-volume"
  size       = 10              # размер в ГБ
  image_id  = var.image_id       # образ для создания тома
  volume_type         = "ceph-ssd"
}

#####################################
# Создание тома для HAProxy инстанса
#####################################
resource "openstack_blockstorage_volume_v3" "haproxy_volume" {
  name       = "haproxy-volume"
  size       = 10
  image_id  = var.image_id
  volume_type         = "ceph-ssd"
}

#####################################
# Создание томов для Apache инстансов (3 штуки)
#####################################
resource "openstack_blockstorage_volume_v3" "apache_volume" {
  count      = 3
  name       = "apache-volume-${count.index}"
  size       = 10
  image_id  = var.image_id
  volume_type         = "ceph-ssd"
}

# 1. Control VM (для запуска ansible-playbook)
resource "openstack_compute_instance_v2" "control_instance" {
  name        = "control-instance"
  image_id  = var.image_id         # Укажите актуальное имя образа CentOS
  flavor_name = "d1.ram2cpu1"
  security_groups = [openstack_compute_secgroup_v2.sg_name.name]
  depends_on = [openstack_compute_secgroup_v2.sg_name]
  network {
    port = openstack_networking_port_v2.control_port.id
  }
  block_device {
    uuid                  = openstack_blockstorage_volume_v3.control_volume.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }
  user_data = <<-EOF
    #cloud-config
    users:
     - name: centos
       sudo: ALL=(ALL) NOPASSWD:ALL
       plain_text_passwd: Cisco
       lock_passwd: false
    password: Cisco
    chpasswd: 
      expire: False
    ssh_pwauth: True
    runcmd:
      - sudo yum update -y
      - sudo yum install -y epel-release 
      - sudo yum install -y ansible python3-pip awscli s3cmd
      - aws s3 cp s3://ans/ /home/centos --recursive --no-sign-request --endpoint-url https://object.pscloud.io/
  EOF

}

# 2. HAProxy VM (на неё вешается Floating IP)
resource "openstack_compute_instance_v2" "haproxy_instance" {
  name        = "haproxy-instance"
  image_id  = var.image_id
  flavor_name = "d1.ram2cpu1"
  security_groups = [openstack_compute_secgroup_v2.sg_name.name]
  depends_on = [openstack_compute_secgroup_v2.sg_name, openstack_blockstorage_volume_v3.haproxy_volume]

  network {
    port = openstack_networking_port_v2.haproxy_port.id
  }

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.haproxy_volume.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }
  user_data         = <<-EOF
    #cloud-config
    users:
     - name: centos
       sudo: ALL=(ALL) NOPASSWD:ALL
       plain_text_passwd: Cisco
       lock_passwd: false
    password: Cisco
    chpasswd: 
      expire: False
    ssh_pwauth: True
    EOF
}
# 3. Apache VMs (3 сервера)
resource "openstack_compute_instance_v2" "apache_instance" {
  count       = 3
  name        = "apache-instance-${count.index}"
  image_id  = var.image_id
  flavor_name = "d1.ram2cpu1"
  security_groups = [openstack_compute_secgroup_v2.sg_name.name]
  depends_on = [openstack_compute_secgroup_v2.sg_name]
  network {
    port = openstack_networking_port_v2.apache_ports[count.index].id
  }

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.apache_volume[count.index].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }
  user_data         = <<-EOF
    #cloud-config
    users:
     - name: centos
       sudo: ALL=(ALL) NOPASSWD:ALL
       plain_text_passwd: Cisco
       lock_passwd: false
    password: Cisco
    chpasswd: 
      expire: False
    ssh_pwauth: True
    EOF
}

resource "openstack_networking_floatingip_v2" "instance_fip" {
  pool             = "FloatingIP Net"
}


resource "openstack_compute_floatingip_associate_v2" "haproxy_fip_assoc" {
  floating_ip = openstack_networking_floatingip_v2.instance_fip.address
  instance_id = openstack_compute_instance_v2.haproxy_instance.id
}
