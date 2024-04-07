Chef::Recipe.send(:include, Hops::Helpers)

# Deploy RBAC rule for Hopsworks user
template "#{node['kube-hops']['conf_dir']}/hopsworks-rbac.yaml" do
  source "hopsworks-rbac.erb"
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
end

kube_hops_kubectl 'apply_hopsworks_rbac' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  url "#{node['kube-hops']['conf_dir']}/hopsworks-rbac.yaml"
end

# TODO (Fabio) : authentication and deploy default images
hopsworks_ip = private_recipe_ip('hopsworks', 'default')
hopsworks_https_port = 8181
if node.attribute?('hopsworks')
  if node['hopsworks'].attribute?('https') and node['hopsworks']['https'].attribute?('port')
    hopsworks_https_port = node['hopsworks']['https']['port']
  end
end

node.override['kube-hops']['pki']['ca_api'] = "#{hopsworks_ip}:#{hopsworks_https_port}"

if node.attribute?('hopsworks')
  if node['hopsworks'].attribute?('user')
    node.override['kube-hops']['pki']['ca_api_user'] = node['hopsworks']['user']
  end
end

# Push default images on the registry
if not node['kube-hops']['docker_img_tar_url'].eql?("")
  hops_images = "#{Chef::Config['file_cache_path']}/docker-images.tar"
  remote_file hops_images do
    source node['kube-hops']['docker_img_tar_url']
    owner node['kube-hops']['user']
    group node['kube-hops']['group']
    mode "0644"
  end

  bash "load" do
    user 'root'
    group 'root'
    code <<-EOH
      docker load < #{hops_images}
    EOH
  end
else
  # TODO(Fabio): pull from registry
end

