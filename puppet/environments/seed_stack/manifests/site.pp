node 'standalone.seed-stack.local' {
  class { 'seed_stack::controller':
    advertise_addr    => $ipaddress_eth0,
    controller_addrs  => [$ipaddress_eth0],
    controller_worker => true,
  }
  class { 'seed_stack::worker':
    advertise_addr        => $ipaddress_eth0,
    controller_addrs      => [$ipaddress_eth0],
    controller_worker     => true,
    xylem_backend         => 'standalone.seed-stack.local',
    gluster_client_manage => false,
  }

  # We need at least two replicas, so they both have to live on the same node
  # in the single-machine setup.
  file { ['/data/', '/data/brick1/', '/data/brick2']:
    ensure  => 'directory',
  }

  package { 'redis-server': ensure => 'installed' }
  ->
  service { 'redis-server': ensure => 'running' }
  ->
  class { 'seed_stack::xylem':
    gluster_mounts  => ['/data/brick1/', '/data/brick2'],
    gluster_hosts   => ['standalone.seed-stack.local'],
    gluster_replica => 2,
  }

  # If this is sharing with seed_stack::worker, we need to add listen_addr so
  # that seed_stack::router doesn't mask our server blocks.
  class { 'seed_stack::load_balancer':
    listen_addr => $ipaddress_eth0,
  }

  include docker_registry

  class { 'seed_stack::mc2':
    infr_domain   => 'infr.standalone.seed-stack.local',
    hub_domain    => 'hub.standalone.seed-stack.local',
    marathon_host => $ipaddress_lo,
  }
}

# Keep track of node IP addresses across the cluster
# FIXME: A better, more automatic way to do this
class seed_stack_cluster {
  # The hostmanager vagrant plugin manages the hosts entries for us, but
  # various things still need the IPs. Bleh.
  $controller_ip = '192.168.55.11'
  $worker_ip = '192.168.55.21'
}

node 'controller.seed-stack.local' {
  include seed_stack_cluster

  file { ['/data/', '/data/brick1/', '/data/brick2']:
    ensure  => 'directory',
  }

  package { 'redis-server': ensure => 'installed' }
  ->
  service { 'redis-server': ensure => 'running' }
  ->
  class { 'seed_stack::xylem':
    gluster_mounts  => ['/data/brick1/', '/data/brick2'],
    gluster_hosts   => ['controller.seed-stack.local'],
    gluster_replica => 2,
  }

  class { 'seed_stack::controller':
    advertise_addr   => $seed_stack_cluster::controller_ip,
    controller_addrs => [$seed_stack_cluster::controller_ip],
  }

  include seed_stack::load_balancer

  class { 'seed_stack::mc2':
    infr_domain   => 'infr.controller.seed-stack.local',
    hub_domain    => 'hub.controller.seed-stack.local',
    marathon_host => $ipaddress_lo,
  }
}

node 'worker.seed-stack.local' {
  include seed_stack_cluster

  class { 'seed_stack::worker':
    advertise_addr   => $seed_stack_cluster::worker_ip,
    controller_addrs => [$seed_stack_cluster::controller_ip],
    xylem_backend    => 'controller.seed-stack.local',
  }

  include docker_registry
}

# Standalone Docker registry for testing
# TODO: Move this to the seed_stack module once we have a proper system for
# distributing the CA cert.
class docker_registry {
  # NOTE: This cert wrangling is only good for a single machine. We need some
  # other mechanism to get our certs to the right place in a multi-node setup.
  package { 'openssl': }
  ->
  file { '/var/docker-certs': ensure => directory }
  ->
  openssl::certificate::x509 { 'docker-registry':
    country      => 'NT',
    organization => 'seed-stack',
    commonname   => 'docker-registry.service.consul',
    base_dir     => '/var/docker-certs',
  }
  ~>
  file { '/usr/local/share/ca-certificates/docker-registry.crt':
    ensure => link,
    target => '/var/docker-certs/docker-registry.crt',
  }
  ~>
  exec { 'update-ca-certificates':
    refreshonly => true,
    command     => '/usr/sbin/update-ca-certificates',
    notify      => [Service['docker']],
  }

  docker::run { 'registry':
    image            => 'registry:2',
    ports            => ['5000:5000'],
    volumes          => [
      '/var/docker-registry:/var/lib/registry',
      '/var/docker-certs:/certs',
    ],
    env              => [
      'REGISTRY_HTTP_TLS_CERTIFICATE=/certs/docker-registry.crt',
      'REGISTRY_HTTP_TLS_KEY=/certs/docker-registry.key',
    ],
    extra_parameters => ['--restart=always'],
    require          => [Service['docker']],
    subscribe        => [Openssl::Certificate::X509['docker-registry']],
  }
}
