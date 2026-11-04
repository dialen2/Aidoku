#!/usr/bin/env ruby
# Injects the embedded CPython runtime into the Aidoku Xcode project.
# Run from the repository root: ruby scripts/inject_python.rb

require 'xcodeproj'

PROJ = 'Aidoku.xcodeproj'
XCFRAMEWORK = 'Frameworks/Python.xcframework'
BRIDGING = 'Aidoku/Aidoku-Bridging-Header.h'

project = Xcodeproj::Project.open(PROJ)
target = project.targets.find { |t| t.name == 'Aidoku' }
abort('Aidoku target not found') unless target

# 1. Swift sources
Dir.glob('Aidoku/Python/*.swift').sort.each do |path|
  next if project.files.any? { |f| f.path == path }

  ref = project.main_group.new_reference(path)
  target.add_file_references([ref])
  puts "added source: #{path}"
end

# 2. Python.xcframework (static, do not embed)
unless project.files.any? { |f| f.path == XCFRAMEWORK }
  abort("missing #{XCFRAMEWORK}") unless File.exist?(XCFRAMEWORK)

  ref = project.main_group.new_reference(XCFRAMEWORK)
  target.frameworks_build_phase.add_file_reference(ref, true)
  puts "linked framework: #{XCFRAMEWORK}"
end

# 3. Build settings
target.build_configurations.each do |config|
  settings = config.build_settings

  settings['SWIFT_OBJC_BRIDGING_HEADER'] = BRIDGING
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'

  flags = Array(settings['OTHER_LDFLAGS'] || ['$(inherited)'])
  flags << '-framework' << 'Python' unless flags.include?('Python')
  settings['OTHER_LDFLAGS'] = flags
end

project.save
puts 'project patched'
