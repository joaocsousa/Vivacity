require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Main Target
main_target = project.targets.find { |t| t.name == 'Vivacity' }
main_group = project.main_group.children.find { |c| c.name == 'Vivacity' || c.path == 'Vivacity' }
services_group = main_group.children.find { |c| c.name == 'Services' || c.path == 'Services' }

file_path = 'LivePreviewService.swift'
file_ref = services_group.children.find { |c| c.path == file_path }
unless file_ref
  file_ref = services_group.new_file(file_path)
end

unless main_target.source_build_phase.files_references.include?(file_ref)
  main_target.source_build_phase.add_file_reference(file_ref)
end

# Test Target
test_target = project.targets.find { |t| t.name == 'VivacityTests' }
tests_group = project.main_group.children.find { |c| c.name == 'VivacityTests' || c.path == 'VivacityTests' }
test_services_group = tests_group.children.find { |c| c.name == 'Services' || c.path == 'Services' }

if test_services_group
    test_file_path = 'LivePreviewServiceTests.swift'
    test_file_ref = test_services_group.children.find { |c| c.path == test_file_path }
    unless test_file_ref
        test_file_ref = test_services_group.new_file(test_file_path)
    end

    unless test_target.source_build_phase.files_references.include?(test_file_ref)
        test_target.source_build_phase.add_file_reference(test_file_ref)
    end
end

project.save
puts "Added LivePreviewService files successfully."
