
db = require "lapis.db"
import Model from require "lapis.db.model"

import concat from table

class Modules extends Model
  @timestamp: true

  @search_index: [[
    to_tsvector('english', coalesce(display_name, name) || ' ' || coalesce(summary, '') || ' ' || coalesce(description, ''))
  ]]

  @name_search_index: [[
    coalesce(display_name, name)
  ]]

  @relations: {
    {"user", belongs_to: "Users"}
  }

  -- spec: parsed rockspec
  @create: (spec, user) =>
    description = spec.description or {}
    name = spec.package\lower!

    if @check_unique_constraint user_id: user.id, :name
      return nil, "Module already exists"

    Model.create @, {
      :name
      user_id: user.id
      display_name: if name != spec.package then spec.package

      current_version_id: -1

      summary: description.summary
      description: description.detailed
      license: description.license
      homepage: description.homepage
    }

  @search: (query, manifest_ids) =>
    clause = if manifest_ids
      ids = table.concat [tonumber id for id in *manifest_ids], ", "
      "and exists(select 1 from manifest_modules where manifest_id in (#{ids}) and module_id = modules.id)"

    @paginated [[
      where (to_tsquery('english', ?) @@ ]] .. @search_index .. [[ or ]] .. @name_search_index .. [[ % ?)
      ]] .. (clause or "") .. [[
      order by downloads desc
    ]], query, query, per_page: 50

  url_key: (name) => @name

  url_params: =>
    "module", user: assert(@user, "user not preloaded"), module: @

  name_for_display: =>
    @display_name or @name

  format_homepage_url: =>
    return if not @homepage or @homepage == ""

    unless @homepage\match "%w+://"
      return "http://" .. @homepage

    @homepage

  allowed_to_edit: (user) =>
    user and (user.id == @user_id or user\is_admin!)

  all_manifests: (...) =>
    import ManifestModules, Manifests from require "models"

    assocs = ManifestModules\select "where module_id = ?", @id
    manifest_ids = [db.escape_literal(a.manifest_id) for a in *assocs]

    if next manifest_ids
      Manifests\select "where id in (#{concat manifest_ids, ","}) order by name asc", ...
    else
      {}

  get_versions: =>
    unless @_versions
      import Versions from require "models"
      @_versions = Versions\select "where module_id = ?", @id

    @_versions

  count_versions: =>
    res = db.query "select count(*) as c from versions where module_id = ?", @id
    res[1].c

  delete: =>
    import Versions, ManifestModules, LinkedModules from require "models"

    if super!
      -- Remove module from manifests
      db.delete ManifestModules\table_name!, module_id: @id

      -- Remove versions
      versions = Versions\select "where module_id = ? ", @id
      for v in *versions
        v\delete!

      -- remove the link
      for link in *LinkedModules\select "where module_id = ?", @id
        link\delete!

      true

  -- copies module/versions/rocks to user
  copy_to_user: (user, take_root=false) =>
    return if user.id == @user_id

    bucket = require "storage_bucket"
    import Versions, Rocks, LinkedModules from require "models"

    module_keys = {
      "name", "display_name", "downloads", "summary", "description", "license",
      "homepage"
    }

    version_keys = {
      "version_name", "display_version_name", "rockspec_fname", "downloads",
      "rockspec_downloads", "lua_version", "source_url", "development"
    }

    rock_keys = {
      "arch", "downloads", "rock_fname"
    }

    new_module = Modules\find user_id: user.id, name: @name
    unless new_module
      params = { k, @[k] for k in *module_keys }
      params.user_id = user.id
      params.current_version_id = -1
      new_module = Model.create Modules, params

    versions = @get_versions!
    for version in *versions
      new_version = Versions\find {
        module_id: new_module.id
        version_name: version.version_name
      }

      unless new_version
        params = { k, version[k] for k in *version_keys }
        params.module_id = new_module.id
        params.rockspec_key = "#{user.id}/#{version.rockspec_fname}"

        rockspec_text = bucket\get_file version.rockspec_key
        bucket\put_file_string rockspec_text, {
          key: params.rockspec_key
          mimetype: "text/x-rockspec"
        }

        new_version = Model.create Versions, params

      rocks = version\get_rocks!
      for rock in *rocks
        new_rock = Rocks\find {
          version_id: new_version.id
          arch: rock.arch
        }

        unless new_rock
          params = { k, rock[k] for k in *rock_keys }
          params.version_id = new_version.id
          params.rock_key = "#{user.id}/#{rock.rock_fname}"

          rock_bin = bucket\get_file rock.rock_key
          bucket\put_file_string rock_bin, {
            key: params.rock_key
            mimetype: "application/x-rock"
          }

          new_rock = Model.create Rocks, params

    LinkedModules\find_or_create @id, user.id

    if take_root
      import ManifestModules, Manifests from require "models"
      root = Manifests\root!

      if mm = ManifestModules\find module_id: @id, manifest_id: root.id
        mm\delete!
        assert ManifestModules\create root, new_module

    new_module

  purge_manifests: =>
    for m in *@all_manifests fields: "id"
      m\purge!

  endorse: (user) =>
    import Endorsements from require "models"
    Endorsements\endorse user, @

  endorsement: (user) =>
    return unless user
    import Endorsements from require "models"
    Endorsements\find user_id: user.id, module_id: @id

  update_has_dev_version: =>
    @update has_dev_version: db.raw [[exists(
      select 1 from versions where module_id = modules.id
      and development
    )]]
