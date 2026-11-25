-- Claude Tabs Link Router: during sign-in mode, receives a claude:// link and
-- hands it to Hammerspoon, which sends it to the tab that is signing in.
on open location theURL
	set f to (POSIX path of (path to home folder)) & ".hammerspoon/claude-tabs/.pending-link"
	do shell script "umask 077; printf '%s' " & quoted form of theURL & " > " & quoted form of f & "; /usr/bin/open -g 'hammerspoon://claude-tabs-link'"
end open location

on run
	display dialog "Claude Tabs Link Router forwards claude:// links while you sign in to another account. Nothing to do here." buttons {"OK"} default button 1
end run
