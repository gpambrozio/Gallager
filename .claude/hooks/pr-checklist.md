Use the Task tool to work through these items before stopping:

1. Document Updates: Determine if any documentation needs to be updated and update them
2. Claude.md File Updates: Check if the /claude.md file or any related files require updates and update them.
3. New Feature cli addition:
   * For new features consider if adding a new command to the cli would add value to users. If it does then add the command and make sure to update both the cli documents and the `gallager` skill that ships with claude and codex plugins.
4. New Feature End-to-End Scenario:
    * If a new feature is introduced, an end-to-end scenario **must** be created and run to prove the feature's functionality.
    * The scenario must contain screenshots that clearly show the feature working as intended.
    * Look at all screenshots to make sure they reflect what you'd expect.
    * Commit the baseline images.
5. Bug Fix Scenario:
    * If a bug is being fixed, a scenario **must** be created that consistently reproduces the bug without the fix.
    * The same scenario must then demonstrate that the fix successfully resolves the bug.
    * Include screenshots showing the scenario reproducing the bug as comments in the pull request
    * Commit the baseline images.
6. Check if scenarios need to be updated
    * If this pr changes behavior that was tested on a scenario update the scenario
    * Run the scenario to make sure it passes.
    * Remove baselines that will change so that ci updates them
    * If the behavior has no scenario testing it then create it, make sure it passes and make sure the screenshots show what you'd expect.
7. Make sure no scenario baslines are pushed
    * If e2e scenarios are added or updated do not push any baseline screenshots created on this machine. Only ci runs must update baselines. Removing baselines that need to be updated is OK.
8. Add #Preview to new views
    * If new SwiftUI views were created add a #Preview so that the user can use XCode to tweak its designs easily. If the view can have many states create a preview for every state.
