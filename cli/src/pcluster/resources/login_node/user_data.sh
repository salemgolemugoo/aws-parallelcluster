Content-Type: multipart/mixed; boundary="==BOUNDARY=="
MIME-Version: 1.0

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"
MIME-Version: 1.0

#!/bin/bash -x

which dnf 2>/dev/null; dnf=$?
which yum 2>/dev/null; yum=$?

if [ "${!dnf}" == "0" ]; then
  echo "proxy=${DnfProxy}" >> /etc/dnf/dnf.conf
elif [ "${!yum}" == "0" ]; then
  echo "proxy=${YumProxy}" >> /etc/yum.conf
else
  echo "Not yum system"
fi

which apt-get && echo "Acquire::http::Proxy \"${AptProxy}\";" >> /etc/apt/apt.conf || echo "Not apt system"

proxy=${ProxyServer}
if [ "${!proxy}" != "NONE" ]; then
  proxy_host=$(echo "${!proxy}" | awk -F/ '{print $3}' | cut -d: -f1)
  proxy_port=$(echo "${!proxy}" | awk -F/ '{print $3}' | cut -d: -f2)
  echo -e "[Boto]\nproxy = ${!proxy_host}\nproxy_port = ${!proxy_port}\n" >/etc/boto.cfg
  cat >> /etc/profile.d/proxy.sh <<PROXY
export http_proxy="${!proxy}"
export https_proxy="${!proxy}"
export no_proxy="localhost,127.0.0.1,169.254.169.254"
export HTTP_PROXY="${!proxy}"
export HTTPS_PROXY="${!proxy}"
export NO_PROXY="localhost,127.0.0.1,169.254.169.254"
PROXY
fi

--==BOUNDARY==
Content-Type: text/cloud-config; charset=us-ascii
MIME-Version: 1.0

package_update: false
package_upgrade: false
repo_upgrade: none

datasource_list: [ Ec2, None ]

output:
  all: "| tee -a /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/ttyS0"
