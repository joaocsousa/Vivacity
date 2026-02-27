require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)

puts "=== Analyzing Main Target ==="
main_target = project.targets.find { |t| t.name == 'Vivacity' }
main_target.source_build_phase.files_references.each do |ref|
  if ref.path && ref.path.include?('ImageReconstructor')
    puts "Found file reference: #{ref.path}"
    puts "  UUID: #{ref.uuid}"
    puts "  Source Tree: #{ref.source_tree}"
    puts "  Real Path (via hierarchy): #{ref.real_path}"
    
    # Trace up the hierarchy
    parent = ref.parent
    path = []
    while parent && parent.respond_to?(:path)
      path.unshift(parent.path || parent.name || '<root>')
      parent = parent.parent
    end
    puts "  Group Path: #{path.join('/')}"
  end
end

puts "\n=== Analyzing Test Target ==="
test_target = project.targets.find { |t| t.name == 'VivacityTests' }
test_target.source_build_phase.files_references.each do |ref|
  if ref.path && ref.path.include?('ImageReconstructor')
    puts "Found file reference: #{ref.path}"
    puts "  UUID: #{ref.uuid}"
    puts "  Source Tree: #{ref.source_tree}"
    puts "  Real Path (via hierarchy): #{ref.real_path}"
    
    # Trace up the hierarchy
    parent = ref.parent
    path = []
    while parent && parent.respond_to?(:path)
      path.unshift(parent.path || parent.name || '<root>')
      parent = parent.parent
    end
    puts "  Group Path: #{path.join('/')}"
  end
end

