require "yaml"
require "json"

path = ARGV.fetch(0)
source = File.open(path, "rb") { |file| file.read(4 * 1024 * 1024 + 1) }
abort "YAML file is too large" if source.bytesize > 4 * 1024 * 1024

begin
  doc = YAML.safe_load(source, permitted_classes: [], aliases: false)
  nodes = doc.is_a?(Hash) ? doc["proxies"] : doc
  abort "Expected a proxies list" unless nodes.is_a?(Array)
  puts JSON.generate(nodes)
rescue Psych::Exception, JSON::GeneratorError, SystemStackError
  abort "Invalid or unsupported YAML"
end
