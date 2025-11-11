## TODOS

Instructions: Complete the next bullet in TODOS.md. Create a plan for this item only. Once you have completed the item, and I have confirmed that you are complete, mark off the item in TODOS.md with a strike through or check, then await further instructions.

### Admin UI

Note: The admin UI is now in ./installer-web. The code at ./services/admin is deprecated.
Note: In order to udpate flakes properly, don't use nixos-rebuild directly, but rather ./scripts/build.sh

- ✅ ~~On first load, the layout is different until the content is loaded. Hide the content and show a loading spinner in the middle of the screen until the page is loaded and ready~~
- ✅ ~~In each section page, "config-section" content is flush against the nav panel on the left and the right side of the page. Add margin. Same with the class "warning-box".~~
- ✅ ~~I have a 5k wide monitor. Fields are stretched ALL the way across the page. for example the hostname input box in the System page/section is about 4000px wide. Keep the admin site full screen width, but update all the pages and fields to be of reasonable max-width.~~
- ✅ ~~Update the services page to be one service per row, with a status on whether the service is running or not~~
- ✅ ~~The colored status icon next to "Status" in the left navigation area is not correct. It usually shows red even if the build succeeded.~~
- ✅ ~~Why does the admin service restart on rebuild even if there are no changes to it?~~
- ✅ ~~The "Save & Apply" button should be disabled when a build is running. If somehow it is enabled due to a race condition, the backend should check whether a build is already running, and ignore the request if so.~~
- ✅ ~~Some items in the Services list don't have clickable URLs. Why is that? Fix it. currently forgejo and freshrss are enabled but no URL is displayed for their entries on the Services page. Maybe try curl to the API to see what is different.~~
- ✅ ~~As module.nix changes, e.g. entries are added, removed, and changed, they get out of sync with the values in /etc/nixos/homefree-config.json, causing build failures. We need to create a script that removes non-existent entries, and updates existing entries if they changed. This should be called both by ./scripts/build.sh, and the admin-api when building the new config.~~
- ✅ ~~The "Save & Apply" process is not good. Instead of a modal, it instead should show a non-blocking toast notification on the bottom left of the screen that auto-dismisses after 5 seconds, then flashes the "Status" entry in the left nav for a couple seconds. Also, if the build fails, the "Status" entry in the left nav should flash until the user clicks on it.~~
- ✅ ~~For the status page, make the build log collapsable, and expand it automatically on load if a build is running or if the last build failed/status is failed.~~
- ✅ ~~An update was made so that the service config on the Services pane is written out to a JSON file at /etc/nixos/homefree-config.json.  During this update, /etc/nixos/homefree-configuration.nix was updated to import the JSON values then set them in the nix config. Apparently the JSON config and the updates to homefree-configuration.nix were not aded to the templates for these files in the installer. Add them.~~
- Add a field to the Network panel of the installer for setting the domain (at module.nix's homefree.system.domain). It is optional.
- When podman-adguardhome starts, it uses socat as a proxy so that DNS is available, but if it fails and restarts, it leaves an additional socat process behind. Fix this.
- Confirm that the installer works identically or at least very closely to the one in the "build-image" branch which this branch is based on. The original instructions were to make the admin page and web installer use the same framework and code, and I want to make sure the installer wasn't broken in the refactor.
- Having all the code in ./installer-web is not accurate. The code that is shared between the installer and the admin page should be in a shared components folder. the admin service should be moved to ./services/admin, and ./installer-web should be renamed to ./installer.
- For the status page, add various system details, the same as those in the old admin UI at services/deprecated/admin/site/components/hf-system-status.js
- The status of the system on the Status page is too simple, and only takes into account the last build. Create a system health module that takes into account the last build status, as well as whether any systemd services have failed, low disk space, lack of connectivity, and SMART status. Have it return a list of issues as warnings and errors, and a status, with error if there is at least one error, warning if there are no errorrs and at least one warning, and healthy otherwise. and display them on the Status page
