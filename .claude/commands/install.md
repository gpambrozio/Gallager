---
name: install
description: Install app on one or multiple targets
argument-hint: Can be all or any compination of ios, mac or server
allowed-tools:
  - Bash(op signin *)
  - Bash(osascript *)
  - Bash(scripts/deploy.sh)
  - Bash(*/ClaudeCodePlugins/XcodeBuildTools/*/scripts/*.py)
  - Skill(XcodeBuildTools:*)
---

Look at $ARGUMENTS and only install on the targets asked. If none or "all" are specified execute all. Always follow the order below:

* Execute `op signin --account OKIDD7RZWVFWPDPZSBA4O4BSPI` to make sure credentials are ready for the server deploy script. Only need to execute this if "server" is in $ARGUMENTS or if installing all.
* Kill the MacOS app using `osascript -e 'quit app "Gallager"'`. Only do this in "all" mode or if "mac" is specified in $ARGUMENTS
* Redeploy the server using the `scripts/deploy.sh` script. If this fails stop and let the user know there's an issue, what the issue is and suggest how to fix it. Only do this in "all" mode or if "server" is specified in $ARGUMENTS
* Compile and restart the MacOS app. Only do this in "all" mode or if "mac" is specified in $ARGUMENTS
* Compile, install and start the app on the myiPhone ios device. Use the `device-app` skill in `XcodeBuildTools` plugin. If the device is not connected let the user know. Only do this in "all" mode or if "ios" is specified in $ARGUMENTS
