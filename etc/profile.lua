local shell = require("shell")

shell.setAlias("dir", "ls")
shell.setAlias("move", "mv")
shell.setAlias("rename", "mv")
shell.setAlias("copy", "cp")
shell.setAlias("del", "rm")
shell.setAlias("md", "mkdir")
shell.setAlias("cls", "clear")
shell.setAlias("rs", "redstone")
shell.setAlias("view", "edit -r")
shell.setAlias("help", "man")
shell.setAlias("l", "ls -lhp")
shell.setAlias("..", "cd ..")
shell.setAlias("df", "df -h")
shell.setAlias("grep", "grep --color")
shell.setAlias("more", "less --noback")

os.setenv("EDITOR", "/bin/edit")
os.setenv("HISTSIZE", "10")
os.setenv("IFS", " ")
os.setenv("MANPATH", "/usr/man:.")
os.setenv("PAGER", "less")
os.setenv("LS_COLORS", "di=0;36:fi=0:ln=0;33:*.lua=0;32")

local home = os.getenv("HOME") or "/home"
shell.setWorkingDirectory(home)

local home_shrc = shell.resolve(".shrc")
if freax.fsExists(home_shrc) then
  local f = freax.fsOpen(home_shrc, "r")
  if f then
    local content = ""
    while true do
      local chunk = freax.fsRead(f, 4096)
      if not chunk then break end
      content = content .. chunk
    end
    freax.fsClose(f)
    if #content > 0 then
      local ok, err = load(content, ".shrc")
      if ok then pcall(ok) end
    end
  end
end