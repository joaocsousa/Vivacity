require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_group = project.main_group.children.find { |c| c.name == 'Vivacity' || c.path == 'Vivacity' }
services_group = main_group.children.find { |c| c.name == 'Services' || c.path == 'Services' }
carvers_group = services_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' }

if carvers_group
  carvers_group.path = 'Carvers' # Explicitly set the path mapping
  puts "Fixed Carvers path in main target"
end

project.save
puts "Project saved."
