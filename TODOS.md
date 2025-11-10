## TODOS

Instructions: Complete the next bullet under Admin UI. Create a plan for this item only. Once you have completed the item, and I have confirmed that you are complete, mark off the item in TODOS.md with a strike through or check, then await further instructions.

### Admin UI

- ✅ ~~On first load, the layout is different until the content is loaded. Hide the content and show a loading spinner in the middle of the screen until the page is loaded and ready~~
- ✅ ~~In each section page, "config-section" content is flush against the nav panel on the left and the right side of the page. Add margin. Same with the class "warning-box".~~
- ✅ ~~I have a 5k wide monitor. Fields are stretched ALL the way across the page. for example the hostname input box in the System page/section is about 4000px wide. Keep the admin site full screen width, but update all the pages and fields to be of reasonable max-width.~~
- Update the services page to be one service per row, with a status on whether the service is running or not
- For the status page, make the build log collapsable, and expand it automatically on load if a build is runninr or if the last build failed/status is failed.
- For the status page, add various system details, the same as those in the old admin UI at services/admin/site/components/hf-system-status.js
- Confirm that the installer works identically or at least very closely to the one in the "build-image" branch which this branch is based on. The original instructions were to make the admin page and web installer use the same framework and code, and I want to make sure the installer wasn't broken in the refactor.
- The "Save & Apply" process is not good. Instead of a modal, it instead should show a non-blocking toast notification on the bottom left of the screen that auto-dismisses after 5 seconds, then flashes the "Status" entry in the left nav for a couple seconds.
- The status of the system on the Status page is too simple, and only takes into account the last build. Create a system health module that takes into account the last build status, as well as whether any systemd services have failed, low disk space, lack of connectivity, and SMART status. Have it return a list of issues as warnings and errors, and a status, with error if there is at least one error, warning if there are no errorrs and at least one warning, and healthy otherwise. and display them on the Status page