write_files:
  - path: /tmp/bootstrap.sh
    permissions: '0744'
    owner: root:root
    content: |
      #!/bin/bash -x

      function error_exit
      {
        echo "Bootstrap failed with error: $1"
        # wait logs flush before signaling the failure
        sleep 10
        # TODO: add possibility to override this behavior and keep the instance for debugging
        shutdown -h now
        exit 1
      }
      function vendor_cookbook
      {
        mkdir /tmp/cookbooks
        cd /tmp/cookbooks
        tar -xzf /etc/chef/aws-parallelcluster-cookbook.tgz
        HOME_BAK="${!HOME}"
        export HOME="/tmp"
        for d in `ls /tmp/cookbooks`; do
          cd /tmp/cookbooks/$d
          LANG=en_US.UTF-8 /opt/cinc/embedded/bin/berks vendor /etc/chef/cookbooks --delete || error_exit 'Vendoring cookbook failed.'
        done;
        export HOME="${!HOME_BAK}"
      }

      export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/aws/bin
      # Load ParallelCluster environment variables
      [ -f /etc/parallelcluster/pcluster_cookbook_environment.sh ] && . /etc/parallelcluster/pcluster_cookbook_environment.sh

      $CFN_BOOTSTRAP_VIRTUALENV_PATH/cfn-init -s ${AWS::StackName} -v -c deployFiles -r ${LaunchTemplateResourceId} --region ${AWS::Region} --url ${CloudFormationUrl} --role ${CfnInitRole} || error_exit 'Failed to bootstrap the login node. Please check /var/log/cfn-init.log in the login node or in CloudWatch logs. Please refer to https://docs.aws.amazon.com/parallelcluster/latest/ug/troubleshooting-v3.html#troubleshooting-v3-get-logs for more details on ParallelCluster logs.'

      [ -f /etc/profile.d/proxy.sh ] && . /etc/profile.d/proxy.sh

      # Configure AWS CLI using the expected overrides, if any.
      [ -f /etc/profile.d/aws-cli-default-config.sh ] && . /etc/profile.d/aws-cli-default-config.sh

      custom_cookbook=${CustomChefCookbook}
      export _region=${AWS::Region}

      s3_url=${AWS::URLSuffix}
      if [ "${!custom_cookbook}" != "NONE" ]; then
        if [[ "${!custom_cookbook}" =~ ^s3://([^/]*)(.*) ]]; then
          # Set the socket connection timeout to 15s. Emperically, it seems like the actual
          # timeout is 8x(cli-connect-timeout). i.e. if cli-connection-timeout is set to
          # 60s, the call will timeout the connect attempt at 8m. Setting it to 15s, causes
          # each attempt to take 240s, so 2m * 3 attempts will result in a failure after 6
          # minutes.
          S3API_RESULT=$(AWS_RETRY_MODE=standard aws s3api get-bucket-location --cli-connect-timeout 15 --bucket ${!BASH_REMATCH[1]} --region ${AWS::Region} 2>&1) || error_exit "${!S3API_RESULT}"
          bucket_region=$(echo "${!S3API_RESULT}" | jq -r '.LocationConstraint')
          if [[ "${!bucket_region}" == null ]]; then
            bucket_region="us-east-1"
          fi
          cookbook_url=$(aws s3 presign "${!custom_cookbook}" --region "${!bucket_region}")
        else
          cookbook_url=${!custom_cookbook}
        fi
      fi
      export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/aws/bin
      export parallelcluster_version=aws-parallelcluster-${ParallelClusterVersion}
      export cookbook_version=${CookbookVersion}
      export chef_version=${ChefVersion}
      export berkshelf_version=${BerkshelfVersion}
      if [ -f /opt/parallelcluster/.bootstrapped ]; then
        installed_version=$(cat /opt/parallelcluster/.bootstrapped)
        if [ "${!cookbook_version}" != "${!installed_version}" ]; then
          cookbook_version_number=$(echo ${!cookbook_version} | awk -F- '{print $NF}')
          installed_version_number=$(echo ${!installed_version} | awk -F- '{print $NF}')
          error_exit "This AMI was created with ParallelCluster ${!installed_version_number}, but is trying to be used with ParallelCluster ${!cookbook_version_number}. Please either use an AMI created with ParallelCluster ${!cookbook_version_number} or change your ParallelCluster to ${!installed_version_number}"
        fi
      else
        error_exit "This AMI was not baked by ParallelCluster. Please use pcluster build-image command to create an AMI by providing your AMI as parent image."
      fi
      if [ "${!custom_cookbook}" != "NONE" ]; then
        curl --retry 3 -v -L -o /etc/chef/aws-parallelcluster-cookbook.tgz ${!cookbook_url}
        vendor_cookbook
      fi
      cd /tmp

      {
        CINC_CMD="cinc-client --local-mode --config /etc/chef/client.rb --log_level info --logfile /var/log/chef-client.log --force-formatter --no-color --chef-zero-port 8889 --json-attributes /etc/chef/dna.json"
        pushd /etc/chef &&
        ${!CINC_CMD} --override-runlist aws-parallelcluster-entrypoints::init &&
        /opt/parallelcluster/scripts/fetch_and_run -preinstall -c /opt/parallelcluster/shared_login_nodes/cluster-config.yaml &&
        ${!CINC_CMD} --override-runlist aws-parallelcluster-entrypoints::config &&
        /opt/parallelcluster/scripts/fetch_and_run -postinstall -c /opt/parallelcluster/shared_login_nodes/cluster-config.yaml &&
        ${!CINC_CMD} --override-runlist aws-parallelcluster-entrypoints::finalize &&
        popd
      } || error_exit 'Failed to run bootstrap recipes. Please check /var/log/chef-client.log in the login node or in CloudWatch logs.'

      if [ ! -f /opt/parallelcluster/.bootstrapped ]; then
        echo ${!cookbook_version} | tee /opt/parallelcluster/.bootstrapped
      fi

--==BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0

#!/bin/bash -x

function error_exit
{
  echo "Timed-out when bootstrapping instance"
  sleep 10  # Allow logs to propagate
  shutdown -h now
  exit 1
}

if [ "${Timeout}" == "NONE" ]; then
  /tmp/bootstrap.sh
else
  timeout ${Timeout} /tmp/bootstrap.sh || error_exit
fi

# Notify the AutoScalingGroup about the successful bootstrap
IMDS_TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" -v http://169.254.169.254/latest/meta-data/instance-id)
aws autoscaling complete-lifecycle-action --auto-scaling-group-name "${AutoScalingGroupName}" --lifecycle-hook-name "${LaunchingLifecycleHookName}" --instance-id "$INSTANCE_ID" --lifecycle-action-result CONTINUE --region "${AWS::Region}"
# End of file
--==BOUNDARY==
