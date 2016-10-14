#! /bin/bash -e

# ---
# RightScript Name: RL10 Linux Setup Automatic Upgrade
# Description: Subscribes to receive updates to the RightLink agent automatically.
#   Creates a cron job that performs a daily check to see if an upgrade to RightLink
#   is available and upgrades if there is.
# Inputs:
#   UPGRADES_FILE_LOCATION:
#     Input Type: single
#     Category: RightScale
#     Description: External location of 'upgrades' file
#     Default: text:https://rightlink.rightscale.com/rightlink/upgrades
#     Required: false
#     Advanced: true
#   ENABLE_AUTO_UPGRADE:
#     Input Type: single
#     Category: RightScale
#     Description: Enables or disables automatic upgrade of RightLink10.
#     Default: text:true
#     Required: false
#     Advanced: true
#     Possible Values:
#       - text:true
#       - text:false
# ...
#

# Determine directory location of rightlink / rsc
[[ -e /usr/local/bin/rsc ]] && bin_dir=/usr/local/bin || bin_dir=/opt/bin
rsc=${bin_dir}/rsc

# Will compare current version of rightlink 'running' with latest version provided from 'upgrades'
# file. If they differ, will update to latest version.  Note that latest version can be an older version
# if a downgrade is best as found in the $UPGRADES_FILE_LOCATION
UPGRADES_FILE_LOCATION=${UPGRADES_FILE_LOCATION:-"https://rightlink.rightscale.com/rightlink/upgrades"}

# Add entry in /etc/cron.d/ to check and execute an upgrade for rightlink daily.
cron_file='/etc/cron.d/rightlink-upgrade'
exec_file="${bin_dir}/rightlink_check_upgrade"
# Add entry in /etc/systemd/system if system doesn't support cron
service_file='/etc/systemd/system/rightlink-upgrade.service'
timer_file='/etc/systemd/system/rightlink-upgrade.timer'

# Grab toggle option to enable
if [[ "$ENABLE_AUTO_UPGRADE" == "false" ]]; then
  if [[ -e $exec_file ]]; then
    sudo rm -f ${timer_file} ${cron_file} ${exec_file} ${service_file}
    echo "Automatic upgrade disabled."
  else
    echo "Automatic upgrade never enabled - no action done"
  fi
else
  # If cron file already exists, will recreate it and update cron config with new random times.
  scheduled_hour=$(( $RANDOM % 24 ))
  scheduled_minute=$(( $RANDOM % 60 ))

  # Generate executable script to run by cron
  sudo dd of="${exec_file}" 2>/dev/null <<EOF
#! /bin/bash

# This file is autogenerated. Do not edit as changes will be overwritten.

current_version=\$($rsc --retry=5 --timeout=10 rl10 show /rll/proc/version)

# Fetch information about what we should become. The "upgrades" file consists of lines formatted
# as "current_version:new_version". If the "upgrades" file does not exist,
# or if the current version is not in the file, no upgrade is done.
re="^\s*\${current_version}\s*:\s*(\S+)\s*$"
upgrade_url="${UPGRADES_FILE_LOCATION}"
match=\$(curl --silent --show-error --retry 3 \$upgrade_url | egrep \${re} || true)
if [[ "\$match" =~ \$re ]]; then
  desired_version="\${BASH_REMATCH[1]}"
  echo "RightlinkUpgrader: Upgrade found from \$current_version to \$desired_version"

  rsc_command="schedule_right_script /api/right_net/scheduler/schedule_right_script"
  $rsc --rl10 cm15 \${rsc_command} right_script="RL10 Linux Upgrade" "arguments=UPGRADE_VERSION=\$desired_version"
else
  echo "RightlinkUpgrader: No upgrades found for \$current_version in upgrade file \$upgrade_url"
  exit 0
fi
EOF
  sudo chown rightlink:rightlink ${exec_file}
  sudo chmod 0700 ${exec_file}

  if [[ $(cat /etc/os-release 2>/dev/null) =~ CoreOS ]]; then
    # Generate service file to be executed by systemd timers
    sudo dd of="${service_file}" 2>/dev/null <<EOF
[Unit]
Description=Runs the RL10 Linux Upgrade script

[Service]
Type=oneshot
ExecStart=${exec_file}
EOF

    # Generate timer file to determine when to run the upgrade script
    sudo dd of="${timer_file}" 2>/dev/null <<EOF
[Unit]
Description=Run rightlink-upgrade.service once daily

[Timer]
OnCalendar=*-*-* ${scheduled_hour}:${scheduled_minute}
EOF

    sudo systemctl daemon-reload
    echo "Configured systemd timer at ${timer_file} to run ${service_file} daily."
  else
    sudo bash -c "umask 077 && echo '${scheduled_minute} ${scheduled_hour} * * * rightlink ${exec_file}' > ${cron_file}"

    # Set perms regardless of umask since the file could be overwritten with existing perms.
    sudo chmod 0600 ${cron_file}
    echo "Configured cron file at ${cron_file} to run daily."
  fi

  echo "Subscribed to receive upgrades from ${UPGRADES_FILE_LOCATION}."
  echo "Automatic upgrade enabled."
fi
