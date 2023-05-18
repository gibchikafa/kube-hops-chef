# For Flannel (overlay network) to work we need to pass bridged IPv4 traffic to iptables’ chains
if node['platform_family'].eql?('rhel')
  # For centos, at least on a VM we need to load some kernel modules
  kernel_module 'bridge' do
    action :install
  end

  kernel_module 'br_netfilter' do
    action :install
  end
end

sysctl_param 'net.bridge.bridge-nf-call-iptables' do
  value 1
end

# Start the docker deamon
service 'docker' do
  action [:enable, :start]
end

case node['platform_family']
when "rhel"
  systemd_path = "/usr/lib/systemd/system"
when "debian"
  systemd_path = "/lib/systemd/system"
end

#Delete the default config.toml. It has the CRI plugin disabled
file '/etc/containerd/config.toml' do
  action :delete
  only_if { File.exist? '/etc/containerd/config.toml' }
end

bash "restart_containerd" do
  user 'root'
  group 'root'
  code <<-EOH
      systemctl restart containerd
  EOH
end

#install cri-dockerd
package_type = node['platform_family'].eql?("debian") ? "_amd64.deb" : ".x86_64.rpm"
cri_dockerd = "cri-dockerd-#{node['kube-hops']['cri_dockerd']['version']}#{package_type}"
remote_file "#{Chef::Config['file_cache_path']}/#{cri_dockerd}" do
  source "#{node['kube-hops']['cri_dockerd']['download_url']}/#{cri_dockerd}"
  owner 'root'
  group 'root'
  mode '0755'
  action :create
end

case node['platform_family']
when 'rhel'

  bash "install_cri_dockerd" do
    user 'root'
    group 'root'
    cwd Chef::Config['file_cache_path']
    code <<-EOH
        yum install -y #{cri_dockerd}
    EOH
  end

when 'debian'

  bash "install_cri_dockerd" do
    user 'root'
    group 'root'
    cwd Chef::Config['file_cache_path']
    code <<-EOH
        apt-get install -y ./#{cri_dockerd}
    EOH
  end
end

#create a service for cri-dockerd
template "#{systemd_path}/cri-docker.service" do
  source "cri-docker.service.erb"
  owner "root"
  group "root"
end

template "#{systemd_path}/cri-docker.socket" do
  source "cri-docker.socket.erb"
  owner "root"
  group "root"
end

bash "enable_cri_docker_service" do
  user 'root'
  group 'root'
  code <<-EOH
        systemctl daemon-reload
        systemctl enable cri-docker.service
        systemctl enable --now cri-docker.socket
        systemctl restart kubelet
  EOH
end

# Install g++ to be able to install http-cookie gem
case node['platform_family']
when 'rhel'
  package 'gcc-c++' do
    retries 10
    retry_delay 30
  end
when 'debian'
  package 'g++' do
    retries 10
    retry_delay 30
  end
end

# If AirGapped installation, download control plane images from download_url and load them 
if node['kube-hops']['image_repo'].eql?("")
  control_plane_images = "#{Chef::Config['file_cache_path']}/#{::File.basename(node['kube-hops']['control_plane_imgs_url'])}"
  remote_file control_plane_images do
    source node['kube-hops']['control_plane_imgs_url']
    owner 'root'
    group 'root'
    mode '0755'
    action :create
  end

  bash 'load_control_plane_imgs' do
    user 'root'
    group 'root'
    code <<-EOH
      docker load < #{control_plane_images}
    EOH
    action :run
  end
end

