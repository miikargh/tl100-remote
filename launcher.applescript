-- TL100 Remote Web.app: opens the hand + music mode page as a small standalone Chrome window (Chrome because it needs Web Bluetooth).
--   not open          -> open it, widget-sized
--   open and in front -> minimise it (the lamp stays connected)
--   otherwise         -> bring it to the front
-- Launch with `open -g -a "TL100 Remote Web"` so the launcher itself never takes focus. Rebuild with ./build.sh
property widgetWidth : 360
property widgetHeight : 700

-- The widget is the one-tab window showing the copy of the page bundled in this app.
-- Matching on the title instead also catches ordinary browser tabs that have the page open.
on widgetId()
	tell application "Google Chrome"
		repeat with w in windows
			if (count of tabs of w) is 1 and (URL of active tab of w) contains "Web.app/Contents/Resources/tl100-remote.html" then return id of w
		end repeat
	end tell
	return missing value
end widgetId

set page to POSIX path of (path to resource "tl100-remote.html")
set wid to widgetId()
if wid is missing value then
	do shell script "open -na 'Google Chrome' --args --app=\"file://$(echo " & quoted form of page & " | sed 's/ /%20/g')\""
	repeat 50 times -- wait up to 5 s for the window, then shrink it to widget size where Chrome put it
		delay 0.1
		set wid to widgetId()
		if wid is not missing value then exit repeat
	end repeat
	tell application "Google Chrome"
		if wid is not missing value then
			set {x, y} to items 1 thru 2 of (get bounds of window id wid)
			set bounds of window id wid to {x, y, x + widgetWidth, y + widgetHeight}
		end if
		activate
	end tell
else
	tell application "Google Chrome"
		set w to window id wid
		if frontmost and (index of w is 1) and not (minimized of w) then
			set minimized of w to true
		else
			set minimized of w to false
			set index of w to 1
			activate
		end if
	end tell
end if
