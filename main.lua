local entry = require 'velar.pkg.entry'

local function main()
    entry.router()
end

local function exception(err)
    ngx.log(ngx.ERR, debug.traceback())
    ngx.exit(ngx.HTTP_NOT_ACCEPTABLE)
end

xpcall(main, exception)
