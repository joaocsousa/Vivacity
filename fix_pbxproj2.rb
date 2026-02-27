require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)
main_target = project.targets.find { |t| t.name == 'Vivacity' }
test_target = project.targets.find { |t| t.name == 'VivacityTests' }

def add_file_safe(project, target, path_relative_to_group, real_path, group_path)
    group = project.main_group
    group_path.split('/').each do |component|
        next if component.empty?
        group = group.children.find { |c| c.name == component || c.path == component } || group.new_group(component, component)
    end
    
    file_ref = group.children.find { |c| c.path == path_relative_to_group }
    unless file_ref
        file_ref = group.new_file(path_relative_to_group)
    end
    
    unless target.source_build_phase.files_references.include?(file_ref)
        target.source_build_phase.add_file_reference(file_ref)
        puts "Added #{real_path} to #{target.name}"
    end
end

# We use the relative filename for the reference inside the group
add_file_safe(project, main_target, 'ImageReconstructor.swift', 'Vivacity/Services/Carvers/ImageReconstructor.swift', 'Vivacity/Services/Carvers')
add_file_safe(project, test_target, 'ImageReconstructorTests.swift', 'VivacityTests/Carvers/ImageReconstructorTests.swift', 'VivacityTests/Carvers')

project.save
puts "Project saved."
