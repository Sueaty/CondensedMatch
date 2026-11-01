# Rally Cut product scope

Rally Cut is a native iPhone video editor. The current product requirements are in [Editor_PRD.md](./Editor_PRD.md), with architecture and implementation guidance in [Editor_TECHNICAL_DESIGN.md](./Editor_TECHNICAL_DESIGN.md).

The workflow is video import → manual editing → preview → export. Editing preserves the original video and supports split, delete, restore, undo, redo, timeline scrolling, and zoom. One active editing session and its history remain in memory during background/foreground transitions. Returning to the main screen discards the session and temporary media. App relaunch starts fresh, with no saved project list.

This document supersedes the former automated match-processing proposal. The editor documents define the current scope.
