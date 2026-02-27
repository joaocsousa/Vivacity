require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_group = project.main_group.children.find { |c| c.name == 'Vivacity' || c.path == 'Vivacity' }
services_group = main_group.children.find { |c| c.name == 'Services' || c.path == 'Services' }
carvers_group = services_group ? services_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' } : nil

if carvers_group
  carvers_group.set_path('Carvers')
  carvers_group.source_tree = '<group>'
  
  carvers_group.children.each do |file_ref|
    # Make path just the filename so it relies on the group path
    filename = file_ref.name || file_ref.path.split('/').last
    file_ref.set_path(filename)
    file_ref.source_tree = '<group>'
  end
end

tests_group = project.main_group.children.find { |c| c.name == 'VivacityTests' || c.path == 'VivacityTests' }
test_carvers_group = tests_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' }

if test_carvers_group
  test_carvers_group.set_path('Carvers')
  test_carvers_group.source_tree = '<group>'
  
  test_carvers_group.children.each do |file_ref|
    filename = file_ref.name || file_ref.path.split('/').last
    file_ref.set_path(filename)
    file_ref.source_tree = '<group>'
  end
end

project.save
puts "Fixed paths for Carvers files"
