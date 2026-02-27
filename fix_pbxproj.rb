require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)
main_target = project.targets.find { |t| t.name == 'Vivacity' }
test_target = project.targets.find { |t| t.name == 'VivacityTests' }

def add_file(project, target, path, group_path)
    group = project.main_group
    group_path.split('/').each do |component|
        next if component.empty?
        group = group.children.find { |c| c.name == component || c.path == component } || group.new_group(component, component)
    end
    
    file_ref = group.children.find { |c| c.path == path.split('/').last }
    unless file_ref
        file_ref = group.new_file(path)
    end
    
    unless target.source_build_phase.files_references.include?(file_ref)
        target.source_build_phase.add_file_reference(file_ref)
        puts "Added #{path} to #{target.name}"
    end
end

add_file(project, main_target, 'Vivacity/Services/Carvers/ImageReconstructor.swift', 'Vivacity/Services/Carvers')
add_file(project, test_target, 'VivacityTests/Carvers/ImageReconstructorTests.swift', 'VivacityTests/Carvers')

project.save
puts "Project saved."
