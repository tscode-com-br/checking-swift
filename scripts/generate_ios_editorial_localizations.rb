#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the four iOS-only editorial catalogs that do not exist in the Android dictionaries.
#
# English is the reviewed intermediary source. The generated translations are an engineering draft:
# privacy, safety and legal copy must be reviewed by a fluent human before release. The app never calls a
# translation service at runtime; this script only creates a committed, static Swift artifact.

require "json"
require "net/http"
require "set"
require "tmpdir"
require "uri"

ROOT = File.expand_path("../..", __dir__)
I18N = File.join(ROOT, "ios/Checking/Domain/I18n")
OUTPUT = File.join(I18N, "IOSAdditionalLocalization.generated.swift")
CACHE_PATH = File.join(Dir.tmpdir, "checking-ios-editorial-translations.json")
LANGUAGES = { "zh" => "zh-CN", "ms" => "ms", "id" => "id", "tl" => "tl" }.freeze
PROTECTED_TERMS = [
  "Checking", "Check-In", "Check-Out", "iPhone", "iOS", "Android", "Kotlin", "Swift", "API", "APNs",
  "FORMS", "Petrobras", "WhatsApp", "Web App", "Website", "Transport Dashboard", "LGPD", "HTTPS",
].freeze

def dictionary(path, name)
  source = File.read(path, encoding: "UTF-8")
  body = source[/^(?:private )?let #{Regexp.escape(name)}: \[String: String\] = \[\n(.*?)^\]/m, 1]
  raise "Dictionary #{name} not found in #{path}" unless body

  body.each_line.map do |line|
    stripped = line.strip
    next unless stripped.start_with?('"')
    JSON.parse("{#{stripped.delete_suffix(',')}}").first
  end.compact.to_h
end

def protect(text)
  replacements = {}
  protected_text = text.gsub(/\{[^}]+\}/) do |token|
    marker = "ZXQTOKEN#{replacements.length}QXZ"
    replacements[marker] = token
    marker
  end
  PROTECTED_TERMS.sort_by { |term| -term.length }.each do |term|
    protected_text = protected_text.gsub(term) do
      marker = "ZXQTERM#{replacements.length}QXZ"
      replacements[marker] = term
      marker
    end
  end
  [protected_text, replacements]
end

def translate(text, target, cache, cache_mutex)
  cache_key = "#{target}\u0000#{text}"
  cached = cache_mutex.synchronize { cache[cache_key] }
  return cached if cached

  protected_text, replacements = protect(text)
  uri = URI("https://translate.googleapis.com/translate_a/single")
  uri.query = URI.encode_www_form(client: "gtx", sl: "en", tl: target, dt: "t", q: protected_text)

  5.times do |attempt|
    response = Net::HTTP.get_response(uri)
    if response.is_a?(Net::HTTPSuccess)
      translated = JSON.parse(response.body).first.map { |segment| segment&.first }.compact.join
      replacements.each { |marker, original| translated.gsub!(marker, original) }
      missing = replacements.values.grep(/^\{/).reject { |token| translated.include?(token) }
      raise "Translation lost tokens #{missing.inspect}" unless missing.empty?
      cache_mutex.synchronize do
        cache[cache_key] = translated
        File.write(CACHE_PATH, JSON.generate(cache), mode: "w", encoding: "UTF-8")
      end
      return translated
    end
    sleep(2**attempt)
  rescue JSON::ParserError, IOError, SystemCallError => error
    raise error if attempt == 4
    sleep(2**attempt)
  end
  raise "Translation failed for #{target}: #{text}"
end

def polish_editorial_value(language, key, value)
  return value unless %w[ms id tl].include?(language)
  return value unless key.end_with?(".title") || key.end_with?("Title")
  return value if value.empty?

  value[0].upcase + value[1..]
end

generated = File.join(I18N, "LocalizationCatalogs.generated.swift")
portuguese = dictionary(File.join(I18N, "Localization.swift"), "ptStrings")
  .merge(dictionary(File.join(I18N, "ContentLocalization.swift"), "contentPtStrings"))
  .merge(dictionary(File.join(I18N, "IOSManualLocalization.swift"), "iosManualPtStrings"))
  .merge(dictionary(File.join(I18N, "AboutLocalization.swift"), "aboutPtStrings"))
english = dictionary(generated, "generatedEnStrings")
  .merge(dictionary(File.join(I18N, "IOSEnglishLocalization.swift"), "iosEnglishStrings"))

unless (portuguese.keys.to_set - english.keys.to_set).empty?
  raise "English must cover every iOS editorial key before generating additional languages"
end

translation_cache = File.exist?(CACHE_PATH) ? JSON.parse(File.read(CACHE_PATH, encoding: "UTF-8")) : {}
cache_mutex = Mutex.new

catalogs = LANGUAGES.to_h do |language, service_code|
  android_keys = dictionary(generated, "generated#{language.capitalize}Strings").keys.to_set
  missing_keys = portuguese.keys.to_set - android_keys
  translations = {}
  mutex = Mutex.new
  queue = Queue.new
  missing_keys.sort.each { |key| queue << key }

  workers = 6.times.map do
    Thread.new do
      loop do
        key = queue.pop(true)
        value = translate(english.fetch(key), service_code, translation_cache, cache_mutex)
        value = polish_editorial_value(language, key, value)
        mutex.synchronize do
          translations[key] = value
          warn "#{language}: #{translations.length}/#{missing_keys.length}" if (translations.length % 25).zero? || translations.length == missing_keys.length
        end
      rescue ThreadError
        break
      end
    end
  end
  workers.each(&:join)
  [language, translations]
end

swift = String.new(<<~SWIFT)
  // Generated by ios/scripts/generate_ios_editorial_localizations.rb.
  // English intermediary source; mandatory fluent-human review before release.
  import Foundation

SWIFT
catalogs.each do |language, entries|
  swift << "let ios#{language.capitalize}EditorialStrings: [String: String] = [\n"
  entries.sort.each do |key, value|
    swift << "    #{key.to_json}: #{value.to_json},\n"
  end
  swift << "]\n\n"
end
swift << <<~SWIFT
  let iosAdditionalEditorialStrings: [String: [String: String]] = [
      "zh": iosZhEditorialStrings,
      "ms": iosMsEditorialStrings,
      "id": iosIdEditorialStrings,
      "tl": iosTlEditorialStrings,
  ]
SWIFT

File.write(OUTPUT, swift, mode: "w", encoding: "UTF-8")
warn "Generated #{OUTPUT} (#{catalogs.transform_values(&:size)})"
