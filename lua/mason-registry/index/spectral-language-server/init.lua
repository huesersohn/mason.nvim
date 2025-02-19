local Optional = require "mason-core.optional"
local Pkg = require "mason-core.package"
local _ = require "mason-core.functional"
local git = require "mason-core.managers.git"
local github = require "mason-core.managers.github"
local path = require "mason-core.path"

return Pkg.new {
    name = "spectral-language-server",
    desc = _.dedent [[
        Awesome Spectral JSON/YAML linter with OpenAPI/AsyncAPI support. Spectral is a flexible object linter with out
        of the box support for OpenAPI v2 and v3, JSON Schema, and AsyncAPI.
    ]],
    homepage = "https://github.com/stoplightio/vscode-spectral",
    languages = { Pkg.Lang.JSON, Pkg.Lang.YAML },
    categories = { Pkg.Cat.LSP },
    ---@async
    ---@param ctx InstallContext
    install = function(ctx)
        local source = github.tag { repo = "stoplightio/vscode-spectral" }
        source.with_receipt()
        ctx.fs:mkdir "build"
        ctx:chdir("build", function()
            git.clone { "https://github.com/stoplightio/vscode-spectral", version = Optional.of(source.tag) }
            ctx.spawn.npm { "install" }
            ctx.spawn.node { "make", "package" }
        end)
        ctx.fs:rename(path.concat { "build", "dist", "server", "index.js" }, "spectral-language-server.js")
        ctx.fs:rmrf "build"
        ctx:link_bin(
            "spectral-language-server",
            ctx:write_node_exec_wrapper("spectral-language-server", "spectral-language-server.js")
        )
    end,
}
