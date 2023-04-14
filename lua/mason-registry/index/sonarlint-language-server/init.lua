local Pkg = require "mason-core.package"
local _ = require "mason-core.functional"
local fetch = require "mason-core.fetch"
local github = require "mason-core.managers.github"
local installer = require "mason-core.installer"
local path = require "mason-core.path"
local std = require "mason-core.managers.std"

local analyzers = {
    "sonar-php-plugin",
    "sonar-javascript-plugin",
    "sonar-html-plugin",
    "sonar-go-plugin",
    -- "sonar-java-plugin", -- not yet supported by sonarlint.nvim
    "sonar-python-plugin",
    "sonar-xml-plugin",
    "sonar-text-plugin",
}

---@param group_id string
---@param artifact_id string
---@param version string
local function download_jar(group_id, artifact_id, version)
    ---@async
    return function()
        local package = _.gsub("[.]", "/", group_id)
        local outfile = ("%s.jar"):format(artifact_id)
        std.download_file(
            ("https://repox.jfrog.io/artifactory/sonarsource/%s/%s/%s/%s-%s.jar"):format(
                package,
                artifact_id,
                version,
                artifact_id,
                version
            ),
            outfile
        )
    end
end

return Pkg.new {
    name = "sonarlint-language-server",
    desc = [[SonarLint language server]],
    homepage = "https://github.com/SonarSource/sonarlint-language-server",
    languages = { Pkg.Lang.PHP, Pkg.Lang.TypeScript, Pkg.Lang.JavaScript },
    categories = { Pkg.Cat.Linter },
    ---@async
    ---@param ctx InstallContext
    install = function(ctx)
        -- follow the versions used in the VSCode extension and use the jars it uses
        local source = github.tag { repo = "SonarSource/sonarlint-vscode" }
        source.with_receipt()

        local jar_data = fetch(
            ("https://raw.githubusercontent.com/SonarSource/sonarlint-vscode/%s/scripts/dependencies.json"):format(
            source.tag)
        ):get_or_throw()
        local jar_json = vim.json.decode(jar_data)

        local download_functions = {}

        for _, info in pairs(jar_json) do
            local artifact_id = info["artifactId"]
            if artifact_id == "sonarlint-language-server" or vim.tbl_contains(analyzers, artifact_id) then
                local group_id = info["groupId"]
                local version = info["version"]
                table.insert(download_functions, download_jar(group_id, artifact_id, version))
            end
        end

        installer.run_concurrently(download_functions)

        ctx:link_bin(
            "sonarlint-language-server",
            ctx:write_shell_exec_wrapper(
                "sonarlint-language-server",
                ("java -jar %q"):format(path.concat { ctx.package:get_install_path(), "sonarlint-language-server.jar" })
            )
        )

        local shares = {}
        for _, analyzer in pairs(analyzers) do
            local filename = analyzer .. ".jar"
            shares["sonarlint-analyzers/" .. filename] = filename
        end

        ctx.links.share = shares
    end,
}
