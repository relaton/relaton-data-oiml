# frozen_string_literal: true

require "relaton/bib"

module OimlFetcher
  # Single place that owns YAML I/O for the data/ directory. Encoding,
  # location resolution, idempotency policy, and round-trip serialization
  # (via Relaton::Bib::Item) all live here.
  #
  # Five callers used to hand-roll +File.write(..., encoding: "UTF-8")+ and
  # read-modify-write. Now they all go through one interface.
  class YamlStore
    def initialize(dir)
      @dir = File.expand_path(dir)
      FileUtils.mkdir_p(@dir)
    end

    def write(name, hash, overwrite: true)
      path = path_for(name)
      return false if File.exist?(path) && !overwrite

      item = Relaton::Bib::Item.from_hash(hash, {})
      File.write(path, item.to_yaml, encoding: "UTF-8")
      true
    end

    def write_raw(name, yaml, overwrite: true)
      path = path_for(name)
      return false if File.exist?(path) && !overwrite

      File.write(path, yaml, encoding: "UTF-8")
      true
    end

    def read(name)
      YAML.safe_load(File.read(path_for(name), encoding: "UTF-8"),
                     permitted_classes: [Date, Time],
                     aliases: true)
    end

    def patch(name, overwrite: true)
      data = read(name)
      yield data
      write_raw(name, YAML.dump(data), overwrite: overwrite)
    end

    def exist?(name)
      File.exist?(path_for(name))
    end

    def each_yaml
      return enum_for(:each_yaml) unless block_given?

      Dir[File.join(@dir, "*.yaml")].sort.each do |path|
        yield File.basename(path, ".yaml"), path
      end
    end

    def path_for(name)
      name = name.sub(/\.yaml\z/, "")
      File.join(@dir, "#{name}.yaml")
    end
  end
end
