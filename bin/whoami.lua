-- whoami: print current user (M2).
io.write((os.getenv("USER") or os.getenv("LOGNAME") or "root") .. "\n")
