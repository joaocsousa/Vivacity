require 'xcodeproj'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)
main_target = project.targets.find { |t| t.name == 'Vivacity' }
test_target = project.targets.find { |t| t.name == 'VivacityTests' }

def remove_all_refs_named(target, name)
    refs_to_remove = []
    target.source_build_phase.files_references.each do |ref|
        if ref.path && ref.path.include?(name)
            refs_to_remove << ref
            puts "Found bad ref #{ref.path} in #{target.name}, removing..."
        end
    end
    
    refs_to_remove.each do |ref|
        target.source_build_phase.remove_file_reference(ref)
        ref.remove_from_project
    end
end

remove_all_refs_named(main_target, 'ImageReconstructor')
remove_all_refs_named(test_target, 'ImageReconstructor')

project.save
puts "Project saved."