if node['kube-hops']['kserve']['enabled'].casecmp?("true")
  # Load kserve images
  # This is done in the default recipe so that both the master
  # and node recipe pull the necessary docker images
  docker_registry = "#{consul_helper.get_service_fqdn("registry")}:#{node['hops']['docker']['registry']['port']}"
  kserve_images = "#{Chef::Config['file_cache_path']}/kserve-v#{node['kube-hops']['kserve']['version']}.tgz"
  remote_file kserve_images do
    source node['kube-hops']['kserve']['img_tar_url']
    owner node['kube-hops']['user']
    group node['kube-hops']['group']
    mode "0644"
  end

  bash "load" do
    user 'root'
    group 'root'
    code <<-EOH
      docker load < #{kserve_images}
    EOH
  end

  knative_image_names = ["serving/cmd/controller", "serving/cmd/autoscaler", "serving/cmd/domain-mapping", "serving/cmd/activator", "serving/cmd/domain-mapping-webhook", "serving/cmd/queue", "serving/cmd/webhook", "net-istio/cmd/webhook", "net-istio/cmd/controller"]
  bash "push_knative_images_to_local_registry" do
    user 'root'
    group 'root'
    code <<-EOH
      KNATIVE_IMAGES=(#{knative_image_names.join(' ')})
      for NAME in "${KNATIVE_IMAGES[@]}"; do
        IMAGE=#{docker_registry}/$NAME:#{node['kube-hops']['knative']['version']}
        docker tag $NAME:#{node['kube-hops']['knative']['version']} $IMAGE
        docker push $IMAGE
        docker rmi $NAME:#{node['kube-hops']['knative']['version']}
      done
    EOH
  end

  kserve_image_names = ["kserve/kserve-controller", "kserve/agent", "kserve/storage-initializer"]
  bash "push_kserve_images_to_local_registry" do
    user 'root'
    group 'root'
    code <<-EOH
      KSERVE_IMAGES=(#{kserve_image_names.join(' ')})
      for NAME in "${KSERVE_IMAGES[@]}"; do
        IMAGE=#{docker_registry}/$NAME:#{node['kube-hops']['kserve']['version']}
        docker tag $NAME:#{node['kube-hops']['kserve']['version']} $IMAGE
        docker push $IMAGE
        docker rmi $NAME:#{node['kube-hops']['kserve']['version']}
      done
    EOH
  end

  certmanager_image_names = ["jetstack/cert-manager-controller", "jetstack/cert-manager-webhook", "jetstack/cert-manager-cainjector"]
  bash "push_certmanager_images_to_local_registry" do
    user 'root'
    group 'root'
    code <<-EOH
      CERTMANAGER_IMAGES=(#{certmanager_image_names.join(' ')})
      for NAME in "${CERTMANAGER_IMAGES[@]}"; do
        IMAGE=#{docker_registry}/$NAME:#{node['kube-hops']['cert-manager']['version']}
        docker tag $NAME:#{node['kube-hops']['cert-manager']['version']} $IMAGE
        docker push $IMAGE
        docker rmi $NAME:#{node['kube-hops']['cert-manager']['version']}
      done
    EOH
  end

  istio_image_names = ["istio/proxyv2", "istio/pilot"]
  bash "push_istio_images_to_local_registry" do
    user 'root'
    group 'root'
    code <<-EOH
      ISTIO_IMAGES=(#{istio_image_names.join(' ')})
      for NAME in "${ISTIO_IMAGES[@]}"; do
        IMAGE=#{docker_registry}/$NAME:#{node['kube-hops']['istio']['version'] }
        docker tag $NAME:#{node['kube-hops']['istio']['version'] } $IMAGE
        docker push $IMAGE
        docker rmi $NAME:#{node['kube-hops']['istio']['version'] }
      done
    EOH
  end

  tensorflow_images = ["tensorflow/serving:#{node['kube-hops']['kserve']['tensorflow']['version']}", "tensorflow/serving:#{node['kube-hops']['kserve']['tensorflow']['version']}-gpu"]
  bash "push_tensorflow_images_to_local_registry" do
    user 'root'
    group 'root'
    code <<-EOH
      TENSORFLOW_IMAGES=(#{tensorflow_images.join(' ')})
      for NAME in "${TENSORFLOW_IMAGES[@]}"; do
        IMAGE=#{docker_registry}/$NAME
        docker tag $NAME $IMAGE
        docker push $IMAGE
        docker rmi $NAME
      done
    EOH
  end

  bash "push_kubebuilder-kube-rbac-proxy_image_to_local_registry" do
    user 'root'
    group 'root'
    code <<-EOH
      IMAGE=kubebuilder/kube-rbac-proxy:v0.13.1
      docker tag $IMAGE  #{docker_registry}/$IMAGE
      docker push #{docker_registry}/$IMAGE
      docker rmi $IMAGE
    EOH
  end
end

remote_file "#{node['kube-hops']['monitoring']['kube-state-metrics-image-tar']}" do
  source node['kube-hops']['monitoring']['kube-state-metrics-image-url']
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  mode "0700"
end

bash 'load_kube_state_metrics_image' do
  user 'root'
  group 'root'
  code <<-EOH
      docker load < #{node['kube-hops']['monitoring']['kube-state-metrics-image-tar']}
  EOH
end


# Install gem as helper to send Hopsworks requrests to sign certificates
chef_gem 'http-cookie'

hopsworks_ip = private_recipe_ip('hopsworks', 'default')
hopsworks_https_port = 8181
if node.attribute?('hopsworks')
  if node['hopsworks'].attribute?('https') and node['hopsworks']['https'].attribute?('port')
    hopsworks_https_port = node['hopsworks']['https']['port']
  end
end

node.override['kube-hops']['pki']['ca_api'] = "#{hopsworks_ip}:#{hopsworks_https_port}"
