-- hello: sandbox proof-of-concept.
-- If the sandbox works, 'component' and 'computer' are invisible here.

print("hello from pid " .. freax.getpid())
print("uptime: " .. string.format("%.1f", freax.uptime()) .. "s")
print("component visible to me? " .. tostring(component ~= nil))
print("(kernel says: " .. tostring(freax ~= nil) .. " for freax)")
