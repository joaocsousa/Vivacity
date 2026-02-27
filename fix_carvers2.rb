require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_group = project.main_group.children.find { |c| c.name == 'Vivacity' || c.path == 'Vivacity' }
services_group = main_group.children.find { |c| c.name == 'Services' || c.path == 'Services' }
carvers_group = services_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' }

if carvers_group
  carvers_group.path = nil # Reset the group path so it inherits correctly if needed, or explicitly set children paths
  carvers_group.source_tree = '<group>'
  
  # Ensure ALL children have the correct relative path
  carvers_group.children.each do |child|
    if child.respond_to?(:set_path) && child.name
      child.set_path("Carvers/#{child.name}")
      child.set_source_tree('<group>')
    elsif child.respond_to?(:set_path) && child.path && !child.path.start_with?('Carvers/')
      child.set_path("Carvers/#{child.path}")
      child.set_source_tree('<group>')
    end
  end
  puts "Fixed Carvers paths in main target"
end

test_group = project.main_group.children.find { |c| c.name == 'VivacityTests' || c.path == 'VivacityTests' }
test_carvers_group = test_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' }

if test_carvers_group
  test_carvers_group.path = nil
  test_carvers_group.source_tree = '<group>'
  
  test_carvers_group.children.each do |child|
    if child.respond_to?(:set_path) && child.name
      child.set_path("Carvers/#{child.name}")
      child.set_source_tree('<group>')
    elsif child.respond_to?(:set_path) && child.path && !child.path.start_with?('Carvers/')
      child.set_path("Carvers/#{child.path}")
      child.set_source_tree('<group>')
    end
  end
  puts "Fixed Carvers paths in test target"
end

project.save
puts "Project saved."
