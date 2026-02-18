terraform {
  required_version = ">= 1.6.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.1"
    }
  }
}

# Credentials are read from OS_* environment variables or clouds.yaml.
# Source your OpenStack RC file before running terraform commands.
provider "openstack" {}