registry_host=consul_helper.get_service_fqdn("registry")
bash "tag_and_push" do
    user "root"
    code <<-EOH
      set -e
      for image in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep #{node['kube-hops']['docker_img_version']})
      do
        img_name=(${image//\// })
        docker tag $image #{registry_host}:#{node['hops']['docker']['registry']['port']}/${img_name[1]}
        docker push #{registry_host}:#{node['hops']['docker']['registry']['port']}/${img_name[1]}
      done
    EOH
end

if node['kube-hops']['docker_img_reg_url'].eql?("")
  node.override['kube-hops']['docker_img_reg_url'] = registry_host + ":#{node['hops']['docker']['registry']['port']}"
end

include_recipe "kube-hops::hops-system"
include_recipe "kube-hops::filebeat"

# Apply node taints
node['kube-hops']['taints'].split(")").each do |node_taint|
  node_taint_splits = node_taint[1, node_taint.length-1].split(",")
  node_name = node_taint_splits[0]
  taint = node_taint_splits[1]

  kube_hops_kubectl "#{taint}" do
    user node['kube-hops']['user']
    group node['kube-hops']['group']
    k8s_node node_name
    action :taint
  end
end

# Apply node labels
node['kube-hops']['labels'].split(")").each do |node_label|
  node_label_splits = node_label[1, node_label.length-1].split(",")
  node_name = node_label_splits[0]
  label = node_label_splits[1]

  kube_hops_kubectl "#{label}" do
    user node['kube-hops']['user']
    group node['kube-hops']['group']
    k8s_node node_name
    action :label
  end
end

if node['kube-hops']['kserve']['enabled'].casecmp?("true")
  include_recipe "kube-hops::kserve"
end
include_recipe "kube-hops::hopsmon"

directory "#{node['kube-hops']['assets_dir']['fuse']}" do
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  mode '0700'
  action :create
end



# create and apply yml files required for fuse related stuff
smart_device_manager_file = "smart-device-manager-plugin.yml"
hopsfsmount_apparmor_profile = "hopsfsmount-apparmor-profile.yml"
apparmor_enabled = is_apparmor_enabled()

template "#{node['kube-hops']['assets_dir']['fuse']}/#{smart_device_manager_file}" do
  source "smart-device-manager-plugin.yml.erb"
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
end

template "#{node['kube-hops']['assets_dir']['fuse']}/#{hopsfsmount_apparmor_profile }" do
  source "hopsfsmount-apparmor-profile.yml.erb"
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  only_if { apparmor_enabled && node['hops']['docker']['load-hopsfsmount-apparmor-profile'].casecmp?("true") }
end

kube_hops_kubectl 'smart_device_manager' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  url "#{node['kube-hops']['assets_dir']['fuse']}/#{smart_device_manager_file}"
end

kube_hops_kubectl 'hopsfsmount_apparmor_profile' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  url "#{node['kube-hops']['assets_dir']['fuse']}/#{hopsfsmount_apparmor_profile}"
  only_if { apparmor_enabled && node['hops']['docker']['load-hopsfsmount-apparmor-profile'].casecmp?("true")}
end

# install helm
helm_version = node['kube-hops']['helm']['version']
helm_url = "https://get.helm.sh/helm-v#{helm_version}-linux-amd64.tar.gz"
helm_tar = "#{Chef::Config['file_cache_path']}/helm-v#{helm_version}-linux-amd64.tar.gz"

remote_file helm_tar do
   source helm_url
   owner node['kube-hops']['user']
   group node['kube-hops']['group']
   mode "0644"
end

bash "install_helm" do
  user 'root'
  group 'root'
  environment ({ 'HOME' => ::Dir.home(node['kube-hops']['user']) })
  code <<-EOH
    tar -zxvf #{helm_tar} -C #{Chef::Config['file_cache_path']}
    mv #{Chef::Config['file_cache_path']}/linux-amd64/helm /usr/bin/helm
  EOH
end

# install spark-operator
bash "install_spark_operator" do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  environment ({ 'HOME' => ::Dir.home(node['kube-hops']['user']) })
  code <<-EOH
    helm repo add spark-operator https://kubeflow.github.io/spark-operator
    helm install spark-operator spark-operator/spark-operator --namespace spark-operator --create-namespace --set enableWebhook=true
  EOH
end


# create the hopsworks namespace
bash 'create_helm_install_namespace' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  environment ({ 'HOME' => ::Dir.home(node['kube-hops']['user']) })
  retries 6
  retry_delay 30
  code <<-EOH
      kubectl create namespace #{node['kube-hops']['helm']['install_namespace'] }
    EOH
  not_if "kubectl get namespaces | grep #{node['kube-hops']['helm']['install_namespace']}", :environment => { 'HOME' => ::Dir.home(node['kube-hops']['user']) }
end

# create secret docker registry secret
bash 'create_docker_registry_secret' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  environment ({ 'HOME' => ::Dir.home(node['kube-hops']['user']) })
  retries 6
  retry_delay 30
  code <<-EOH
      kubectl create secret docker-registry regcred --docker-server=docker.hops.works --docker-username=#{node['install']['enterprise']['username']} \
       --docker-password=#{node['install']['enterprise']['password']} --docker-email=gibson@hopsworks.ai --namespace=#{node['kube-hops']['helm']['install_namespace']}
  EOH
end

directory "#{node['kube-hops']['helm']['base_dir']}" do
  owner node['kube-hops']['user']
  group node['kube-hops']['group']
  mode '0700'
  action :create
end

remote_directory "#{node['kube-hops']['helm']['base_dir']}/helm/rss" do
  source "helm/rss"
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  mode 0700
end

# install rss
bash 'install_rss' do
  user node['kube-hops']['user']
  group node['kube-hops']['group']
  environment ({ 'HOME' => ::Dir.home(node['kube-hops']['user']) })
  retries 6
  retry_delay 30
  code <<-EOH
      cd #{node['kube-hops']['helm']['base_dir']}/helm/rss && helm install hopsworks-release --debug . --namespace #{node['kube-hops']['helm']['install_namespace']} --values values.yaml
  EOH
end




