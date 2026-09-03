#!/usr/bin/env bash
# The adapter for "no tracker configured". Every verb succeeds and does
# nothing, so a fresh install runs the whole tracking path inertly rather than
# erroring at a board it has never heard of.
# ponytail: no logging. A user who configured no tracker does not want a log
# of the tracking that did not happen.

tk_current_user()    { return 0; }
tk_project_list()    { return 0; }
tk_project_create()  { return 0; }
tk_issue_create()    { cat >/dev/null; return 0; }
tk_issue_get_status(){ return 0; }
tk_issue_status()    { return 0; }
tk_issue_describe()  { cat >/dev/null; return 0; }
tk_issue_comment()   { cat >/dev/null; return 0; }
tk_issue_title()     { return 0; }
tk_issue_label()     { return 0; }
tk_issue_property()  { return 0; }
tk_label_list()      { return 0; }
tk_label_create()    { return 0; }
tk_property_list()   { return 0; }
tk_property_create() { return 0; }
