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

# 2. Framework reference
framework_ref = project.files.find { |f| f.path == XCFRAMEWORK }
unless framework_ref
  abort("missing #{XCFRAMEWORK}") unless File.exist?(XCFRAMEWORK)

  framework_ref = project.main_group.new_reference(XCFRAMEWORK)
  target.frameworks_build_phase.add_file_reference(framework_ref, true)
  puts "linked framework: #{XCFRAMEWORK}"
end

# 3. Embed it. Python.framework is MH_DYLIB, not a static archive --
#    without an Embed Frameworks phase dyld fails at launch.
embed = target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
unless embed
  embed = target.new_copy_files_build_phase('Embed Frameworks')
  embed.dst_subfolder_spec = '10'
  embed.dst_path = ''
  puts 'created Embed Frameworks phase'
end

unless embed.files.any? { |f| f.file_ref == framework_ref }
  build_file = embed.add_file_reference(framework_ref, true)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "embedded framework: #{XCFRAMEWORK}"
end

# 4. Build settings
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
