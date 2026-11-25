-- Run with osascript and the bundle identifier of a running AIStats test build.
on run argv
    set bundleID to item 1 of argv
    tell application "System Events"
        tell (first application process whose bundle identifier is bundleID)
            if value of attribute "AXIdentifier" of menu bar item 1 of menu bar 1 is not "aistats.statusItem" then error "Unexpected status item."
            if exists (first UI element of menu bar item 1 of menu bar 1 whose role is "AXPopover") then error "Close the popover before running this check."
            click menu bar item 1 of menu bar 1
            try
                repeat 30 times
                    if exists (first UI element of menu bar item 1 of menu bar 1 whose role is "AXPopover") then exit repeat
                    delay 0.1
                end repeat
                tell (first UI element of menu bar item 1 of menu bar 1 whose role is "AXPopover")
                    if value of attribute "AXIdentifier" is not "aistats.popover" then error "Unexpected popover identifier."
                    if (count of UI elements) is 0 then error "Popover has no accessible content."
                end tell
            on error reason
                if exists (first UI element of menu bar item 1 of menu bar 1 whose role is "AXPopover") then click menu bar item 1 of menu bar 1
                error reason
            end try
            click menu bar item 1 of menu bar 1
            repeat 30 times
                if not (exists (first UI element of menu bar item 1 of menu bar 1 whose role is "AXPopover")) then return "Popover opened, exposed content, and closed."
                delay 0.1
            end repeat
            error "Popover stayed open."
        end tell
    end tell
end run
