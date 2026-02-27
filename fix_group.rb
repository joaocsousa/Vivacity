require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_group = project.main_group.children.find { |c| c.name == 'Vivacity' || c.path == 'Vivacity' }
services_group = main_group.children.find { |c| c.name == 'Services' || c.path == 'Services' }
carvers_group = services_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' }

if carvers_group
  file_ref = carvers_group.children.find { |c| c.path == 'ImageReconstructor.swift' }
  if file_ref
    file_ref.set_path('ImageReconstructor.swift')
    file_ref.set_source_tree('<group>')
    puts "Fixed Vivacity target ImageReconstructor.swift path"
  end
end

tests_group = project.main_group.children.find { |c| c.name == 'VivacityTests' || c.path == 'VivacityTests' }
test_carvers_group = tests_group.children.find { |c| c.name == 'Carvers' || c.path == 'Carvers' }

if test_carvers_group
  test_file_ref = test_carvers_group.children.find { |c| c.path == 'ImageReconstructorTests.swift' }
  if test_file_ref
    test_file_ref.set_path('ImageReconstructorTests.swift')
    test_file_ref.set_source_tree('<group>')
    puts "Fixed VivacityTests target ImageReconstructorTests.swift path"
  end
end

project.save
puts "Project saved successfully."
