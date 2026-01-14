---
name:  restart-all
description: "Restart the whole system."
context: fork
allowed-tools:
  - Bash(op signin *)
  - Bash(osascript *)
  - Bash(ClaudeSpyPackage/deploy.sh)
  - Bash(*/ClaudeCodePlugins/XcodeBuildTools/*/scripts/*.py)
  - Skill(XcodeBuildTools:*)
---

* Execute `op signin --account OKIDD7RZWVFWPDPZSBA4O4BSPI` to make sure credentials are ready for the deploy script.
* Kill the MacOS app using `osascript -e 'quit app "ClaudeSpyServer"'`
* Redeploy the server using the `ClaudeSpyPackage/deploy.sh` script. If this fails stop and let the user know there's an issue, what the issue is and suggest how to fix it.
* Compile and restart the MacOS app.
* Compile, install and start the app on the myiPhone device. If the device is not connected let the user know.
