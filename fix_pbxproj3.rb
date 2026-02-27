require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)
main_target = project.targets.find { |t| t.name == 'Vivacity' }
test_target = project.targets.find { |t| t.name == 'VivacityTests' }

def remove_bad_refs(target, bad_paths)
    refs_to_remove = []
    target.source_build_phase.files_references.each do |ref|
        if bad_paths.include?(ref.path)
            refs_to_remove << ref
            puts "Found bad ref #{ref.path} in #{target.name}, removing..."
        end
    end
    
    refs_to_remove.each do |ref|
        target.source_build_phase.remove_file_reference(ref)
        ref.remove_from_project
    end
end

bad = [
    'Vivacity/Services/Vivacity/Services/Carvers/ImageReconstructor.swift',
    'Vivacity/Services/ImageReconstructor.swift',
    'ImageReconstructor.swift',
    'VivacityTests/Carvers/ImageReconstructorTests.swift',
    'ImageReconstructorTests.swift'
]

remove_bad_refs(main_target, bad)
remove_bad_refs(test_target, bad)

project.save
puts "Project saved."
