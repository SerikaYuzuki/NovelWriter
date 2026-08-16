#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SYNC_ROOT = File.join(ROOT, "docs", "sync", "v1")

def pointer_get(root, pointer)
  pointer.split("/").drop(1).inject(root) do |value, part|
    key = part.gsub("~1", "/").gsub("~0", "~")
    raise "unresolved local reference #{pointer}" unless value.is_a?(Hash) && value.key?(key)

    value.fetch(key)
  end
end

def inline_refs(node, root, stack = [])
  case node
  when Hash
    if node.key?("$ref")
      ref = node.fetch("$ref")
      raise "only local references are supported: #{ref}" unless ref.start_with?("#/")
      raise "cyclic local reference: #{(stack + [ref]).join(" -> ")}" if stack.include?(ref)

      resolved = inline_refs(pointer_get(root, ref), root, stack + [ref])
      extras = node.reject { |key, _| key == "$ref" }
      return resolved.merge(inline_refs(extras, root, stack)) if resolved.is_a?(Hash)
      return resolved if extras.empty?
      raise "reference with non-object siblings: #{ref}"
    end
    node.each_with_object({}) do |(key, value), result|
      result[key] = inline_refs(value, root, stack)
    end
  when Array
    node.map { |value| inline_refs(value, root, stack) }
  else
    node
  end
end

ANNOTATIONS = %w[$schema $id title description $comment].freeze
SET_LIKE_ARRAYS = %w[required enum].freeze

def normalize(node, parent_key = nil)
  case node
  when Hash
    normalized = node.each_with_object({}) do |(key, value), result|
      next if ANNOTATIONS.include?(key) || key.start_with?("x-fuminiwa-") || key == "$defs"

      result[key] = normalize(value, key)
    end
    normalized.sort.to_h
  when Array
    values = node.map { |value| normalize(value, parent_key) }
    SET_LIKE_ARRAYS.include?(parent_key) ? values.sort_by { |value| JSON.generate(value) } : values
  else
    node
  end
end

def walk_refs(node, root, location = "$")
  case node
  when Hash
    if node["$ref"]
      ref = node.fetch("$ref")
      raise "#{location}: non-local reference #{ref}" unless ref.start_with?("#/")

      pointer_get(root, ref)
    end
    node.each { |key, value| walk_refs(value, root, "#{location}.#{key}") }
  when Array
    node.each_with_index { |value, index| walk_refs(value, root, "#{location}[#{index}]") }
  end
end

def assert_schema_shape(schema, path)
  raise "#{path}: schema must be an object" unless schema.is_a?(Hash)
  raise "#{path}: schema must declare type" unless schema["type"]
  raise "#{path}: schema must declare $defs" unless schema["$defs"].is_a?(Hash)
end

def check_operation_ids(openapi)
  operations = []
  openapi.fetch("paths").each do |path, methods|
    methods.each do |method, operation|
      next unless operation.is_a?(Hash) && operation.key?("operationId")

      operations << [operation.fetch("operationId"), "#{method.upcase} #{path}"]
    end
  end
  ids = operations.map(&:first)
  duplicates = ids.group_by(&:itself).select { |_id, occurrences| occurrences.length > 1 }.keys
  raise "duplicate operationId: #{duplicates.join(", ")}" unless duplicates.empty?
  raise "operationId must not be empty" if ids.any?(&:empty?)
end

openapi_path = File.join(SYNC_ROOT, "openapi.yaml")
openapi = YAML.safe_load(File.read(openapi_path), aliases: true)
raise "openapi.yaml must be OpenAPI 3.1" unless openapi["openapi"] == "3.1.0"
check_operation_ids(openapi)
walk_refs(openapi, openapi)

[
  ["SnapshotManifest", "snapshot.schema.json"],
  ["PublishHeadCommand", "publish-command.schema.json"]
].each do |name, filename|
  external_path = File.join(SYNC_ROOT, filename)
  external = JSON.parse(File.read(external_path))
  assert_schema_shape(external, external_path)
  walk_refs(external, external)

  embedded = openapi.fetch("components").fetch("schemas").fetch(name)
  left = normalize(inline_refs(external, external))
  right = normalize(inline_refs(embedded, openapi))
  raise "schema equivalence failed: #{name}" unless left == right
end

puts "R0 schema equivalence: 2 external schemas, #{openapi.fetch("paths").length} paths, operationIds unique"
